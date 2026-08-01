import AppKit
import Foundation

/// A downloadable macOS full installer, as listed by `softwareupdate`.
struct MacOSInstaller: Identifiable, Hashable {
    var id: String { build }
    let title: String     // "macOS Tahoe"
    let version: String   // "26.5"
    let build: String     // "25F71"
    let sizeKiB: Int64
    var sizeText: String { bytesHuman(sizeKiB * 1024) }
    var displayName: String { "\(title) \(version)" }
    /// Rough download time at 100 Mbps, rounded to 5 minutes.
    var etaText: String {
        let minutes = Double(sizeKiB) * 1024 * 8 / 100_000_000 / 60
        let rounded = max(5, Int((minutes / 5).rounded()) * 5)
        return "~\(rounded) min on 100 Mbps"
    }
}

/// A major macOS version (e.g. "macOS Tahoe") grouping its point-release builds.
/// Derived live from whatever `softwareupdate` returns — nothing is hardcoded,
/// so new macOS releases appear automatically.
struct MacOSGroup: Identifiable {
    let title: String                 // "macOS Tahoe"
    let builds: [MacOSInstaller]      // latest first; guaranteed non-empty (see `group`)

    /// Private so a group can only be built via `group(_:)`, which guarantees
    /// `builds` is non-empty — that invariant is what makes `latest` safe.
    private init(title: String, builds: [MacOSInstaller]) {
        self.title = title
        self.builds = builds
    }

    var id: String { title }
    var majorLabel: String { title.replacingOccurrences(of: "macOS ", with: "") }  // "Tahoe"
    var versionLabel: String { builds.first.map { String($0.version.split(separator: ".").first ?? "") } ?? "" }
    var majorInt: Int { Int(versionLabel) ?? 0 }
    var latest: MacOSInstaller { builds[0] }   // safe: builds is non-empty by construction

    /// Group a flat installer list by major version, preserving order.
    static func group(_ installers: [MacOSInstaller]) -> [MacOSGroup] {
        var order: [String] = []
        var map: [String: [MacOSInstaller]] = [:]
        for inst in installers {
            if map[inst.title] == nil { order.append(inst.title) }
            map[inst.title, default: []].append(inst)
        }
        return order.compactMap { title in
            guard let builds = map[title], !builds.isEmpty else { return nil }
            return MacOSGroup(title: title, builds: builds)
        }
    }
}

enum MacInstallerError: LocalizedError {
    case cancelled
    case noInstallersListed
    case downloadFailed(String)
    case installerAppNotFound
    case createMediaToolMissing
    case eraseFailed(String)
    case createMediaFailed(String)
    case authCancelled

    var errorDescription: String? {
        switch self {
        case .cancelled:            return "Cancelled."
        case .noInstallersListed:
            return "Couldn't get the list of macOS installers from Apple. Check your connection and try again."
        case .downloadFailed(let m): return "Downloading the macOS installer failed: \(m)"
        case .installerAppNotFound:
            return "The macOS installer app wasn't found after downloading. Try again, or use an installer already in /Applications."
        case .createMediaToolMissing:
            return "This installer is missing its createinstallmedia tool — it may be incomplete. Re-download it."
        case .eraseFailed(let m):   return "Failed to format the USB drive:\n\(m)"
        case .createMediaFailed(let m):
            return "createinstallmedia failed:\n\(m)"
        case .authCancelled:
            return "Administrator authorisation was cancelled — the macOS installer needs it to erase and write the drive."
        }
    }
}

/// Creates a bootable macOS installer USB using Apple's own tools:
/// `softwareupdate` to obtain the installer, `diskutil` to format, and
/// `createinstallmedia` (run as root via the system admin prompt) to write it.
final class MacInstaller {

    static let softwareupdate = "/usr/sbin/softwareupdate"
    static let diskutil       = "/usr/sbin/diskutil"
    static let eraseName      = "MACINSTALL"   // createinstallmedia renames it later

