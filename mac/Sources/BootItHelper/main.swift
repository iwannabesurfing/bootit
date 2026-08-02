import BootItShared
import Foundation
import Security

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

/// A thread-safe one-way flag, for stopping the copy poller.
private final class CancelBox {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Daemon-wide record of destructive work in flight.
///
/// `HelperService` is created per connection, so nothing in an instance can
/// stop two connections erasing the same disk at once. This is process-wide on
/// purpose. It also gates the idle-exit: killing the daemon while a child
/// `createinstallmedia` is running does not kill the child — it is reparented
/// to launchd and keeps writing, and the next app launch would start a second
/// write against the same drive.
enum ActiveWork {

    private static let lock = NSLock()
    private static var busyDisks = Set<String>()

    /// Claim `disk`, or return false if something is already working on it.
    static func claim(_ disk: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !busyDisks.contains(disk) else { return false }
        busyDisks.insert(disk)
        return true
    }

    static func release(_ disk: String) {
        lock.lock()
        busyDisks.remove(disk)
        lock.unlock()
    }

    static var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return busyDisks.isEmpty
    }
}

private final class HelperService: NSObject, HelperProtocol {

    private static let diskutil = "/usr/sbin/diskutil"
    /// Serial: the daemon does one destructive thing at a time, and the XPC
    /// invocation thread is never the one blocked doing it.
    fileprivate static let workQueue = DispatchQueue(label: "au.media.bootit.helper.work")
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

    func helperFingerprint(reply: @escaping (String) -> Void) {
        reply(Self.launchFingerprint)
    }

    /// Captured once, at process launch, BEFORE the app bundle can be replaced
    /// underneath us. Reading it lazily later would hash whatever new binary had
    /// been installed since and report a match that isn't one.
    static let launchFingerprint: String = {
        guard let path = Bundle.main.executablePath else { return "" }
        return BinaryFingerprint.of(path: path)
    }()

    func cancelCurrentOperation(reply: @escaping (Bool) -> Void) {
        runner.cancel()
        reply(true)
    }

    func probeWrite(volumePath: String, reply: @escaping (String?) -> Void) {
        // Scoped so this cannot be used as an as-root "can I write here?" oracle
        // against arbitrary directories. It exists to test USB drives.
        guard DiskGuard.isVolumeRootPath(volumePath) else {
            reply("Refusing to probe a path outside /Volumes.")
            return
        }
        reply(Self.writeDenialReason(at: volumePath))
    }

    func eraseDisk(_ disk: String, volumeName: String, reply: @escaping (String?) -> Void) {
        // Only ever touch a whole external disk. A caller that has somehow got
        // past the signature check still cannot aim this at "disk1s2" or a path.
        guard DiskGuard.isWholeDiskName(disk) else {
            reply("Refusing to erase \"\(disk)\" — not a whole-disk BSD name.")
            return
        }
        // `volumeName` becomes an argument to diskutil and, later, the path
        // "/Volumes/<name>" that a root process is pointed at. It needs the same
        // scrutiny `disk` gets; it previously had none.
        guard DiskGuard.isSafeVolumeName(volumeName) else {
            reply("Refusing to use \"\(volumeName)\" as a volume name.")
            return
        }
        guard Self.isExternalDisk(disk) else {
            reply("Refusing to erase \(disk) — it is not an external disk.")
            return
        }
        // Never let two callers erase the same drive at once.
        guard ActiveWork.claim(disk) else {
            reply("Another operation is already running on \(disk).")
            return
        }
        // Off the XPC invocation thread: doing the work inline blocks this
        // connection, so cancelCurrentOperation sent on it could not be
        // serviced — which is half of why Cancel did nothing.
        Self.workQueue.async {
            defer { ActiveWork.release(disk) }
            self.performErase(disk, volumeName: volumeName, reply: reply)
        }
    }

    private func performErase(_ disk: String, volumeName: String, reply: @escaping (String?) -> Void) {

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
        guard let disk = Self.wholeDisk(hosting: "/Volumes/\(volumeName)"),
              DiskGuard.isSafeVolumeName(volumeName) else {
            reply("Refusing to write to a volume named \"\(volumeName)\".")
            return
        }
        guard ActiveWork.claim(disk) else {
            reply("Another operation is already running on \(disk).")
            return
        }
        Self.workQueue.async {
            defer { ActiveWork.release(disk) }
            self.performCreateInstallMedia(installerAppPath: installerAppPath,
                                           volumeName: volumeName,
                                           disk: disk,
                                           reply: reply)
        }
    }

