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

    /// The running tool's pid, for `proc_pid_rusage`. Nil between runs.
    var currentPID: pid_t? {
        lock.lock()
        defer { lock.unlock() }
        guard let process = current, process.isRunning else { return nil }
        return process.processIdentifier
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

    func probeWrite(volumePath: String, reply: @escaping (NSError?) -> Void) {
        // Scoped so this cannot be used as an as-root "can I write here?" oracle
        // against arbitrary directories. It exists to test USB drives.
        guard DiskGuard.isVolumeRootPath(volumePath) else {
            reply(HelperInfo.failure(.refused, "Refusing to probe a path outside /Volumes."))
            return
        }
        reply(Self.writeDenialReason(at: volumePath))
    }

    func eraseDisk(_ disk: String, volumeName: String, reply: @escaping (NSError?) -> Void) {
        // Only ever touch a whole external disk. A caller that has somehow got
        // past the signature check still cannot aim this at "disk1s2" or a path.
        guard DiskGuard.isWholeDiskName(disk) else {
            reply(HelperInfo.failure(.refused, "Refusing to erase \"\(disk)\" — not a whole-disk BSD name."))
            return
        }
        // `volumeName` becomes an argument to diskutil and, later, the path
        // "/Volumes/<name>" that a root process is pointed at. It needs the same
        // scrutiny `disk` gets; it previously had none.
        guard DiskGuard.isSafeVolumeName(volumeName) else {
            reply(HelperInfo.failure(.refused, "Refusing to use \"\(volumeName)\" as a volume name."))
            return
        }
        guard Self.isExternalDisk(disk) else {
            reply(HelperInfo.failure(.refused, "Refusing to erase \(disk) — it is not an external disk."))
            return
        }
        // Never let two callers erase the same drive at once.
        guard ActiveWork.claim(disk) else {
            reply(HelperInfo.failure(.busy, "Another operation is already running on \(disk)."))
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

    private func performErase(_ disk: String, volumeName: String, reply: @escaping (NSError?) -> Void) {

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

        let outcome = DiskErase.perform(
            device: device,
            volumeName: volumeName,
            format: .macOSInstaller,
            onRetry: { self.log("Erase failed; rewriting the partition scheme and retrying…") },
            run: { arguments in
                var output = ""
                let code = self.runner.run(Self.diskutil, arguments) { output += $0 + "\n" }
                return DiskErase.StepResult(ok: code == 0, output: output)
            })

        if case .failed(let detail) = outcome {
            reply(HelperInfo.failure(.operationFailed, detail))
            return
        }

        log("Formatted.")
        progress(0.05, "Formatted")
        reply(nil)
    }

    func createInstallMedia(installerAppPath: String,
                            volumeName: String,
                            reply: @escaping (NSError?) -> Void) {
        guard let disk = Self.wholeDisk(hosting: "/Volumes/\(volumeName)"),
              DiskGuard.isSafeVolumeName(volumeName) else {
            reply(HelperInfo.failure(.refused, "Refusing to write to a volume named \"\(volumeName)\"."))
            return
        }
        guard ActiveWork.claim(disk) else {
            reply(HelperInfo.failure(.busy, "Another operation is already running on \(disk)."))
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
                                           reply: @escaping (NSError?) -> Void) {

        guard DiskGuard.isSafeVolumeName(volumeName) else {
            reply(HelperInfo.failure(.refused, "Refusing to write to a volume named \"\(volumeName)\"."))
            return
        }
        // `/Applications` only, resolved first, so a symlink or `..` cannot aim
        // this somewhere the user does not control — /tmp, say.
        let appPath = (installerAppPath as NSString).standardizingPath
        guard appPath.hasPrefix("/Applications/"), !appPath.contains("..") else {
            reply(HelperInfo.failure(.refused, "Refusing to run an installer from outside /Applications."))
            return
        }
        let tool = appPath + "/Contents/Resources/createinstallmedia"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            reply(HelperInfo.failure(.refused, "This installer is missing its createinstallmedia tool — it may be incomplete."))
            return
        }
        // The single most dangerous line in this daemon is the one that execs
        // this path as root. "The client is signature-pinned" is not enough on
        // its own: that gate is exactly what this check is meant to backstop,
        // and the helper holds Full Disk Access, so a forged binary here would
        // run as root with standing access to every user's files.
        guard Self.isSignedByApple(tool) else {
            reply(HelperInfo.failure(.refused, "That createinstallmedia is not signed by Apple — refusing to run it."))
            return
        }
        let volume = "/Volumes/\(volumeName)"
        guard FileManager.default.fileExists(atPath: volume) else {
            reply(HelperInfo.failure(.refused, "The formatted volume \(volume) is not mounted."))
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
        // rather than the path. One clock for the whole phase: the timer's
        // samples and the tool's own output have to be stamped against the same
        // origin or a recorded trace cannot be replayed as one sequence.
        let clock = CopyClock()
        let stopSampling = Self.startCopySampling(
            disk: disk,
            clock: clock,
            pid: { [weak self] in self?.runner.currentPID },
            emit: { [weak self] sample in self?.sample(sample) })
        defer { stopSampling() }

        var tail: [String] = []
        let code = runner.run(tool, ["--volume", volume, "--nointeraction"]) { [weak self] line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            self?.log(trimmed)
            self?.report(trimmed)
            // The tool's own words go into the trace on their own sample, so a
            // claim about what a line means can be checked against the bytes
            // that followed it rather than argued about.
            //
            // This comment used to assert that "Making disk bootable" was the
            // only trustworthy signal that the bulk copy is over. It is not: the
            // trace this very line writes shows it arriving at 15–18% of the run,
            // twice. Recording the lines is what falsified the belief the code
            // was written on — which is the argument for recording them, and the
            // reason the reason is worth keeping accurate.
            self?.sample(CopySample(elapsed: clock.elapsed(), line: trimmed))
            tail.append(trimmed)
            if tail.count > 40 { tail.removeFirst() }
        }

        guard code == 0 else {
            reply(HelperInfo.failure(.operationFailed,
                                     "createinstallmedia exited \(code).\n"
                                     + tail.suffix(12).joined(separator: "\n")))
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

    /// Elapsed time within the copy phase, shared by the sampler and the output
    /// reader so their samples interleave into one replayable sequence.
    ///
    /// A monotonic clock, not a wall clock: `Date` moves when the machine's time
    /// is corrected, and a 40-minute run is long enough for that to happen.
    final class CopyClock {
        private let started = DispatchTime.now()
        func elapsed() -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
        }
    }

    /// Send one measurement to the app. Best-effort by design: a dropped sample
    /// costs one row of a trace and one UI tick, and must never interrupt a
    /// write that is going fine.
    private func sample(_ sample: CopySample) {
        guard let data = try? JSONEncoder().encode(sample) else { return }
        client?.helperDidSample(data)
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
    // The copy phase prints no percentages, so the daemon measures instead. It
    // measures and reports; it does not decide. Everything that turns numbers
    // into words lives in the app, as a pure function of these samples, so that
    // a wrong answer can be reproduced from a recorded trace in a second rather
    // than from a forty-minute write against a real drive.
    //
    // Three columns, because two of them are here to be disproved:
    //   • device Bytes (Write) — the signal the UI is driven from.
    //   • the tool's own rusage — suspected of measuring the buffer cache, which
    //     would make it race then freeze exactly as the filesystem does.
    //   • filesystem used bytes — the source of the bar that froze at 95% for 33
    //     minutes, kept as the control column so a trace can prove it wrong.

    /// Sample the copy every couple of seconds until the returned closure is
    /// called.
    ///
    /// A timer source rather than a `while` loop around `Thread.sleep`. The loop
    /// held one of the global pool's threads for the entire copy — up to forty
    /// minutes on a slow stick — doing nothing for all but a few microseconds of
    /// it, and could only notice the stop request when its current sleep expired.
    /// The timer occupies no thread between firings and stops on the spot.
    static func startCopySampling(disk: String?,
                                  clock: CopyClock,
                                  pid: @escaping () -> pid_t?,
                                  emit: @escaping (CopySample) -> Void) -> () -> Void {
        guard let disk else { return {} }
        let queue = DispatchQueue(label: "au.media.bootit.helper.copy-sample", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Fires immediately: the first sample is the baseline every later total
        // is measured from, and taking it late attributes whatever the drive did
        // in the meantime to nobody.
        // Leeway because two seconds is a UI cadence, not a deadline — it lets
        // the kernel coalesce this with other wakeups.
        timer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(500))
        timer.setEventHandler {
            emit(CopySample(elapsed: clock.elapsed(),
                            deviceBytes: DeviceIOCounters.bytesWritten(onDisk: disk),
                            processBytes: pid().flatMap { ProcessIOCounters.bytesWritten(pid: $0) },
                            volumeUsedBytes: volumeUsedBytes(onDisk: disk),
                            line: nil))
        }
        timer.resume()
        // Captures `timer` strongly on purpose — it is the only thing keeping the
        // source alive, and a deallocated timer source stops firing silently.
        return { timer.cancel() }
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

    // `expectedPayloadBytes` and its 1.1 overhead constant lived here until
    // 2026-08-04. They existed to be the denominator of a percentage that is no
    // longer claimed, and nothing else used them. Kept only in the research
    // record: the measurements they encoded (an 18.37 GB SharedSupport.dmg
    // produces 20.1 GB on the drive; the device writes 21.27 GB to put it there)
    // are the evidence a future denominator would be argued from, and they are
    // in docs/research and the trace fixture rather than in unreachable code.

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
    static func writeDenialReason(at path: String) -> NSError? {
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
            return HelperInfo.failure(
                .operationFailed,
                "Couldn't write to \(path): \(String(cString: strerror(err))).")
        }
        return HelperInfo.failure(
            .needsFullDiskAccess,
            "macOS is blocking BootIt's helper from writing to removable drives.")
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
        //
        // Enforcement is XPC's, not this line's. `setCodeSigningRequirement` is
        // non-throwing — it registers the requirement, and XPC invalidates the
        // connection later if the peer fails it. This used to be wrapped in a
        // do/catch returning false, which read as "reject it here" while the
        // catch could never run; the compiler had been saying so all along.
        connection.setCodeSigningRequirement(HelperInfo.clientRequirement)

        let service = HelperService()
        connection.exportedInterface = HelperInterface.make()
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
