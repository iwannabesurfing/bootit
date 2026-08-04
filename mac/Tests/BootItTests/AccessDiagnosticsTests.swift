import XCTest
@testable import BootItKit

/// "Test USB Access" reported **"USB access blocked"** for a run in which it had
/// never reached the helper at all, and offered Full Disk Access as the remedy.
///
/// The actual cause that day was an app and a helper from different builds — the
/// running app predated the change that moved failures across XPC as `NSError`,
/// so the two disagreed about a method signature and XPC dropped the connection.
/// Nothing was blocked. The reason was captured in `helperError` and then thrown
/// away without ever being shown.
///
/// So there are two things to hold: a test that reached no conclusion must not
/// claim one, and the sentence saying *why* has to survive to the screen.
final class AccessDiagnosticsReportTests: XCTestCase {

    private let volume = "/Volumes/Install macOS Tahoe"

    private func report(volume: String?,
                        appCanWrite: Bool?,
                        helperDenial: String? = nil,
                        helperError: String? = nil) -> AccessDiagnostics.Report {
        AccessDiagnostics.Report(volume: volume,
                                 appCanWrite: appCanWrite,
                                 helperDenial: helperDenial,
                                 helperError: helperError)
    }

    // MARK: - What the test actually established

    func testBothSidesWritingIsTheOnlyHealthyOutcome() {
        let healthy = report(volume: volume, appCanWrite: true)
        XCTAssertEqual(healthy.outcome, .ok)
        XCTAssertTrue(healthy.summary.contains("should work"))
    }

    func testAHelperThatIsRefusedIsGenuinelyBlocked() {
        let denied = report(volume: volume, appCanWrite: true,
                            helperDenial: "Operation not permitted")
        XCTAssertEqual(denied.outcome, .blocked)
        XCTAssertTrue(denied.summary.contains("Full Disk Access"))
    }

    /// The daemon separates a TCC denial from every other reason a write can
    /// fail, and only the first one is fixed by Full Disk Access. Both used to
    /// print the same sentence, so the screen could not tell them apart — which
    /// is also why a verification run could not confirm which code had crossed.
    func testTheHelpersOwnDenialReachesTheScreen() {
        let tcc = report(volume: volume, appCanWrite: true,
                         helperDenial: "macOS is blocking BootIt's helper from writing to removable drives.")
        XCTAssertTrue(tcc.summary.contains("blocking BootIt's helper"), tcc.summary)

        let other = report(volume: volume, appCanWrite: true,
                           helperDenial: "Couldn't write to \(volume): Read-only file system.")
        XCTAssertTrue(other.summary.contains("Read-only file system"), other.summary)
    }

    func testAnEmptyDenialStillReadsAsASentence() {
        let blank = report(volume: volume, appCanWrite: true, helperDenial: "")
        XCTAssertEqual(blank.outcome, .blocked)
        XCTAssertFalse(blank.summary.contains("cannot. \n"), blank.summary)
        XCTAssertTrue(blank.summary.contains("Full Disk Access"))
    }

    func testTheAppItselfBeingRefusedIsAlsoBlocked() {
        let denied = report(volume: volume, appCanWrite: false)
        XCTAssertEqual(denied.outcome, .blocked)
    }

    /// The regression this exists for.
    func testAnUnreachableHelperIsInconclusiveRatherThanBlocked() {
        let unreachable = report(volume: volume, appCanWrite: true,
                                 helperError: "the helper stopped unexpectedly")
        XCTAssertEqual(unreachable.outcome, .inconclusive,
                       "nothing here observed USB access being refused")
        XCTAssertNotEqual(unreachable.outcome, .blocked)
    }

    /// An unreachable helper says nothing either way even if the app itself can
    /// write — half a test is not a result.
    func testAnUnreachableHelperStaysInconclusiveWhateverTheAppCanDo() {
        for appCanWrite in [true, false] {
            let unreachable = report(volume: volume, appCanWrite: appCanWrite,
                                     helperError: "the helper was disconnected")
            XCTAssertEqual(unreachable.outcome, .inconclusive,
                           "appCanWrite=\(appCanWrite) must not decide this on its own")
        }
    }

    /// No drive inserted is not a diagnosis either, and used to draw the same
    /// "blocked" headline.
    func testNoDriveIsInconclusiveNotBlocked() {
        let nothing = report(volume: nil, appCanWrite: nil)
        XCTAssertEqual(nothing.outcome, .inconclusive)
        XCTAssertTrue(nothing.summary.contains("Insert a USB drive"))
    }

    // MARK: - The reason has to reach the screen

    func testTheUnderlyingErrorIsShownAndNotSwallowed() {
        let unreachable = report(volume: volume, appCanWrite: true,
                                 helperError: "the helper stopped unexpectedly")
        XCTAssertTrue(unreachable.summary.contains("the helper stopped unexpectedly"),
                      "the only sentence saying why must not be discarded: \(unreachable.summary)")
    }

    /// The summary must not assert a cause it did not observe.
    func testTheInconclusiveSummaryDoesNotClaimAccessWasBlocked() {
        let unreachable = report(volume: volume, appCanWrite: true,
                                 helperError: "the helper stopped unexpectedly")
        XCTAssertFalse(unreachable.summary.lowercased().contains("blocked"),
                       "must not name a cause the test never reached: \(unreachable.summary)")
    }

    /// Different builds of app and helper is the failure that actually happened,
    /// and the user cannot guess the fix from "couldn't reach the helper".
    func testTheInconclusiveSummaryNamesTheRecoveryTheUserCanPerform() {
        let unreachable = report(volume: volume, appCanWrite: true,
                                 helperError: "the helper stopped unexpectedly")
        XCTAssertTrue(unreachable.summary.contains("quit and reopen"),
                      unreachable.summary)
    }

    func testAMissingReasonStillProducesAReadableSentence() {
        // helperError is optional; the sentence must not end in a dangling colon.
        let unreachable = report(volume: volume, appCanWrite: true, helperError: nil)
        // With no volume-level failure and no error this is .ok, so construct the
        // genuinely odd case: a helper that neither answered nor errored.
        XCTAssertEqual(unreachable.outcome, .ok)

        let noReason = report(volume: volume, appCanWrite: nil, helperError: "")
        XCTAssertEqual(noReason.outcome, .inconclusive)
        XCTAssertFalse(noReason.summary.contains(": \n"), noReason.summary)
    }
}
