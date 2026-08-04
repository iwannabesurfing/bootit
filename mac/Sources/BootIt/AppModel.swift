import BootItShared
import Foundation
import SwiftUI

/// Drives the whole flow for both platforms. UI reads `@Published` state; the
/// heavy work runs on a background queue and marshals updates to the main thread.
final class AppModel: ObservableObject {

    enum Step: Int, CaseIterable { case platform, source, options, usb, progress, done }

    enum Platform: String, Identifiable {
        case windows, macos
        var id: String { rawValue }
        var title: String { self == .windows ? "Windows" : "macOS" }
        // Kept version-agnostic on purpose: the macOS list comes live from
        // `softwareupdate`, so naming the newest release here would go stale.
        var subtitle: String { self == .windows ? "Windows 10 or 11" : "Ventura or later" }
        var symbol: String { self == .windows ? "pc" : "apple.logo" }
    }

    enum SourceMode { case download, local }   // local = existing ISO (Win) / installer app (mac)

    enum OSChoice: String, CaseIterable, Identifiable {
        case windows11, windows10
        var id: String { rawValue }
        var title: String { self == .windows11 ? "Windows 11" : "Windows 10" }
    }

    // Navigation
    @Published var step: Step = .platform
    @Published var platform: Platform?

    // Source
    @Published var source: SourceMode = .download
    @Published var hasAcknowledgedErase = false
    /// Drives the system confirmation shown before anything is erased.
    @Published var isConfirmingErase = false

    // Windows
    @Published var osChoice: OSChoice = .windows11
    @Published var bypassWin11 = false   // write autounattend.xml (TPM/SB/RAM + BypassNRO)
    @Published var localISOPath = ""

    /// What can be installed, and what the user has picked from it. A value
    /// type, so mutating it republishes without a nested-observable subscription.
    @Published var catalog = CatalogModel()

    // USB
    @Published var disks: [USBDisk] = []
    /// Nil until the user picks a drive — nothing destructive is ever preselected.
    @Published var diskIndex: Int?
    @Published var refreshingDisks = false
    @Published var ejectError: String?
    /// Set once the finished drive has actually been ejected, so the completion
    /// step can stop telling the user to do something they have already done.
    @Published var driveEjected = false
    /// True when the installer was already in /Applications and no download ran.
    @Published var downloadSkipped = false

    // Presentation-only disclosure state
    @Published var showsAdvancedWindowsOptions = false
    @Published var showsLogDetails = false

    /// Can this app still do the work it is about to promise? A value type, so
    /// mutating it republishes without a nested-observable subscription.
    @Published var preflight: InstallPreflight

    // Progress
    @Published var progress: Double = 0
    @Published var statusText = "Starting…"

    /// What the opaque copy phase is doing, when one is running.
    ///
    /// Non-nil only during `createinstallmedia`'s silent stretch, which is where
    /// the ring has nothing defensible to show as a percentage and shows
    /// liveness instead. Nil everywhere else, so every other phase keeps the
    /// determinate bar it has genuinely earned.
    @Published var copyState: CopyProgressState?
    @Published var logText = ""
    @Published var runError: String?
    /// True when the run stopped because the user asked it to. Distinct from
    /// `runError` being set: cancelling is an outcome, not a fault, and the two
    /// must not present the same way.
    @Published var wasCancelled = false
    @Published var running = false
    @Published var currentPhase: WritePhase?

    /// The pipeline queue. Serial, and occupied for the whole run — including the
    /// 10–20 minutes spent inside a single privileged call. Not `private` only so
    /// a test can occupy it the way a real write does; nothing else submits here.
    let worker = DispatchQueue(label: "bootit.worker", qos: .userInitiated)

    /// Cancellation must never be posted to `worker`. The operation a cancel is
    /// meant to stop is the very thing blocking that queue, so the block would
    /// not run until it had already finished. Measured 2026-08-03: two presses,
    /// then forty more minutes of writing, through to a successful completion.
    private let cancelQueue = DispatchQueue(label: "bootit.cancel", qos: .userInitiated)

    /// How a cancel reaches the privileged daemon. Injectable so the queue choice
    /// above is provable by a test instead of being re-broken a third time.
    private let privilegedCancel: () -> Void

    private let cancelFlag = CancelFlag()

    init(privilegedCancel: @escaping () -> Void = { PrivilegedHelper.shared.cancel() },
         preflight: InstallPreflight = InstallPreflight()) {
        self.privilegedCancel = privilegedCancel
        self.preflight = preflight
    }

