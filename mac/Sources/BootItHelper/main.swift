import BootItShared
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// BootItHelper — the privileged half of BootIt.
//
// Runs as root, launched on demand by launchd from a LaunchDaemon registered
// with SMAppService. It exists for one reason: `createinstallmedia` has to write
// to a removable volume, and TCC evaluates that access against the *responsible*
// process. When the app shelled out to `osascript`, the responsible process was
// the app itself — which, as a user-launched GUI app, has no removable-volume
// grant and cannot durably hold one. The write failed with EPERM even as root.
//
// A LaunchDaemon runs in the system context with its own stable, Developer
// ID-signed identity, so it is not evaluated against the user's GUI session.
//
// Nothing here trusts its caller: every connection must satisfy a code-signing
// requirement pinned to this team and this app before a single method is served.
// ─────────────────────────────────────────────────────────────────────────────

/// Runs a tool to completion, streaming combined output line by line.
///
/// `createinstallmedia` rewrites its progress line with `\r` rather than
/// emitting new lines, so both terminators have to count as a line break or the
/// UI sees nothing for twenty minutes and then everything at once.
private final class ToolRunner {

    private let lock = NSLock()
    private var current: Process?

    func cancel() {
        lock.lock()
        let running = current
        lock.unlock()
        running?.terminate()
    }

    @discardableResult
    func run(_ launchPath: String, _ args: [String], onLine: @escaping (String) -> Void) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            onLine("Failed to launch \(launchPath): \(error.localizedDescription)")
            return -1
        }

        lock.lock(); current = process; lock.unlock()
        defer { lock.lock(); current = nil; lock.unlock() }

        let handle = pipe.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let idx = buffer.firstIndex(where: { $0 == 0x0a || $0 == 0x0d }) {
                let lineData = buffer[buffer.startIndex..<idx]
                if !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) {
                    onLine(line)
                }
                buffer.removeSubrange(buffer.startIndex...idx)
            }
        }
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) { onLine(line) }

        process.waitUntilExit()
        return process.terminationStatus
    }
}

private final class HelperService: NSObject, HelperProtocol {

    private static let diskutil = "/usr/sbin/diskutil"
    private let runner = ToolRunner()

    /// The connection this service is answering, so progress can be sent back
    /// to the app that asked for the work.
    ///
    /// Held weakly and the proxy fetched on demand — deliberately. Storing
    /// `remoteObjectProxy` in a `weak var` looks equivalent and is not: the
    /// proxy is autoreleased, so a weak reference to it is nil by the time the
    /// first callback fires. That silently cost every log line and every
    /// progress update during a 20-minute write, with no error anywhere.
    weak var connection: NSXPCConnection?

    private var client: HelperClientProtocol? {
        connection?.remoteObjectProxy as? HelperClientProtocol
    }

    private func log(_ line: String) { client?.helperDidLog(line) }
    private func progress(_ fraction: Double, _ status: String) {
        client?.helperDidProgress(fraction, status: status)
    }

    // MARK: - HelperProtocol

    func helperVersion(reply: @escaping (String) -> Void) {
        reply(HelperInfo.version)
    }

    func cancelCurrentOperation(reply: @escaping (Bool) -> Void) {
        runner.cancel()
        reply(true)
    }

    func probeWrite(volumePath: String, reply: @escaping (String?) -> Void) {
        reply(Self.writeDenialReason(at: volumePath))
    }

