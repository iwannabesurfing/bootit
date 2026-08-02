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

    /// Start of the copy phase — everything below this is the erase.
    public static let copyStart = 0.15
    /// The copy is not allowed to reach the end on its own; only the tool
    /// announcing completion does that.
    public static let copyCeiling = 0.93

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
    /// So output parsing cannot drive the bar through the copy; bytes landing on
    /// the target volume do that instead. See `copyFraction(used:expected:)`.
    public static func fraction(for line: String) -> Double? {
        if line.contains("Install media now available") { return 1.0 }
        // Emitted right at the end, after the bulk copy.
        if line.contains("Making disk bootable") { return 0.95 }
        // Older macOS printed "Copying to disk: 50%". macOS 26 prints nothing.
        // Either way the byte poller owns this phase — routing a copy
        // percentage through the erase mapping below would under-report it.
        if line.contains("Copying") { return nil }
        guard let percent = lastPercent(line) else { return nil }
        return 0.05 + (Double(percent) / 100) * (copyStart - 0.05)
    }

    /// Progress through the copy, measured by what has actually landed on the
    /// drive rather than by what the tool says.
    ///
    /// `expected` is an estimate, so this deliberately cannot finish the bar —
    /// underestimating would otherwise sit at 100% for minutes, which is the
    /// same "is it stuck?" failure in a different costume.
    public static func copyFraction(used: Int64, expected: Int64) -> Double {
        guard expected > 0, used > 0 else { return copyStart }
        let ratio = min(1.0, Double(used) / Double(expected))
        return copyStart + ratio * (copyCeiling - copyStart)
    }

    /// Human-readable position within the copy.
    public static func copyStatus(used: Int64, expected: Int64) -> String {
        let gb = Double(used) / 1_000_000_000
        guard expected > 0 else { return String(format: "Copying macOS to the USB… %.1f GB", gb) }
        let percent = Int(min(100, Double(used) / Double(expected) * 100))
        return String(format: "Copying macOS to the USB… %d%%  (%.1f GB)", percent, gb)
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
