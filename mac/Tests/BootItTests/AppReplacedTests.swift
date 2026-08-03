import XCTest
@testable import BootIt

/// BootIt ships as a DMG, so an update is a drag-and-replace — often performed
/// with the old copy still open, because hitting a bug is what sent the user to
/// download a new one. The old process then reads the *new* bundle, installs the
/// new helper, and talks to it over an XPC protocol that has changed.
final class AppBundleWatchTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bundle-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ contents: String, to name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: false, encoding: .utf8)
        return url.path
    }

    func testAFileThatHasNotMovedKeepsItsIdentity() throws {
        let path = try write("v1", to: "BootItHelper")
        let first = AppBundleWatch.identity(of: path)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, AppBundleWatch.identity(of: path))
        XCTAssertFalse(AppBundleWatch.wasReplaced(recorded: first,
                                                  current: AppBundleWatch.identity(of: path)))
    }

    /// The actual update gesture: the old file is unlinked and a different file
    /// takes its place at the same path.
    func testReplacingTheFileAtAPathIsDetected() throws {
        let path = try write("v1", to: "BootItHelper")
        let atLaunch = AppBundleWatch.identity(of: path)

        try FileManager.default.removeItem(atPath: path)
        _ = try write("v2 — a different build entirely", to: "BootItHelper")

        XCTAssertTrue(AppBundleWatch.wasReplaced(recorded: atLaunch,
                                                 current: AppBundleWatch.identity(of: path)),
                      "a different file at the same path is a replaced bundle")
    }

    /// The reason this compares inodes rather than modification dates. Finder,
    /// `ditto` and `cp -p` all preserve mtime, so the replacement can arrive
    /// wearing the timestamp of the thing it replaced.
    func testDetectionSurvivesAPreservedModificationDate() throws {
        let path = try write("v1", to: "BootItHelper")
        let stamp = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        let atLaunch = AppBundleWatch.identity(of: path)

        try FileManager.default.removeItem(atPath: path)
        _ = try write("v2", to: "BootItHelper")
        try FileManager.default.setAttributes([.modificationDate: XCTUnwrap(stamp)],
                                              ofItemAtPath: path)

        let now = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.modificationDate]
                                as? Date)
        XCTAssertEqual(now.timeIntervalSince1970,
                       try XCTUnwrap(stamp).timeIntervalSince1970,
                       accuracy: 1,
                       "precondition: the copy is wearing the original's timestamp")
        XCTAssertTrue(AppBundleWatch.wasReplaced(recorded: atLaunch,
                                                 current: AppBundleWatch.identity(of: path)),
                      "mtime is not evidence; a timestamp-preserving copy still replaced the file")
    }

    /// This gates the Start button, so the failure to prefer is refusing to make
    /// a claim. A build with no bundled helper to stat must not become a
    /// permanent "BootIt was updated" that reopening cannot clear.
    func testAnUnreadablePathIsNotAReplacement() {
        let missing = directory.appendingPathComponent("not-here").path
        XCTAssertNil(AppBundleWatch.identity(of: missing))
        XCTAssertFalse(AppBundleWatch.wasReplaced(recorded: nil, current: nil))
        XCTAssertFalse(AppBundleWatch.wasReplaced(
            recorded: AppBundleWatch.Identity(inode: 1, device: 1), current: nil))
        XCTAssertFalse(AppBundleWatch.wasReplaced(
            recorded: nil, current: AppBundleWatch.Identity(inode: 1, device: 1)))
    }
}

/// What the app does about it, as opposed to how it notices.
///
/// The identity source is one injected closure used for both the reading taken
/// at launch and every reading since, so these drive the same path the app does
/// rather than a parallel one that happens to agree with it.
final class AppReplacedGateTests: XCTestCase {

    /// Stands in for the bundle on disk. Changing `current` between readings is
    /// the drag-and-replace, seen from inside the running process.
    private final class BundleOnDisk {
        var current: AppBundleWatch.Identity? = AppBundleWatch.Identity(inode: 100, device: 1)
    }

    private func model(_ bundle: BundleOnDisk) -> AppModel {
        let model = AppModel(privilegedCancel: {},
                             preflight: InstallPreflight(bundleIdentity: { bundle.current },
                                                         usbAccessProbe: { nil }))
        model.disks = [USBDisk(id: "/dev/disk4", name: "SanDisk", sizeText: "32 GB")]
        model.diskIndex = 0
        model.hasAcknowledgedErase = true
        return model
    }

    func testAReplacedAppCannotStartAWrite() {
        let bundle = BundleOnDisk()
        let app = model(bundle)
        XCTAssertTrue(app.canStart, "precondition: nothing else is holding Start back")

        bundle.current = AppBundleWatch.Identity(inode: 200, device: 1)   // dragged over
        app.checkWhetherAppWasReplaced()

        XCTAssertTrue(app.preflight.appWasReplaced)
        XCTAssertFalse(app.canStart, "a window running code its bundle no longer contains "
                                   + "must not begin erasing a drive")
    }

    func testAnAppThatWasNotReplacedIsLeftAlone() {
        let bundle = BundleOnDisk()
        let app = model(bundle)
        app.checkWhetherAppWasReplaced()
        XCTAssertFalse(app.preflight.appWasReplaced)
        XCTAssertTrue(app.canStart)
    }

    /// The bundle becoming unreadable is not a replacement. Otherwise a transient
    /// failure to stat would permanently withhold the Start button.
    func testAnUnreadableBundleDoesNotBlockTheApp() {
        let bundle = BundleOnDisk()
        let app = model(bundle)
        bundle.current = nil
        app.checkWhetherAppWasReplaced()
        XCTAssertFalse(app.preflight.appWasReplaced)
        XCTAssertTrue(app.canStart)
    }

    /// Starting over does not un-replace the bundle. A reset that cleared this
    /// would hand back the Start button the flag exists to withhold.
    func testStartingOverDoesNotClearTheWarning() {
        let bundle = BundleOnDisk()
        let app = model(bundle)
        bundle.current = AppBundleWatch.Identity(inode: 200, device: 1)
        app.checkWhetherAppWasReplaced()
        XCTAssertTrue(app.preflight.appWasReplaced)

        app.reset()
        XCTAssertTrue(app.preflight.appWasReplaced, "only relaunching clears this")
    }
}
