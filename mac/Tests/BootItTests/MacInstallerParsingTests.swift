import XCTest
@testable import BootIt

final class MacInstallerParsingTests: XCTestCase {

    /// Representative `softwareupdate --list-full-installers` output.
    private let sample = """
    Finding available software
    Software Update found the following full installers:
    * Title: macOS Sequoia, Version: 15.5, Size: 15500000KiB, Build: 24F74
    * Title: macOS Sequoia, Version: 15.4, Size: 15400000KiB, Build: 24E248
    * Title: macOS Sonoma, Version: 14.7.1, Size: 13000000KiB, Build: 23H222
    """

    func testParsesEveryInstallerLine() {
        let installers = MacInstaller.parseInstallers(sample)
        XCTAssertEqual(installers.count, 3)
        XCTAssertEqual(installers[0].title, "macOS Sequoia")
        XCTAssertEqual(installers[0].version, "15.5")
        XCTAssertEqual(installers[0].build, "24F74")
        XCTAssertEqual(installers[0].sizeKiB, 15_500_000)
    }

    func testIgnoresNonInstallerLines() {
        XCTAssertTrue(MacInstaller.parseInstallers("Finding available software\n(no installers)").isEmpty)
    }

    func testGroupingCollapsesByMajorVersionPreservingOrder() {
        let groups = MacOSGroup.group(MacInstaller.parseInstallers(sample))
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].title, "macOS Sequoia")
        XCTAssertEqual(groups[0].builds.count, 2)
        XCTAssertEqual(groups[0].latest.build, "24F74")   // first inserted = latest
        XCTAssertEqual(groups[0].majorLabel, "Sequoia")
        XCTAssertEqual(groups[1].title, "macOS Sonoma")
    }

    func testGroupingEmptyInputYieldsNoGroups() {
        XCTAssertTrue(MacOSGroup.group([]).isEmpty)
    }
}

/// Reusing an installer that is already on disk, rather than re-fetching ~18 GB
/// of it, hinges entirely on reading the right version key. `CFBundleShortVersionString`
/// is the installer app's own version (21.6.01); the macOS release it delivers
/// is `DTPlatformVersion` (26.6). Matching on the wrong one would either
/// re-download every time or, worse, hand back an installer for the wrong OS.
final class InstallerVersionMatchingTests: XCTestCase {

    func testPlatformVersionComesFromDTPlatformVersion() {
        let info: [String: Any] = [
            "CFBundleShortVersionString": "21.6.01",
            "DTPlatformVersion": "26.6",
            "CFBundleIdentifier": "com.apple.InstallAssistant.macOSTahoe"
        ]
        XCTAssertEqual(MacInstaller.platformVersion(ofInfo: info), "26.6")
        XCTAssertNotEqual(MacInstaller.platformVersion(ofInfo: info), "21.6.01",
                          "the installer's own version must never be mistaken for the OS version")
    }

    func testMissingKeyYieldsNoVersionRatherThanAWrongOne() {
        XCTAssertNil(MacInstaller.platformVersion(ofInfo: ["CFBundleShortVersionString": "21.6.01"]))
        XCTAssertNil(MacInstaller.platformVersion(ofInfo: [:]))
    }

    /// A point release is a different download; 26.6 must not satisfy a request
    /// for 26.5.2, or the user gets an installer they did not choose.
    func testVersionsMatchExactly() {
        let info: [String: Any] = ["DTPlatformVersion": "26.6"]
        XCTAssertEqual(MacInstaller.platformVersion(ofInfo: info), "26.6")
        XCTAssertNotEqual(MacInstaller.platformVersion(ofInfo: info), "26.5.2")
        XCTAssertNotEqual(MacInstaller.platformVersion(ofInfo: info), "26")
    }
}
