import Foundation

/// Whether the `.app` this process is running from is still the one on disk.
///
/// BootIt ships as a DMG, so "updating" means dragging a new BootIt.app over the
/// old one — and people do that with the old one still open, usually *because*
/// they hit something they wanted fixed. The running process keeps its own code,
/// but everything it reads from its bundle afterwards belongs to the new version.
///
/// That is not cosmetic here, because of what BootIt reads from its bundle.
/// `PrivilegedHelper.isStale()` fingerprints the bundled helper binary to decide
/// whether the running daemon is out of date. After a replace it reads the *new*
/// helper, correctly concludes the running daemon does not match, and installs
/// the new one — leaving the old app talking to a newer daemon across an XPC
/// protocol that has changed underneath it. What the user sees is "the helper
/// stopped unexpectedly", which points at nothing they can act on.
///
/// `AccessDiagnostics` already tells anyone who reaches its diagnostic to "quit
/// and reopen it" when the helper cannot be reached. This is the same sentence,
/// arriving before the user has committed to erasing a drive rather than after.
enum AppBundleWatch {

    /// Which file is at a path, as opposed to what it contains.
    ///
    /// Inode and device rather than a modification date: Finder, `ditto` and
    /// `cp -p` all preserve mtime, so a replaced bundle can carry the timestamp
    /// of the one it replaced. Replacing a bundle unlinks the old directory and
    /// puts a different one at the same path, and a different file is exactly
    /// what an inode identifies.
    ///
    /// Cheaper than a fingerprint, too, which matters because this is checked
    /// every time the app comes to the front. Content is not the question —
    /// "is this still the same file I launched from" is.
    struct Identity: Equatable {
        let inode: UInt64
        let device: Int
    }

    static func identity(of path: String, fileManager: FileManager = .default) -> Identity? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber else { return nil }
        return Identity(inode: inode.uint64Value, device: device.intValue)
    }

    /// The bundled helper binary — the file whose replacement actually causes
    /// the breakage above, and which is replaced by any update to the bundle.
    ///
    /// Watching this rather than the `.app` directory keeps the check pointed at
    /// the thing that goes wrong. It also survives an in-place update that
    /// rewrites the bundle's contents without replacing the directory itself,
    /// which comparing the directory's inode would miss.
    static var helperBinaryPath: String? {
        Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("BootItHelper").path
    }

    /// Whether the bundle has been replaced since `recorded` was taken.
    ///
    /// An unreadable identity on either side is **not** a replacement. This gates
    /// the Start button, so the failure to prefer is refusing to make a claim:
    /// a build with no bundled helper to stat, or a sandbox that will not answer,
    /// must not become a permanent "BootIt was updated" that no amount of
    /// reopening clears.
    static func wasReplaced(recorded: Identity?, current: Identity?) -> Bool {
        guard let recorded, let current else { return false }
        return recorded != current
    }
}
