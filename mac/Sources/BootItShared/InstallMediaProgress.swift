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
    /// Only the erase phase reports percentages. On macOS 26 the entire copy —
    /// the multi-gigabyte, fifteen-minute part — emits exactly three lines,
    /// none carrying a number:
    ///
    ///     Erasing disk: 0%... 10%... 20%... 30%... 100%
    ///     Copying essential files...
    ///     Copying the macOS RecoveryOS...
    ///     Making disk bootable...
    ///
    /// So output parsing cannot drive the bar through the copy, and neither can
    /// anything else that has been tried: this returns nil for the whole opaque
    /// stretch, and `CopyProgressModel` reports what the drive is *doing*
    /// instead of guessing how far through it is.
    ///
    /// A `copyFraction(used:expected:)` lived here until 2026-08-04, dividing
    /// filesystem used-bytes by an estimated payload. It shipped a bar that
    /// reached 95% in four minutes of a 38-minute write and never moved again,
    /// because JHFS+ allocates the extents up front. It is deleted rather than
    /// left unused — the estimate machinery beside it invited exactly the fourth
    /// substitution the tri-model pass was convened to stop.
    public static func fraction(for line: String) -> Double? {
        if line.contains("Install media now available") { return 1.0 }
        // Emitted right at the end, after the bulk copy — the one point where a
        // real end is in sight again and a determinate bar is honest.
        if line.contains("Making disk bootable") { return 0.95 }
        // Older macOS printed "Copying to disk: 50%". macOS 26 prints nothing.
        // Either way this phase has no defensible fraction; routing a copy
        // percentage through the erase mapping below would under-report it.
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