    func eraseDisk(_ disk: String, volumeName: String, reply: @escaping (String?) -> Void) {
        // Only ever touch a whole external disk. A caller that has somehow got
        // past the signature check still cannot aim this at "disk1s2" or a path.
        guard DiskGuard.isWholeDiskName(disk) else {
            reply("Refusing to erase \"\(disk)\" — not a whole-disk BSD name.")
            return
        }
        guard Self.isExternalDisk(disk) else {
            reply("Refusing to erase \(disk) — it is not an external disk.")
            return
        }

        // Prove we can write to this drive BEFORE destroying what is on it.
        //
        // The daemon can be denied removable-volume access by TCC without ever
        // being asked, and the denial only shows up at the very end of
        // createinstallmedia — after a 15-minute copy onto a drive that was
        // erased 15 minutes earlier. Checking first turns "your data is gone
        // and it still didn't work" into a message before anything is touched.
        if let mounted = Self.mountedVolume(onDisk: disk),
           let denial = Self.writeDenialReason(at: mounted) {
            reply(denial)
            return
        }

        let device = "/dev/\(disk)"
        log("Erasing \(device) → Mac OS Extended (Journaled) / GPT…")
        progress(0.02, "Erasing USB…")

        runner.run(Self.diskutil, ["unmountDisk", "force", device]) { _ in }

        var out = ""
        var code = runner.run(Self.diskutil,
                              ["eraseDisk", "JHFS+", volumeName, "GPT", device]) { line in
            out += line + "\n"
        }

        if code != 0 {
            // `eraseDisk` reuses the existing partition scheme, which fails with
            // -69850 on a drive already carrying a bootable or cloned layout —
            // including one BootIt itself wrote earlier. `partitionDisk` replaces
            // the scheme outright, which is the case a plain retry cannot reach.
            log("Erase failed; rewriting the partition scheme and retrying…")
            runner.run(Self.diskutil, ["unmountDisk", "force", device]) { _ in }
            var retry = ""
            code = runner.run(Self.diskutil,
                              ["partitionDisk", device, "GPT", "JHFS+", volumeName, "100%"]) { line in
                retry += line + "\n"
            }
            if code != 0 {
                reply([out, retry].filter { !$0.isEmpty }.joined(separator: "\n"))
                return
            }
        }

        log("Formatted.")
        progress(0.05, "Formatted")
        reply(nil)
    }

    func createInstallMedia(installerAppPath: String,
                            volumeName: String,
                            reply: @escaping (String?) -> Void) {

        let tool = installerAppPath + "/Contents/Resources/createinstallmedia"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            reply("This installer is missing its createinstallmedia tool — it may be incomplete.")
            return
        }
        let volume = "/Volumes/\(volumeName)"
        guard FileManager.default.fileExists(atPath: volume) else {
            reply("The formatted volume \(volume) is not mounted.")
            return
        }
        // Second gate, for the case where the drive held no mounted volume
        // before the erase and so could not be probed then. createinstallmedia
        // only discovers this at the bless step, ~15 minutes in.
        if let denial = Self.writeDenialReason(at: volume) {
            reply(denial)
            return
        }

        var tail: [String] = []
        let code = runner.run(tool, ["--volume", volume, "--nointeraction"]) { [weak self] line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            self?.log(trimmed)
            self?.report(trimmed)
            tail.append(trimmed)
            if tail.count > 40 { tail.removeFirst() }
        }

