import Foundation

/// How the copy is behaving right now.
///
/// Deliberately **not** a percentage. Three shipped attempts answered "what
/// fraction is done" when the question being asked of the screen was "is this
/// still working", and each answer was wrong in a different way: output parsing
/// (the tool says nothing for 33 minutes), filesystem used-bytes (JHFS+ reports
/// the allocation up front, so the bar reached 95% in four minutes and froze),
/// and a fixed time estimate (device throughput spans two orders of magnitude).
///
/// See `docs/research/copy-progress-reporting-trimodel-synthesis.md`.
public enum CopyActivity: Equatable {

    /// Sampling has begun but the device has not moved yet.
    case starting

    /// Bytes are reaching the device, at this rate.
    case writing(bytesPerSecond: Double)

    /// Nothing has reached the device for a while. Reported, not hidden: a slow
    /// stick and a wedged one look identical for the first minute, and only one
    /// of them is worth waiting on.
    case idle(seconds: Double)

    /// The tool has announced the bless step.
    ///
    /// Entered **only** when the tool says so, never inferred from the counters
    /// going flat. Whether the long tail of a run is transfer or flush is an open
    /// measurement, and guessing it would be the same defect as the three fixes
    /// this design replaces: reporting what we concluded instead of what we were
    /// told.
    case finishing

    /// No trustworthy byte signal. The screen drops to elapsed time and says so.
    case unmeasured(reason: UnmeasuredReason)

    public enum UnmeasuredReason: String, Equatable {
        /// The device counter could not be read at all.
        case unavailable
        /// The counter went backwards — the device re-enumerated, was detached
        /// and reattached, or the machine slept. Cheap to detect, and it
        /// invalidates every total derived from a baseline captured before it.
        case reset
    }
}

/// What the screen should say about the copy.
public struct CopyProgressState: Equatable {

    public var activity: CopyActivity

    /// Bytes written this run, or nil once that number stops being knowable.
    ///
    /// Goes nil — and stays nil — after a counter reset. A rate survives a reset
    /// because it only needs two adjacent samples; a run total does not, because
    /// its baseline is gone. Dropping the total while keeping the rate is the
    /// honest split, and it is why these are separate fields.
    public var bytesWritten: Int64?

    public var elapsed: Double

    /// Completion, when there is a defensible one — nil means an indeterminate
    /// ring, which is the macOS copy phase today.
    ///
    /// The evidence bar for filling this in is in the synthesis §D1: a
    /// denominator that holds across slow flash, fast flash, external SSD and a
    /// hub, and that does not reach 90–99% substantially before completion. One
    /// instrumented run on one stick does not clear it. Traces are being
    /// collected; until they clear the bar this stays nil.
    public var fraction: Double?

    /// One short sentence naming the state.
    public var status: String

    /// The liveness numbers, when there are any.
    public var detail: String?

    public init(activity: CopyActivity,
                bytesWritten: Int64?,
                elapsed: Double,
                fraction: Double?,
                status: String,
                detail: String?) {
        self.activity = activity
        self.bytesWritten = bytesWritten
        self.elapsed = elapsed
        self.fraction = fraction
        self.status = status
        self.detail = detail
    }
}

/// Tunable thresholds, gathered so they can be changed from measurement rather
/// than hunted for in the logic.
public struct CopyProgressDials: Equatable {

    /// How far back the throughput average reaches.
    ///
    /// Thirty seconds, not four. A four-second window on the 2026-08-03 trace
    /// read 1–3.5 MB/s against a true ~9 MB/s, which nearly produced a "stalled"
    /// call on a drive that was writing steadily the whole time. Too short is
    /// not merely noisy — it manufactures a state that is not happening.
    public var rateWindow: Double = 30

    /// Silence before the screen says so. Long enough that a slow stick between
    /// large extents is not accused of stalling.
    public var idleThreshold: Double = 90

    /// How many bytes have to arrive before that counts as the drive moving.
    ///
    /// Not zero, and this was measured rather than guessed: a *mounted, idle*
    /// volume ticks its journal about 275 B/s, so treating any increase at all
    /// as movement means a wedged drive is never reported as wedged — the noise
    /// keeps resetting the clock. One megabyte is 0.1 s of real writing at the
    /// rate we measured, so it cannot mask a working drive, and it takes that
    /// journal an hour to accumulate, so it cannot be faked by one.
    public var movementFloor: Int64 = 1_000_000

