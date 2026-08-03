import BootItShared
import XCTest

/// The copy reporter, driven from traces rather than from hardware.
///
/// Every earlier version of this logic could only be falsified by a 40-minute
/// write against a real stick, which is why three wrong answers shipped. These
/// run in milliseconds.
final class CopyProgressModelTests: XCTestCase {

    // MARK: - The mutation check
    //
    // The fixture has to prove the fix, not merely accompany it. Replayed
    // through the reader BootIt shipped, it must reproduce the pathology that
    // was measured; replayed through the new one, it must not.

    func testOldReaderFreezesOnTheTraceThatExposedIt() {
        let samples = CopyTraceFixtures.run()
        let expected = CopyTraceFixtures.expectedPayload

        let atFreeze = LegacyFilesystemProgress.copyFraction(
            used: CopyTraceFixtures.volumeUsed(at: 253), expected: expected)
        let atEnd = LegacyFilesystemProgress.copyFraction(
            used: CopyTraceFixtures.volumeUsed(at: 2233), expected: expected)

        // Four minutes in and 33 minutes later, the identical number.
        XCTAssertEqual(atFreeze, atEnd, accuracy: 0.0001)
        // And high enough to read as nearly finished, which is what made it a
        // defect rather than merely a coarse bar.
        XCTAssertGreaterThan(atFreeze, 0.85)

        // The frozen stretch is the overwhelming majority of the run.
        let frozen = samples.filter { $0.elapsed >= 253 }
        XCTAssertGreaterThan(Double(frozen.count) / Double(samples.count), 0.85)
    }

    func testNewReaderKeepsReportingMovementAcrossTheFrozenStretch() {
        let states = CopyProgressModel.replay(CopyTraceFixtures.run())
        let afterTheFreeze = zip(CopyTraceFixtures.run(), states)
            .filter { $0.0.elapsed >= 300 }
            .map(\.1)

        XCTAssertFalse(afterTheFreeze.isEmpty)
        for state in afterTheFreeze {
            guard case .writing(let rate) = state.activity else {
                return XCTFail("expected .writing at \(state.elapsed) s, got \(state.activity)")
            }
            // The measured 535 MB/min is 8.9 MB/s; allow the interpolation slack.
            XCTAssertEqual(rate, 9_524_000, accuracy: 1_500_000)
        }
    }

    func testBytesWrittenTracksTheDeviceNotTheFilesystem() throws {
        let states = CopyProgressModel.replay(CopyTraceFixtures.run())
        let final = try XCTUnwrap(states.last)
        // The filesystem froze at 18.71 GB; the device kept going to 21.27 GB.
        XCTAssertEqual(final.bytesWritten, CopyTraceFixtures.deviceBytesTotal)
    }

    // MARK: - Baseline

    func testTotalIsMeasuredFromTheFirstReadingNotFromZero() {
        // A stick written to before this run reports a large starting value.
        // Reporting it as "written this run" would open at 40 GB.
        let offset: Int64 = 40_000_000_000
        let states = CopyProgressModel.replay(CopyTraceFixtures.run(deviceOffset: offset))
        XCTAssertEqual(states.first?.bytesWritten, 0)
        XCTAssertEqual(states.last?.bytesWritten, CopyTraceFixtures.deviceBytesTotal)
    }

    // MARK: - The states

    func testNoDeviceCounterIsReportedAsUnmeasuredNotAsStalled() {
        let samples = (0..<10).map { CopySample(elapsed: Double($0) * 2, deviceBytes: nil) }
        let states = CopyProgressModel.replay(samples)
        for state in states {
            XCTAssertEqual(state.activity, .unmeasured(reason: .unavailable))
            XCTAssertNil(state.bytesWritten)
        }
        XCTAssertEqual(states.last?.detail,
                       "This drive doesn't report progress — the copy is still running")
    }

    func testSilenceBeyondTheThresholdIsReportedAsWaiting() {
        var samples = (0...15).map {
            CopySample(elapsed: Double($0) * 2, deviceBytes: Int64($0) * 10_000_000)
        }
        // Counter stops moving at t = 30; keep sampling for another three minutes.
        let stuck = samples.last!.deviceBytes
        samples += stride(from: 32.0, through: 210.0, by: 2).map {
            CopySample(elapsed: $0, deviceBytes: stuck)
        }
        let states = CopyProgressModel.replay(samples)

        // Still "writing" one minute into the silence — a slow stick between
        // extents must not be accused of stalling.
        let atOneMinute = states.first { $0.elapsed == 90 }
        XCTAssertEqual(atOneMinute?.activity, .writing(bytesPerSecond: 0))

        guard case .idle(let seconds) = states.last?.activity else {
            return XCTFail("expected .idle, got \(String(describing: states.last?.activity))")
        }
        XCTAssertEqual(seconds, 180, accuracy: 0.001)
        XCTAssertEqual(states.last?.status, "Waiting for the drive")
    }

    func testJournalNoiseOnAWedgedDriveDoesNotPassAsMovement() {
        // Measured on the still-attached 2026-08-03 stick: an idle *mounted*
        // volume ticks its journal ~275 B/s. Counting any increase at all as
        // movement means the one drive that most needs reporting — wedged, but
        // still mounted — resets the clock forever and never gets reported.
        let noise = 275.0
        let samples = stride(from: 0.0, through: 400.0, by: 2).map {
            CopySample(elapsed: $0, deviceBytes: 5_000_000_000 + Int64($0 * noise))
        }
        let states = CopyProgressModel.replay(samples)

        guard case .idle(let seconds) = states.last?.activity else {
            return XCTFail("journal noise passed as movement: \(String(describing: states.last?.activity))")
        }
        XCTAssertGreaterThan(seconds, 90)
    }