    private func performCreateInstallMedia(installerAppPath: String,
                                           volumeName: String,
                                           disk: String,
                                           reply: @escaping (String?) -> Void) {

        guard DiskGuard.isSafeVolumeName(volumeName) else {
            reply("Refusing to write to a volume named \"\(volumeName)\".")
            return
        }
        // `/Applications` only, resolved first, so a symlink or `..` cannot aim
        // this somewhere the user does not control — /tmp, say.
        let appPath = (installerAppPath as NSString).standardizingPath
        guard appPath.hasPrefix("/Applications/"), !appPath.contains("..") else {
            reply("Refusing to run an installer from outside /Applications.")
            return
        }
        let tool = appPath + "/Contents/Resources/createinstallmedia"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            reply("This installer is missing its createinstallmedia tool — it may be incomplete.")
            return
        }
        // The single most dangerous line in this daemon is the one that execs
        // this path as root. "The client is signature-pinned" is not enough on
        // its own: that gate is exactly what this check is meant to backstop,
        // and the helper holds Full Disk Access, so a forged binary here would
        // run as root with standing access to every user's files.
        guard Self.isSignedByApple(tool) else {
            reply("That createinstallmedia is not signed by Apple — refusing to run it.")
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

        // createinstallmedia renames the volume mid-run, so follow the device
        // rather than the path, and estimate the payload before it starts.
        let expected = Self.expectedPayloadBytes(installerAppPath: installerAppPath)
        let stopPolling = Self.startCopyPolling(disk: disk, expected: expected) { [weak self] fraction, status in
            self?.reportMeasured(fraction, status)
        }
        defer { stopPolling() }

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
    /// `lastFraction` is now written from two threads — the output reader and
    /// the byte poller — so the monotonic check and the update have to be one
    /// atomic step, or a slow poll can undo a newer value.
    private let fractionLock = NSLock()

    /// Advance to `fraction` if it is ahead of where the bar already is.
    private func advance(to fraction: Double) -> Bool {
        fractionLock.lock()
        defer { fractionLock.unlock() }
        guard fraction > lastFraction else { return false }
        lastFraction = fraction
        return true
    }

    /// Map createinstallmedia's chatter onto the 0.05…1.0 slice the erase left.
    ///
    /// Monotonic on purpose: the tool restarts its counter at 0% for each of its
    /// own phases, and a bar that snaps backwards reads as a fault.
    private func report(_ line: String) {
        guard let fraction = InstallMediaProgress.fraction(for: line),
              advance(to: fraction) else { return }
        progress(fraction, InstallMediaProgress.status(for: line))
    }

    /// Progress derived from bytes on the drive rather than from output.
    /// Shares `lastFraction` with `report` so the two sources cannot fight and
    /// send the bar backwards.
    private func reportMeasured(_ fraction: Double, _ status: String) {
        guard advance(to: fraction) else { return }
        progress(fraction, status)
    }

    // MARK: - Code signing

    /// True when `path` is signed by Apple itself.
    ///
    /// `anchor apple` — not `anchor apple generic` — accepts only Apple's own
    /// software, rather than anything Apple issued a Developer ID to.
    static func isSignedByApple(_ path: String) -> Bool {
        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement)
                == errSecSuccess,
              let requirement else { return false }

        return SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
    }

    // MARK: - Measured copy progress
    //
    // The copy phase prints no percentages, so the only honest signal is how
    // much has actually landed on the drive. Polling the target volume's used
    // space gives a bar that moves continuously for the fifteen minutes during
    // which createinstallmedia says nothing at all.

    /// Poll the target volume's used space until the returned closure is called.
    static func startCopyPolling(disk: String?,
                                 expected: Int64,
                                 report: @escaping (Double, String) -> Void) -> () -> Void {
        guard let disk else { return {} }
        let stopped = CancelBox()
        DispatchQueue.global(qos: .utility).async {
            while !stopped.isSet {
                if let used = volumeUsedBytes(onDisk: disk), used > 0 {
                    report(InstallMediaProgress.copyFraction(used: used, expected: expected),
                           InstallMediaProgress.copyStatus(used: used, expected: expected))
                }
                Thread.sleep(forTimeInterval: 2)
            }
        }
        return { stopped.set() }
    }

    /// Bytes in use on whichever volume is currently mounted from `disk`.
    ///
    /// Resolved fresh every poll because createinstallmedia renames the volume
    /// partway through — "MACINSTALL" becomes "Install macOS Tahoe", and a path
    /// captured at the start stops existing exactly when the copy gets going.
    static func volumeUsedBytes(onDisk disk: String) -> Int64? {
        guard let path = mountedVolume(onDisk: disk) else { return nil }
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return nil }
        let block = Int64(stats.f_bsize)
        let used = Int64(stats.f_blocks) - Int64(stats.f_bfree)
        return used * block
    }

    /// The whole-disk BSD name currently backing `volumePath` ("disk4s2" → "disk4").
    static func wholeDisk(hosting volumePath: String) -> String? {
        guard let node = deviceNode(forVolume: volumePath) else { return nil }
        guard let range = node.range(of: #"^disk\d+"#, options: .regularExpression) else { return nil }
        return String(node[range])
    }

    /// Rough size of what createinstallmedia will copy.
    ///
    /// SharedSupport.dmg is nearly all of it; the multiplier covers the app
    /// itself and the RecoveryOS. Measured on macOS Tahoe 26.6: an 18.37 GB dmg
    /// produced 20.1 GB on the drive, a ratio of 1.09.
    ///
    /// Deliberately erring low. Overestimating strands the bar short of the end
    /// and makes the finish a visible jump; underestimating just parks it on the
    /// 93% cap for the last few seconds, which reads as "nearly done" rather
    /// than as a fault.
    static let payloadOverhead = 1.1

    static func expectedPayloadBytes(installerAppPath: String) -> Int64 {
        let dmg = installerAppPath + "/Contents/SharedSupport/SharedSupport.dmg"
        let attributes = try? FileManager.default.attributesOfItem(atPath: dmg)
        guard let size = attributes?[.size] as? Int64, size > 0 else { return 16_000_000_000 }
        return Int64(Double(size) * payloadOverhead)
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
            // Exiting here would NOT kill a running createinstallmedia — the
            // child is reparented to launchd and keeps writing to the drive,
            // and the next app launch starts a second write against the same
            // disk. Idle means "no connections AND nothing in flight".
            if unchanged && ActiveWork.isIdle { exit(0) }
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
