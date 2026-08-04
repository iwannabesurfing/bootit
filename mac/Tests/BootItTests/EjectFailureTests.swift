import XCTest
@testable import BootItKit

/// What the user is told when the drive will not eject.
///
/// **2026-08-04.** A finished run reported "Couldn't eject SanDisk 3.2Gen1 — a
/// file on it may still be open." `lsof` showed nothing open on the volume, and
/// `diskutil eject disk4` succeeded from a shell moments later. The sentence was
/// a hardcoded string printed for every failure, in the grammar of a diagnosis.
///
/// Third instance of this mistake in this project. `20e1874` stopped guessing at
/// the helper's reason for refusing; `AccessDiagnostics` stopped rendering every
/// daemon refusal as "enable Full Disk Access"; this is the eject path.
final class EjectFailureTests: XCTestCase {

    private let drive = USBDisk(id: "/dev/disk4", name: "SanDisk 3.2Gen1", sizeText: "61.5 GB")

    /// The part that actually helps: `diskutil` names what is holding the disk.
    func testDiskutilsOwnSentenceReachesTheUser() {
        let message = DriveEject.failureMessage(drive, Shell.Result(
            code: 1,
            out: "",
            err: "Unmount failed for /dev/disk4s2\nDissenter PID=442 (mds) status=0x0000c02f"))

        XCTAssertTrue(message.contains("Dissenter PID=442 (mds)"),
                      "the process holding the disk is the whole answer")
        XCTAssertTrue(message.contains("SanDisk 3.2Gen1"))
    }

    /// `diskutil` writes some failures to stdout, so a message there must not be
    /// dropped just because stderr happened to be empty.
    func testAReasonOnStdoutIsNotDiscarded() {
        let message = DriveEject.failureMessage(drive, Shell.Result(
            code: 1,
            out: "Unmount of disk4 failed: at least one volume could not be unmounted",
            err: ""))

        XCTAssertTrue(message.contains("at least one volume could not be unmounted"))
    }

    /// The regression, stated directly: no cause may be asserted that the tool
    /// did not report.
    func testNoCauseIsInventedWhenDiskutilGivesNone() {
        let message = DriveEject.failureMessage(drive, Shell.Result(code: 1, out: "   \n", err: ""))

        XCTAssertTrue(message.contains("gave no reason"),
                      "say that nothing was reported rather than supplying a cause")
        XCTAssertFalse(message.contains("may still be open"),
                       "that sentence was printed for every failure and was wrong for this one")
    }

    /// Advice is still offered — "a program is using the disk" is not actionable
    /// on its own. It just must not masquerade as the diagnosis.
    func testAdviceFollowsTheReasonRatherThanReplacingIt() {
        let message = DriveEject.failureMessage(drive, Shell.Result(
            code: 1, out: "", err: "Dissenter PID=442 (mds)"))

        let reason = try? XCTUnwrap(message.range(of: "Dissenter PID=442 (mds)"))
        let advice = try? XCTUnwrap(message.range(of: "Close anything using the drive"))
        XCTAssertNotNil(reason)
        XCTAssertNotNil(advice)
        if let reason, let advice {
            XCTAssertTrue(reason.upperBound <= advice.lowerBound,
                          "what happened first, what to do about it second")
        }
    }
}
