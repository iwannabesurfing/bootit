import XCTest
@testable import BootItKit

/// Covers the navigation and enablement logic that used to live inside
/// `ContentView`, where nothing could reach it. `AppModel()` performs no I/O on
/// init, and `flowDecision(fileExists:)` takes its filesystem check as a
/// parameter, so none of this touches a disk, a network or a window.
final class FlowTests: XCTestCase {

    private func model(_ configure: (AppModel) -> Void) -> AppModel {
        let model = AppModel()
        configure(model)
        return model
    }

    private let fileMissing: (String) -> Bool = { _ in false }
    private let filePresent: (String) -> Bool = { _ in true }

    // MARK: - Platform step

    func testPlatformStepBlocksUntilAPlatformIsChosen() {
        let model = model { $0.step = .platform }
        XCTAssertFalse(model.isPrimaryActionEnabled)
        XCTAssertEqual(model.flowDecision(fileExists: filePresent), .noop)
    }

    func testPlatformStepAdvancesToSourceOnceChosen() {
        let model = model { $0.step = .platform; $0.platform = .windows }
        XCTAssertTrue(model.isPrimaryActionEnabled)
        XCTAssertEqual(model.flowDecision(fileExists: filePresent), .advance(to: .source))
    }

    func testPrimaryActionIsAlwaysTitledEvenWhenDisabled() {
        // The button stays on screen while unavailable, so it always needs a title.
        for step in AppModel.Step.allCases {
            let model = model { $0.step = step }
            XCTAssertFalse(model.primaryActionTitle.isEmpty, "no title for \(step)")
        }
    }

    // MARK: - Source step

    func testDownloadSourceGoesToOptions() {
        let model = model { $0.step = .source; $0.platform = .windows; $0.source = .download }
        XCTAssertTrue(model.isSourceValid)
        XCTAssertEqual(model.flowDecision(fileExists: fileMissing), .advance(to: .options))
    }

    func testLocalWindowsSourceIsInvalidWithoutAPath() {
        let model = model { $0.step = .source; $0.platform = .windows; $0.source = .local }
        XCTAssertFalse(model.isSourceValid)
        XCTAssertFalse(model.isPrimaryActionEnabled)
        XCTAssertEqual(model.flowDecision(fileExists: filePresent),
                       .block(message: "Choose a valid .iso file first."))
    }

    func testLocalWindowsSourceIsBlockedWhenTheFileIsGone() {
        let model = model {
            $0.step = .source; $0.platform = .windows; $0.source = .local
            $0.localISOPath = "/tmp/deleted.iso"
        }
        XCTAssertTrue(model.isSourceValid, "a non-empty path passes the field check…")
        XCTAssertEqual(model.flowDecision(fileExists: fileMissing),
                       .block(message: "Choose a valid .iso file first."),
                       "…but a missing file must still block the step")
    }

    func testLocalMacSourceReportsItsOwnMessage() {
        let model = model { $0.step = .source; $0.platform = .macos; $0.source = .local }
        XCTAssertEqual(model.flowDecision(fileExists: filePresent),
                       .block(message: "Choose a macOS installer first."))
    }

    func testValidLocalSourceGoesStraightToTheDriveAndRescans() {
        let model = model {
            $0.step = .source; $0.platform = .windows; $0.source = .local
            $0.localISOPath = "/tmp/win11.iso"
        }
        XCTAssertEqual(model.flowDecision(fileExists: filePresent),
                       .advance(to: .usb, refreshingDisks: true))
    }

    /// Guards the routing fact that makes Windows-only settings placement subtle:
    /// a local ISO never visits `.options`, so anything offered only on that step
    /// is unreachable for users bringing their own ISO. The "Bypass Windows 11
    /// checks" toggle lives on the USB step for exactly this reason — moving it
    /// to the options step would silently remove it from this route.
    func testLocalISORouteNeverPassesThroughOptions() {
        let model = model {
            $0.step = .source; $0.platform = .windows; $0.source = .local
            $0.localISOPath = "/tmp/win11.iso"
        }
        XCTAssertEqual(model.flowDecision(fileExists: filePresent),
                       .advance(to: .usb, refreshingDisks: true))

        model.step = .usb
        XCTAssertEqual(model.backDestination, .source,
                       "Back from the drive step must skip options on the local route")
    }

    // MARK: - Options step

    func testOptionsStepWaitsForItsCatalogue() {
        let model = model { $0.step = .options; $0.platform = .windows }
        XCTAssertFalse(model.isPrimaryActionEnabled, "no languages loaded yet")

        model.catalog.languages = [CatalogItem(id: "1", name: "English (United States)")]
        XCTAssertTrue(model.isPrimaryActionEnabled)
        XCTAssertEqual(model.flowDecision(fileExists: filePresent),
                       .advance(to: .usb, refreshingDisks: true))
    }

    func testOptionsStepStaysDisabledWhileLoading() {
        let model = model {
            $0.step = .options; $0.platform = .windows
            $0.catalog.languages = [CatalogItem(id: "1", name: "English (United States)")]
            $0.catalog.isLoading = true
        }
        XCTAssertFalse(model.isPrimaryActionEnabled)
    }

