import BootItShared
import Foundation

/// Answers one question: when a write to a USB drive is refused, *who* was
/// refused — BootIt itself, or its privileged helper?
///
/// The two are governed separately. The app runs in the user's GUI session, so
/// macOS can prompt it ("BootIt would like to access files on a removable
/// volume") and the user can say yes. The helper is a system daemon with no
/// session to be prompted in, so it is denied silently and can only be allowed
/// by adding BootIt to Full Disk Access by hand.
///
/// Both failures look identical from the outside — EPERM — which is why the
/// first diagnosis of this bug was wrong. This separates them.
enum AccessDiagnostics {

    /// What the test actually established.
    ///
    /// The third case is the one that was missing. A helper that could not be
    /// reached, or no drive to test against, says **nothing** about whether USB
    /// access is blocked — but both used to be reported as "USB access blocked",
    /// which names a cause the test never observed and sends the user to Full
    /// Disk Access for a problem that may have nothing to do with it.
    enum Outcome {
        case ok
        case blocked
        case inconclusive
    }

    struct Report {
        let volume: String?
        let appCanWrite: Bool?        // nil when there was no volume to test
        let helperDenial: String?     // nil when the helper can write
        let helperError: String?      // set when the helper couldn't be reached

        var helperCanWrite: Bool? {
            guard helperError == nil else { return nil }
            return helperDenial == nil
        }

        var outcome: Outcome {
            guard volume != nil, helperError == nil else { return .inconclusive }
            if helperCanWrite == true, appCanWrite != false { return .ok }
            return .blocked
        }

        /// What to tell the user, in the order the problems have to be solved.
        var summary: String {
            guard let volume else {
                return "Insert a USB drive and run this again — there is nothing to test against."
            }
            switch (appCanWrite, helperCanWrite) {
            case (_, .some(true)):
                return "Tested \(volume). Both BootIt and its helper can write to it — "
                     + "creating a macOS installer should work."
            case (.some(false), _):
                return "BootIt itself cannot write to \(volume). Allow it when macOS asks for "
                     + "access to files on a removable volume, or enable BootIt under "
                     + "System Settings → Privacy & Security → Files and Folders."
            case (_, .some(false)):
                // The daemon's own sentence, not just our guess at what it meant.
                //
                // `writeDenialReason` reports EPERM/EACCES as needsFullDiskAccess
                // and everything else — a read-only volume, a full disk, an I/O
                // error — as operationFailed with the strerror text. Both used to
                // render as the identical "go and add Full Disk Access", which is
                // the right advice for exactly one of them and sends the user to
                // change an unrelated setting for the rest.
                let reason = helperDenial.flatMap { $0.isEmpty ? nil : $0 }
                return "BootIt can write to \(volume) but its helper cannot."
                     + (reason.map { " \($0)" } ?? "")
                     + "\n\nmacOS never asks a background helper for removable-drive access, so "
                     + "add BootIt under System Settings → Privacy & Security → Full Disk "
                     + "Access, then click Install or Repair."
            default:
                // `helperError` used to be computed here and thrown away, so the
                // one sentence saying *what went wrong* never reached the screen.
                // It is the difference between "the helper stopped unexpectedly"
                // — which points at the app and helper being different builds —
                // and a user reading "blocked" and going to change a setting that
                // was never the problem.
                // An error that is present but empty still has to read as a
                // sentence rather than trail off after a colon.
                let reason = helperError.flatMap { $0.isEmpty ? nil : $0 }
                return "Couldn't reach the helper, so this says nothing about USB access"
                     + (reason.map { ": \($0)" } ?? ".")
                     + "\n\nIf BootIt was updated while it was open, quit and reopen it, "
                     + "then test again."
            }
        }
    }

    /// Mounted volumes on physically attached removable media.
    ///
    /// `volumeIsInternal == false` is not enough on its own: a mounted SMB or
    /// AFP share also reports as not-internal, so a NAS can sort ahead of the
    /// USB stick and the whole diagnosis ends up describing the wrong device.
    /// Requiring `volumeIsLocal` excludes network mounts; requiring removable
    /// or ejectable excludes the boot disk.
    static func externalVolumes() -> [String] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsRemovableKey,
                                      .volumeIsEjectableKey, .volumeIsLocalKey]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return mounted.filter { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isLocal = values?.volumeIsLocal ?? false
            let isInternal = values?.volumeIsInternal ?? true
            let isRemovable = (values?.volumeIsRemovable ?? false)
                           || (values?.volumeIsEjectable ?? false)
            return isLocal && !isInternal && isRemovable
        }.map(\.path)
    }

    /// Perform the same syscall createinstallmedia dies on, from this process.
    static func appCanWrite(to volume: String) -> Bool {
        let probe = (volume as NSString).appendingPathComponent(".bootit-app-probe")
        let fd = open(probe, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { return errno == EEXIST }
        close(fd)
        unlink(probe)
        return true
    }

    /// Blocks; call off the main queue.
    static func run() -> Report {
        guard let volume = externalVolumes().first else {
            return Report(volume: nil, appCanWrite: nil, helperDenial: nil, helperError: nil)
        }
        let app = appCanWrite(to: volume)

        var denial: String?
        var failure: String?
        do {
            // Must come first. A daemon from an older build stays resident and
            // answers happily, but without whatever method was added since —
            // which reads as "the helper is broken" rather than "the helper is
            // stale". ensureReady() is what notices the version gap.
            try PrivilegedHelper.shared.ensureReady()
            // The reason arrives as an NSError carrying a HelperFailure code, so
            // there is no marker to strip any more — the message is just the
            // message, and the classification travels beside it.
            denial = try PrivilegedHelper.shared.probeWrite(volumePath: volume)?
                .localizedDescription
        } catch {
            failure = error.localizedDescription
        }
        return Report(volume: volume, appCanWrite: app, helperDenial: denial, helperError: failure)
    }
}
