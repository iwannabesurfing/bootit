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

    /// True only for a volume name safe to interpolate into `/Volumes/<name>`
    /// and to hand to `diskutil` as an argument.
    ///
    /// This guard was missing while `isWholeDiskName` was being tested to death
    /// next door. `volumeName` went straight into `"/Volumes/\(volumeName)"` and
    /// on to a root `createinstallmedia --volume …`, so `".."` resolved to `/`
    /// and pointed an as-root operation at the boot volume. Hardening one
    /// parameter and forgetting the one beside it is how that happens.
    ///
    /// HFS+ permits `/` in a volume name and macOS renders it as `:`, so the
    /// permissive set here is deliberately narrower than the filesystem's.
    public static func isSafeVolumeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 27 else { return false }   // HFS+ limit
        // No separators, no traversal, no leading dot, nothing that a shell or
        // an argument parser could read as an option.
        guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9 ._-]*$"#, options: .regularExpression) != nil
        else { return false }
        guard !name.contains(".."), name.trimmingCharacters(in: .whitespaces) == name
        else { return false }
        return true
    }

    /// True when `path` names a volume directly beneath `/Volumes`, with no
    /// traversal and no nesting — the only place this daemon has any business
    /// writing.
    public static func isVolumeRootPath(_ path: String) -> Bool {
        let standardised = (path as NSString).standardizingPath
        guard standardised.hasPrefix("/Volumes/") else { return false }
        let name = String(standardised.dropFirst("/Volumes/".count))
        return !name.isEmpty && !name.contains("/")
    }
}
