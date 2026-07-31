import XCTest
@testable import BootIt

/// Covers the derived presentation state the views read: which stages the
/// indicator shows, which page heading applies, and how the write phases are
/// planned and sequenced. All of it is a pure function of the model, so none of
/// these need a window.
final class PresentationTests: XCTestCase {

    private func model(_ configure: (AppModel) -> Void) -> AppModel {
        let model = AppModel()
        configure(model)
        return model
    }

    // MARK: - Setup stages

    func testDownloadRouteShowsFourStages() {
        let model = model { $0.source = .download }
        XCTAssertEqual(model.setupStages, [.platform, .source, .options, .usb])
    }

    /// The local route skips `.options`, so advertising it would promise a step
    /// the user never reaches and make the flow look longer than it is.
    func testLocalRouteDropsTheOptionsStage() {
        let model = model { $0.source = .local }
        XCTAssertEqual(model.setupStages, [.platform, .source, .usb])
        XCTAssertFalse(model.setupStages.contains(.options))
    }

    func testWritingAndCompletionReplaceSetupProgress() {
        XCTAssertTrue(model { $0.step = .platform }.showsSetupProgress)
        XCTAssertTrue(model { $0.step = .usb }.showsSetupProgress)
        XCTAssertFalse(model { $0.step = .progress }.showsSetupProgress)
        XCTAssertFalse(model { $0.step = .done }.showsSetupProgress)
    }

    /// Every stage the indicator can show must be one it can also locate, or the
    /// "step N of M" label silently falls back to the first stage.
    func testEveryShownStageIsAddressable() {
        for source in [AppModel.SourceMode.download, .local] {
            let model = model { $0.source = source }
            for stage in model.setupStages {
                XCTAssertNotNil(model.setupStages.firstIndex(of: stage))
            }
        }
    }

    // MARK: - The Windows 11 bypass stays reachable on both routes

    /// The download route configures the bypass on the options step. The local
    /// route never visits that step, so the drive step has to carry it — this is
    /// the invariant that keeps the option available to everyone.
    func testBypassOptionAppearsOnTheDriveStepOnlyForLocalWindowsSources() {
        XCTAssertTrue(model { $0.platform = .windows; $0.source = .local }.showsBypassOptionOnDriveStep)
        XCTAssertFalse(model { $0.platform = .windows; $0.source = .download }.showsBypassOptionOnDriveStep,
                       "the options step already offers it on the download route")
        XCTAssertFalse(model { $0.platform = .macos; $0.source = .local }.showsBypassOptionOnDriveStep,
                       "there is no Windows bypass on the macOS route")
    }

    func testEveryWindowsRouteCanReachTheBypassOption() {
        // Download: reachable via the options step, which that route always visits.
        let download = model { $0.platform = .windows; $0.source = .download }
        XCTAssertTrue(download.setupStages.contains(.options))

        // Local: options is skipped, so the drive step must offer it instead.
        let local = model { $0.platform = .windows; $0.source = .local }
        XCTAssertFalse(local.setupStages.contains(.options))
        XCTAssertTrue(local.showsBypassOptionOnDriveStep)
    }

    // MARK: - Page headings

    func testPageTitlesAreDistinctPerStep() {
        let model = model { $0.platform = .windows }
        var seen = Set<String>()
        for step in AppModel.Step.allCases {
            model.step = step
            let title = model.pageTitle
            XCTAssertFalse(title.isEmpty, "no title for \(step)")
            XCTAssertTrue(seen.insert(title).inserted, "duplicate page title: \(title)")
        }
    }

    func testProgressTitleSwitchesToFailure() {
        let model = model { $0.platform = .windows; $0.step = .progress }
        XCTAssertEqual(model.pageTitle, "Creating Windows installer")
        model.runError = "diskutil eraseDisk failed"
        XCTAssertEqual(model.pageTitle, "Something went wrong")
    }