    public init(rateWindow: Double = 30,
                idleThreshold: Double = 90,
                movementFloor: Int64 = 1_000_000) {
        self.rateWindow = rateWindow
        self.idleThreshold = idleThreshold
        self.movementFloor = movementFloor
    }
}

/// Turns a stream of samples into what the screen should say.
///
/// A pure reducer on purpose. Every previous version of this logic could only be
/// falsified by a 40-minute write against real hardware, which is why three
/// wrong answers reached users: nobody was going to run the experiment often
/// enough to catch them. Fed from a recorded trace this is falsifiable in under
/// a second, and `replay` exists so a fixture is a test rather than a document.
public struct CopyProgressModel {

    public let dials: CopyProgressDials

    /// The first device reading of the run — every total is measured from here,
    /// because the counter is cumulative for the life of the device attachment
    /// and carries whatever was written to it before BootIt started.
    private var baseline: Int64?
    private var window: [(elapsed: Double, bytes: Int64)] = []
    private var lastDeviceBytes: Int64?
    /// Where the counter stood, and when, the last time it moved by enough to
    /// count. Both are needed: silence is measured from the time, and "enough"
    /// is measured from the reading.
    private var lastMovement: (at: Double, bytes: Int64)?
    private var totalIsKnowable = true
    private var sawResetThisSample = false
    private var announcedFinishing = false

    public init(dials: CopyProgressDials = CopyProgressDials()) {
        self.dials = dials
    }

    /// Fold one sample in and return what to display.
    public mutating func ingest(_ sample: CopySample) -> CopyProgressState {
        sawResetThisSample = false
        if let line = sample.line, Self.announcesFinishing(line) { announcedFinishing = true }

        track(sample)

        let written = totalIsKnowable ? writtenSoFar(sample) : nil
        let activity = self.activity(at: sample.elapsed)
        return CopyProgressState(activity: activity,
                                 bytesWritten: written,
                                 elapsed: sample.elapsed,
                                 fraction: nil,
                                 status: Self.status(for: activity),
                                 detail: Self.detail(for: activity, bytesWritten: written))
    }

    /// Replay a whole trace. The harness the synthesis asks for in §5.2.
    public static func replay(_ samples: [CopySample],
                              dials: CopyProgressDials = CopyProgressDials()) -> [CopyProgressState] {
        var model = CopyProgressModel(dials: dials)
        return samples.map { model.ingest($0) }
    }

    /// The tool's own announcement that the bulk copy is over.
    ///
    /// This matched `Making disk bootable` until 2026-08-05. That line arrives at
    /// **17.9%** (2026-08-04) and **14.7%** (2026-08-05) of the run, and this flag
    /// is sticky — so the screen read "Making the drive bootable…" for the last
    /// 85% of a 30-minute write while 18 GB was still being copied. The user
    /// reading it asked the question that found the bug: *if it's making the
    /// drive bootable, why is it still copying?*
    ///
    /// The copy-complete line is the real one, and it is the only tool output
    /// that lands near the end in both traces — **90.4%** and **91.4%**. Matching
    /// on the completed percentage rather than the bare prefix matters: the line
    /// is `\r`-rewritten, so a partial `Copying to disk: 30%…` is a legitimate
    /// earlier read of the same line.
    ///
    /// n = 2, one device. If a third trace disagrees, this is the assertion to
    /// break first — `RecordedRunTests.testNothingAnnouncesFinishingUntilTheEnd`
    /// pins it against every committed trace for exactly that reason.
    public static func announcesFinishing(_ line: String) -> Bool {
        line.contains("Copying to disk") && line.contains("100%")
    }

    /// Typical duration, stated as a range because a constant cannot be honest
    /// across devices that differ by two orders of magnitude in throughput. This
    /// replaces the "10–20 minutes" line, which promised 20 against a measured 38.
    public static let durationRange = "typically 15–45 minutes on USB flash"

