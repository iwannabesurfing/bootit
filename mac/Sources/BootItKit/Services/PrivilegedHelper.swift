import BootItShared
import Foundation
import ServiceManagement

enum HelperError: LocalizedError {
    case needsApproval
    case needsFullDiskAccess(String)
    case registrationFailed(String)
    case notConnected(String)
    case operationFailed(String)
    case cancelled

    /// The pane that resolves `needsFullDiskAccess`, so the UI can offer a
    /// button instead of prose describing where to click.
    static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")

    var errorDescription: String? {
        switch self {
        case .needsFullDiskAccess(let detail):
            return """
                \(detail)

                Apple's createinstallmedia writes a file to the root of the USB drive, and \
                macOS blocks that for background helpers unless you allow it.

                Open System Settings → Privacy & Security → Full Disk Access, click +, then \
                choose BootIt in your Applications folder. Then try again.
                """
        case .needsApproval:
            return "BootIt needs an administrator's approval to install its privileged helper. "
                 + "Open System Settings → General → Login Items & Extensions, enable BootIt "
                 + "under “Allow in the Background”, then try again. macOS only accepts this "
                 + "approval from an administrator account — if this one isn't, someone who "
                 + "administers this Mac has to give it."
        case .registrationFailed(let m):
            return "Couldn't install BootIt's privileged helper: \(m)"
        case .notConnected(let m):
            return "Couldn't reach BootIt's privileged helper: \(m)"
        case .operationFailed(let m):
            return m
        case .cancelled:
            return "Cancelled."
        }
    }
}

/// Receives the helper's progress callbacks and forwards them to whoever is
/// currently driving a write.
///
/// Internal rather than private so a test can deliver a callback directly. The
/// alternative is that "a sample arriving after the run ended is ignored" stays
/// unprovable, and that is the defect this class most recently had.
final class HelperCallbacks: NSObject, HelperClientProtocol {
    var onLog: (String) -> Void = { _ in }
    var onProgress: (Double, String) -> Void = { _, _ in }
    var onSample: (CopySample) -> Void = { _ in }

    func helperDidLog(_ line: String) { onLog(line) }
    func helperDidProgress(_ fraction: Double, status: String) { onProgress(fraction, status) }

    /// A sample that will not decode is dropped, not guessed at. The only way
    /// this happens is an app and a daemon from different builds, which is a
    /// condition to survive quietly rather than to render badly.
    func helperDidSample(_ payload: Data) {
        guard let sample = try? JSONDecoder().decode(CopySample.self, from: payload) else { return }
        onSample(sample)
    }
}

/// The app's side of the privileged helper: registers the LaunchDaemon with
/// `SMAppService`, opens an XPC connection to it, and pins its code signature.
///
/// Why a daemon at all, when `osascript … with administrator privileges` also
/// gets root: TCC evaluates removable-volume access against the *responsible*
/// process, which for an osascript child is the GUI app that spawned it. The app
/// has no such grant and — being user-launched — cannot durably hold one, so
/// `createinstallmedia` failed with EPERM writing `.IAPhysicalMedia` even though
/// it was running as root. A LaunchDaemon runs in the system context under its
/// own signed identity and is not judged against the user's GUI session.
///
/// It is also the honest thing to show the user: the approval prompt names
/// BootIt, instead of an "osascript" dialog nobody asked for.
final class PrivilegedHelper {

    static let shared = PrivilegedHelper()

    /// Internal for the same reason `HelperCallbacks` is. Nothing outside this
    /// file sets these — `setHandlers`/`clearHandlers` own that.
    let callbacks = HelperCallbacks()
    private var connection: NSXPCConnection?
    private let lock = NSLock()
    /// Signalled when a call in flight must give up — the helper died, or the
    /// connection was torn down under it.
    private var inFlight: (() -> Void)?
    private var inFlightFailure: Error?

