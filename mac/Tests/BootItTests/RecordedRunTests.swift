import BootItShared
import XCTest
@testable import BootIt

/// The first instrumented run, replayed.
///
/// **2026-08-04.** A complete `createinstallmedia` write to a 61.5 GB USB stick:
/// 865 samples over 28.8 minutes, recorded by the app itself with no special
/// build. Every number asserted below was measured, not chosen.
///
/// This file is the reason the trace format exists. Three wrong answers about
/// copy progress shipped because the only way to falsify one was a 40-minute
/// human-gated write; now a wrong answer fails in milliseconds. It replaces
/// `CopyTraceFixtures`, which reconstructed the 2026-08-03 run by interpolating
/// between six measured points and was labelled as a reconstruction throughout.
///
/// It is also the first production caller of `CopySample.parseTrace`, which was
/// recorded last session as having none.
final class RecordedRunTests: XCTestCase {

    private static let samples: [CopySample] = {
        guard let url = Bundle.module.url(forResource: "Fixtures/copy-run-2026-08-04",
                                          withExtension: "jsonl"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return CopySample.parseTrace(text)
    }()

    private var samples: [CopySample] { Self.samples }
    private var measured: [CopySample] { samples.filter { $0.deviceBytes != nil } }

    func testTheFixtureIsTheRunItClaimsToBe() {
        XCTAssertEqual(samples.count, 871, "the whole trace, log lines included")
        XCTAssertEqual(measured.count, 865)
        XCTAssertEqual(samples.last?.elapsed ?? 0, 1728.4, accuracy: 0.1)
    }

    // MARK: - What the screen would have shown

    /// The headline behaviour, on real data: across a 28.8-minute run the app
    /// never once claims a percentage during the opaque copy.
    func testTheRingNeverClaimsAPercentageDuringTheCopy() {
        let states = CopyProgressModel.replay(measured)
        let opaque = states.filter {
            if case .finishing = $0.activity { return false }
            return true
        }
        XCTAssertFalse(opaque.isEmpty)
        XCTAssertTrue(opaque.allSatisfy { $0.fraction == nil },
                      "a percentage here is a claim nothing in this trace supports")
    }

    /// And it does not spend the run telling the user the drive has stalled.
    /// `createinstallmedia` says nothing at all between 309 s and 1562 s — 20.8
    /// minutes — which is the stretch the whole feature exists for.
    func testTheDriveReadsAsMovingThroughTheTwentyMinuteSilence() {
        let silence = measured.filter { (309...1562).contains($0.elapsed) }
        XCTAssertGreaterThan(silence.count, 500)

        let states = CopyProgressModel.replay(silence)
        let idle = states.filter { if case .idle = $0.activity { return true }; return false }
        XCTAssertTrue(idle.isEmpty,
                      "the counter moved throughout; reporting a stall would be false")
    }

    /// Bytes and elapsed are the liveness figures the ring carries instead of a
    /// percentage, so they have to be present for essentially the whole run.
    func testTheLivenessFiguresAreAvailableThroughout() {
        let states = CopyProgressModel.replay(measured)
        let withTotal = states.filter { $0.bytesWritten != nil }
        XCTAssertGreaterThan(Double(withTotal.count) / Double(states.count), 0.99)
    }

    // MARK: - The measurements this run settled

    /// **Question 1, and the answer is no.** The tri-model D2 prediction was that
    /// `proc_pid_rusage` counts writes into the unified buffer cache, so it would
    /// race to the payload size within about two minutes and then freeze — the
    /// `df` failure one layer up.
    ///
    /// It did not. It tracked the device counter for the entire run and finished
    /// within 1.2% of it. The prediction is falsified on this hardware.
    ///
    /// That does **not** reinstate a percentage: the reason the app declines to
    /// show one is that the *denominator* is unknowable before the run, and a
    /// second numerator that behaves well does not supply one.
    func testTheProcessCounterDidNotRaceAheadAndFreeze() throws {
        let withProcess = measured.filter { ($0.processBytes ?? 0) > 0 }
        let end = try XCTUnwrap(measured.last?.deviceBytes)
        let start = try XCTUnwrap(measured.first?.deviceBytes)
        let device = end - start
        let process = try XCTUnwrap(withProcess.map { $0.processBytes ?? 0 }.max())

        XCTAssertEqual(Double(device) / Double(process), 1.0, accuracy: 0.05,
                       "device and process ended within 5% of each other")

        // Freezing would mean the last third of the run adds nothing. It added
        // roughly a third of the total.
        let twoThirdsIn = withProcess.first { $0.elapsed > 1152 }?.processBytes ?? 0
        XCTAssertLessThan(Double(twoThirdsIn) / Double(process), 0.95,
                          "a counter that had raced ahead and frozen would already be at its maximum")
    }

    /// **Question 2.** Device bytes exceed the payload that lands, by a little.
    /// M1 put this at 1.058 from a baseline that was assumed rather than
    /// measured; with a measured baseline it is 1.048.
    ///
    /// The direction is what matters and it is the dangerous one: a payload-sized
    /// denominator would reach 100% while roughly 5% of the writing was still to
    /// come. Gemini's 95% clamp was load-bearing, and this is why the design
    /// stopped needing it — there is no denominator to clamp.
    func testDeviceBytesExceedThePayloadThatLands() throws {
        let end = try XCTUnwrap(measured.last?.deviceBytes)
        let start = try XCTUnwrap(measured.first?.deviceBytes)
        let device = end - start
        let payload = try XCTUnwrap(measured.compactMap { $0.volumeUsedBytes }.max())
        let amplification = Double(device) / Double(payload)

        XCTAssertEqual(amplification, 1.048, accuracy: 0.01)
        XCTAssertGreaterThan(amplification, 1.0, "the device always writes more than lands")
    }

    /// **Question 3, and the answer is transfer.** After `createinstallmedia`
    /// finally prints "Copying to disk: … 100%" at 1562 s there are still 166
    /// seconds to go, and the drive writes 1.5 GB during them at 9.2 MB/s.
    ///
    /// So the tail is not a flush and not a hang. It is the drive still working,
    /// which is exactly the case a percentage would have got wrong — the tool
    /// says 100% while a sixteenth of the writing is outstanding.
    func testTheTailIsStillTransferringNotFlushing() throws {
        let tail = measured.filter { $0.elapsed >= 1562 }
        XCTAssertGreaterThan(tail.count, 50)

        let endBytes = try XCTUnwrap(tail.last?.deviceBytes)
        let startBytes = try XCTUnwrap(tail.first?.deviceBytes)
        let written = endBytes - startBytes
        let duration = try XCTUnwrap(tail.last?.elapsed) - (tail.first?.elapsed ?? 0)

        XCTAssertGreaterThan(Double(written) / 1e9, 1.0, "over a gigabyte after the tool said 100%")
        XCTAssertGreaterThan(Double(written) / duration / 1e6, 5.0, "at a working drive's rate")
    }

    /// The control column, and the whole reason three attempts failed — captured
    /// on a real run for the first time.
    ///
    /// `df` does not go blind, which is what I assumed from the first few
    /// samples and the data refuted. It goes **static**: filesystem used-bytes
    /// reaches 99.9% of its final value at **310 s**, which is 18% of the way
    /// through a 28.8-minute run. At that moment the device had written 12.7% of
    /// what it would write, and 23.6 minutes remained.
    ///
    /// So a bar driven from this column sits at essentially 100% for
    /// three-quarters of an hour-long job. That is not a rounding problem or a
    /// tuning problem, and no clamp rescues it — it is the wrong signal. The
    /// 2026-08-03 run showed the same shape sampled by hand; this is it recorded,
    /// and it now fails in milliseconds instead of after forty minutes.
    func testAFilesystemDrivenBarWouldShow99PercentAOneFifthOfTheWayThrough() throws {
        let used = measured.compactMap { sample in
            sample.volumeUsedBytes.map { (sample.elapsed, $0) }
        }
        let final = try XCTUnwrap(used.last?.1)
        let total = try XCTUnwrap(measured.last?.elapsed)

        let sawNinetyNine = try XCTUnwrap(used.first { Double($0.1) >= Double(final) * 0.99 }?.0)
        XCTAssertEqual(sawNinetyNine, 310, accuracy: 5)
        XCTAssertLessThan(sawNinetyNine / total, 0.20,
                          "99% of the filesystem's answer arrives in the first fifth of the run")

        // And what the honest signal said at the same instant.
        let start = try XCTUnwrap(measured.first?.deviceBytes)
        let end = try XCTUnwrap(measured.last?.deviceBytes)
        let atThatMoment = try XCTUnwrap(measured.first { $0.elapsed >= sawNinetyNine }?.deviceBytes)
        let reallyDone = Double(atThatMoment - start) / Double(end - start)
        XCTAssertLessThan(reallyDone, 0.20, "the drive was an eighth of the way through")
    }

    /// It then sits perfectly still for over a quarter of an hour while the drive
    /// writes on — the "frozen bar" three sessions chased.
    ///
    /// Measured as the longest motionless stretch rather than "still at its final
    /// value", because the very last sample ticks up once as the volume is
    /// unmounted. That single tick at 1726 s does not shorten the freeze the user
    /// sat through; it just means the naive phrasing of this assertion was wrong,
    /// which the data said before I could ship it.
    func testTheFilesystemAnswerFreezesForOverFifteenMinutes() throws {
        let used = measured.compactMap { sample in
            sample.volumeUsedBytes.map { (sample.elapsed, $0) }
        }
        var longest = 0.0
        var startedAt = try XCTUnwrap(used.first?.0)
        for (previous, current) in zip(used, used.dropFirst()) {
            if current.1 == previous.1 {
                longest = max(longest, current.0 - startedAt)
            } else {
                startedAt = current.0
            }
        }
        XCTAssertGreaterThan(longest, 15 * 60,
                             "the filesystem's answer does not move for over fifteen minutes")
    }
}
