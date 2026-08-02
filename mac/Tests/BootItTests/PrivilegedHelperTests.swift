import XCTest
@testable import BootIt
@testable import BootItShared

/// The daemon runs as root and its whole job is to erase disks, so the two
/// things worth proving here are that the disk-name guard rejects everything
/// except a whole external disk, and that the code-signing requirements both
/// sides enforce are actually pinned to something.
final class DiskGuardTests: XCTestCase {

    func testAcceptsWholeDiskNames() {
        for name in ["disk0", "disk4", "disk11", "disk999"] {
            XCTAssertTrue(DiskGuard.isWholeDiskName(name), "should accept \(name)")
        }
    }

    func testRejectsSlices() {
        // A slice is the dangerous case: "disk1s2" is a volume on the internal
        // drive, and eraseDisk pointed at one is not recoverable.
        for name in ["disk4s2", "disk0s1", "disk1s2s3"] {
            XCTAssertFalse(DiskGuard.isWholeDiskName(name), "should reject \(name)")
        }
    }

    func testRejectsPathsAndMetacharacters() {
        for name in ["/dev/disk4", "../disk4", "disk4 ", " disk4", "disk4;rm -rf /",
                     "disk4\n", "disk", "", "notadisk", "disk-4", "DISK4"] {
            XCTAssertFalse(DiskGuard.isWholeDiskName(name), "should reject \(String(reflecting: name))")
        }
    }

    func testRejectsOverlongInput() {
        XCTAssertFalse(DiskGuard.isWholeDiskName("disk" + String(repeating: "9", count: 64)))
    }
}

final class HelperInfoTests: XCTestCase {

    /// The Mach service name, the launchd Label and the plist filename have to
    /// agree with au.media.bootit.helper.plist in the repo. If someone renames
    /// one, the daemon silently never launches — this makes that a test failure
    /// instead of a mystery at runtime.
    func testIdentifiersAgreeWithLaunchdPlist() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BootItTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // mac
            .appendingPathComponent(HelperInfo.plistName)

        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any])

        XCTAssertEqual(plist["Label"] as? String, HelperInfo.machServiceName)
        XCTAssertEqual(plist["BundleProgram"] as? String, "Contents/MacOS/BootItHelper")

        let machServices = try XCTUnwrap(plist["MachServices"] as? [String: Any])
        XCTAssertEqual(Array(machServices.keys), [HelperInfo.machServiceName])

        let associated = plist["AssociatedBundleIdentifiers"] as? [String]
        XCTAssertEqual(associated, [HelperInfo.appBundleID])
    }

    /// A requirement string that forgot to pin the team, or pinned the wrong
    /// side, would still compile and still look plausible in review.
    func testRequirementsPinTeamAndIdentity() {
        XCTAssertTrue(HelperInfo.clientRequirement.contains("anchor apple generic"))
        XCTAssertTrue(HelperInfo.clientRequirement.contains(HelperInfo.teamIdentifier))
        XCTAssertTrue(HelperInfo.clientRequirement.contains("identifier \"\(HelperInfo.appBundleID)\""))

        XCTAssertTrue(HelperInfo.helperRequirement.contains("anchor apple generic"))
        XCTAssertTrue(HelperInfo.helperRequirement.contains(HelperInfo.teamIdentifier))
        XCTAssertTrue(HelperInfo.helperRequirement.contains("identifier \"\(HelperInfo.helperBundleID)\""))

        // The two must not be the same string: the app pins the helper and the
        // helper pins the app, and swapping them would let either impersonate.
        XCTAssertNotEqual(HelperInfo.clientRequirement, HelperInfo.helperRequirement)
    }
}

/// The progress bar sat at 50% through an entire 20-minute write. Two separate
/// causes, both of which these tests would have caught.
final class InstallMediaProgressTests: XCTestCase {

    func testTakesTheLastPercentNotTheFirst() {
        // createinstallmedia rewrites one line in place and keeps appending.
        // Reading the first match reports 0% forever while the tool is working.
        let line = "Erasing disk: 0%... 10%... 20%... 30%..."
        XCTAssertEqual(InstallMediaProgress.lastPercent(line), 30)
    }

    func testHandlesSinglePercentAndNone() {
        XCTAssertEqual(InstallMediaProgress.lastPercent("Copying to disk: 100%"), 100)
        XCTAssertNil(InstallMediaProgress.lastPercent("Making disk bootable..."))
        XCTAssertNil(InstallMediaProgress.lastPercent(""))
    }

