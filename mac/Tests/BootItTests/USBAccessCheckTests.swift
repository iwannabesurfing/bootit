import BootItShared
import XCTest
@testable import BootIt

/// Asking whether the helper can write *before* the user commits to erasing.
///
/// The answer already existed — `AccessDiagnostics` has been able to tell a
/// refused app from a refused daemon for some time — but the only way to reach
/// it was Help → Privileged Helper… → Test USB Access, which no first-run user
/// has any reason to open. This puts the same question on the path they are
/// already walking.
final class USBAccessCheckTests: XCTestCase {

    /// The probe runs on a background queue, so anything it touches is touched
    /// off the main thread and asserted on it. A plain `var` here raced, and
    /// `swift test --sanitize=thread` is a CI gate — a racing *test* fails that
    /// gate on somebody else's unrelated change, which is a worse debt than the
    /// one it was written to prevent.
    private final class ProbeLog {
        private let lock = NSLock()
        private var value = 0

        @discardableResult func record() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }

        var calls: Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    private func model(probe: @escaping () -> AccessDiagnostics.Report?) -> AppModel {
        let model = AppModel(
            privilegedCancel: {},
            preflight: InstallPreflight(bundleIdentity: { AppBundleWatch.Identity(inode: 1, device: 1) },
                                        usbAccessProbe: probe))
        model.platform = .macos
        model.disks = [USBDisk(id: "/dev/disk4", name: "SanDisk", sizeText: "32 GB")]
        model.diskIndex = 0
        return model
    }

    private let volume = "/Volumes/Install macOS Tahoe"

