import XCTest
@testable import BootIt

/// What can be installed, and what happens when the user changes their mind
/// while the answer is still in flight.
///
/// This logic is not new — it lived in `AppModel` as a `catalogLoadID` compared
/// inside each completion handler — but it had **no tests**, in either place. It
/// could not easily have had any: exercising it meant driving a live fetch
/// against Microsoft's catalogue through a class that also owned disk listing
/// and the write pipeline. Pulling it into a value type is what made it
/// reachable, and two mutation checks survived the whole suite until this file
/// existed.
final class CatalogModelTests: XCTestCase {

    private let english = CatalogItem(id: "1", name: "English (United States)")
    private let german = CatalogItem(id: "2", name: "Deutsch")
    private let edition = CatalogItem(id: "3321", name: "Windows 11 Home/Pro")

    private var tahoe: [MacOSInstaller] {
        [MacOSInstaller(title: "macOS Tahoe", version: "26.2", build: "25C61", sizeKiB: 15_800_000)]
    }

    // MARK: - Superseded replies

    /// The case this exists for: the user switches Windows 11 → 10 while the
    /// first fetch is still running. The slower answer describes a version they
    /// are no longer looking at.
    func testAStaleWindowsReplyIsDiscarded() {
        var catalog = CatalogModel()
        let first = catalog.beginLoad(clearingWindowsResults: true)
        let second = catalog.beginLoad(clearingWindowsResults: true)

        catalog.acceptWindows(editions: [edition], languages: [german], id: first)
        XCTAssertTrue(catalog.languages.isEmpty, "the superseded fetch must not land")
        XCTAssertTrue(catalog.isLoading, "and must not report the newer one as finished")

        catalog.acceptWindows(editions: [edition], languages: [english], id: second)
        XCTAssertEqual(catalog.languages, [english])
        XCTAssertFalse(catalog.isLoading)
    }

    func testAStaleMacReplyIsDiscarded() {
        var catalog = CatalogModel()
        let first = catalog.beginLoad()
        _ = catalog.beginLoad()

        catalog.acceptMac(tahoe, id: first)
        XCTAssertTrue(catalog.macInstallers.isEmpty)
        XCTAssertTrue(catalog.isLoading)
    }

    /// A superseded *failure* matters just as much. A dead fetch for a version
    /// the user has moved off must not put an error on screen about the one they
    /// are now waiting for.
    func testAStaleFailureIsDiscarded() {
        var catalog = CatalogModel()
        let first = catalog.beginLoad()
        _ = catalog.beginLoad()

        catalog.fail("Couldn't reach Microsoft.", id: first)
        XCTAssertNil(catalog.error)
        XCTAssertTrue(catalog.isLoading, "the newer fetch is still running")
    }

    /// Starting over does not make an in-flight fetch current again.
    ///
    /// The reset carries the load counter forward rather than restarting it,
    /// and the reason is a **collision**, not merely a stale reply: if the
    /// counter went back to zero, the first fetch after the reset would be
    /// handed the same id as one already in flight, and the older reply would be
    /// accepted as the answer to the newer question. Asserting only that a
    /// pre-reset reply is discarded does not catch that — both a carried and a
    /// restarted counter reject it — so this drives the collision itself.
    func testStartingOverCannotHandANewFetchTheIdOfAnOldOne() {
        var catalog = CatalogModel()
        let inFlight = catalog.beginLoad()

        catalog.reset()
        let afterReset = catalog.beginLoad()
        XCTAssertNotEqual(afterReset, inFlight, "ids must not be reissued across a reset")

        catalog.acceptMac(tahoe, id: inFlight)
        XCTAssertTrue(catalog.macInstallers.isEmpty,
                      "a reply from before the reset belongs to a run that no longer exists")
    }

    // MARK: - What a fresh answer sets up

    func testEnglishIsSelectedWhereItIsOffered() {
        var catalog = CatalogModel()
        let id = catalog.beginLoad(clearingWindowsResults: true)
        catalog.acceptWindows(editions: [edition], languages: [german, english], id: id)
        XCTAssertEqual(catalog.languageIndex, 1)
    }

    func testTheFirstLanguageIsUsedWhenEnglishIsNotOffered() {
        var catalog = CatalogModel()
        let id = catalog.beginLoad(clearingWindowsResults: true)
        catalog.acceptWindows(editions: [edition], languages: [german], id: id)
        XCTAssertEqual(catalog.languageIndex, 0)
    }

    /// An empty list is not a working catalogue with nothing in it — Apple's
    /// tool returning nothing means the fetch failed, and it has to say so.
    func testAnEmptyMacListReadsAsAFailure() {
        var catalog = CatalogModel()
        let id = catalog.beginLoad()
        catalog.acceptMac([], id: id)
        XCTAssertNotNil(catalog.error)
        XCTAssertFalse(catalog.isLoading)
    }

    /// Stale editions and languages are cleared as the fetch *starts*, so the
    /// previous version's choices do not sit on screen looking current while the
    /// new ones load.
    func testWindowsResultsAreClearedWhenTheNextFetchBegins() {
        var catalog = CatalogModel()
        let first = catalog.beginLoad(clearingWindowsResults: true)
        catalog.acceptWindows(editions: [edition], languages: [english], id: first)
        XCTAssertFalse(catalog.editions.isEmpty)

        _ = catalog.beginLoad(clearingWindowsResults: true)
        XCTAssertTrue(catalog.editions.isEmpty)
        XCTAssertTrue(catalog.languages.isEmpty)
    }

    /// The macOS loader does not clear its list, deliberately: `listAvailable()`
    /// is one call with nothing to switch between mid-fetch, and blanking the
    /// list would flicker the user's selection away for no reason.
    func testTheMacListIsNotBlankedWhileRefreshing() {
        var catalog = CatalogModel()
        let id = catalog.beginLoad()
        catalog.acceptMac(tahoe, id: id)

        _ = catalog.beginLoad()
        XCTAssertFalse(catalog.macInstallers.isEmpty)
    }

    // MARK: - Readiness

    func testReadinessAsksTheRightListPerPlatform() {
        var catalog = CatalogModel()
        XCTAssertFalse(catalog.isReady(for: .macos))
        XCTAssertFalse(catalog.isReady(for: .windows))

        let id = catalog.beginLoad()
        catalog.acceptMac(tahoe, id: id)
        XCTAssertTrue(catalog.isReady(for: .macos))
        XCTAssertFalse(catalog.isReady(for: .windows), "a mac list says nothing about Windows")
    }

    func testNothingIsReadyWhileALoadIsRunning() {
        var catalog = CatalogModel()
        let id = catalog.beginLoad()
        catalog.acceptMac(tahoe, id: id)
        _ = catalog.beginLoad()
        XCTAssertFalse(catalog.isReady(for: .macos))
    }
}