    func testCopyingDominatesTheBar() {
        // Erasing is quick; copying is the multi-gigabyte phase. If they shared
        // the range evenly the bar would race to half and then crawl.
        let erasing = try? XCTUnwrap(InstallMediaProgress.fraction(for: "Erasing disk: 100%"))
        let copyingStart = try? XCTUnwrap(InstallMediaProgress.fraction(for: "Copying to disk: 0%"))
        let copyingEnd = try? XCTUnwrap(InstallMediaProgress.fraction(for: "Copying to disk: 100%"))

        XCTAssertEqual(erasing ?? 0, 0.15, accuracy: 0.001)
        XCTAssertEqual(copyingStart ?? 0, 0.15, accuracy: 0.001)
        XCTAssertEqual(copyingEnd ?? 0, 1.0, accuracy: 0.001)
    }

    func testProgressAdvancesAcrossARealisticRun() {
        let transcript = [
            "Erasing disk: 0%... 10%... 50%...",
            "Erasing disk: 0%... 10%... 50%... 100%",
            "Copying to disk: 0%... 10%...",
            "Copying to disk: 0%... 10%... 60%...",
            "Copying to disk: 0%... 100%",
            "Install media now available at \"/Volumes/Install macOS Tahoe\""
        ]
        let fractions = transcript.compactMap { InstallMediaProgress.fraction(for: $0) }
        XCTAssertEqual(fractions.count, transcript.count, "every line should move the bar")
        XCTAssertEqual(fractions, fractions.sorted(), "progress must never go backwards")
        XCTAssertEqual(fractions.last, 1.0)
    }

    func testLinesWithoutProgressLeaveTheBarAlone() {
        // Returning 0 here would snap a half-finished bar back to the start.
        XCTAssertNil(InstallMediaProgress.fraction(for: "Preparing to copy installer files..."))
    }

    func testStatusMentionsThePercentSoTheUserSeesMovement() {
        XCTAssertTrue(InstallMediaProgress.status(for: "Copying to disk: 0%... 40%").contains("40%"))
        XCTAssertEqual(InstallMediaProgress.status(for: "Install media now available"),
                       "Install media ready")
    }
}

/// The completion step offered "Quit" as its primary button while the drive it
/// had just written was still mounted — pressing Return there was one keystroke
/// away from an unejected pull.
final class CompletionActionTests: XCTestCase {

    private func completedModel(ejected: Bool) -> AppModel {
        let model = AppModel()
        model.step = .done
        model.driveEjected = ejected
        return model
    }

    func testPrimaryActionEjectsBeforeItOffersToLeave() {
        XCTAssertEqual(completedModel(ejected: false).primaryActionTitle, "Eject Drive")
    }

    func testPrimaryActionBecomesDoneOnceEjected() {
        XCTAssertEqual(completedModel(ejected: true).primaryActionTitle, "Done")
    }

    func testQuitIsNeverThePrimaryAction() {
        // Keyboard shortcut .defaultAction is bound to this button, so the title
        // is also what Return does.
        for ejected in [true, false] {
            XCTAssertNotEqual(completedModel(ejected: ejected).primaryActionTitle, "Quit")
        }
    }
}

/// A ring reading 2% underneath a green-ticked "Downloading macOS" reads as a
/// bar that reset. The download either happened or it didn't; the checklist has
/// to say which.
final class SkippedPhaseTests: XCTestCase {

    private func macModel(skipped: Bool) -> AppModel {
        let model = AppModel()
        model.platform = .macos
        model.source = .download
        model.downloadSkipped = skipped
        model.currentPhase = .preparing
        return model
    }

    func testSkippedDownloadIsNotReportedAsCompleted() {
        XCTAssertEqual(macModel(skipped: true).state(of: .downloading), .skipped)
    }

    func testRealDownloadStillCompletesNormally() {
        XCTAssertEqual(macModel(skipped: false).state(of: .downloading), .done)
    }

    func testSkippedSurvivesTheFinishedBuild() {
        // `state(of:)` short-circuits everything to .done once the build ends,
        // which would quietly re-assert that a skipped download had happened.
        let model = macModel(skipped: true)
        model.step = .done
        XCTAssertEqual(model.state(of: .downloading), .skipped)
        XCTAssertEqual(model.state(of: .preparing), .done)
    }
}