    func testAGenuinelySlowDriveIsNotMistakenForAWedgedOne() {
        // The floor must not swallow a drive that is working, just slowly.
        // 500 KB/s is far below the 9 MB/s we measured and still clears 1 MB
        // every two seconds.
        let samples = stride(from: 0.0, through: 400.0, by: 2).map {
            CopySample(elapsed: $0, deviceBytes: Int64($0 * 500_000))
        }
        guard case .writing = CopyProgressModel.replay(samples).last?.activity else {
            return XCTFail("a slow but working drive was reported as idle")
        }
    }

    func testFinishingComesFromTheToolNotFromTheCountersGoingFlat() {
        let flat = (0...120).map { CopySample(elapsed: Double($0) * 2, deviceBytes: 1_000) }
        // Counters flat for four minutes and the tool silent: this is waiting,
        // not finishing. Inferring a flush here would be the same defect as the
        // three readers this replaces.
        XCTAssertEqual(CopyProgressModel.replay(flat).last?.activity, .idle(seconds: 240))

        var announced = flat
        announced[60].line = "Making disk bootable..."
        let states = CopyProgressModel.replay(announced)
        XCTAssertEqual(states[59].activity, .idle(seconds: 118))
        XCTAssertEqual(states[60].activity, .finishing)
        XCTAssertEqual(states.last?.activity, .finishing)
        XCTAssertEqual(states.last?.status, "Making the drive bootable…")
    }

    // MARK: - The counter reset ChatGPT caught

    func testACounterResetGivesUpTheTotalAndKeepsTheRate() {
        var samples = (0...30).map {
            CopySample(elapsed: Double($0) * 2, deviceBytes: 10_000_000_000 + Int64($0) * 10_000_000)
        }
        // Device re-enumerates: the counter restarts near zero.
        samples += (0...30).map {
            CopySample(elapsed: 62 + Double($0) * 2, deviceBytes: Int64($0) * 10_000_000)
        }
        let states = CopyProgressModel.replay(samples)

        XCTAssertEqual(states[30].bytesWritten, 300_000_000)
        XCTAssertEqual(states[31].activity, .unmeasured(reason: .reset))
        XCTAssertEqual(states[31].detail, "The drive reconnected, so the total so far is unknown")

        // The run total is gone for good — its baseline no longer exists…
        XCTAssertNil(states.last?.bytesWritten)
        // …but throughput needs only two adjacent samples, so it recovers.
        guard case .writing(let rate) = states.last?.activity else {
            return XCTFail("expected .writing after the reset, got \(String(describing: states.last?.activity))")
        }
        XCTAssertEqual(rate, 5_000_000, accuracy: 100_000)
        XCTAssertEqual(states.last?.detail, "5.0 MB/s")
    }

    // MARK: - The decision itself

    func testNoPercentageIsClaimedForTheOpaquePhase() {
        // The synthesis' core resolution: no macOS percentage until traces from a
        // device matrix clear the evidence bar. If this test starts failing,
        // someone has re-introduced one — check §D1 before deleting it.
        for state in CopyProgressModel.replay(CopyTraceFixtures.run()) {
            XCTAssertNil(state.fraction)
        }
    }

    func testTheDurationClaimIsARangeNotTheOldTwentyMinutePromise() {
        XCTAssertFalse(CopyProgressModel.durationRange.contains("10–20"))
        XCTAssertTrue(CopyProgressModel.durationRange.contains("15–45"))
    }

    // MARK: - The rate window

    func testAShortWindowManufacturesAStallThatIsNotHappening() {
        // Why the window is 30 s and not 4: on the real trace a four-second
        // window read 1–3.5 MB/s against a true ~9 MB/s and nearly produced a
        // "stalled" call on a drive writing steadily. Sampling is coarse enough
        // that a short window sees whole intervals of nothing.
        let samples: [CopySample] = stride(from: 0.0, through: 120.0, by: 2).map { t in
            // Bursty at the sample scale, steady at the minute scale.
            let bursts = Int64(t / 10) * 90_000_000
            return CopySample(elapsed: t, deviceBytes: bursts)
        }
        // Judged only once each window has had time to fill: before that both
        // are averaging over whatever they have, and neither claim applies.
        let short = rates(CopyProgressModel.replay(samples, dials: .init(rateWindow: 4,
                                                                        idleThreshold: 90)),
                          after: 30)
        let long = rates(CopyProgressModel.replay(samples, dials: .init(rateWindow: 30,
                                                                       idleThreshold: 90)),
                         after: 30)

        XCTAssertTrue(short.contains { $0 == 0 },
                      "a 4 s window should see intervals of apparent stillness")
        XCTAssertFalse(long.contains { $0 == 0 },
                       "a 30 s window should see through them")
        XCTAssertEqual(long.last ?? 0, 9_000_000, accuracy: 1_500_000)
    }

    private func rates(_ states: [CopyProgressState], after: Double = 0) -> [Double] {
        states.filter { $0.elapsed >= after }.compactMap {
            if case .writing(let rate) = $0.activity { return rate }
            return nil
        }
    }

    // MARK: - Trace round-trip

    func testATraceSurvivesEncodingAndAnInterruptedLastLine() {
        let samples = Array(CopyTraceFixtures.run().prefix(5))
        var text = try! samples.map { try $0.traceLine() }.joined()
        // A run killed mid-write leaves a partial line. That trace is the most
        // interesting one, so parsing must not throw the whole file away.
        text += #"{"elapsed":11.0,"deviceB"#

        let parsed = CopySample.parseTrace(text)
        XCTAssertEqual(parsed, samples)
    }
}
