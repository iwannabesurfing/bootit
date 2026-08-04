import XCTest
@testable import BootItKit
@testable import BootItShared

/// A stand-in daemon.
///
/// Its default behaviour is the one that matters: **it never replies**. That is
/// the shape of a real `createinstallmedia` — a single XPC call that stays
/// outstanding for forty minutes — and it is the condition under which every
/// interesting failure in `PrivilegedHelper.call()` happens.
private final class StubHelper: NSObject, HelperProtocol {

    /// What `eraseDisk` does with its reply handler. Holding it and never
    /// calling it leaves the call in flight, exactly as a long write does.
    var onErase: (@escaping (NSError?) -> Void) -> Void = { _ in }

    private(set) var erasedDisk: String?
    private(set) var cancelCount = 0

    func helperFingerprint(reply: @escaping (String) -> Void) { reply("stub") }

    func eraseDisk(_ disk: String, volumeName: String, reply: @escaping (NSError?) -> Void) {
        erasedDisk = disk
        onErase(reply)
    }

    func createInstallMedia(installerAppPath: String,
                            volumeName: String,
                            reply: @escaping (NSError?) -> Void) {
        reply(nil)
    }

    func cancelCurrentOperation(reply: @escaping (Bool) -> Void) {
        cancelCount += 1
        reply(true)
    }

    /// What the daemon says when asked whether it can write. Configurable for
    /// the same reason `onErase` is: the interesting cases are its refusals.
    var onProbe: (@escaping (NSError?) -> Void) -> Void = { reply in reply(nil) }

    func probeWrite(volumePath: String, reply: @escaping (NSError?) -> Void) { onProbe(reply) }
}

/// `PrivilegedHelper.call()` is the app's whole relationship with a root daemon,
/// and until now none of it was tested — only `decode()` was.
///
/// What makes it worth testing is the one deliberate design choice inside it:
/// the wait is **untimed**, because a legitimate write runs for forty minutes
/// and any clock would eventually be wrong about it. That choice is only safe if
/// something *else* always unblocks the wait. These prove it does.
///
/// Every test drives the real `erase(disk:volumeName:)`, so `call()` is
/// exercised as the app uses it rather than through a hole opened for testing.
/// The only seam is where the daemon comes from.
final class PrivilegedCallTests: XCTestCase {

    private let disk = "disk4"
    private let volume = "MACINSTALL"

    /// Run `erase` off the test thread — it blocks its caller by design — and
    /// hand back the error it threw, if any.
    private func eraseInBackground(_ helper: PrivilegedHelper,
                                   thrown: @escaping (Error?) -> Void) -> XCTestExpectation {
        let finished = expectation(description: "the call returned")
        DispatchQueue.global().async {
            do {
                try helper.erase(disk: self.disk, volumeName: self.volume)
                thrown(nil)
            } catch {
                thrown(error)
            }
            finished.fulfill()
        }
        return finished
    }

    // MARK: - The ordinary paths

    func testASuccessfulReplyCompletesTheCallAndReleasesTheHelper() throws {
        let stub = StubHelper()
        stub.onErase = { reply in reply(nil) }
        let helper = PrivilegedHelper { stub }

        XCTAssertNoThrow(try helper.erase(disk: disk, volumeName: volume))
        XCTAssertEqual(stub.erasedDisk, disk)
        XCTAssertFalse(helper.isBusy)
    }

    func testADaemonFailureArrivesAsTheDecodedError() {
        let stub = StubHelper()
        stub.onErase = { reply in
            reply(HelperInfo.failure(.needsFullDiskAccess, "denied writing to the volume"))
        }
        let helper = PrivilegedHelper { stub }

        XCTAssertThrowsError(try helper.erase(disk: disk, volumeName: volume)) { error in
            // Not merely "it threw": the classification the UI branches on has to
            // survive the whole round trip, not just `decode()` in isolation.
            guard case HelperError.needsFullDiskAccess = error else {
                return XCTFail("expected .needsFullDiskAccess, got \(error)")
            }
        }
        XCTAssertFalse(helper.isBusy)
    }

    /// `probeWrite` was the last reply that skipped `decode()`, handing back a
    /// raw `NSError` and flattening the daemon's classification into a string.
    /// The only caller then could not tell a TCC denial — the one failure with a
    /// fix the user can perform — from a read-only volume, and offered the Full
    /// Disk Access pane for both.
    func testAProbeRefusalArrivesClassifiedRatherThanAsAString() throws {
        let stub = StubHelper()
        stub.onProbe = { reply in
            reply(HelperInfo.failure(.needsFullDiskAccess, "Operation not permitted"))
        }
        let helper = PrivilegedHelper { stub }

        guard case .needsFullDiskAccess(let reason) = try helper.probeWrite(volumePath: "/Volumes/X") else {
            return XCTFail("the daemon's classification did not survive the boundary")
        }
        XCTAssertEqual(reason, "Operation not permitted",
                       "and its own sentence survives inside the classification")
    }

    func testAProbeRefusalForAnyOtherReasonIsNotBlamedOnFullDiskAccess() throws {
        let stub = StubHelper()
        stub.onProbe = { reply in
            reply(HelperInfo.failure(.operationFailed, "Read-only file system"))
        }
        let helper = PrivilegedHelper { stub }

        guard case .operationFailed(let message) = try helper.probeWrite(volumePath: "/Volumes/X") else {
            return XCTFail("a non-TCC refusal must not be reported as a TCC refusal")
        }
        XCTAssertEqual(message, "Read-only file system")
    }