    /// Where `call()` gets the daemon from.
    ///
    /// `nil` in the app: it opens the real XPC connection. A test supplies a
    /// stand-in, because everything worth proving here is the blocking and
    /// unblocking *around* the call — an untimed wait that must survive a
    /// 40-minute write and still not outlive a dead helper — and none of that
    /// needs a root daemon to exercise.
    private let proxyProvider: (() throws -> HelperProtocol)?

    init(proxyProvider: (() throws -> HelperProtocol)? = nil) {
        self.proxyProvider = proxyProvider
    }

    // MARK: - Registration

    private var service: SMAppService { .daemon(plistName: HelperInfo.plistName) }

    var status: SMAppService.Status { service.status }

    /// Make sure a helper of *this* version is registered and reachable.
    ///
    /// Safe to call repeatedly — it is a no-op once the daemon is enabled and
    /// reports a matching version.
    func ensureReady() throws {
        switch service.status {
        case .enabled:
            break
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            throw HelperError.needsApproval
        case .notRegistered, .notFound:
            try register()
        @unknown default:
            try register()
        }

        // A daemon left behind by an older BootIt would happily answer, then
        // behave like the version that installed it. Replace it instead — but
        // never mid-write; re-registering invalidates the connection the write
        // is using.
        if !isBusy, isStale() {
            try reregister()
        }
    }

