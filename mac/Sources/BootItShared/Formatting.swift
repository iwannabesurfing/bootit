import Foundation

/// Formats a byte count the way macOS does — base 1000, so "GB" means what
/// Disk Utility, Finder and the drive's own packaging mean by it.
///
/// This used to divide by 1024 while still labelling the result GB, which made
/// a 61.5 GB stick read as "57.3 GB" here and 61.5 GB everywhere else. On the
/// screen where someone is identifying which drive to erase, disagreeing with
/// the rest of the system about its size is the last thing this should do.
///
/// Lives in the shared target because the copy reporter formats throughput and
/// byte totals too, and a second implementation is how the 1024/1000 mismatch
/// arose the first time.
public func bytesHuman(_ n: Int64) -> String {
    var v = Double(n)
    for unit in ["B", "KB", "MB", "GB"] {
        if v < 1000 { return String(format: "%.1f %@", v, unit) }
        v /= 1000
    }
    return String(format: "%.1f TB", v)
}