    private let cancel: CancelFlag
    private let onProgress: (Double, String) -> Void   // fraction 0…1 + status
    private let onLog: (String) -> Void
    /// Coarse stage changes, for the progress checklist. Purely observational.
    private let onPhase: (WritePhase) -> Void

    init(cancel: CancelFlag,
         onProgress: @escaping (Double, String) -> Void,
         onLog: @escaping (String) -> Void,
         onPhase: @escaping (WritePhase) -> Void = { _ in }) {
        self.cancel = cancel
        self.onProgress = onProgress
        self.onLog = onLog
        self.onPhase = onPhase
    }

    // MARK: - Catalogue (static, no instance needed)

    /// List installers offered by `softwareupdate --list-full-installers`.
    static func listAvailable() -> [MacOSInstaller] {
        parseInstallers(Shell.run(softwareupdate, ["--list-full-installers"]).out)
    }

    /// Parse the text output of `softwareupdate --list-full-installers`.
    /// Pure (no I/O) so it can be unit-tested against captured sample output.
    static func parseInstallers(_ output: String) -> [MacOSInstaller] {
        var out: [MacOSInstaller] = []
        for line in output.split(separator: "\n") {
            let s = String(line)
            guard s.contains("Title:") else { continue }
            guard let title = capture(s, #"Title:\s*(.+?),"#),
                  let version = capture(s, #"Version:\s*([^,]+),"#),
                  let sizeStr = capture(s, #"Size:\s*(\d+)KiB"#),
                  let build = capture(s, #"Build:\s*(\S+?)(?:,|$)"#)
            else { continue }
            out.append(MacOSInstaller(
                title: title.trimmingCharacters(in: .whitespaces),
                version: version.trimmingCharacters(in: .whitespaces),
                build: build.trimmingCharacters(in: .whitespaces),
                sizeKiB: Int64(sizeStr) ?? 0))
        }
        return out
    }

    /// The macOS release an installer bundle actually installs, e.g. "26.6".
    /// `CFBundleShortVersionString` is the *installer's* own version (21.6.01),
    /// not the OS it delivers, so it can't be used for this.
    static func platformVersion(ofInfo info: [String: Any]) -> String? {
        info["DTPlatformVersion"] as? String
    }

    static func platformVersion(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any] else { return nil }
        return platformVersion(ofInfo: info)
    }

    /// An already-downloaded installer for exactly this release, if one is here.
    static func installedInstaller(forVersion version: String) -> URL? {
        installedApps().first {
            platformVersion(of: $0) == version
                && FileManager.default.isExecutableFile(
                    atPath: $0.appendingPathComponent("Contents/Resources/createinstallmedia").path)
        }
    }

    /// `softwareupdate --fetch-full-installer` opens the installer assistant when
    /// it finishes. That window lands in front of BootIt offering to install
    /// macOS on *this* Mac — confusing at best, and genuinely destructive if
    /// someone clicks through it. BootIt caused it to appear, so BootIt closes it.
    @discardableResult
    static func closeInstallerAssistant() -> Bool {
        let assistants = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier?.hasPrefix("com.apple.InstallAssistant") == true
        }
        assistants.forEach { $0.terminate() }
        return !assistants.isEmpty
    }

    /// "Install macOS *.app" bundles already in /Applications.
    static func installedApps() -> [URL] {
        let apps = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Applications"),
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return apps.filter {
            $0.pathExtension == "app" && $0.lastPathComponent.hasPrefix("Install macOS")
        }.sorted { modDate($0) > modDate($1) }
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    // MARK: - Download

    /// Download a macOS installer to /Applications via softwareupdate, then
    /// return the path to the resulting "Install macOS *.app".
    func download(version: String) throws -> String {
        // Re-fetching ~18 GB that is already sitting in /Applications helps
        // nobody, and it is the step that triggers the installer assistant.
        if let existing = Self.installedInstaller(forVersion: version) {
            onLog("\(existing.lastPathComponent) (macOS \(version)) is already in /Applications — "
                + "using it instead of downloading it again.")
            onProgress(1.0, "Using the installer already on this Mac")
            return existing.path
        }

        onLog("Downloading macOS \(version) from Apple — this is a large download (~12–18 GB).")
        onProgress(0, "Starting download…")
        let code = Shell.runStreaming(
            Self.softwareupdate,
            ["--fetch-full-installer", "--full-installer-version", version],
            isCancelled: { self.cancel.isCancelled },
            onLine: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { self.onLog(trimmed) }
                if let p = Self.firstPercent(line) {
                    self.onProgress(Double(p) / 100, "Downloading macOS \(version)… \(p)%")
                }
            })
        if cancel.isCancelled { throw MacInstallerError.cancelled }
        if code != 0 { throw MacInstallerError.downloadFailed("softwareupdate exit \(code)") }

        // The assistant is launched by softwareupdate as it exits, so it can
        // appear a moment after the command returns.
        if Self.closeInstallerAssistant() {
            onLog("Closed the macOS installer window that opened itself.")
        }

        guard let app = Self.installedInstaller(forVersion: version) ?? Self.installedApps().first else {
            throw MacInstallerError.installerAppNotFound
        }
        onLog("Downloaded: \(app.lastPathComponent)")
        return app.path
    }

    // MARK: - Write

    func write(installerAppPath: String, disk: String) throws {
        let tool = "\(installerAppPath)/Contents/Resources/createinstallmedia"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw MacInstallerError.createMediaToolMissing
        }
        // A late-appearing assistant also keeps the installer's SharedSupport
        // image mounted, which createinstallmedia has to work around.
        if Self.closeInstallerAssistant() {
            onLog("Closed the macOS installer window that opened itself.")
        }
        try check()
        onPhase(.preparing)
        try eraseToMac(disk)
        try check()
        onPhase(.creatingInstaller)
        onLog("Writing the installer with createinstallmedia (this takes 10–20 minutes)…")
        try runCreateInstallMedia(tool: tool)
        onProgress(1.0, "Done")
        onLog("✅  macOS installer USB is ready.")
    }

    private func eraseToMac(_ disk: String) throws {
        onLog("Erasing \(disk) → Mac OS Extended (Journaled) / GPT…")
        onProgress(0.02, "Erasing USB…")
        Shell.run(Self.diskutil, ["unmountDisk", "force", disk])

        let erase = Shell.run(Self.diskutil, ["eraseDisk", "JHFS+", Self.eraseName, "GPT", disk])
        if !erase.ok {
            // `eraseDisk` keeps the existing partition scheme, which fails with
            // -69850 ("chosen size is not valid") on drives that already carry a
            // bootable or cloned layout — including one BootIt itself wrote
            // earlier. `partitionDisk` replaces the scheme outright, so it gets
            // past exactly the case a retry of the same command cannot.
            onLog("Erase failed; rewriting the partition scheme and retrying…")
            Shell.run(Self.diskutil, ["unmountDisk", "force", disk])
            let repartition = Shell.run(
                Self.diskutil, ["partitionDisk", disk, "GPT", "JHFS+", Self.eraseName, "100%"])
            guard repartition.ok else {
                let detail = [erase.err.isEmpty ? erase.out : erase.err,
                              repartition.err.isEmpty ? repartition.out : repartition.err]
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                throw MacInstallerError.eraseFailed(detail)
            }
        }
        onLog("Formatted.")
        onProgress(0.05, "Formatted")
    }

    /// Run createinstallmedia as root via the system admin prompt, streaming
    /// progress from a temp log file while the privileged command runs.
    private func runCreateInstallMedia(tool: String) throws {
        let tmp = NSTemporaryDirectory()
        let progLog = tmp + "bootit_cim_\(UUID().uuidString).log"
        let scriptPath = tmp + "bootit_cim_\(UUID().uuidString).sh"
        FileManager.default.createFile(atPath: progLog, contents: nil)

        let script = """
        #!/bin/sh
        "\(tool)" --volume "/Volumes/\(Self.eraseName)" --nointeraction > "\(progLog)" 2>&1
        """
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: scriptPath)
            try? FileManager.default.removeItem(atPath: progLog)
        }