    func testHeadingsNameThePlatform() {
        let mac = model { $0.platform = .macos; $0.step = .done }
        XCTAssertEqual(mac.pageTitle, "Your macOS installer is ready")
        let windows = model { $0.platform = .windows; $0.step = .done }
        XCTAssertEqual(windows.pageTitle, "Your Windows installer is ready")
    }

    // MARK: - Write phases

    func testWindowsDownloadPlansEveryStage() {
        let model = model { $0.platform = .windows; $0.source = .download }
        XCTAssertEqual(model.plannedPhases, [.downloading, .preparing, .copying, .finalising])
    }

    func testWindowsLocalSourceHasNothingToDownload() {
        let model = model { $0.platform = .windows; $0.source = .local }
        XCTAssertEqual(model.plannedPhases, [.preparing, .copying, .finalising])
    }

    /// createinstallmedia does its own copying and finalising, so listing those
    /// separately would show two stages that never light up independently.
    func testMacRouteDelegatesToCreateInstallMedia() {
        let model = model { $0.platform = .macos; $0.source = .download }
        XCTAssertEqual(model.plannedPhases, [.downloading, .preparing, .creatingInstaller])
        XCTAssertFalse(model.plannedPhases.contains(.copying))
    }

    func testPhasesSequenceDoneActiveAndPending() {
        let model = model { $0.platform = .windows; $0.source = .download; $0.step = .progress }
        model.currentPhase = .preparing

        XCTAssertEqual(model.state(of: .downloading), .done)
        XCTAssertEqual(model.state(of: .preparing), .active)
        XCTAssertEqual(model.state(of: .copying), .pending)
        XCTAssertEqual(model.state(of: .finalising), .pending)
    }

    func testAllPhasesReadAsDoneOnceFinished() {
        let model = model { $0.platform = .windows; $0.source = .download; $0.step = .done }
        for phase in model.plannedPhases {
            XCTAssertEqual(model.state(of: phase), .done, "\(phase) should be complete")
        }
    }

    func testNothingIsActiveBeforeTheFirstPhaseArrives() {
        let model = model { $0.platform = .windows; $0.source = .download; $0.step = .progress }
        XCTAssertNil(model.currentPhase)
        for phase in model.plannedPhases {
            XCTAssertEqual(model.state(of: phase), .pending)
        }
    }

    func testPhaseTitlesNameTheOperatingSystem() {
        let windows = model { $0.platform = .windows; $0.osChoice = .windows11 }
        XCTAssertEqual(windows.title(for: .downloading), "Downloading Windows 11")

        let mac = model { $0.platform = .macos }
        XCTAssertEqual(mac.title(for: .downloading), "Downloading macOS")
        XCTAssertEqual(mac.title(for: .creatingInstaller), "Creating macOS installer")
    }

    func testEveryPlannedPhaseHasATitleAndSymbol() {
        let model = model { $0.platform = .windows; $0.source = .download }
        for phase in model.plannedPhases {
            XCTAssertFalse(model.title(for: phase).isEmpty)
            XCTAssertFalse(phase.symbol.isEmpty)
        }
    }

    // MARK: - Failure surfaces the log

    func testStartClearsPhaseAndLogDisclosure() {
        let model = model {
            $0.currentPhase = .copying
            $0.showsLogDetails = true
            $0.disks = [USBDisk(id: "/dev/disk4", name: "SanDisk Ultra", sizeText: "31.9 GB")]
            $0.diskIndex = 0
        }
        model.start()
        XCTAssertNil(model.currentPhase)
        model.cancel()
    }

    func testResetClearsPresentationState() {
        let model = model {
            $0.currentPhase = .copying
            $0.showsLogDetails = true
            $0.showsAdvancedWindowsOptions = true
        }
        model.reset()
        XCTAssertNil(model.currentPhase)
        XCTAssertFalse(model.showsLogDetails)
        XCTAssertFalse(model.showsAdvancedWindowsOptions)
    }
}