        guard code == 0 else {
            reply("createinstallmedia exited \(code).\n" + tail.suffix(12).joined(separator: "\n"))
            return
        }
        progress(1.0, "Install media ready")
        reply(nil)
    }

    // MARK: - Progress

    private var lastFraction = -1.0

    /// Map createinstallmedia's chatter onto the 0.05…1.0 slice the erase left.
    ///
    /// Monotonic on purpose: the tool restarts its counter at 0% for each of its
    /// own phases, and a bar that snaps backwards reads as a fault.
    private func report(_ line: String) {
        guard let fraction = InstallMediaProgress.fraction(for: line),
              fraction > lastFraction else { return }
        lastFraction = fraction
        progress(fraction, InstallMediaProgress.status(for: line))
    }

    // MARK: - Removable-volume access

    /// Where `disk` is currently mounted, if anywhere. Used only as a place to
    /// test whether this daemon may write to removable media at all.
    static func mountedVolume(onDisk disk: String) -> String? {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeURLKey]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: []) ?? []
        for url in mounted {
            let device = deviceNode(forVolume: url.path)
            if device?.hasPrefix(disk) == true { return url.path }
        }
        return nil
    }

    private static func deviceNode(forVolume path: String) -> String? {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return nil }
        let node = withUnsafeBytes(of: &stats.f_mntfromname) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
        guard !node.isEmpty else { return nil }
        return node.hasPrefix("/dev/") ? String(node.dropFirst(5)) : node
    }

    /// `nil` when this daemon can create a file at `path`, otherwise the reason.
    ///
    /// This performs the exact syscall createinstallmedia dies on — creating a
    /// temporary file in the volume root — rather than inferring from TCC state,
    /// which is not readable from here anyway.
    static func writeDenialReason(at path: String) -> String? {
        let probe = (path as NSString).appendingPathComponent(".bootit-write-probe")
        let fd = open(probe, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        if fd >= 0 {
            close(fd)
            unlink(probe)
            return nil
        }
        let err = errno
        if err == EEXIST {
            unlink(probe)
            return nil
        }
        guard err == EPERM || err == EACCES else {
            return "Couldn't write to \(path): \(String(cString: strerror(err)))."
        }
        return HelperInfo.needsFullDiskAccessPrefix
             + "macOS is blocking BootIt's helper from writing to removable drives."
    }

    // MARK: - Guards

    /// Ask diskutil whether this is genuinely removable/external before erasing.
    /// The app filters the list it shows, but the daemon must not depend on the
    /// caller having done that correctly.
    static func isExternalDisk(_ disk: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: diskutil)
        process.arguments = ["info", "-plist", "/dev/\(disk)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else { return false }

        let internalDisk = plist["Internal"] as? Bool ?? true
        let wholeDisk    = plist["WholeDisk"] as? Bool ?? false
        return !internalDisk && wholeDisk
    }
}

/// Exits the daemon once nothing has been talking to it for a while.
///
/// launchd starts this on demand and will start it again the moment the app
/// opens the Mach service, so staying resident buys nothing — and it costs
/// something real: a daemon that never exits is still running the binary from
/// whichever build installed it, so an updated app finds an old helper still
/// answering. That is exactly how a build with no `probeWrite` kept serving
/// requests after the method was added.
private final class IdleExit {

    private let lock = NSLock()
    private var active = 0
    private var generation = 0
    private let quiet: TimeInterval = 30

    func connectionOpened() {
        lock.lock()
        active += 1
        generation += 1
        lock.unlock()
    }

    func connectionClosed() {
        lock.lock()
        active = max(0, active - 1)
        generation += 1
        let mark = generation
        let idle = active == 0
        lock.unlock()
        guard idle else { return }

        DispatchQueue.global().asyncAfter(deadline: .now() + quiet) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let unchanged = self.generation == mark && self.active == 0
            self.lock.unlock()
            // Anything reconnecting in the meantime bumps `generation`, so a
            // long createinstallmedia followed by more work is never cut off.
            if unchanged { exit(0) }
        }
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {

    let idle = IdleExit()

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {

        // The whole security model of this daemon. Anything that cannot prove it
        // is our Developer ID-signed app never reaches a method that erases a disk.
        do {
            try connection.setCodeSigningRequirement(HelperInfo.clientRequirement)
        } catch {
            NSLog("BootItHelper: rejected a connection failing the signing requirement: \(error)")
            return false
        }

        let service = HelperService()
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = service
        connection.remoteObjectInterface = NSXPCInterface(with: HelperClientProtocol.self)
        service.connection = connection

        idle.connectionOpened()
        connection.invalidationHandler = { [idle] in idle.connectionClosed() }

        connection.resume()
        return true
    }
}

private let delegate = ListenerDelegate()
private let listener = NSXPCListener(machServiceName: HelperInfo.machServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