    var osKey: String { osChoice.rawValue }
    var selectedDrive: USBDisk? {
        guard let index = diskIndex, index < disks.count else { return nil }
        return disks[index]
    }
    var canStart: Bool { selectedDrive != nil && hasAcknowledgedErase && !preflight.appWasReplaced }

    /// Whether the options step has enough loaded to continue.
    var optionsReady: Bool { catalog.isReady(for: platform) }

    // MARK: - Was this app replaced while it was open?

    /// Run every time the app comes to the front, which is the moment it
    /// matters: the user has just been in Finder dragging the new version over
    /// the old one, and is coming back to a window whose code is no longer the
    /// code in the bundle beneath it.
    ///
    /// Deliberately does not care whether a write is running. Setting the flag
    /// interrupts nothing — it gates the *next* Start and shows a banner on the
    /// steps before it, and the progress step shows neither. A run already under
    /// way holds a live connection to the daemon it started with and is safer
    /// finished than abandoned.
    ///
    /// **The reading never happens on the main thread.** It is one `stat`, and
    /// on a local disk it is measured in microseconds — but nothing constrains
    /// an `.app` to a local disk. Run from a mounted SMB or NFS share whose
    /// server has since gone away, that `stat` blocks for the mount's timeout,
    /// which is tens of seconds, on every single activation. There is no
    /// measurement that makes a synchronous main-thread filesystem call against
    /// a remote volume safe, so this does not try to be fast — it declines to
    /// be on the main thread at all. The decision it feeds is still made there,
    /// which is the single-writer discipline the rest of this subsystem uses.
    ///
    /// Two guards, both for the same hung-volume case. The flag is latched, so
    /// once it is set no further reading can change anything and asking again
    /// is pure cost. And at most one reading is ever outstanding: activations
    /// arrive far faster than a stalled mount answers, and a queue of blocked
    /// `stat`s is how one slow volume becomes an exhausted thread pool.
    func checkWhetherAppWasReplaced() {
        onMain {
            guard !self.preflight.appWasReplaced, !self.bundleReadingInFlight else { return }
            self.bundleReadingInFlight = true
            let read = self.preflight.bundleIdentity
            self.bundleReader.async { [weak self] in
                let current = read()
                self?.onMain {
                    self?.bundleReadingInFlight = false
                    self?.preflight.noteBundleReading(current)
                }
            }
        }
    }

    /// Where the reading above runs. Its own queue rather than a global one: a
    /// `stat` against a dead network mount blocks its thread for the mount's
    /// timeout, and a private queue confines that to one thread nothing else is
    /// waiting on. Not `private` only so a test can drain it; nothing else
    /// submits here.
    let bundleReader = DispatchQueue(label: "bootit.bundle-reader", qos: .utility)

    /// Touched on the main queue only, like everything else this model owns.
    private var bundleReadingInFlight = false

    // MARK: - Can the helper actually write to a USB drive?

