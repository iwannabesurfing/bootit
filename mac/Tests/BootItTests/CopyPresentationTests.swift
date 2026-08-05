import BootItShared
import XCTest
@testable import BootItKit

/// What the progress screen claims during the opaque copy.
///
/// The defect being guarded against is not a wrong number — it is a *confident*
/// number where none is available. These assert the app declines to produce one.
final class CopyPresentationTests: XCTestCase {

    private func model(_ activity: CopyActivity, progress: Double = 0.15) -> AppModel {
        let model = AppModel()
        model.progress = progress
        model.copyState = CopyProgressState(
            activity: activity,
            bytesWritten: 12_400_000_000,
            elapsed: 900,
            fraction: nil,
            status: CopyProgressModel.status(for: activity),
            detail: CopyProgressModel.detail(for: activity, bytesWritten: 12_400_000_000))
        return model
    }

    func testTheRingHasNoValueWhileTheCopyIsOpaque() {
        // The whole point. A number here is a claim nothing supports.
        XCTAssertNil(model(.writing(bytesPerSecond: 9_000_000)).ringValue)
        XCTAssertNil(model(.idle(seconds: 200)).ringValue)
        XCTAssertNil(model(.unmeasured(reason: .unavailable)).ringValue)
        XCTAssertNil(model(.starting).ringValue)
    }

    /// No copy state draws a number, `.finishing` included.
    ///
    /// It did until 2026-08-05, paired with a fabricated 0.95. With that gone,
    /// `progress` is still at the erase ceiling during the copy, so honouring it
    /// here would draw ~15% at 90% through the run. Both directions of the same
    /// error; the ring stays indeterminate until the run itself completes.
    func testTheRingStaysIndeterminateEvenForTheFinishingTail() {
        XCTAssertNil(model(.finishing, progress: 0.15).ringValue)
        XCTAssertNil(model(.finishing, progress: 0.95).ringValue)
    }

    /// And the measured phases are untouched — this only ever governed the
    /// opaque macOS copy, so the download, the erase and all of Windows keep
    /// their real percentage.
    func testTheRingIsDeterminateWhenNoCopyIsRunning() {
        let model = AppModel()
        model.progress = 0.42
        XCTAssertEqual(model.ringValue, 0.42)
    }

    func testOnlyAQuietDriveIsDrawnAsAWarning() {
        XCTAssertTrue(model(.idle(seconds: 200)).livenessIsWarning)
        // "Can't measure this drive" is a limitation, not a fault — colouring it
        // as one sends people hunting for a problem that isn't there.
        XCTAssertFalse(model(.unmeasured(reason: .unavailable)).livenessIsWarning)
        XCTAssertFalse(model(.writing(bytesPerSecond: 9_000_000)).livenessIsWarning)
        XCTAssertFalse(model(.finishing).livenessIsWarning)
    }

    func testTheStatusLineNeverPromisesAFixedDuration() {
        // The log line said "10–20 minutes" against a measured 38.
        for activity: CopyActivity in [.starting, .writing(bytesPerSecond: 9_000_000),
                                       .idle(seconds: 200), .finishing,
                                       .unmeasured(reason: .reset)] {
            let text = model(activity).copyState?.status ?? ""
            XCTAssertFalse(text.contains("10–20"), text)
            XCTAssertFalse(text.contains("minutes"), text)
        }
    }

    func testLivenessDetailNamesThroughputAndBytes() {
        let detail = model(.writing(bytesPerSecond: 8_900_000)).copyState?.detail ?? ""
        XCTAssertTrue(detail.contains("12.4 GB written"), detail)
        XCTAssertTrue(detail.contains("8.9 MB/s"), detail)
    }

    func testAFinishedRunLeavesNoLivenessLineBehind() {
        // A run that ends must not leave the screen describing a drive nothing
        // is writing to.
        let model = self.model(.writing(bytesPerSecond: 9_000_000))
        model.reset()
        XCTAssertNil(model.copyState)
        XCTAssertEqual(model.ringValue, 0)
    }

    // MARK: - The cancel window (synthesis UNANIMOUS #9)
    //
    // Decided at the gate on 2026-08-03, unimplemented until the first cancel
    // was ever fired on 2026-08-05. `createinstallmedia` surfaced from
    // uninterruptible sleep twice in 85 seconds, so the gap between the click
    // and the stop is seconds of a screen that has to mean something.