    func testAHelperThatCanWriteReportsNoRefusalAtAll() throws {
        let helper = PrivilegedHelper { StubHelper() }
        XCTAssertNil(try helper.probeWrite(volumePath: "/Volumes/X"))
    }

    /// `uninstall()` refuses while busy and `ensureReady()` won't replace a stale
    /// daemon while busy — so this flag is what stands between a re-registration
    /// and the write it would tear the connection out from under.
    func testTheHelperReadsAsBusyForExactlyAsLongAsACallIsInFlight() {
        let stub = StubHelper()
        let entered = expectation(description: "the daemon received the call")
        var release: ((NSError?) -> Void)?
        stub.onErase = { reply in
            release = reply
            entered.fulfill()
        }
        let helper = PrivilegedHelper { stub }

        let finished = eraseInBackground(helper) { _ in }
        wait(for: [entered], timeout: 2)

        XCTAssertTrue(helper.isBusy, "a write is outstanding — removing the helper now must be refused")
        release?(nil)

        wait(for: [finished], timeout: 2)
        XCTAssertFalse(helper.isBusy, "the claim has to be released, or Remove Helper is refused forever")
    }

    // MARK: - The wait is untimed, so something else must end it

    /// The failure this exists to prevent: a helper that dies mid-write used to
    /// leave the app parked on its semaphore with no error, no timeout and no
    /// recovery — for as long as the app stayed open.
    func testInvalidationUnblocksACallThatWillNeverBeAnswered() {
        let stub = StubHelper()   // never replies
        let entered = expectation(description: "the daemon received the call")
        stub.onErase = { _ in entered.fulfill() }
        let helper = PrivilegedHelper { stub }

        var thrown: Error?
        let finished = eraseInBackground(helper) { thrown = $0 }
        wait(for: [entered], timeout: 2)

        // What `invalidationHandler` and `interruptionHandler` both call. The one
        // line that wires each of them up is not covered here; what happens once
        // either fires is.
        helper.connectionFailed(HelperError.notConnected("the helper was disconnected"))

        // Seconds, against a wait that is otherwise unbounded.
        wait(for: [finished], timeout: 2)
        guard case HelperError.notConnected? = thrown else {
            return XCTFail("expected .notConnected, got \(String(describing: thrown))")
        }
        XCTAssertFalse(helper.isBusy)
    }

    /// The narrow window that made the untimed wait unsafe in a second way.
    ///
    /// `call()` used to obtain the proxy *before* registering the in-flight
    /// signal. A connection dying in between found nothing to signal, and the
    /// failure it recorded was then overwritten by the registration itself — so
    /// the call went out on a dead connection whose reply could never arrive,
    /// and the untimed wait waited for it forever.
    ///
    /// Restoring the old order (move `let helper = try proxy()` back above the
    /// registration) hangs this test until it times out.
    func testAConnectionDyingWhileTheProxyIsObtainedDoesNotHangTheCall() {
        let stub = StubHelper()   // never replies
        var built: PrivilegedHelper?
        let helper = PrivilegedHelper {
            // Precisely the window: the connection is gone by the time the
            // caller has a proxy in hand.
            built?.connectionFailed(HelperError.notConnected("the helper was disconnected"))
            return stub
        }
        built = helper

        var thrown: Error?
        let finished = eraseInBackground(helper) { thrown = $0 }

        wait(for: [finished], timeout: 3)
        guard case HelperError.notConnected? = thrown else {
            return XCTFail("expected .notConnected, got \(String(describing: thrown))")
        }
    }

    /// A helper that cannot be reached at all must fail the call, and must not
    /// leave the flag that blocks Remove Helper stuck on.
    func testAnUnreachableHelperFailsTheCallWithoutLeavingItBusy() {
        let helper = PrivilegedHelper { throw HelperError.notConnected("no daemon") }

        XCTAssertThrowsError(try helper.erase(disk: disk, volumeName: volume))
        XCTAssertFalse(helper.isBusy, "a connection that never opened must not look like a write in progress")
    }

    // MARK: - Cancel

    /// The app-level half of this is covered in CancellationTests — that the
    /// message leaves the app while the pipeline queue is blocked. This is the
    /// other half: that it reaches the daemon once it does.
    func testCancelReachesTheDaemon() {
        let stub = StubHelper()
        let helper = PrivilegedHelper { stub }

        helper.cancel()

        XCTAssertEqual(stub.cancelCount, 1)
    }

    /// Cancel is pressed exactly when the daemon is busy writing, so it must not
    /// depend on the connection being idle.
    func testCancelReachesTheDaemonWhileAWriteIsOutstanding() {
        let stub = StubHelper()
        let entered = expectation(description: "the daemon received the write")
        var release: ((NSError?) -> Void)?
        stub.onErase = { reply in
            release = reply
            entered.fulfill()
        }
        let helper = PrivilegedHelper { stub }

        let finished = eraseInBackground(helper) { _ in }
        wait(for: [entered], timeout: 2)

        helper.cancel()
        XCTAssertEqual(stub.cancelCount, 1)

        release?(nil)
        wait(for: [finished], timeout: 2)
    }

    /// An unreachable daemon must not make Cancel itself throw or hang — the
    /// user pressed stop, and there is nothing left to stop.
    func testCancelIsHarmlessWhenTheHelperCannotBeReached() {
        let helper = PrivilegedHelper { throw HelperError.notConnected("no daemon") }

        helper.cancel()   // must simply return
    }
}