    /// What the screen says between the Cancel click and the write stopping.
    ///
    /// Synthesis UNANIMOUS #9, decided at the gate and unimplemented until
    /// 2026-08-05: a SIGTERM to a process in uninterruptible sleep is not
    /// delivered until it returns from the syscall, so the UI must say it is
    /// waiting rather than appear to have ignored the click.
    ///
    /// Measured on the first cancel this project ever fired: `createinstallmedia`
    /// surfaced from state `U` to `R` **twice in 85 seconds**, and the drive wrote
    /// 1.00 → 1.145 GB *after* the click. Until now the only feedback was one
    /// "Cancelling…" line in a log that is collapsed by default, while the status
    /// still read "Copying macOS to the drive…" and the byte counter climbed — so
    /// the honest reading of that screen was that the button did nothing.
    ///
    /// It names the drive, not BootIt, because the delay belongs to the drive.
    public static let cancellingStatus = "Cancelling — waiting for the drive to respond…"

    // MARK: - Bookkeeping

    private mutating func track(_ sample: CopySample) {
        guard let bytes = sample.deviceBytes else { return }

        if let last = lastDeviceBytes, bytes < last {
            // Backwards is not a slow sample, it is a different counter. Rebase
            // so throughput keeps working, and give up the run total for good.
            totalIsKnowable = false
            sawResetThisSample = true
            baseline = bytes
            window.removeAll()
            lastMovement = (sample.elapsed, bytes)
        }
        if baseline == nil { baseline = bytes }
        if let moved = lastMovement {
            if bytes - moved.bytes >= dials.movementFloor { lastMovement = (sample.elapsed, bytes) }
        } else {
            lastMovement = (sample.elapsed, bytes)
        }

        lastDeviceBytes = bytes
        window.append((sample.elapsed, bytes))
        window.removeAll { sample.elapsed - $0.elapsed > dials.rateWindow }
    }

    private func writtenSoFar(_ sample: CopySample) -> Int64? {
        guard let bytes = sample.deviceBytes, let baseline else { return nil }
        return max(0, bytes - baseline)
    }

    private func activity(at elapsed: Double) -> CopyActivity {
        if sawResetThisSample { return .unmeasured(reason: .reset) }
        guard lastDeviceBytes != nil else { return .unmeasured(reason: .unavailable) }
        if announcedFinishing { return .finishing }

        guard let moved = lastMovement else { return .starting }
        let silence = elapsed - moved.at
        if silence >= dials.idleThreshold { return .idle(seconds: silence) }

        guard let rate = currentRate() else { return .starting }
        return .writing(bytesPerSecond: rate)
    }

    /// Bytes per second across the window, or nil until the window spans enough
    /// time to mean anything.
    private func currentRate() -> Double? {
        guard let first = window.first, let last = window.last else { return nil }
        let span = last.elapsed - first.elapsed
        guard span > 0 else { return nil }
        return Double(last.bytes - first.bytes) / span
    }

    // MARK: - Wording

    public static func status(for activity: CopyActivity) -> String {
        switch activity {
        case .starting:
            return "Copying macOS to the drive…"
        case .writing:
            return "Copying macOS to the drive…"
        case .idle:
            return "Waiting for the drive"
        case .finishing:
            return "Making the drive bootable…"
        case .unmeasured:
            return "Copying macOS to the drive…"
        }
    }

    public static func detail(for activity: CopyActivity, bytesWritten: Int64?) -> String? {
        let written = bytesWritten.map { "\(bytesHuman($0)) written" }
        switch activity {
        case .starting:
            return "Starting…"
        case .writing(let rate):
            let speed = "\(bytesHuman(Int64(rate)))/s"
            return [written, speed].compactMap { $0 }.joined(separator: " · ")
        case .idle(let seconds):
            let quiet = "nothing written for \(durationHuman(seconds))"
            return [written, quiet].compactMap { $0 }.joined(separator: " · ")
        case .finishing:
            return written
        case .unmeasured(let reason):
            switch reason {
            case .unavailable:
                return "This drive doesn't report progress — the copy is still running"
            case .reset:
                return "The drive reconnected, so the total so far is unknown"
            }
        }
    }
}

/// "2 min", "45 s" — coarse on purpose, because this number is only ever read to
/// answer "has it been long enough to worry".
public func durationHuman(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s) s" }
    let minutes = s / 60
    if minutes < 60 { return "\(minutes) min" }
    return "\(minutes / 60) h \(minutes % 60) min"
}