    /// The status line stops describing the copy and starts describing the wait.
    func testCancellingTakesOverTheStatusLine() {
        let model = self.model(.writing(bytesPerSecond: 9_000_000))
        model.statusText = "Copying macOS to the drive…"
        XCTAssertEqual(model.displayedStatus, "Copying macOS to the drive…")

        model.cancel()
        XCTAssertTrue(model.isCancelling)
        XCTAssertEqual(model.displayedStatus, CopyProgressModel.cancellingStatus)
        XCTAssertTrue(model.displayedStatus.contains("waiting for the drive"),
                      "the delay belongs to the drive and the wording must say so")
    }

    /// And the byte counter goes away, because it keeps rising after the click.
    func testTheLivenessLineIsSuppressedWhileCancelling() {
        let model = self.model(.writing(bytesPerSecond: 9_000_000))
        XCTAssertTrue(model.showsLivenessLine)

        model.cancel()
        XCTAssertFalse(model.showsLivenessLine,
                       "'waiting for the drive' above a climbing byte count reads as a contradiction")
    }

    /// The window closes however the run ends — including the write finishing
    /// normally in the seconds after the click.
    func testTheCancelWindowClosesWhenTheRunDoes() {
        let model = self.model(.writing(bytesPerSecond: 9_000_000))
        model.cancel()
        XCTAssertTrue(model.isCancelling)

        model.endCopyReporting()
        let expectation = XCTestExpectation(description: "main queue drains")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
        XCTAssertFalse(model.isCancelling)
    }

    /// Starting over clears it too, so a retry does not open on the last run's
    /// pending cancel.
    func testStartingOverClearsTheCancelWindow() {
        let model = self.model(.writing(bytesPerSecond: 9_000_000))
        model.cancel()
        model.reset()
        XCTAssertFalse(model.isCancelling)
        XCTAssertEqual(model.displayedStatus, "Starting…")
    }
}

/// The trace file every run leaves behind — the evidence a future percentage
/// would have to be argued from.
final class CopyTraceWriterTests: XCTestCase {

    func testStampIsFilenameSafeAndSortsChronologically() {
        let early = CopyTraceWriter.stamp(for: Date(timeIntervalSince1970: 1_000_000))
        let late = CopyTraceWriter.stamp(for: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertLessThan(early, late, "stamps must sort in time order as strings")
        for stamp in [early, late] {
            XCTAssertFalse(stamp.contains("/"), stamp)
            XCTAssertFalse(stamp.contains(":"), stamp)   // a path separator in Finder
            XCTAssertFalse(stamp.contains(" "), stamp)
        }
    }

    func testStampIsUTCRegardlessOfWhereTheMachineIs() {
        // A trace named in local time cannot be compared against a log from
        // another machine, and half of them would be an hour out twice a year.
        XCTAssertEqual(CopyTraceWriter.stamp(for: Date(timeIntervalSince1970: 0)),
                       "1970-01-01T000000Z")
    }

    func testSamplesRoundTripThroughAWrittenFile() throws {
        let writer = CopyTraceWriter(stamp: "test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: writer.fileURL) }

        let samples = Array(CopyTraceFixtures.run().prefix(20))
        samples.forEach(writer.append)
        writer.close()

        // Writes are queued; wait for the file rather than for a fixed delay.
        let text = try waitForFile(writer.fileURL, toContainLines: samples.count)
        XCTAssertEqual(CopySample.parseTrace(text), samples)
    }

    func testPruningKeepsRecentTracesAndRemovesStaleOnes() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = sandbox.appendingPathComponent("copy-trace-old.jsonl")
        let recent = sandbox.appendingPathComponent("copy-trace-recent.jsonl")
        let unrelated = sandbox.appendingPathComponent("something-else.log")
        for (url, age) in [(old, 40.0), (recent, 3.0), (unrelated, 400.0)] {
            fm.createFile(atPath: url.path, contents: Data("{}".utf8))
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age * 86_400)],
                                 ofItemAtPath: url.path)
        }

        CopyTraceWriter.pruneOldTraces(olderThan: 30, now: now, fileManager: SandboxedFileManager(sandbox))

        XCTAssertFalse(fm.fileExists(atPath: old.path), "a 40-day-old trace should be pruned")
        XCTAssertTrue(fm.fileExists(atPath: recent.path), "a 3-day-old trace should be kept")
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path),
                      "pruning must only ever touch files it wrote")
    }

    private func waitForFile(_ url: URL, toContainLines count: Int) throws -> String {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if text.split(separator: "\n").count >= count { return text }
            usleep(20_000)
        }
        XCTFail("trace never reached \(count) lines")
        return ""
    }
}

/// Redirects the pruner at a temporary directory, so a test can never delete a
/// real trace out of the user's Logs folder.
private final class SandboxedFileManager: FileManager {
    private let root: URL
    init(_ root: URL) { self.root = root; super.init() }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        try super.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: mask)
    }
}
