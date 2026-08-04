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

    /// The reading runs off the main thread, so a test has to wait for it — and
    /// waits deterministically rather than on a sleep. Draining the reader queue
    /// proves the `stat` has finished, and because its result is handed back with
    /// `DispatchQueue.main.async` *before* that drain can return, the FIFO main
    /// queue runs the delivery ahead of the block that ends this wait.
    private func settle(_ app: AppModel) {
        app.bundleReader.sync {}
        let delivered = expectation(description: "the reading reached the model")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 5)
    }

    func testAReplacedAppCannotStartAWrite() {
        let bundle = BundleOnDisk()
        let app = model(bundle)
        XCTAssertTrue(app.canStart, "precondition: nothing else is holding Start back")

        bundle.current = AppBundleWatch.Identity(inode: 200, device: 1)   // dragged over
        app.checkWhetherAppWasReplaced()
        settle(app)

        XCTAssertTrue(app.preflight.appWasReplaced)
        XCTAssertFalse(app.canStart, "a window running code its bundle no longer contains "
                                   + "must not begin erasing a drive")
    }

    func testAnAppThatWasNotReplacedIsLeftAlone() {
        let bundle = BundleOnDisk()
        let app = model(bundle)
        app.checkWhetherAppWasReplaced()
        settle(app)
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
        settle(app)
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
        settle(app)
        XCTAssertTrue(app.preflight.appWasReplaced)

        app.reset()
        XCTAssertTrue(app.preflight.appWasReplaced, "only relaunching clears this")
    }
}

/// The reading is one `stat`, and on a local disk it costs microseconds. But an
/// `.app` can be run from a mounted SMB or NFS share, and when that server stops
/// answering the `stat` blocks for the mount's timeout — tens of seconds, on
/// every activation, on the thread that draws the window.
///
/// These are not measurements of how fast the check is. They assert the property
/// that makes its speed irrelevant: the main thread never waits for it.
final class BundleReadingLatencyTests: XCTestCase {

    /// Long enough that a synchronous implementation cannot pass by being quick,
    /// short enough not to slow the suite. A hung SMB mount blocks far longer.
    private static let stall: TimeInterval = 0.6

    /// A bundle on a mount that has stopped answering: every reading of it costs
    /// `stall` seconds, and the readings are counted.
    ///
    /// Everything is behind one lock. The identity is written by the test thread
    /// and read on the reader queue, and the count is the other way around —
    /// both are cross-thread, and this suite runs under ThreadSanitizer in CI. A
    /// racing *test* fails that gate on somebody else's unrelated change, which
    /// is a worse debt than the race it was written to measure.
    private final class StalledBundle {
        private let lock = NSLock()
        private var identity: AppBundleWatch.Identity? = AppBundleWatch.Identity(inode: 100, device: 1)
        private var stored = 0

        /// What the reader sees. Sleeps outside the lock so a test can stage the
        /// next answer while a reading is still stalled — which is the case the
        /// pile-up test depends on.
        func read(stalling stall: TimeInterval) -> AppBundleWatch.Identity? {
            lock.lock(); stored += 1; let answer = identity; lock.unlock()
            Thread.sleep(forTimeInterval: stall)
            return answer
        }

        /// The drag-and-replace, and the point from which readings are counted —
        /// `InstallPreflight`'s init takes its own reading for `launchIdentity`,
        /// and that one is not what these tests are counting.
        func replace(with new: AppBundleWatch.Identity?) {
            lock.lock(); identity = new; lock.unlock()
        }
        func startCounting() { lock.lock(); stored = 0; lock.unlock() }
        var readings: Int { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private func stalledModel(replacedWith new: AppBundleWatch.Identity?)
    -> (AppModel, StalledBundle) {
        let bundle = StalledBundle()
        let stall = Self.stall
        let model = AppModel(
            privilegedCancel: {},
            preflight: InstallPreflight(bundleIdentity: { bundle.read(stalling: stall) },
                                        usbAccessProbe: { nil }))
        bundle.replace(with: new)
        bundle.startCounting()
        return (model, bundle)
    }

    /// The property the whole change exists for. `InstallPreflight`'s init takes
    /// its own reading, so the stall is paid once at construction — deliberately
    /// outside what is timed, because that one happens while the app is
    /// launching from a volume that is by definition still answering.
    func testComingToTheFrontDoesNotBlockTheMainThread() {
        let (app, _) = stalledModel(replacedWith: AppBundleWatch.Identity(inode: 200, device: 1))

        let started = Date()
        app.checkWhetherAppWasReplaced()
        let blocked = Date().timeIntervalSince(started)

        XCTAssertLessThan(blocked, Self.stall / 2,
                          "the reading must not be performed on the calling thread — "
                          + "on a stalled network mount this is the app beachballing "
                          + "every time it comes to the front")
        app.bundleReader.sync {}
    }

    /// Activations arrive far faster than a stalled mount answers. Without the
    /// in-flight guard each one enqueues another blocking `stat`, and the queue
    /// of them outlives the stall that produced it.
    func testActivationsWhileAReadingIsStalledDoNotPileUp() {
        // Unchanged on purpose: nothing must latch, so every one of the twenty
        // activations below reaches the guard that is under test.
        let (app, bundle) = stalledModel(replacedWith:
            AppBundleWatch.Identity(inode: 100, device: 1))

        for _ in 0..<20 { app.checkWhetherAppWasReplaced() }
        app.bundleReader.sync {}

        XCTAssertEqual(bundle.readings, 1,
                       "twenty activations during one stalled reading must cost one `stat`")
    }

    /// Once the flag is latched no further reading can change anything, so the
    /// cheapest correct thing is to stop asking.
    func testNoFurtherReadingsOnceTheAppIsKnownReplaced() {
        let (app, bundle) = stalledModel(replacedWith:
            AppBundleWatch.Identity(inode: 200, device: 1))

        app.checkWhetherAppWasReplaced()
        app.bundleReader.sync {}
        let settled = expectation(description: "the first reading reached the model")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertTrue(app.preflight.appWasReplaced, "precondition: the flag is latched")

        for _ in 0..<5 { app.checkWhetherAppWasReplaced() }
        app.bundleReader.sync {}

        XCTAssertEqual(bundle.readings, 1, "a latched flag has nothing left to learn from a `stat`")
    }
}
