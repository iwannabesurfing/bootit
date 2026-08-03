import BootItShared
import Foundation

/// The 2026-08-03 write, reconstructed.
///
/// **This is not a recorded trace.** The instrumentation that would have
/// produced one is what this session is adding; the run it describes predates
/// it. Six values were measured and are reproduced exactly, and the samples
/// between them are interpolated:
///
/// | Measured | Value | Source |
/// |---|---|---|
/// | Run duration | 20:29:47 → ~21:07, 2233 s | session log, `createinstallmedia` timestamps |
/// | `df` used at +73 s | 1.13 GB | session log table |
/// | `df` used at +193 s | 2.06 GB | session log table |
/// | `df` used at +253 s | 18.71 GB | session log table — +16.65 GB in 60 s at ~9 MB/s |
/// | `df` used, +253 s → end | 18.71 GB, unchanged | session log table |
/// | Device throughput | 535 MB/min, steady | session log table |
/// | Device bytes, whole run | 21.266 GB | `IOBlockStorageDriver` on the stick, still attached 2026-08-04 |
/// | Payload landed | 20.105 GB | `diskutil info disk4s2`, same stick |
///
/// The interpolation is linear, which the measurement explicitly supports for
/// the device column ("steady") and does not contradict for the frozen `df`
/// column. It is used for exactly one thing: proving that the old reader
/// freezes on this data and the new one does not. That property is fixed by the
/// measured points, not by the interpolation between them.
///
/// Replace this with a recorded `.jsonl` the moment an instrumented run exists.
enum CopyTraceFixtures {

    static let runDuration: Double = 2233
    static let deviceBytesTotal: Int64 = 21_266_141_696
    static let payloadLanded: Int64 = 20_105_474_048

    /// `df` used-bytes at `t`, following the four measured points and then flat.
    static func volumeUsed(at t: Double) -> Int64 {
        let points: [(Double, Double)] = [(0, 0), (73, 1.13e9), (193, 2.06e9), (253, 18.71e9)]
        if t >= 253 { return 18_710_000_000 }
        for i in 1..<points.count where t <= points[i].0 {
            let (t0, v0) = points[i - 1], (t1, v1) = points[i]
            let f = (t - t0) / (t1 - t0)
            return Int64(v0 + (v1 - v0) * f)
        }
        return 0
    }

    /// Cumulative device bytes at `t`, ramping steadily to the measured total.
    ///
    /// `offset` seeds a non-zero starting value, as a real device that has been
    /// written to before this run reports.
    static func deviceBytes(at t: Double, offset: Int64 = 0) -> Int64 {
        offset + Int64(Double(deviceBytesTotal) * min(1, t / runDuration))
    }

    /// The reconstruction, sampled on the interval the daemon uses.
    ///
    /// The last sample lands exactly on the end of the run whatever the interval
    /// divides into, because a real run's final sample is taken when the tool
    /// exits, not when the timer next happens to fire.
    static func run(interval: Double = 2, deviceOffset: Int64 = 0) -> [CopySample] {
        var times = Array(stride(from: 0.0, to: runDuration, by: interval))
        times.append(runDuration)
        return times.map { t in
            CopySample(elapsed: t,
                       deviceBytes: deviceBytes(at: t, offset: deviceOffset),
                       processBytes: nil,
                       volumeUsedBytes: volumeUsed(at: t),
                       line: nil)
        }
    }

    /// What `expectedPayloadBytes` would have returned for this run: the
    /// 18.37 GB `SharedSupport.dmg` times the 1.1 overhead constant.
    static let expectedPayload = Int64(18.37e9 * 1.1)
}

/// The progress reader BootIt shipped until 2026-08-04, kept here — and only
/// here — so the fixture can prove it wrong.
///
/// It is deleted from the app. A test that replays a trace through a
/// reimplementation of a bug proves nothing about the bug, so this is a verbatim
/// copy of what shipped, not a paraphrase of it. Its constants are the shipped
/// ones: 0.15 where the erase ended, 0.93 as the cap it could not pass.
///
/// If a future percentage is ever re-approved (synthesis §D1, against traces
/// from a device matrix), it must clear this fixture before it ships.
enum LegacyFilesystemProgress {

    static let copyStart = 0.15
    static let copyCeiling = 0.93

    static func copyFraction(used: Int64, expected: Int64) -> Double {
        guard expected > 0, used > 0 else { return copyStart }
        let ratio = min(1.0, Double(used) / Double(expected))
        return copyStart + ratio * (copyCeiling - copyStart)
    }
}
