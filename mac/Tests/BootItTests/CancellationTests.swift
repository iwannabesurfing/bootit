import XCTest
@testable import BootIt

/// Cancel has now shipped dead twice, and both times every piece existed.
///
/// The first time, nothing called `PrivilegedHelper.cancel()` at all. The fix
/// for that posted the call to `worker` — the serial queue the privileged write
/// is itself occupying — so the cancel queued behind the operation it was meant
/// to stop and could not run until that operation had finished. Verified against
/// a real run on 2026-08-03: two presses at 09:33, then `createinstallmedia`
/// wrote for forty more minutes and exited normally at 10:14 having never been
/// signalled.
///
/// So the thing worth proving is not that `cancel()` exists, but that the
/// message gets out *while a write is in flight*.
final class CancellationTests: XCTestCase {

    func testCancelReachesTheDaemonWhileThePipelineQueueIsBlocked() {
        let reached = expectation(description: "the privileged cancel was invoked")
        let model = AppModel(privilegedCancel: { reached.fulfill() })

        // Occupy `worker` exactly as a real run does: the pipeline sits on it,
        // blocked inside one untimed privileged call, for the whole write.
        let release = DispatchSemaphore(value: 0)
        model.worker.async { release.wait() }
        defer { release.signal() }

        model.cancel()

        // Seconds, not the twenty minutes the queued version took.
        wait(for: [reached], timeout: 2)
    }

    /// The cancel must not depend on the pipeline being busy either — pressing it
    /// between phases has to reach the daemon just the same.
    func testCancelReachesTheDaemonWhenNothingIsRunning() {
        let reached = expectation(description: "the privileged cancel was invoked")
        let model = AppModel(privilegedCancel: { reached.fulfill() })

        model.cancel()

        wait(for: [reached], timeout: 2)
    }

    // MARK: - How a cancellation is presented
    //
    // Once cancel started working, the screen behind it became reachable for the
    // first time and was reporting the user's own choice as a crash: "Something
    // went wrong", a red banner, and "createinstallmedia exited 15" — which is
    // the SIGTERM BootIt itself sent — offered up as diagnostics to copy.

    private func cancelledModel() -> AppModel {
        let model = AppModel(privilegedCancel: {})
        model.platform = .macos
        model.step = .progress
        model.runError = "Stopped before the installer was finished."
        model.wasCancelled = true
        return model
    }

    func testACancelledBuildIsNotTitledAsAFailure() {
        XCTAssertEqual(cancelledModel().pageTitle, "Build cancelled")
    }

    func testAFailedBuildIsStillTitledAsAFailure() {
        let model = AppModel(privilegedCancel: {})
        model.platform = .macos
        model.step = .progress
        model.runError = "Splitting install.wim failed (wimlib exit 2)."
        XCTAssertEqual(model.pageTitle, "Something went wrong")
    }

    /// The stopped phase must not read "Failed" — nothing failed.
    func testTheStoppedPhaseReadsAsCancelledRatherThanFailed() {
        let model = cancelledModel()
        model.source = .local
        model.currentPhase = .creatingInstaller
        XCTAssertEqual(model.state(of: .creatingInstaller), .cancelled)
    }

    func testTheStoppedPhaseStillReadsAsFailedWhenSomethingActuallyFailed() {
        let model = AppModel(privilegedCancel: {})
        model.platform = .macos
        model.source = .local
        model.step = .progress
        model.runError = "createinstallmedia could not bless the disk."
        model.currentPhase = .creatingInstaller
        XCTAssertEqual(model.state(of: .creatingInstaller), .failed)
    }

    /// Starting again has to clear the cancelled presentation, or the next run
    /// begins wearing the last one's outcome.
    func testResetClearsTheCancelledState() {
        let model = cancelledModel()
        model.reset()
        XCTAssertFalse(model.wasCancelled)
        XCTAssertNil(model.runError)
    }
}
