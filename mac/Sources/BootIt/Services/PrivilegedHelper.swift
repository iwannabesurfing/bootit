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
            return "BootIt needs your approval to install its privileged helper. "
                 + "Open System Settings → General → Login Items & Extensions, enable BootIt "
                 + "under “Allow in the Background”, then try again."
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
private final class HelperCallbacks: NSObject, HelperClientProtocol {
    var onLog: (String) -> Void = { _ in }
    var onProgress: (Double, String) -> Void = { _, _ in }

    func helperDidLog(_ line: String) { onLog(line) }
    func helperDidProgress(_ fraction: Double, status: String) { onProgress(fraction, status) }
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

    private let callbacks = HelperCallbacks()
    private var connection: NSXPCConnection?
    private let lock = NSLock()
    /// Signalled when a call in flight must give up — the helper died, or the
    /// connection was torn down under it.
    private var inFlight: (() -> Void)?
    private var inFlightFailure: Error?

    private init() {}

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
        lock.lock()
        defer { lock.unlock() }

        if connection == nil {
            let conn = NSXPCConnection(machServiceName: HelperInfo.machServiceName,
                                       options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            conn.exportedInterface = NSXPCInterface(with: HelperClientProtocol.self)
            conn.exportedObject = callbacks

            // Pin the daemon, so a process squatting the Mach service can't
            // pose as it and harvest what we send.
            do {
                try conn.setCodeSigningRequirement(HelperInfo.helperRequirement)
            } catch {
                throw HelperError.notConnected("the helper failed its signature check")
            }

            // Both must fail an outstanding call, not just interruption.
            // `invalidate()` is what "Remove Helper" triggers, and it fires
            // invalidationHandler only — so a write in progress used to hang on
            // its semaphore forever with no error and no recovery.
            conn.invalidationHandler = { [weak self] in
                self?.failInFlight(HelperError.notConnected("the helper was disconnected"))
            }
            conn.interruptionHandler = { [weak self] in
                self?.failInFlight(HelperError.notConnected("the helper stopped unexpectedly"))
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
    private func failInFlight(_ error: Error) {
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

    private func currentHelperVersion() throws -> String {
        let helper = try proxy()
        var result = ""
        let done = DispatchSemaphore(value: 0)
        helper.helperVersion { version in
            result = version
            done.signal()
        }
        guard done.wait(timeout: .now() + 10) == .success else {
            throw HelperError.notConnected("the helper did not respond")
        }
        return result
    }

    func setHandlers(onLog: @escaping (String) -> Void,
                     onProgress: @escaping (Double, String) -> Void) {
        callbacks.onLog = onLog
        callbacks.onProgress = onProgress
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
    /// reason, or nil if it can.
    func probeWrite(volumePath: String) throws -> String? {
        let helper = try proxy()
        var result: String?
        let done = DispatchSemaphore(value: 0)
        helper.probeWrite(volumePath: volumePath) { reason in
            result = reason
            done.signal()
        }
        guard done.wait(timeout: .now() + 20) == .success else {
            throw HelperError.notConnected("the helper did not respond")
        }
        return result
    }

    func cancel() {
        guard let helper = try? proxy() else { return }
        let done = DispatchSemaphore(value: 0)
        helper.cancelCurrentOperation { _ in done.signal() }
        _ = done.wait(timeout: .now() + 5)
    }

    /// Shared shape for "ask the helper to do something long, throw if it says no".
    ///
    /// Deliberately without a timeout: `createinstallmedia` legitimately runs for
    /// 10–20 minutes. The connection's invalidation handler is what catches a
    /// helper that dies, not a clock.
    private func call(_ body: (HelperProtocol, @escaping (String?) -> Void) -> Void) throws {
        let helper = try proxy()
        var failure: String?
        let done = DispatchSemaphore(value: 0)

        lock.lock()
        inFlightFailure = nil
        inFlight = { done.signal() }
        lock.unlock()

        body(helper) { message in
            failure = message
            done.signal()
        }
        // Untimed on purpose: createinstallmedia legitimately runs 10-20
        // minutes. A dead connection is caught by the handlers above, which is
        // the correct trigger — a clock would only ever be wrong.
        done.wait()

        lock.lock()
        inFlight = nil
        let connectionError = inFlightFailure
        inFlightFailure = nil
        lock.unlock()

        if let connectionError { throw connectionError }
        guard let failure else { return }

        // The daemon flags the one denial a user can fix; everything else is
        // reported verbatim rather than guessed at.
        if failure.hasPrefix(HelperInfo.needsFullDiskAccessPrefix) {
            throw HelperError.needsFullDiskAccess(
                String(failure.dropFirst(HelperInfo.needsFullDiskAccessPrefix.count)))
        }
        throw HelperError.operationFailed(failure)
    }
}
