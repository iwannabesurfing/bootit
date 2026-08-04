import XCTest
@testable import BootItKit

/// The question these answer sat open across four sessions as "test whether
/// `SMAppService` registration is admin-gated — 5 min on a test account".
///
/// It never needed a test account. macOS's own header settles the rule
/// (`SMAppService.h`: a LaunchDaemon "will not be bootstrapped until an admin
/// approves"), and the reading of *who is an administrator* is checkable
/// against accounts that ship with every macOS install: `/etc/group` carries
/// `admin:*:80:root`, `nobody:*:-2:` and `daemon:*:1:root`. So root is an
/// administrator and the service accounts are not, on this machine and on a CI
/// runner alike, without anybody creating a second login.
final class AdminRightsTests: XCTestCase {

    /// The direction that matters for correctness of the warning: a
    /// non-administrator must be reported as one, or the warning never fires
    /// for the people it exists for.
    func testServiceAccountsAreNotAdministrators() {
        XCTAssertEqual(AdminRights.isAdministrator(user: "nobody"), false)
        XCTAssertEqual(AdminRights.isAdministrator(user: "daemon"), false)
    }

    /// The direction that matters for not crying wolf: an administrator must
    /// not be told to go and find an administrator. `root` is listed as a
    /// member of `admin` in the shipped `/etc/group`.
    func testRootIsAnAdministrator() {
        XCTAssertEqual(AdminRights.isAdministrator(user: "root"), true)
    }

    /// nil rather than false. Every caller treats nil as "say nothing", so a
    /// name the directory cannot resolve must not read as a demotion.
    func testUnknownUserIsUnestablishedRatherThanDenied() {
        XCTAssertNil(AdminRights.isAdministrator(user: "no-such-user-b8f2c1"))
    }

    // MARK: - What the preflight does with the answer

    private func preflight(admin: Bool?) -> InstallPreflight {
        InstallPreflight(bundleIdentity: { nil },
                         usbAccessProbe: { nil },
                         administratorCheck: { admin })
    }

    func testWarnsOnMacOSForAStandardAccount() {
        XCTAssertTrue(preflight(admin: false).warnsAboutAdministrator(platform: .macos))
    }

    /// The Windows path writes through `USBWriter` unprivileged and registers no
    /// daemon, so a standard account completes it unaided. Warning there would
    /// be a false blocker on the one platform that has no such gate.
    func testNeverWarnsOnWindows() {
        XCTAssertFalse(preflight(admin: false).warnsAboutAdministrator(platform: .windows))
    }

    func testDoesNotWarnAnAdministrator() {
        XCTAssertFalse(preflight(admin: true).warnsAboutAdministrator(platform: .macos))
    }

    /// "Could not establish" is silence, not a warning. A failed reading that
    /// rendered as a warning would tell administrators to go and find one.
    func testDoesNotWarnWhenTheReadingFailed() {
        XCTAssertFalse(preflight(admin: nil).warnsAboutAdministrator(platform: .macos))
    }

    /// Before a platform is chosen there is nothing to warn about, and the
    /// banner would appear on a screen that has not yet mentioned macOS.
    func testDoesNotWarnBeforeAPlatformIsChosen() {
        XCTAssertFalse(preflight(admin: false).warnsAboutAdministrator(platform: nil))
    }
}
