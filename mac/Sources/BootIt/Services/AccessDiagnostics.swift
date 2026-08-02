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

    struct Report {
        let volume: String?
        let appCanWrite: Bool?        // nil when there was no volume to test
        let helperDenial: String?     // nil when the helper can write
        let helperError: String?      // set when the helper couldn't be reached

        var helperCanWrite: Bool? {
            guard helperError == nil else { return nil }
            return helperDenial == nil
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
                return "BootIt can write to \(volume) but its helper cannot. macOS never asks a "
                     + "background helper for this, so add BootIt under System Settings → "
                     + "Privacy & Security → Full Disk Access, then click Install or Repair."
            default:
                return "Couldn't reach the helper to test it."
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
            denial = try PrivilegedHelper.shared.probeWrite(volumePath: volume)
            // Strip the marker the daemon uses to flag this to the UI.
            if let text = denial, text.hasPrefix(HelperInfo.needsFullDiskAccessPrefix) {
                denial = String(text.dropFirst(HelperInfo.needsFullDiskAccessPrefix.count))
            }
        } catch {
            failure = error.localizedDescription
        }
        return Report(volume: volume, appCanWrite: app, helperDenial: denial, helperError: failure)
    }
}
