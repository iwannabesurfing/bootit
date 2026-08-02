import Foundation

/// The last thing standing between a malformed disk identifier and a root
/// process running `diskutil eraseDisk` on it.
///
/// This lives in the shared target rather than inside the daemon so it can be
/// unit-tested. A guard that only exists in an executable target is a guard
/// nobody ever proves works, and this one protects an irreversible operation.
public enum DiskGuard {

    /// True only for a whole-disk BSD name: `disk4`, never `disk4s2`, never
    /// `/dev/disk4`, and never anything carrying a path separator or metacharacter.
    ///
    /// Rejecting slices matters as much as rejecting paths — `eraseDisk` aimed
    /// at a slice of the internal drive is exactly the outcome worth spending a
    /// regex on.
    public static func isWholeDiskName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 16 else { return false }
        guard name.range(of: #"^disk\d{1,3}$"#, options: .regularExpression) != nil else {
            return false
        }
        return true
    }
}