    // MARK: - USB step and the destructive gate

    func testDriveStepRequiresBothASelectionAndAnAcknowledgement() {
        let model = model {
            $0.step = .usb
            $0.disks = [USBDisk(id: "/dev/disk4", name: "SanDisk Ultra", sizeText: "31.9 GB")]
        }
        XCTAssertNil(model.diskIndex, "nothing destructive may be preselected")
        XCTAssertFalse(model.isPrimaryActionEnabled)

        model.diskIndex = 0
        XCTAssertFalse(model.isPrimaryActionEnabled, "selection alone is not consent")

        model.hasAcknowledgedErase = true
        XCTAssertTrue(model.isPrimaryActionEnabled)
    }

    func testDriveStepAsksForConfirmationRatherThanErasingImmediately() {
        let model = model {
            $0.step = .usb
            $0.disks = [USBDisk(id: "/dev/disk4", name: "SanDisk Ultra", sizeText: "31.9 GB")]
            $0.diskIndex = 0
            $0.hasAcknowledgedErase = true
        }
        XCTAssertEqual(model.flowDecision(fileExists: filePresent), .confirmErase)

        model.apply(.confirmErase)
        XCTAssertTrue(model.isConfirmingErase, "the dialog is what actually starts the write")
    }

    func testStartDoesNothingWithoutASelectedDrive() {
        let model = model { $0.step = .usb; $0.hasAcknowledgedErase = true }
        model.start()
        XCTAssertEqual(model.step, .usb, "must not begin writing with no drive selected")
        XCTAssertFalse(model.running)
    }

    func testSelectedDriveIsNilWhenTheIndexOutlivesTheDrive() {
        let model = model {
            $0.disks = [USBDisk(id: "/dev/disk4", name: "SanDisk Ultra", sizeText: "31.9 GB")]
            $0.diskIndex = 0
        }
        model.disks = []          // drive unplugged
        XCTAssertNil(model.selectedDrive)
        XCTAssertFalse(model.canStart)
    }

    // MARK: - Back navigation

    func testBackDestinations() {
        XCTAssertNil(model { $0.step = .platform }.backDestination)
        XCTAssertEqual(model { $0.step = .source }.backDestination, .platform)
        XCTAssertEqual(model { $0.step = .options }.backDestination, .source)
        XCTAssertEqual(model { $0.step = .usb; $0.source = .download }.backDestination, .options)
        XCTAssertEqual(model { $0.step = .usb; $0.source = .local }.backDestination, .source)
        XCTAssertNil(model { $0.step = .progress }.backDestination, "no going back mid-write")
        XCTAssertNil(model { $0.step = .done }.backDestination)
    }

    func testGoBackClearsAStaleErrorMessage() {
        let model = model { $0.step = .options; $0.catalog.error = "Couldn't reach Microsoft." }
        model.goBack()
        XCTAssertEqual(model.step, .source)
        XCTAssertNil(model.catalog.error)
    }

    func testGoBackIsInertWhereThereIsNoBack() {
        let model = model { $0.step = .progress }
        model.goBack()
        XCTAssertEqual(model.step, .progress)
    }

    // MARK: - Reset

    func testResetClearsTheDestructiveGates() {
        let model = model {
            $0.step = .done
            $0.hasAcknowledgedErase = true
            $0.isConfirmingErase = true
            $0.platform = .windows
        }
        model.reset()
        XCTAssertEqual(model.step, .platform)
        XCTAssertNil(model.platform)
        XCTAssertFalse(model.hasAcknowledgedErase)
        XCTAssertFalse(model.isConfirmingErase)
    }

    /// A cancel in flight cannot be cancelled harder.
    ///
    /// The wait is the drive's — `createinstallmedia` sits in uninterruptible
    /// sleep and cannot take the signal until it surfaces. A live Cancel button
    /// through that window invites a second press whose only possible outcome is
    /// proving that pressing it does nothing.
    func testCancelIsNotOfferedTwice() {
        let model = AppModel()
        model.step = .progress
        model.running = true
        XCTAssertEqual(model.primaryActionTitle, "Cancel")
        XCTAssertTrue(model.isPrimaryActionEnabled)

        model.cancel()
        XCTAssertEqual(model.primaryActionTitle, "Cancelling…")
        XCTAssertFalse(model.isPrimaryActionEnabled)
    }

    /// But a *stopped* run still offers the way out, cancelled or not — leaving
    /// a dead button as the only action is what stranded users before.
    func testAStoppedRunAlwaysOffersStartOver() {
        let model = AppModel()
        model.step = .progress
        model.running = true
        model.cancel()
        model.runError = "Build cancelled"

        XCTAssertEqual(model.primaryActionTitle, "Start Over")
        XCTAssertTrue(model.isPrimaryActionEnabled,
                      "a pending cancel must not disable the exit from a finished run")
    }
}