    private func settle(_ interval: TimeInterval = 0.4) {
        // The probe blocks, so it runs off the main queue and hops back. XCTest
        // owns the main thread; without giving the run loop a turn the answer
        // never lands.
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    // MARK: - What reaches the screen

    func testADeniedHelperIsReportedBeforeTheUserCommits() {
        let app = model {
            AccessDiagnostics.Report(volume: self.volume, appCanWrite: true,
                                     helperDenial: "Operation not permitted",
                                     helperNeedsFullDiskAccess: true)
        }
        app.checkUSBAccess()
        settle()

        let report = app.preflight.usbAccessReport
        XCTAssertNotNil(report, "a blocked drive has to be said before Start, not after")
        XCTAssertTrue(report?.helperNeedsFullDiskAccess == true)
        XCTAssertTrue(report?.summary.contains("Full Disk Access") == true)
    }

    func testAHealthyDriveSaysNothingAtAll() {
        let app = model {
            AccessDiagnostics.Report(volume: self.volume, appCanWrite: true)
        }
        app.checkUSBAccess()
        settle()
        XCTAssertNil(app.preflight.usbAccessReport, "there is nothing to warn about")
    }

    /// The mistake this app has already made once, in the other direction:
    /// reporting "USB access blocked" for a run that never reached the helper.
    func testAnInconclusiveProbeIsNotRenderedAsAProblem() {
        let app = model {
            AccessDiagnostics.Report(volume: self.volume, appCanWrite: nil,
                                     helperError: "the helper did not respond")
        }
        app.checkUSBAccess()
        settle()
        XCTAssertNil(app.preflight.usbAccessReport,
                     "a test that established nothing must not be shown as a failure")
    }

    // MARK: - When it declines to ask

    /// The guard that keeps this safe to run unprompted. `AccessDiagnostics.run()`
    /// calls `ensureReady()`, which *registers the daemon* — so a probe that ran
    /// regardless would install a root LaunchDaemon and raise an approval prompt
    /// because the user clicked a drive. nil means "did not ask".
    func testNoProbeMeansNoWarning() {
        let log = ProbeLog()
        let app = model { log.record(); return nil }
        app.checkUSBAccess()
        settle()
        XCTAssertEqual(log.calls, 1)
        XCTAssertNil(app.preflight.usbAccessReport)
    }

    func testTheWindowsPathIsNeverProbed() {
        let log = ProbeLog()
        let app = model { log.record(); return nil }
        app.platform = .windows
        app.checkUSBAccess()
        settle()
        XCTAssertEqual(log.calls, 0, "the Windows path never goes near the privileged helper")
    }

    func testNoDriveSelectedIsNotAQuestionWorthAsking() {
        let log = ProbeLog()
        let app = model { log.record(); return nil }
        app.diskIndex = nil
        app.checkUSBAccess()
        settle()
        XCTAssertEqual(log.calls, 0)
    }

    /// The warning belongs to a drive. Starting over deselects it, so a warning
    /// left on screen would be describing something the user is no longer
    /// looking at — the same defect as a liveness line outliving its run.
    func testStartingOverClearsTheWarning() {
        let app = model {
            AccessDiagnostics.Report(volume: self.volume, appCanWrite: true,
                                     helperDenial: "Operation not permitted",
                                     helperNeedsFullDiskAccess: true)
        }
        app.checkUSBAccess()
        settle()
        XCTAssertNotNil(app.preflight.usbAccessReport)

        app.reset()
        XCTAssertNil(app.preflight.usbAccessReport, "it described a drive that is no longer selected")
    }

    // MARK: - Answers arriving out of order

    /// The user can pick a different drive while a probe is still in flight. The
    /// slower answer belongs to a question nobody is asking any more.
    func testAStaleAnswerDoesNotOverwriteANewerQuestion() {
        let slow = DispatchSemaphore(value: 0)
        let log = ProbeLog()
        let app = model {
            if log.record() == 1 {
                slow.wait()
                return AccessDiagnostics.Report(volume: self.volume, appCanWrite: true,
                                                helperDenial: "Operation not permitted",
                                                helperNeedsFullDiskAccess: true)
            }
            return AccessDiagnostics.Report(volume: self.volume, appCanWrite: true)
        }

        app.checkUSBAccess()          // blocks in the probe
        app.checkUSBAccess()          // supersedes it, and answers "fine"
        settle()
        slow.signal()                 // the first answer finally arrives
        settle()

        XCTAssertNil(app.preflight.usbAccessReport,
                     "the superseded answer must not repaint a warning the user has moved past")
    }

    // MARK: - Which remedy is offered

    /// The wire, not the pure core: an `NSError` shaped exactly as the daemon
    /// sends one, through `decode()`, into the fields the banner reads.
    ///
    /// Worth its own test because a mutation that dropped the classification in
    /// `run()` survived the entire suite — `Report` was thoroughly tested, and
    /// nothing checked what actually filled it in.
    func testTheDaemonsOwnReplyCarriesItsClassificationThrough() {
        let refused = PrivilegedHelper.decode(
            HelperInfo.failure(.needsFullDiskAccess, "Operation not permitted"))
        let tcc = AccessDiagnostics.classify(refused)
        XCTAssertTrue(tcc.needsFullDiskAccess)
        XCTAssertEqual(tcc.denial, "Operation not permitted",
                       "the daemon's own sentence, not the paragraph summary writes itself")

        let refusedForAnotherReason = PrivilegedHelper.decode(
            HelperInfo.failure(.operationFailed, "Read-only file system"))
        let other = AccessDiagnostics.classify(refusedForAnotherReason)
        XCTAssertFalse(other.needsFullDiskAccess,
                       "Full Disk Access does not fix a read-only volume")
        XCTAssertEqual(other.denial, "Read-only file system")

        XCTAssertEqual(AccessDiagnostics.classify(nil).denial, nil)
        XCTAssertFalse(AccessDiagnostics.classify(nil).needsFullDiskAccess)
    }

    /// Only a TCC denial is fixed in Full Disk Access. A read-only volume, a
    /// full disk and an I/O error are all blocked writes that sending the user
    /// to that pane does nothing about — which is why `probeWrite` now routes
    /// through `decode()` and keeps the daemon's own classification.
    func testTheSettingsButtonIsOfferedOnlyForATCCDenial() {
        let tcc = AccessDiagnostics.Report(volume: volume, appCanWrite: true,
                                           helperDenial: "Operation not permitted",
                                           helperNeedsFullDiskAccess: true)
        let readOnly = AccessDiagnostics.Report(volume: volume, appCanWrite: true,
                                                helperDenial: "Read-only file system",
                                                helperNeedsFullDiskAccess: false)

        XCTAssertEqual(tcc.outcome, .blocked)
        XCTAssertEqual(readOnly.outcome, .blocked, "both are refusals")
        XCTAssertTrue(tcc.helperNeedsFullDiskAccess)
        XCTAssertFalse(readOnly.helperNeedsFullDiskAccess,
                       "only one of them has a fix in that settings pane")
        XCTAssertTrue(readOnly.summary.contains("Read-only file system"),
                      "the daemon's own sentence still reaches the user")
    }
}
