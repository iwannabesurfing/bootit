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

    /// Where a line of output sits in the 0…1 range.
    ///
    /// Returns nil when the line carries no progress information, so the caller
    /// leaves the bar where it is rather than resetting it.
    public static func fraction(for line: String) -> Double? {
        if line.contains("Install media now available") { return 1.0 }
        guard let percent = lastPercent(line) else { return nil }

        // Copying dominates the wall clock — it is the multi-gigabyte phase —
        // so it gets the bulk of the bar. Erasing is quick and gets a sliver.
        let copying = line.contains("Copying") || line.contains("Making disk bootable")
        let base = copying ? 0.15 : 0.05
        let span = copying ? 0.85 : 0.10
        return base + (Double(percent) / 100) * span
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