    private func register() throws {
        do {
            try service.register()
        } catch let error as NSError {
            // kSMErrorAlreadyRegistered — nothing to do.
            if error.code == 2 { return }
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                throw HelperError.needsApproval
            }
            throw HelperError.registrationFailed(error.localizedDescription)
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            throw HelperError.needsApproval
        }
    }

    private func reregister() throws {
        disconnect()
        try? service.unregister()
        try register()
    }

    /// Remove the daemon entirely. Exposed so uninstalling BootIt does not leave
    /// a root LaunchDaemon behind — installing one is only defensible if getting
    /// rid of it is equally easy.
    func uninstall() throws {
        guard !isBusy else {
            throw HelperError.operationFailed(
                "BootIt is writing a drive right now. Wait for it to finish before removing the helper.")
        }
        disconnect()
        do {
            try service.unregister()
        } catch let error as NSError {
            throw HelperError.registrationFailed(error.localizedDescription)
        }
    }

    // MARK: - Connection

    private func proxy() throws -> HelperProtocol {
        if let proxyProvider { return try proxyProvider() }

        lock.lock()
        defer { lock.unlock() }

        if connection == nil {
            let conn = NSXPCConnection(machServiceName: HelperInfo.machServiceName,
                                       options: .privileged)
            conn.remoteObjectInterface = HelperInterface.make()
            conn.exportedInterface = NSXPCInterface(with: HelperClientProtocol.self)
            conn.exportedObject = callbacks

            // Pin the daemon, so a process squatting the Mach service can't
            // pose as it and harvest what we send.
            //
            // Non-throwing: this registers the requirement and XPC invalidates
            // the connection later if the peer fails it, so there is no error to
            // catch here. The do/catch that used to wrap it threw
            // "the helper failed its signature check" from a block that could
            // never execute — a failure surfaces through `invalidationHandler`
            // below instead, which is where it actually arrives.
            conn.setCodeSigningRequirement(HelperInfo.helperRequirement)

            // Both must fail an outstanding call, not just interruption.
            // `invalidate()` is what "Remove Helper" triggers, and it fires
            // invalidationHandler only — so a write in progress used to hang on
            // its semaphore forever with no error and no recovery.
            conn.invalidationHandler = { [weak self] in
                self?.connectionFailed(HelperError.notConnected("the helper was disconnected"))
            }
            conn.interruptionHandler = { [weak self] in
                self?.connectionFailed(HelperError.notConnected("the helper stopped unexpectedly"))
            }
            conn.resume()
            connection = conn
        }

        var thrown: Error?
        let remote = connection?.remoteObjectProxyWithErrorHandler { error in
            thrown = error
        }
        if let thrown { throw HelperError.notConnected(thrown.localizedDescription) }
        guard let helper = remote as? HelperProtocol else {
            throw HelperError.notConnected("unexpected proxy type")
        }
        return helper
    }

    private func clearConnection() {
        lock.lock()
        connection = nil
        lock.unlock()
    }

    /// Abandon whatever call is waiting, and drop the connection.
    ///
    /// Internal rather than private so a test can drive it: `call()` waits
    /// *untimed*, so this is the only thing standing between a dead helper and a
    /// write that hangs forever. The two handler assignments above are one line
    /// each and are **not** covered by those tests — what is covered is what
    /// happens once one of them fires.
    func connectionFailed(_ error: Error) {
        lock.lock()
        let signal = inFlight
        inFlight = nil
        inFlightFailure = error
        connection = nil
        lock.unlock()
        signal?()
    }

    /// True while a privileged operation is outstanding. Tearing the connection
    /// down under one is the caller's mistake, not something to do silently.
    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight != nil
    }

    private func disconnect() {
        lock.lock()
        connection?.invalidate()
        connection = nil
        lock.unlock()
    }

    // MARK: - Operations
    //
    // All of these block the calling thread and must run off the main queue —
    // the same contract `Shell.run` already had, so callers don't change shape.

    /// Whether the running daemon is a different build from the one in this
    /// bundle. Compares the binary the daemon launched with, not a constant
    /// somebody has to remember to change.
    private func isStale() -> Bool {
        guard let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("BootItHelper").path else { return false }
        let expected = BinaryFingerprint.of(path: bundled)
        guard !expected.isEmpty else { return false }

        guard let running = try? currentHelperFingerprint() else {
            // An older daemon predating this method cannot answer it at all,
            // which is itself proof that it is stale.
            return true
        }
        return running != expected
    }

    private func currentHelperFingerprint() throws -> String {
        let helper = try proxy()
        var result = ""
        let done = DispatchSemaphore(value: 0)
        helper.helperFingerprint { value in
            result = value
            done.signal()
        }
        guard done.wait(timeout: .now() + 10) == .success else {
            throw HelperError.notConnected("the helper did not respond")
        }
        return result
    }

    // `currentHelperVersion()` and the `helperVersion` XPC method both lived
    // here until 2026-08-04, superseded by the fingerprint check above, which
    // cannot be forgotten the way a hand-bumped constant can.
    //
    // The first pass at this deleted the caller and kept the protocol method,
    // with a comment claiming it was the fallback for "a daemon too old to know
    // what a fingerprint is". Nothing implemented that fallback — the comment
    // described an intention, and a reviewer rightly called it a third instance
    // of the dead code the same commit claimed to be removing. It buys nothing
    // real either: a daemon that cannot answer `helperFingerprint` fails the
    // call, and a failed call already means re-register.

    func setHandlers(onLog: @escaping (String) -> Void,
                     onProgress: @escaping (Double, String) -> Void,
                     onSample: @escaping (CopySample) -> Void = { _ in }) {
        callbacks.onLog = onLog
        callbacks.onProgress = onProgress
        callbacks.onSample = onSample
    }

    /// Detach the current run's handlers.
    ///
    /// This is a singleton, so handlers set for one run stayed live until the
    /// *next* run replaced them. A sample still in flight when the run ended —
    /// which is the tail of every run, since the daemon stops sampling only after
    /// sending its reply — then reached closures belonging to work that was over:
    /// reopening a trace file that had been closed, and putting a liveness line
    /// back on a screen the user may already have left.
    ///
    /// Clearing at the end rather than only at the start makes "this run is
    /// finished" a thing the object actually knows.
    func clearHandlers() {
        callbacks.onLog = { _ in }
        callbacks.onProgress = { _, _ in }
        callbacks.onSample = { _ in }
    }

    func erase(disk: String, volumeName: String) throws {
        try call { helper, done in
            helper.eraseDisk(disk, volumeName: volumeName, reply: done)
        }
    }

    func createInstallMedia(installerAppPath: String, volumeName: String) throws {
        try call { helper, done in
            helper.createInstallMedia(installerAppPath: installerAppPath,
                                      volumeName: volumeName,
                                      reply: done)
        }
    }

    /// Ask the daemon whether it can write to `volumePath`. Returns the denial
    /// already classified, or nil if it can.
    ///
    /// Routed through `decode` like every other reply rather than handing back a
    /// raw `NSError`. This was the last call that skipped it, and the cost was
    /// not theoretical: the classification the daemon had gone to the trouble of
    /// sending — TCC refusal, or any of the ordinary reasons a write fails —
    /// was flattened to a string at the boundary, so the only caller could not
    /// tell a Full Disk Access problem from a read-only volume and had to offer
    /// the same remedy for both.
    ///
    /// The daemon's own sentence is not lost by decoding: it survives as the
    /// associated value, which is what the caller shows.
    func probeWrite(volumePath: String) throws -> HelperError? {
        let helper = try proxy()
        var result: NSError?
        let done = DispatchSemaphore(value: 0)
        helper.probeWrite(volumePath: volumePath) { reason in
            result = reason
            done.signal()
        }
        guard done.wait(timeout: .now() + 20) == .success else {
            throw HelperError.notConnected("the helper did not respond")
        }
        return result.map(Self.decode)
    }

    func cancel() {
        guard let helper = try? proxy() else { return }
        let done = DispatchSemaphore(value: 0)
        helper.cancelCurrentOperation { _ in done.signal() }
        _ = done.wait(timeout: .now() + 5)
    }

    /// Turn the daemon's reply into the app's own error type.
    ///
    /// The one distinction the app has to *act* on is Full Disk Access, because
    /// it is the only failure with a fix the user can perform — so it gets a
    /// button to the right settings pane. Everything else is shown verbatim
    /// rather than guessed at. An error from outside the daemon's own domain is
    /// passed through untouched: it came from XPC itself, and rewording it would
    /// only hide where it came from.
    static func decode(_ error: NSError) -> HelperError {
        guard error.domain == HelperInfo.errorDomain else {
            return HelperError.operationFailed(error.localizedDescription)
        }
        switch HelperFailure(rawValue: error.code) {
        case .needsFullDiskAccess:
            return HelperError.needsFullDiskAccess(error.localizedDescription)
        default:
            return HelperError.operationFailed(error.localizedDescription)
        }
    }

    /// Shared shape for "ask the helper to do something long, throw if it says no".
    ///
    /// Deliberately without a timeout: `createinstallmedia` legitimately runs for
    /// 10–20 minutes. The connection's invalidation handler is what catches a
    /// helper that dies, not a clock.
    private func call(_ body: (HelperProtocol, @escaping (NSError?) -> Void) -> Void) throws {
        var failure: NSError?
        let done = DispatchSemaphore(value: 0)

        // Registered *before* the proxy is obtained, not after.
        //
        // The other order left a window: a connection dying between `proxy()`
        // returning and this registration found `inFlight` still nil, so it had
        // nothing to signal, and the `inFlightFailure` it recorded was then
        // wiped by this very line. The reply for a call sent down a dead
        // connection never arrives, so `done.wait()` below — untimed — waited
        // for it forever. The window is small; the consequence was unbounded.
        lock.lock()
        inFlightFailure = nil
        inFlight = { done.signal() }
        lock.unlock()

        defer {
            lock.lock()
            inFlight = nil
            inFlightFailure = nil
            lock.unlock()
        }

        let helper = try proxy()

        body(helper) { error in
            failure = error
            done.signal()
        }
        // Untimed on purpose: createinstallmedia legitimately runs 10-20
        // minutes. A dead connection is caught by the handlers above, which is
        // the correct trigger — a clock would only ever be wrong.
        done.wait()

        lock.lock()
        let connectionError = inFlightFailure
        lock.unlock()

        if let connectionError { throw connectionError }
        guard let failure else { return }
        throw Self.decode(failure)
    }
}
