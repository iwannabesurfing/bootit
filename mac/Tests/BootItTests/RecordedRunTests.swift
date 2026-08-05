import BootItShared
import XCTest
@testable import BootItKit

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
    ///
    /// The `.finishing` states used to be filtered out of this assertion. That
    /// exemption is why the 0.95 survived — the single state that claimed a
    /// percentage was the single state this test agreed not to look at. There is
    /// no filter now: `CopyProgressModel` emits `fraction: nil` unconditionally,
    /// so the honest assertion is over every state.
    func testTheRingNeverClaimsAPercentageDuringTheCopy() {
        let states = CopyProgressModel.replay(measured)
        XCTAssertFalse(states.isEmpty)
        XCTAssertTrue(states.allSatisfy { $0.fraction == nil },
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

/// Every committed trace, held to the properties that a single run cannot
/// establish on its own.
///
/// **2026-08-05.** A second complete write, same 61.5 GB stick, on the notarised
/// v3.4.0 build: 907 samples over 30.0 minutes. It exists because a human watched
/// the ring sit at 95% and asked why a drive being "made bootable" was still
/// copying — a question no green test suite had asked, because the one assertion
/// that would have caught it exempted the one state that lied.
///
/// These run over the traces as a set. A property proven on one run is a property
/// of that run; the reason this class is separate is to make adding trace #3 the
/// act of testing the claims, rather than an act of filing it.
final class EveryRecordedRunTests: XCTestCase {

    /// Each committed trace, by name so a failure says which run disagreed.
    private static let runs: [(name: String, samples: [CopySample])] = {
        ["copy-run-2026-08-04", "copy-run-2026-08-05"].compactMap { name in
            guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "jsonl"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (name, CopySample.parseTrace(text))
        }
    }()

    private var runs: [(name: String, samples: [CopySample])] { Self.runs }

    func testBothRunsLoaded() {
        XCTAssertEqual(runs.count, 2, "a missing fixture would silently pass every test below")
        XCTAssertTrue(runs.allSatisfy { $0.samples.count > 800 })
    }

    /// The regression this class was created for.
    ///
    /// `announcesFinishing` matched "Making disk bootable" until 2026-08-05, and
    /// the flag is sticky, so the run entered `.finishing` at 17.9% / 14.7% and
    /// stayed there. Anything claiming the end is near must actually arrive near
    /// the end — in *every* trace, not the one it was written against.
    func testNothingAnnouncesFinishingUntilTheEnd() throws {
        for run in runs {
            let total = try XCTUnwrap(run.samples.last?.elapsed)
            let announcements = run.samples
                .compactMap { sample in sample.line.map { (sample.elapsed, $0) } }
                .filter { CopyProgressModel.announcesFinishing($0.1) }

            let first = try XCTUnwrap(announcements.first?.0,
                                      "\(run.name): no line announces finishing at all")
            XCTAssertGreaterThan(first / total, 0.80,
                                 "\(run.name): announced finishing at \(Int(first / total * 100))% of the run")
        }
    }

    /// The same property stated as the user saw it break: how much of the run is
    /// spent showing the finishing status. At 14.7% in, it was 85% of a
    /// thirty-minute write.
    func testTheFinishingStatusIsNotMostOfTheRun() throws {
        for run in runs {
            let measured = run.samples.filter { $0.deviceBytes != nil || $0.line != nil }
            let states = CopyProgressModel.replay(measured)
            let finishing = states.filter { if case .finishing = $0.activity { return true }; return false }
            let share = Double(finishing.count) / Double(states.count)

            XCTAssertLessThan(share, 0.20,
                              "\(run.name): \(Int(share * 100))% of the run reads 'Making the drive bootable…'")
        }
    }

    /// The premise the deleted `0.95` rested on, stated as a falsifiable claim
    /// rather than a comment: the bulk of the bytes land *after* the tool says it
    /// is making the disk bootable.
    func testMostOfTheWritingHappensAfterTheBootableBanner() throws {
        for run in runs {
            let banner = try XCTUnwrap(run.samples.first { ($0.line ?? "").contains("Making disk bootable") }?.elapsed,
                                       "\(run.name): the banner both traces contain")
            let measured = run.samples.filter { $0.deviceBytes != nil }
            let start = try XCTUnwrap(measured.first?.deviceBytes)
            let end = try XCTUnwrap(measured.last?.deviceBytes)
            let atBanner = try XCTUnwrap(measured.first { $0.elapsed >= banner }?.deviceBytes)

            let doneThen = Double(atBanner - start) / Double(end - start)
            XCTAssertLessThan(doneThen, 0.25,
                              "\(run.name): banner arrived with \(Int((1 - doneThen) * 100))% still to write")
        }
    }

    /// macOS 26 does emit copy percentages — the claim that it "prints nothing"
    /// was contradicted by `copy-run-2026-08-04.jsonl` on the day that fixture
    /// was committed. What it does not do is emit them *live*.
    ///
    /// The three stage banners arriving within a millisecond of each other is the
    /// evidence: sequential stages cannot be simultaneous, so the tool's stdout is
    /// block-buffered down a pipe and released in batches. That is the finding a
    /// pty would act on, and it is pinned here so the claim stays falsifiable.
    func testTheCopyPercentagesExistButArriveInOneBatch() throws {
        for run in runs {
            let lines = run.samples.compactMap { sample in sample.line.map { (sample.elapsed, $0) } }

            XCTAssertTrue(lines.contains { $0.1.contains("Copying to disk") && $0.1.contains("100%") },
                          "\(run.name): the copy line the code claimed macOS 26 never prints")

            let banners = lines.filter {
                $0.1.contains("Copying essential files")
                    || $0.1.contains("RecoveryOS")
                    || $0.1.contains("Making disk bootable")
            }
            XCTAssertEqual(banners.count, 3, "\(run.name)")
            let spread = try XCTUnwrap(banners.last?.0) - (banners.first?.0 ?? 0)
            XCTAssertLessThan(spread, 0.01,
                              "\(run.name): three sequential stages \(spread)s apart is a buffer flush, not progress")
        }
    }
}
