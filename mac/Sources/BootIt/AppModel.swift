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
        var subtitle: String { self == .windows ? "Windows 10 or 11" : "Ventura – Tahoe" }
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
    @Published var diskIndex = 0
    @Published var refreshingDisks = false

    // Progress
    @Published var progress: Double = 0
    @Published var statusText = "Starting…"
    @Published var logText = ""
    @Published var runError: String?
    @Published var running = false

    private let worker = DispatchQueue(label: "bootit.worker", qos: .userInitiated)
    private let cancelFlag = CancelFlag()
    /// Bumped on every catalogue load; a completion whose id no longer matches
    /// has been superseded (e.g. the user switched Windows version mid-fetch)
    /// and must not write its stale results.
    private var catalogLoadID = 0

    var osKey: String { osChoice.rawValue }
    var selectedDrive: USBDisk? { diskIndex < disks.count ? disks[diskIndex] : nil }
    var canStart: Bool { selectedDrive != nil && hasAcknowledgedErase }

    /// Whether the options step has enough loaded to continue.
    var optionsReady: Bool {
        guard !loadingCatalog else { return false }
        return platform == .macos ? !macInstallers.isEmpty : !languages.isEmpty
    }

    // MARK: - Main-thread helpers

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
        worker.async { [weak self] in
            guard let self else { return }
            let found = DiskLister.external()
            self.onMain {
                self.disks = found
                if self.diskIndex >= found.count { self.diskIndex = 0 }
                self.hasAcknowledgedErase = false
                self.refreshingDisks = false
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
        cancelFlag.reset()
        runError = nil
        progress = 0
        logText = ""
        statusText = "Starting…"
        running = true
        step = .progress

        // Snapshot UI state on the main thread before going background.
        let request = BuildRequest(
            platform: platform ?? .windows,
            source: source,
            disk: disks[diskIndex].id,
            osKey: osKey,
            skuID: (languageIndex < languages.count) ? languages[languageIndex].id : nil,
            localISO: localISOPath,
            bypassWin11: bypassWin11,
            macVersion: selectedMacInstaller?.version,
            macApp: macAppPath)

        worker.async { [weak self] in self?.runPipeline(request) }
    }

    func cancel() { cancelFlag.cancel(); log("Cancelling…") }

    /// Reset to the start for "Make Another".
    func reset() {
        cancelFlag.reset()
        step = .platform
        platform = nil
        source = .download
        hasAcknowledgedErase = false
        progress = 0; logText = ""; runError = nil; running = false; statusText = "Starting…"
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
            let msg = message(error)
            onMain {
                self.running = false
                self.statusText = "Error"
                self.runError = msg
                self.log("\n❌  \(msg)")
            }
        }
    }

    // MARK: Windows pipeline

    private func runWindows(_ request: BuildRequest) throws {
        let isoPath: String
        let writeBase: Double
        if request.source == .download {
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
            onProgress: { frac, status in self.setProgress(writeBase + frac * span, "Writing USB…  \(status)") },
            onLog: { self.log($0) }).write()
    }

    // MARK: macOS pipeline

    private func runMac(_ request: BuildRequest) throws {
        let installerApp: String
        let writeBase: Double
        if request.source == .download {
            guard let version = request.macVersion else { throw MacInstallerError.noInstallersListed }
            let dl = MacInstaller(
                cancel: cancelFlag,
                onProgress: { frac, status in self.setProgress(frac * 0.5, status) },
                onLog: { self.log($0) })
            installerApp = try dl.download(version: version)
            writeBase = 0.5
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
            onLog: { self.log($0) }).write(installerAppPath: installerApp, disk: request.disk)
    }

    private func check() throws {
        if cancelFlag.isCancelled { throw WriterError.cancelled }
    }
}
