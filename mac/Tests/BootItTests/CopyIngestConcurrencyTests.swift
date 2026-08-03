import BootItShared
import XCTest
@testable import BootIt

/// The seam between the daemon's samples and the state machine.
///
/// The reducer itself is exhaustively tested and pure; what was untested is the
/// *feed* — and that is where the defect was. Samples arrive on the XPC
/// connection's own delivery thread, while the end of the run arrives on
/// `worker`, and both touch `copyModel`.
///
/// This subsystem has now shipped three threading bugs: a cancel dispatched onto
/// the queue it was meant to interrupt, a poller holding a global-pool thread for
/// forty minutes, and this. Run under `swift test --sanitize=thread` these fail
/// on the unsynchronised version and pass on the fixed one; without the
/// sanitizer they are a smoke test that the hop works at all.
final class CopyIngestConcurrencyTests: XCTestCase {

    /// The real shape of the bug: samples still in flight on the XPC queue when
    /// the run ends on `worker`.
    ///
    /// The window is not theoretical. `DispatchSourceTimer.cancel()` does not
    /// interrupt a handler already running, and the daemon's `stopSampling()`
    /// runs *after* the reply that unblocks the app — so the last sample of every
    /// run races the end of it. A dropped connection opens the same window wider.
    func testSamplesArrivingAsTheRunEndsDoNotRaceTheModel() {
        let model = AppModel()
        let samples = CopyTraceFixtures.run(interval: 40)
        let delivery = DispatchQueue(label: "test.xpc-delivery")
        let worker = DispatchQueue(label: "test.worker")
        let finished = expectation(description: "both queues drained")
        finished.expectedFulfillmentCount = 2

        delivery.async {
            for sample in samples { model.ingest(sample) }
            finished.fulfill()
        }
        worker.async {
            // Interleaved with the samples above, as the end of a real run is.
            for _ in 0..<20 { model.endCopyReporting() }
            finished.fulfill()
        }

        // Also drains the main queue, which is where the state has to land.
        wait(for: [finished], timeout: 10)
        drainMainQueue()
    }

    func testConcurrentSamplesFromTwoDeliveriesLeaveTheModelIntact() {
        // Belt and braces: NSXPCConnection does not promise a serial delivery
        // queue, and the array inside the reducer's rate window is not something
        // to find out about the hard way.
        let model = AppModel()
        let samples = CopyTraceFixtures.run(interval: 20)
        let finished = expectation(description: "both deliveries drained")
        finished.expectedFulfillmentCount = 2

        for _ in 0..<2 {
            DispatchQueue.global(qos: .utility).async {
                for sample in samples { model.ingest(sample) }
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 10)
        drainMainQueue()
    }

    func testTheEndOfARunClearsTheStateEvenWhenSamplesWereStillArriving() {
        let model = AppModel()
        for sample in CopyTraceFixtures.run(interval: 60).prefix(10) { model.ingest(sample) }
        drainMainQueue()
        XCTAssertNotNil(model.copyState)

        model.endCopyReporting()
        drainMainQueue()
        XCTAssertNil(model.copyState, "a finished run must not leave a liveness line behind")

        // And the reducer is genuinely reset, not merely hidden: the next run's
        // first sample has to read as its own baseline, not as a continuation.
        model.ingest(CopySample(elapsed: 0, deviceBytes: 500_000_000_000))
        drainMainQueue()
        XCTAssertEqual(model.copyState?.bytesWritten, 0)
    }

    /// Runs queued main-queue work without returning to the test runner.
    /// `XCTest` occupies the main thread, so state hopped there with
    /// `DispatchQueue.main.async` only lands if the run loop is given a turn.
    private func drainMainQueue(for interval: TimeInterval = 0.25) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }
}

/// What happens to a callback that arrives after the work it belonged to is
/// over — which, because the daemon stops sampling only after sending its reply,
/// is the tail of every single run.
final class FinishedRunDetachmentTests: XCTestCase {

    private func payload(_ elapsed: Double) -> Data {
        // swiftlint:disable:next force_try
        try! JSONEncoder().encode(CopySample(elapsed: elapsed, deviceBytes: 1_000_000))
    }

    func testClearingHandlersDetachesAFinishedRun() {
        let helper = PrivilegedHelper()
        var samples = 0
        var logs = 0
        helper.setHandlers(onLog: { _ in logs += 1 },
                           onProgress: { _, _ in },
                           onSample: { _ in samples += 1 })

        helper.callbacks.helperDidLog("during the run")
        helper.callbacks.helperDidSample(payload(2))
        XCTAssertEqual(samples, 1)
        XCTAssertEqual(logs, 1)

        helper.clearHandlers()

        // This is a singleton: before the fix these closures stayed live until
        // the *next* run replaced them, so a late sample reached a finished run.
        helper.callbacks.helperDidLog("after the run ended")
        helper.callbacks.helperDidSample(payload(4))
        XCTAssertEqual(samples, 1, "a sample arriving after the run ended must not reach it")
        XCTAssertEqual(logs, 1, "a log line arriving after the run ended must not reach it")
    }

    func testAMalformedPayloadIsDroppedRatherThanGuessedAt() {
        let helper = PrivilegedHelper()
        var samples = 0
        helper.setHandlers(onLog: { _ in }, onProgress: { _, _ in }, onSample: { _ in samples += 1 })
        helper.callbacks.helperDidSample(Data("not json".utf8))
        helper.callbacks.helperDidSample(Data())
        XCTAssertEqual(samples, 0)
    }

    func testAClosedTraceStaysClosed() throws {
        let writer = CopyTraceWriter(stamp: "test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: writer.fileURL) }

        writer.append(CopySample(elapsed: 1, deviceBytes: 10))
        writer.close()
        writer.append(CopySample(elapsed: 2, deviceBytes: 20))

        // `append` opens the file lazily, so without a latch the second sample
        // would reopen a trace that had already been finished and extend it.
        let text = try waitForSettledFile(writer.fileURL)
        XCTAssertEqual(CopySample.parseTrace(text).count, 1,
                       "a trace must not grow after the run that produced it ended")
    }

    private func waitForSettledFile(_ url: URL) throws -> String {
        var last = ""
        for _ in 0..<50 {
            usleep(20_000)
            let now = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if !now.isEmpty, now == last { return now }
            last = now
        }
        return last
    }
}
