import XCTest
@testable import BootIt
@testable import BootItShared

/// The daemon used to signal the one user-fixable failure by prefixing its
/// message with `"NEEDS_FULL_DISK_ACCESS: "`, which the app matched on and then
/// sliced back off. Three independent reviewers flagged it, because a contract
/// living in the first 24 characters of a human-readable sentence breaks
/// silently the moment anyone rewords the sentence — and nothing in the type
/// system would have said so.
///
/// It travels as an `NSError` code now. These prove the classification survives
/// the crossing and that the text is free to change without breaking it.
final class HelperErrorDecodeTests: XCTestCase {

    private func decoded(_ reason: HelperFailure, _ message: String) -> Error {
        PrivilegedHelper.decode(HelperInfo.failure(reason, message))
    }

    func testFullDiskAccessIsRecognisedByCodeNotByWording() {
        // Deliberately not the wording the daemon actually ships: the whole
        // point is that rewording cannot break the classification.
        let error = decoded(.needsFullDiskAccess, "something entirely different")
        guard case HelperError.needsFullDiskAccess(let detail) = error else {
            return XCTFail("expected .needsFullDiskAccess, got \(error)")
        }
        XCTAssertEqual(detail, "something entirely different")
    }

    func testAMessageThatMerelyMentionsFullDiskAccessIsNotMisclassified() {
        // Under the old prefix scheme any message could be made to look like the
        // marker. Only the code decides now.
        let error = decoded(.operationFailed, "NEEDS_FULL_DISK_ACCESS: not really")
        guard case HelperError.operationFailed = error else {
            return XCTFail("expected .operationFailed, got \(error)")
        }
    }

    func testRefusalsAndBusyReportTheirMessageVerbatim() {
        for reason in [HelperFailure.refused, .busy, .operationFailed] {
            let error = decoded(reason, "the reason")
            guard case HelperError.operationFailed(let message) = error else {
                return XCTFail("expected .operationFailed for \(reason), got \(error)")
            }
            XCTAssertEqual(message, "the reason")
        }
    }

    /// An error raised by XPC itself, not by the daemon's own code. Rewording it
    /// would only hide where it came from.
    func testAnErrorFromOutsideTheDaemonsDomainPassesThrough() {
        let foreign = NSError(domain: NSCocoaErrorDomain, code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "connection interrupted"])
        guard case HelperError.operationFailed(let message) = PrivilegedHelper.decode(foreign) else {
            return XCTFail("expected .operationFailed")
        }
        XCTAssertEqual(message, "connection interrupted")
    }

    func testAnUnknownCodeInOurOwnDomainStillSurfacesItsMessage() {
        let future = NSError(domain: HelperInfo.errorDomain, code: 9999,
                             userInfo: [NSLocalizedDescriptionKey: "added in a later build"])
        guard case HelperError.operationFailed(let message) = PrivilegedHelper.decode(future) else {
            return XCTFail("expected .operationFailed")
        }
        XCTAssertEqual(message, "added in a later build")
    }
}

/// There was a test here asserting every failable reply whitelists `NSError`.
/// It passed with the whitelisting code deleted, which is the only reason it was
/// caught: Foundation already infers `NSError` into the allowed set from an
/// `NSError?` reply signature, so both the safeguard and the test were asserting
/// something that cannot fail. Removed rather than kept as reassurance.
