import BootItShared
import XCTest

/// The two things that can happen to a drive mid-run, measured on hardware
/// 2026-08-04 and replayed here.
///
/// This was §5 question 4 — ChatGPT's catch, and the one the other two legs did
/// not raise. It had been handled defensively since, with no evidence either
/// hazard was real or that the handling was right. Both were measured on the
/// SanDisk used for the recorded run:
///
/// | Event | `Bytes (Write)` before | after | |
/// |---|---|---|---|
/// | Sleep + wake, drive left attached | 99,840 | 247,808 | **survives** |
/// | Unplug + replug | 21,261,767,168 | 99,840 | **resets** |
///
/// They are not the same hazard and only one needs handling. The counter lives
/// on the `IOBlockStorageDriver` instance: sleeping does not destroy it, so the
/// count continues monotonically across a wake. Unplugging destroys it, and the
/// replacement starts from zero.
final class CounterHazardTests: XCTestCase {

    private func samples(_ readings: [(Double, Int64)]) -> [CopySample] {
        readings.map { CopySample(elapsed: $0.0, deviceBytes: $0.1) }
    }

    /// Sleep is a non-event. The counter keeps counting, so the run total stays
    /// knowable and the ring keeps carrying bytes written.
    ///
    /// The only visible effect is the ~148 KB the system itself writes flushing
    /// and remounting around a sleep, which is well under the 1 MB movement
    /// floor — so a drive asleep next to an idle volume still reads as idle, and
    /// a working one is unaffected.
    func testSleepDoesNotDisturbTheRunTotal() {
        let states = CopyProgressModel.replay(samples([
            (0, 5_000_000_000),
            (2, 5_100_000_000),
            (4, 5_100_147_968),   // the measured sleep/wake bookkeeping, +148 KB
            (6, 5_300_000_000)
        ]))

        XCTAssertTrue(states.allSatisfy { $0.bytesWritten != nil },
                      "nothing about a sleep makes the total unknowable")
        XCTAssertEqual(states.last?.bytesWritten, 300_000_000)
    }

    /// A replug is a different counter wearing the same name. The real readings:
    /// 21,261,767,168 at the end of the run, 99,840 after unplugging and
    /// plugging back in.
    ///
    /// The total must go nil and *stay* nil — its baseline is gone and no later
    /// sample brings it back. Reporting 99,840 bytes written after 21 GB had
    /// already landed would be a bar running backwards.
    func testAReplugGivesUpTheRunTotalForGood() {
        let states = CopyProgressModel.replay(samples([
            (0, 21_000_000_000),
            (2, 21_261_767_168),
            (4, 99_840),          // measured, immediately after replug
            (6, 40_000_000),
            (8, 80_000_000)
        ]))

        XCTAssertNotNil(states[1].bytesWritten, "still knowable before the replug")
        XCTAssertNil(states[2].bytesWritten, "the baseline is gone")
        XCTAssertNil(states.last?.bytesWritten,
                     "and it does not come back — a later sample is not a new baseline")
    }

    /// Throughput does survive, because a rate needs only two adjacent samples
    /// while a total needs an origin. Giving up one and keeping the other is the
    /// honest split, and it means a replugged drive still shows liveness.
    func testThroughputSurvivesAReplug() {
        let states = CopyProgressModel.replay(samples([
            (0, 21_261_767_168),
            (2, 99_840),
            (4, 40_000_000),
            (6, 80_000_000),
            (8, 120_000_000)
        ]))

        XCTAssertNil(states.last?.bytesWritten)
        let moving = states.suffix(2).filter {
            if case .writing = $0.activity { return true }
            return false
        }
        XCTAssertFalse(moving.isEmpty, "the drive is plainly working and must read as working")
    }
}
