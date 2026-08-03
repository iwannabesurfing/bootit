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
    @Published var editions: [CatalogItem] = []
    @Published var languages: [CatalogItem] = []
    @Published var editionIndex = 0
    @Published var languageIndex = 0

    // macOS
    @Published var macInstallers: [MacOSInstaller] = []
    @Published var selectedMacGroupTitle = ""     // e.g. "macOS Tahoe"
    @Published var selectedMacBuild = ""          // MacOSInstaller.build
    @Published var showOlderMacBuilds = false
    @Published var macInstalledApps: [URL] = []
    @Published var macAppPath = ""        // chosen existing "Install macOS *.app"

    var macOSGroups: [MacOSGroup] { MacOSGroup.group(macInstallers) }
    var selectedMacGroup: MacOSGroup? {
        let groups = macOSGroups
        return groups.first { $0.id == selectedMacGroupTitle } ?? groups.first
    }
    var selectedMacInstaller: MacOSInstaller? {
        guard let g = selectedMacGroup else { return nil }
        return g.builds.first { $0.build == selectedMacBuild } ?? g.latest
    }

    // Catalogue loading (shared)
    @Published var loadingCatalog = false
    @Published var catalogError: String?

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

    // Progress
    @Published var progress: Double = 0
    @Published var statusText = "Starting…"
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

    /// Bumped on every catalogue load; a completion whose id no longer matches
    /// has been superseded (e.g. the user switched Windows version mid-fetch)
    /// and must not write its stale results.
    private var catalogLoadID = 0

    init(privilegedCancel: @escaping () -> Void = { PrivilegedHelper.shared.cancel() }) {
        self.privilegedCancel = privilegedCancel
    }

    var osKey: String { osChoice.rawValue }
    var selectedDrive: USBDisk? {
        guard let index = diskIndex, index < disks.count else { return nil }
        return disks[index]
    }
    var canStart: Bool { selectedDrive != nil && hasAcknowledgedErase }

    /// Whether the options step has enough loaded to continue.
    var optionsReady: Bool {
        guard !loadingCatalog else { return false }
        return platform == .macos ? !macInstallers.isEmpty : !languages.isEmpty
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
    private func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Catalogue loaders (called when the options/source step appears)

    func loadWindowsCatalog() {
        loadingCatalog = true
        catalogError = nil
        // Clear stale results immediately so the previous version's edition/
        // language don't linger on screen while the new ones fetch.
        editions = []
        languages = []
        catalogLoadID += 1
        let loadID = catalogLoadID
        let key = osKey
        worker.async { [weak self] in
            guard let self else { return }
            do {
                let cat = MicrosoftCatalog()
                cat.register(osKey: key)
                let eds = cat.editions(osKey: key)
                let langs = try cat.languages(editionID: eds.first?.id ?? "", osKey: key)
                self.onMain {
                    guard self.catalogLoadID == loadID else { return }
                    self.editions = eds
                    self.languages = langs
                    self.editionIndex = 0
                    self.languageIndex = langs.firstIndex { $0.name.lowercased().hasPrefix("english") } ?? 0
                    self.loadingCatalog = false
                }
            } catch {
                self.onMain {
                    guard self.catalogLoadID == loadID else { return }
                    self.loadingCatalog = false
                    self.catalogError = self.message(error)
                }
            }
        }
    }

    func loadMacCatalog() {
        loadingCatalog = true
        catalogError = nil
        catalogLoadID += 1
        let loadID = catalogLoadID
        worker.async { [weak self] in
            guard let self else { return }
            let list = MacInstaller.listAvailable()
            self.onMain {
                guard self.catalogLoadID == loadID else { return }
                self.macInstallers = list
                self.selectedMacGroupTitle = list.first?.title ?? ""
                self.selectedMacBuild = list.first?.build ?? ""
                self.showOlderMacBuilds = false
                self.loadingCatalog = false
                if list.isEmpty {
                    self.catalogError = "Couldn't get the macOS installer list from Apple. Check your connection and try again."
                }
            }
        }
    }

    func loadInstalledMacApps() {
        let apps = MacInstaller.installedApps()
        macInstalledApps = apps
        if macAppPath.isEmpty, let first = apps.first { macAppPath = first.path }
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
            let result = Shell.run(DiskLister.diskutil, ["eject", drive.id])
            guard let self else { return }
            self.onMain {
                self.ejectError = result.ok
                    ? nil
                    : "Couldn't eject \(drive.name) — a file on it may still be open."
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
            skuID: (languageIndex < languages.count) ? languages[languageIndex].id : nil,
            localISO: localISOPath,
            bypassWin11: bypassWin11,
            macVersion: selectedMacInstaller?.version,
            macApp: macAppPath)

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
        running = false; statusText = "Starting…"
        currentPhase = nil; showsLogDetails = false; showsAdvancedWindowsOptions = false
        editions = []; languages = []; macInstallers = []
        selectedMacGroupTitle = ""; selectedMacBuild = ""; showOlderMacBuilds = false
        localISOPath = ""; macAppPath = ""; bypassWin11 = false
        catalogError = nil
    }

    private func runPipeline(_ request: BuildRequest) {
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
            // Stopping on request is not a fault. The tool's own message is
            // discarded here on purpose: "createinstallmedia exited 15" is the
            // SIGTERM *we* sent it, and reporting that as "Something went wrong"
            // — with diagnostics to copy and a hint about what to try — blames
            // the user for pressing the button we offered them.
            let cancelled = cancelFlag.isCancelled
            let msg = cancelled
                ? "Stopped before the installer was finished, so the drive is not bootable. Start over to make one."
                : message(error)
            onMain {
                self.running = false
                self.wasCancelled = cancelled
                self.statusText = cancelled ? "Cancelled" : "Error"
                self.runError = msg
                // A failure is exactly when the technical detail stops being
                // noise and starts being the thing you need. A cancellation is
                // not that moment — nothing in the log needs reading.
                self.showsLogDetails = !cancelled
                self.log(cancelled ? "\nCancelled." : "\n❌  \(msg)")
            }
        }
    }

    // MARK: Windows pipeline

    private func runWindows(_ request: BuildRequest) throws {
        let isoPath: String
        let writeBase: Double
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
                    self.setProgress(frac * 0.55, "Downloading…  \(Int(frac * 100))%  \(speed)  ETA \(eta)")
                },
                onLog: { self.log($0) }).download()
            isoPath = dest.path
            writeBase = 0.55
        } else {
            isoPath = request.localISO
            log("Using local ISO:\n\(request.localISO)")
            writeBase = 0.0
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
            let dl = MacInstaller(
                cancel: cancelFlag,
                onProgress: { frac, status in self.setProgress(frac * 0.5, status) },
                onLog: { self.log($0) })
            let source = try dl.download(version: version)
            installerApp = source.path
            // A download that happened owns the first half of the ring. One that
            // was skipped owns none of it — and the checklist says "Skipped"
            // rather than ticking green, so a bar at 2% is not contradicted by a
            // completed stage sitting above it.
            onMain { self.downloadSkipped = source.reused }
            writeBase = source.reused ? 0.0 : 0.5
        } else {
            installerApp = request.macApp
            log("Using installer:\n\(request.macApp)")
            writeBase = 0.0
        }
        try check()
        let span = 1.0 - writeBase
        try MacInstaller(
            cancel: cancelFlag,
            onProgress: { frac, status in self.setProgress(writeBase + frac * span, status) },
            onLog: { self.log($0) },
            onPhase: { self.setPhase($0) }).write(installerAppPath: installerApp, disk: request.disk)
    }

    private func check() throws {
        if cancelFlag.isCancelled { throw WriterError.cancelled }
    }
}