    /// Ask before the user has committed to erasing anything, rather than after.
    ///
    /// Only for macOS: the Windows path never goes near the privileged helper,
    /// so there is no daemon for TCC to refuse and nothing here to report.
    ///
    /// The probe blocks on XPC, so it runs off the main queue — and pointedly
    /// not on `worker`, which is occupied for the entire 40 minutes of a write.
    /// Posting this there would leave the answer arriving after the run it was
    /// meant to warn about.
    /// Every read and write of the model's own state happens inside `onMain`,
    /// including the generation counter — so this is correct whichever thread
    /// calls it, rather than correct as long as every caller remembers.
    func checkUSBAccess() {
        onMain {
            guard self.platform == .macos, self.selectedDrive != nil else { return }
            let id = self.preflight.beginProbe()
            let probe = self.preflight.usbAccessProbe
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let report = probe()
                self?.onMain { self?.preflight.acceptProbe(report, id: id) }
            }
        }
    }

    // MARK: - Main-thread helpers

    // MARK: - Phases

    /// The stages this build will actually run, given the platform and source.
    var plannedPhases: [WritePhase] {
        var phases: [WritePhase] = []
        if source == .download { phases.append(.downloading) }
        phases.append(.preparing)
        if platform == .macos {
            phases.append(.creatingInstaller)   // createinstallmedia does the rest itself
        } else {
            phases.append(.copying)
            phases.append(.finalising)
        }
        return phases
    }

    /// Names the operating system where the phase allows it.
    func title(for phase: WritePhase) -> String {
        switch phase {
        case .downloading:
            return platform == .macos ? "Downloading macOS" : "Downloading \(osChoice.title)"
        case .creatingInstaller:
            return platform == .macos ? "Creating macOS installer" : phase.genericTitle
        default:
            return phase.genericTitle
        }
    }

    func state(of phase: WritePhase) -> PhaseState {
        // Checked before the .done shortcut: a skipped download is still skipped
        // after the build finishes, and claiming otherwise on the summary would
        // be the same lie a beat later.
        if phase == .downloading, downloadSkipped { return .skipped }
        if step == .done { return .done }
        let planned = plannedPhases
        guard let current = currentPhase,
              let currentIndex = planned.firstIndex(of: current),
              let index = planned.firstIndex(of: phase)
        else { return .pending }
        if index < currentIndex { return .done }
        guard index == currentIndex else { return .pending }
        if runError == nil { return .active }
        return wasCancelled ? .cancelled : .failed
    }

    private func setPhase(_ phase: WritePhase) {
        onMain { self.currentPhase = phase }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
    private func log(_ s: String) { onMain { self.logText += s + "\n" } }
    private func setProgress(_ p: Double, _ status: String) {
        onMain { self.progress = min(max(p, 0), 1); self.statusText = status }
    }

    /// The copy state machine. Lives here, fed by the daemon's measurements, and
    /// is a pure function of them — `CopyProgressModelTests` drives the identical
    /// code from a recorded trace, so the screen can be falsified without a
    /// forty-minute write.
    /// Mutated on the main queue and nowhere else. That is not a style choice:
    /// samples arrive on the XPC connection's own delivery thread while the end
    /// of a run arrives on `worker`, and this first shipped folding the sample in
    /// on whichever thread delivered it, hopping only the derived state to main.
    /// ThreadSanitizer reported the race in `ingest` and `track` and killed the
    /// test process outright.
    ///
    /// The window is not exotic — it is the tail of *every* run.
    /// `DispatchSourceTimer.cancel()` does not interrupt a handler that is
    /// already running, and the daemon stops sampling only after sending the
    /// reply that unblocks the app, so the last sample always races the end.
    ///
    /// The main queue is serial, so hopping first makes the reducer single-writer
    /// for free. It is the discipline the rest of this subsystem already uses —
    /// the daemon locks `lastFraction`, the trace writer owns a serial queue —
    /// and this was the one place it was missed.
    private var copyModel = CopyProgressModel()

    func ingest(_ sample: CopySample) {
        onMain {
            let state = self.copyModel.ingest(sample)
            self.copyState = state
            self.statusText = state.status
        }
    }

    /// Called when the copy phase ends, so a finished or failed run does not
    /// leave a liveness line describing a drive nothing is writing to.
    func endCopyReporting() {
        onMain {
            self.copyModel = CopyProgressModel()
            self.copyState = nil
        }
    }

    // MARK: - What the ring shows
    //
    // The rules themselves live in `CopyRing`, where they are a pure function of
    // the state rather than a property of the object that owns it.

    var ringValue: Double? { CopyRing.value(copyState, progress: progress) }
    var livenessSymbol: String { CopyRing.symbol(copyState) }
    var livenessIsWarning: Bool { CopyRing.isWarning(copyState) }

    private func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Catalogue loaders (called when the options/source step appears)

    func loadWindowsCatalog() {
        let loadID = catalog.beginLoad(clearingWindowsResults: true)
        let key = osKey
        worker.async { [weak self] in
            guard let self else { return }
            do {
                let cat = MicrosoftCatalog()
                cat.register(osKey: key)
                let eds = cat.editions(osKey: key)
                let langs = try cat.languages(editionID: eds.first?.id ?? "", osKey: key)
                self.onMain { self.catalog.acceptWindows(editions: eds, languages: langs, id: loadID) }
            } catch {
                let described = self.message(error)
                self.onMain { self.catalog.fail(described, id: loadID) }
            }
        }
    }

    func loadMacCatalog() {
        let loadID = catalog.beginLoad()
        worker.async { [weak self] in
            guard let self else { return }
            let list = MacInstaller.listAvailable()
            self.onMain { self.catalog.acceptMac(list, id: loadID) }
        }
    }

    func loadInstalledMacApps() {
        catalog.acceptInstalledApps(MacInstaller.installedApps())
    }

    // MARK: - Disks

    func refreshDisks() {
        refreshingDisks = true
        let previous = selectedDrive?.id
        worker.async { [weak self] in
            guard let self else { return }
            let found = DiskLister.external()
            self.onMain {
                self.disks = found
                // Track the same physical drive across a rescan. If it was
                // unplugged, select nothing — never let the selection slide onto
                // whichever drive happens to inherit its index.
                self.diskIndex = previous.flatMap { id in found.firstIndex { $0.id == id } }
                self.hasAcknowledgedErase = false
                self.refreshingDisks = false
            }
        }
    }

    /// Ejects the finished drive. Safe by construction — `diskutil eject` only
    /// unmounts a volume; it cannot alter what was written to it.
    func eject(_ drive: USBDisk) {
        ejectError = nil
        worker.async { [weak self] in
            let result = DriveEject.perform(drive)
            guard let self else { return }
            self.onMain {
                self.ejectError = result.ok ? nil : DriveEject.failureMessage(drive, result)
                self.driveEjected = result.ok
            }
        }
    }

    // MARK: - Run

    /// Immutable snapshot of the UI state a build needs, captured on the main
    /// thread before the work hops to the background queue.
    private struct BuildRequest {
        let platform: Platform
        let source: SourceMode
        let disk: String
        let osKey: String
        let skuID: String?
        let localISO: String
        let bypassWin11: Bool
        let macVersion: String?
        let macApp: String
    }

    func start() {
        // Nothing runs without a live selection — this also removes the
        // out-of-range crash the old `disks[diskIndex]` could hit if a drive
        // disappeared between selection and Start.
        guard let drive = selectedDrive else { return }
        cancelFlag.reset()
        runError = nil
        wasCancelled = false
        progress = 0
        logText = ""
        statusText = "Starting…"
        copyState = nil
        running = true
        currentPhase = nil
        showsLogDetails = false
        step = .progress

        // Snapshot UI state on the main thread before going background.
        let request = BuildRequest(
            platform: platform ?? .windows,
            source: source,
            disk: drive.id,
            osKey: osKey,
            skuID: (catalog.languageIndex < catalog.languages.count)
                ? catalog.languages[catalog.languageIndex].id : nil,
            localISO: localISOPath,
            bypassWin11: bypassWin11,
            macVersion: catalog.selectedMacInstaller?.version,
            macApp: catalog.macAppPath)

        worker.async { [weak self] in self?.runPipeline(request) }
    }

    func cancel() {
        cancelFlag.cancel()
        log("Cancelling…")
        // The flag alone only stops the pipeline between phases. Nearly all the
        // wall-clock time is inside a single privileged call, so the daemon has
        // to be told directly — and told on a queue that is not `worker`, which
        // that same call is blocking. Posting it to `worker` (as this did until
        // 2026-08-03) queues the cancel behind the operation it cancels, so the
        // message never leaves the app and the write runs to completion.
        cancelQueue.async { [privilegedCancel] in privilegedCancel() }
    }

    /// Reset to the start for "Make Another".
    func reset() {
        cancelFlag.reset()
        step = .platform
        platform = nil
        source = .download
        hasAcknowledgedErase = false
        isConfirmingErase = false
        progress = 0; logText = ""; runError = nil; wasCancelled = false
        running = false; statusText = "Starting…"; copyState = nil
        currentPhase = nil; showsLogDetails = false; showsAdvancedWindowsOptions = false
        catalog.reset()
        localISOPath = ""; bypassWin11 = false
        // Only the findings that belong to a drive. `appWasReplaced` survives a
        // reset by design — starting over does not un-replace the bundle.
        preflight.forgetDrive()
    }

    private func runPipeline(_ request: BuildRequest) {
        // However this ends — done, failed, cancelled — the copy is over, and a
        // liveness line left on screen would be describing a drive that nothing
        // is writing to.
        defer { endCopyReporting() }
        do {
            switch request.platform {
            case .windows: try runWindows(request)
            case .macos:   try runMac(request)
            }
            onMain {
                self.running = false
                self.progress = 1
                self.statusText = "Complete!"
                self.log("\n🎉  All done!")
                self.step = .done
            }
        } catch {
            // How this is reported is decided in `RunPlan`, where it is a pure
            // function of "did the user ask for this" and can be falsified
            // without a drive. All that happens here is applying it.
            let outcome = RunPlan.outcome(cancelled: cancelFlag.isCancelled,
                                          describedError: message(error))
            onMain {
                self.running = false
                self.wasCancelled = outcome.wasCancelled
                self.statusText = outcome.statusText
                self.runError = outcome.message
                self.showsLogDetails = outcome.showsLogDetails
                self.log(outcome.logLine)
            }
        }
    }

    // MARK: Windows pipeline

    private func runWindows(_ request: BuildRequest) throws {
        let isoPath: String
        // Windows never reuses an already-downloaded installer the way macOS
        // does, so the base is a property of the source alone and is known
        // before the download starts.
        let writeBase = RunPlan.writeBase(platform: .windows,
                                          source: request.source,
                                          installerWasReused: false)
        if request.source == .download {
            setPhase(.downloading)
            log("Resolving download from Microsoft…")
            let cat = MicrosoftCatalog(log: { self.log($0) })
            guard let skuID = request.skuID else { throw CatalogError.noLinks }
            let url = try cat.resolveSku(osKey: request.osKey, skuID: skuID)
            let dest = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/Windows_\(request.osKey)_\(Int(Date().timeIntervalSince1970)).iso")
            log("Saving to:\n\(dest.path)")
            try ISODownloader(
                url: url, dest: dest,
                isCancelled: { self.cancelFlag.isCancelled },
                onProgress: { frac, speed, eta in
                    // The download owns exactly the stretch the write is scaled
                    // out of, so both come from the one number.
                    self.setProgress(frac * writeBase,
                                     "Downloading…  \(Int(frac * 100))%  \(speed)  ETA \(eta)")
                },
                onLog: { self.log($0) }).download()
            isoPath = dest.path
        } else {
            isoPath = request.localISO
            log("Using local ISO:\n\(request.localISO)")
        }
        try check()
        log("\nWriting USB drive…")
        let span = 1.0 - writeBase
        try USBWriter(
            disk: request.disk, isoPath: isoPath, cancel: cancelFlag, bypassWin11: request.bypassWin11,
            onProgress: { frac, status in self.setProgress(writeBase + frac * span, status) },
            onLog: { self.log($0) },
            onPhase: { self.setPhase($0) }).write()
    }

    // MARK: macOS pipeline

    private func runMac(_ request: BuildRequest) throws {
        let installerApp: String
        let writeBase: Double
        if request.source == .download {
            setPhase(.downloading)
            guard let version = request.macVersion else { throw MacInstallerError.noInstallersListed }
            // Whether the installer was already on disk is only known once the
            // call returns, so the download's own share is the one a download
            // that genuinely runs owns. If it turns out to have been reused,
            // nothing was fetched and no progress was reported through here.
            let downloadShare = RunPlan.writeBase(platform: .macos,
                                                  source: .download,
                                                  installerWasReused: false)
            let dl = MacInstaller(
                cancel: cancelFlag,
                onProgress: { frac, status in self.setProgress(frac * downloadShare, status) },
                onLog: { self.log($0) })
            let source = try dl.download(version: version)
            installerApp = source.path
            // A download that happened owns the first half of the ring. One that
            // was skipped owns none of it — and the checklist says "Skipped"
            // rather than ticking green, so a bar at 2% is not contradicted by a
            // completed stage sitting above it.
            onMain { self.downloadSkipped = source.reused }
            writeBase = RunPlan.writeBase(platform: .macos,
                                          source: .download,
                                          installerWasReused: source.reused)
        } else {
            installerApp = request.macApp
            log("Using installer:\n\(request.macApp)")
            writeBase = RunPlan.writeBase(platform: .macos,
                                          source: .local,
                                          installerWasReused: false)
        }
        try check()
        let span = 1.0 - writeBase
        let trace = CopyTraceWriter(stamp: CopyTraceWriter.stamp())
        defer { trace.close() }
        try MacInstaller(
            cancel: cancelFlag,
            onProgress: { frac, status in self.setProgress(writeBase + frac * span, status) },
            onLog: { self.log($0) },
            onPhase: { self.setPhase($0) },
            onSample: { sample in
                trace.append(sample)
                self.ingest(sample)
            }).write(installerAppPath: installerApp, disk: request.disk)
    }

    private func check() throws {
        if cancelFlag.isCancelled { throw WriterError.cancelled }
    }
}