        // Poll the log for progress while the privileged command runs.
        let pollStop = CancelFlag()
        DispatchQueue(label: "bootit.cim.poll").async {
            while !pollStop.isCancelled {
                if let txt = try? String(contentsOfFile: progLog, encoding: .utf8) {
                    self.reportCreateMediaProgress(txt)
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        // macOS attributes this dialog to the process that asks, which is the
        // osascript helper rather than BootIt. Saying so up front is better than
        // letting an unexplained "osascript wants to make changes" appear.
        onLog("Authorising… macOS will ask for your administrator password. "
            + "The dialog is titled “osascript” — that's the helper BootIt uses to run "
            + "Apple's createinstallmedia as root.")
        let result = runWithAdmin(scriptPath: scriptPath)
        pollStop.cancel()

        let finalLog = (try? String(contentsOfFile: progLog, encoding: .utf8)) ?? ""
        if result.cancelled { throw MacInstallerError.authCancelled }
        guard result.ok else {
            if !finalLog.isEmpty { onLog(finalLog) }
            throw MacInstallerError.createMediaFailed(result.message)
        }
        if finalLog.contains("Install media now available") {
            onLog("Install media now available.")
        }
    }

    private struct AdminResult {
        let ok: Bool
        let cancelled: Bool
        let message: String
    }

    /// Run a shell script as root using the native AppleScript admin prompt.
    private func runWithAdmin(scriptPath: String) -> AdminResult {
        let apple = "do shell script \"/bin/sh '\(scriptPath)'\" with administrator privileges"
        let r = Shell.run("/usr/bin/osascript", ["-e", apple])
        if r.code == 0 { return AdminResult(ok: true, cancelled: false, message: r.out) }
        let err = (r.err + r.out).lowercased()
        if err.contains("-128") || err.contains("user canceled") || err.contains("user cancelled") {
            return AdminResult(ok: false, cancelled: true, message: r.err)
        }
        return AdminResult(ok: false, cancelled: false, message: r.err.isEmpty ? r.out : r.err)
    }

    private var lastReportedFraction = -1.0
    private func reportCreateMediaProgress(_ text: String) {
        if text.contains("Install media now available") {
            onProgress(1.0, "Install media ready"); return
        }
        let copying = text.contains("Copying to disk") || text.contains("Copying boot files")
        let phase: String
        if copying {
            phase = "Copying macOS to the drive…"
        } else if text.contains("Making disk bootable") {
            phase = "Making the drive bootable…"
        } else if text.contains("Erasing") {
            phase = "Erasing the drive…"
        } else {
            phase = "Working…"
        }

        var fraction = 0.06
        if let p = Self.lastPercent(text) {
            fraction = copying ? 0.10 + Double(p) / 100 * 0.85
                               : Double(p) / 100 * 0.10
        }
        fraction = min(fraction, 0.97)
        if abs(fraction - lastReportedFraction) >= 0.005 || fraction >= 0.97 {
            lastReportedFraction = fraction
            onProgress(fraction, phase)
        }
    }

    private func check() throws {
        if cancel.isCancelled { throw MacInstallerError.cancelled }
    }

    // MARK: - Regex helpers

    private static func capture(_ s: String, _ pattern: String) -> String? {
        RegexCache.firstCapture(s, pattern)
    }

    private static func firstPercent(_ s: String) -> Int? {
        RegexCache.firstCapture(s, #"(\d+(?:\.\d+)?)%"#).map { Int(Double($0) ?? 0) }
    }

    private static func lastPercent(_ s: String) -> Int? {
        RegexCache.lastCapture(s, #"(\d+)%"#).flatMap { Int($0) }
    }
}
