import XCTest
@testable import BootIt

/// The progress ring's arithmetic. It lived inside `runWindows` / `runMac`,
/// where reaching it meant a forty-minute write to a real drive, and it had no
/// tests at all — on a bar that has already shipped three wrong answers.
final class WriteBaseTests: XCTestCase {

    private func base(_ platform: AppModel.Platform,
                      _ source: AppModel.SourceMode,
                      reused: Bool = false) -> Double {
        RunPlan.writeBase(platform: platform, source: source, installerWasReused: reused)
    }

    /// The regression that motivated extracting this. The exact installer is
    /// already in `/Applications`, nothing is fetched, and the run charges the
    /// user's ring for a download that never happened — the bar starts at 50%
    /// while the drive is untouched, directly under a checklist row reading
    /// "Skipped".
    func testAReusedInstallerIsChargedNothing() {
        XCTAssertEqual(base(.macos, .download, reused: true), 0,
                       "a download that did not happen owns none of the ring")
        XCTAssertEqual(base(.macos, .download, reused: false), 0.5,
                       "one that did happen owns its half")
    }

    /// Picking a local ISO or a local installer app skips the fetch entirely,
    /// so the write owns the whole ring on either platform.
    func testALocalSourceGivesTheWriteTheWholeRing() {
        XCTAssertEqual(base(.windows, .local), 0)
        XCTAssertEqual(base(.macos, .local), 0)
        XCTAssertEqual(RunPlan.writeSpan(platform: .windows, source: .local,
                                         installerWasReused: false), 1)
        XCTAssertEqual(RunPlan.writeSpan(platform: .macos, source: .local,
                                         installerWasReused: false), 1)
    }

    /// The two platforms weigh their downloads differently, and swapping the
    /// constants would make one bar crawl and the other jump.
    func testTheTwoPlatformsWeighTheirDownloadsDifferently() {
        XCTAssertEqual(base(.windows, .download), 0.55)
        XCTAssertEqual(base(.macos, .download), 0.5)
    }

    /// Whatever the base is, the write is scaled into the rest — so the bar
    /// finishes at exactly 1 rather than short of it or past it.
    func testTheBaseAndTheSpanAlwaysAccountForTheWholeRing() {
        for platform in [AppModel.Platform.windows, .macos] {
            for source in [AppModel.SourceMode.download, .local] {
                for reused in [true, false] {
                    let base = RunPlan.writeBase(platform: platform, source: source,
                                                 installerWasReused: reused)
                    let span = RunPlan.writeSpan(platform: platform, source: source,
                                                 installerWasReused: reused)
                    XCTAssertEqual(base + span, 1, accuracy: .ulpOfOne,
                                   "\(platform) / \(source) / reused=\(reused)")
                    XCTAssertGreaterThan(span, 0, "the write must always have room to move")
                    XCTAssertLessThanOrEqual(base, 1)
                }
            }
        }
    }
}

/// A run that stops early. Cancelling is an outcome, not a fault, and the two
/// must not present the same way — this lived in a `catch` block reachable only
/// by cancelling a real forty-minute write, and had no tests.
final class RunOutcomeTests: XCTestCase {

    /// The tool's own message on a cancellation is the SIGTERM *we* sent it.
    /// Showing "createinstallmedia exited 15" as an error blames the user for
    /// pressing the button we offered them.
    func testCancellingDoesNotReportTheSignalWeSent() {
        let outcome = RunPlan.outcome(cancelled: true,
                                      describedError: "createinstallmedia exited 15")
        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(outcome.statusText, "Cancelled")
        XCTAssertFalse(outcome.message.contains("createinstallmedia"),
                       "the signal we sent is not a fault to report back")
        XCTAssertFalse(outcome.message.contains("15"))
    }

    /// The drive is left half-written, and saying so is the whole point — a
    /// cancelled run that reads as tidy invites someone to try booting from it.
    func testCancellingSaysTheDriveIsNotBootable() {
        let outcome = RunPlan.outcome(cancelled: true, describedError: "irrelevant")
        XCTAssertTrue(outcome.message.lowercased().contains("not bootable"),
                      "got: \(outcome.message)")
    }

    /// A failure is exactly when technical detail stops being noise and starts
    /// being the thing you need. A cancellation is not that moment.
    func testTheLogOpensItselfOnlyOnAFailure() {
        XCTAssertTrue(RunPlan.outcome(cancelled: false, describedError: "disk full").showsLogDetails)
        XCTAssertFalse(RunPlan.outcome(cancelled: true, describedError: "disk full").showsLogDetails)
    }

    /// A real failure keeps the tool's own words — that is the one case where
    /// the underlying message is the useful thing.
    func testAGenuineFailureIsReportedVerbatim() {
        let outcome = RunPlan.outcome(cancelled: false, describedError: "Could not unmount disk4")
        XCTAssertFalse(outcome.wasCancelled)
        XCTAssertEqual(outcome.statusText, "Error")
        XCTAssertEqual(outcome.message, "Could not unmount disk4")
        XCTAssertTrue(outcome.logLine.contains("Could not unmount disk4"))
    }

    /// The status line and the log must agree about which of the two happened.
    /// They were built from three separate ternaries on the same flag, which is
    /// three chances for one of them to be edited alone.
    func testTheStatusLineAndTheLogNeverDisagree() {
        for cancelled in [true, false] {
            let outcome = RunPlan.outcome(cancelled: cancelled, describedError: "boom")
            XCTAssertEqual(outcome.wasCancelled, cancelled)
            XCTAssertEqual(outcome.logLine.contains("Cancelled"), cancelled)
            XCTAssertEqual(outcome.statusText == "Cancelled", cancelled)
            XCTAssertEqual(outcome.showsLogDetails, !cancelled)
        }
    }
}
