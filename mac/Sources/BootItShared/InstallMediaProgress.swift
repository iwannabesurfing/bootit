import Foundation

/// Turns `createinstallmedia` output into a progress fraction.
///
/// In the shared target so it can be unit-tested: this logic lives in the
/// daemon, and every bug it has had — reading the first percentage instead of
/// the last, and reporting a skipped download as "complete" — was invisible in
/// code review and obvious the moment a human watched the bar not move.
public enum InstallMediaProgress {

    /// The LAST percentage on the line, not the first.
    ///
    /// createinstallmedia rewrites a single line in place, emitting
    /// "Erasing disk: 0%... 10%... 20%..." and appending as it goes. Taking the
    /// first match returns 0 forever.
    public static func lastPercent(_ line: String) -> Int? {
        var found: Int?
        var search = line.startIndex..<line.endIndex
        while let range = line.range(of: #"\d{1,3}%"#, options: .regularExpression, range: search) {
            found = Int(line[range].dropLast())
            search = range.upperBound..<line.endIndex
        }
        return found
    }

    /// Where the erase ends. Everything above this belongs to the copy, which
    /// reports liveness rather than a fraction — see `CopyProgressModel`.
    public static let eraseCeiling = 0.15

    /// Where a line of output sits in the 0…1 range.
    ///
    /// Returns nil when the line says nothing about progress, so the caller
    /// leaves the bar where it is rather than resetting it.
    ///
    /// Only the erase phase reports percentages *usefully*. What macOS 26
    /// actually emits, with the elapsed time each line arrived at, from the two
    /// committed traces:
    ///
    ///     0.9% / 2.3%   Erasing disk: 0%... 10%... 20%... 30%... 100%
    ///     17.9% / 14.7% Copying essential files...
    ///     17.9% / 14.7% Copying the macOS RecoveryOS...
    ///     17.9% / 14.7% Making disk bootable...
    ///     90.4% / 91.4% Copying to disk: 0%... 10%... ... 100%
    ///     100%          Install media now available at "…"
    ///
    /// Two things in that table were believed otherwise until 2026-08-05, and
    /// both were wrong:
    ///
    /// 1. **The copy is not silent.** `Copying to disk: 0%…100%` is emitted, on
    ///    macOS 26, and has been present in `copy-run-2026-08-04.jsonl` since the
    ///    day that fixture was committed. What is true is that it does not arrive
    ///    *live*: the three middle banners land within 0.2 ms of each other, which
    ///    sequential stages cannot do, so the tool's stdout is block-buffered
    ///    because it is a pipe rather than a tty. Every percentage is inside that
    ///    one line by the time we see it, at ~90% of the run.
    /// 2. **"Making disk bootable" is not the tail.** It arrives at 15–18%. The
    ///    bulk copy happens *after* it.
    ///
    /// So output parsing still cannot drive the bar through the copy — not for
    /// the reason previously written down, but because the numbers arrive in one
    /// batch at the end. `CopyProgressModel` reports what the drive is *doing*
    /// instead of guessing how far through it is.
    ///
    /// Defeating the buffering (a pty) is the open question this reopens; it is
    /// not attempted here, because it would revisit the tri-model synthesis's
    /// core decision rather than restore it.
    ///
    /// A `copyFraction(used:expected:)` lived here until 2026-08-04, dividing
    /// filesystem used-bytes by an estimated payload. It shipped a bar that
    /// reached 95% in four minutes of a 38-minute write and never moved again,
    /// because JHFS+ allocates the extents up front. It is deleted rather than
    /// left unused — the estimate machinery beside it invited exactly the fourth
    /// substitution the tri-model pass was convened to stop.
    public static func fraction(for line: String) -> Double? {
        if line.contains("Install media now available") { return 1.0 }
        // "Making disk bootable" returned 0.95 here until 2026-08-05, on the
        // premise — written in a comment as fact — that it was "emitted right at
        // the end, after the bulk copy". Measured across both traces it arrives
        // at 17.9% and 14.7% of the run, with 87% of the bytes still to write.
        // The 2026-08-05 run therefore displayed 95% for 25.6 of its 30 minutes.
        //
        // Note where that number came from: the synthesis records Gemini's
        // guardrail as "clamp to 95%", a CEILING for a determinate bar. It was
        // implemented as a VALUE on the indeterminate phase, which §3.2 of the
        // same document says must be "animated, not a frozen number". Deleting
        // it restores the adopted design rather than overriding it.
        //
        // The copy lines carry percentages but arrive in one batch at ~90% (see
        // above), so they cannot drive a bar either; routing them through the
        // erase mapping below would under-report them besides.
        if line.contains("Copying") { return nil }
        guard let percent = lastPercent(line) else { return nil }
        return 0.05 + (Double(percent) / 100) * (eraseCeiling - 0.05)
    }

    /// What to show beside the bar for a line of output.
    public static func status(for line: String) -> String {
        if line.contains("Install media now available") { return "Install media ready" }
        if line.contains("Making disk bootable") { return "Making the drive bootable…" }
        let percent = lastPercent(line).map { " \($0)%" } ?? ""
        if line.contains("Copying") { return "Copying macOS to the USB…\(percent)" }
        if line.contains("Erasing") { return "Erasing the drive…\(percent)" }
        return "Working…\(percent)"
    }
}
