import Foundation

/// Names and identifiers shared by the app and its privileged helper.
///
/// These are compile-time constants in a shared target precisely because a typo
/// in any one of them fails at runtime in a way that looks like "the helper is
/// broken" rather than "the string is wrong" — the daemon simply never appears.
public enum HelperInfo {

    /// launchd label, the Mach service name, and the plist basename all have to
    /// agree with `Contents/Library/LaunchDaemons/<plistName>` in the app bundle.
    public static let machServiceName = "au.media.bootit.helper"
    public static let plistName       = "au.media.bootit.helper.plist"

    /// Bumped whenever the helper's behaviour changes. The app compares this
    /// against the installed daemon and re-registers on a mismatch, so an app
    /// update can never end up talking to a helper from an older version.
    public static let version = "5"

    /// The app's Developer ID team. Both sides pin the other to this.
    public static let teamIdentifier = "MD4M4DL5PP"

    public static let appBundleID    = "au.media.bootit"
    public static let helperBundleID = "au.media.bootit.helper"

    /// Code-signing requirement the helper demands of anything connecting to it.
    ///
    /// Without this, any process on the machine could open the Mach service and
    /// ask a root daemon to erase a disk. `anchor apple generic` pins it to a
    /// real Apple-issued certificate chain, the leaf OU pins it to this team,
    /// and the identifier pins it to this app — an attacker would need our
    /// signing key, not merely a copy of the binary.
    /// The two marker OIDs that `codesign` puts in its own designated
    /// requirement for a Developer ID build.
    ///
    /// Without them the requirement accepts *any* certificate ever issued to
    /// this team — including an "Apple Development" cert sitting in a day-to-day
    /// Xcode keychain, which is protected far less carefully than the
    /// notarisation key. Narrowing to Developer ID Application costs nothing.
    private static let developerIDMarkers = """
        and certificate 1[field.1.2.840.113635.100.6.2.6] \
        and certificate leaf[field.1.2.840.113635.100.6.1.13]
        """

    public static let clientRequirement = """
        anchor apple generic \
        and identifier "\(appBundleID)" \
        \(developerIDMarkers) \
        and certificate leaf[subject.OU] = "\(teamIdentifier)"
        """

    /// The mirror of the above: what the app demands of the helper, so a
    /// planted daemon squatting the Mach service can't impersonate it.
    public static let helperRequirement = """
        anchor apple generic \
        and identifier "\(helperBundleID)" \
        \(developerIDMarkers) \
        and certificate leaf[subject.OU] = "\(teamIdentifier)"
        """

    /// Marks the one failure the user can actually fix themselves.
    ///
    /// `createinstallmedia` writes a `.IAPhysicalMedia` cookie to the root of
    /// the target volume, and TCC gates writes to removable volumes. A daemon
    /// has no GUI session, so it is never *prompted* for that access — it is
    /// silently denied with EPERM, which surfaces as an opaque "Operation not
    /// permitted" a long way from its cause. The app matches on this prefix to
    /// show the one instruction that resolves it.
    public static let needsFullDiskAccessPrefix = "NEEDS_FULL_DISK_ACCESS: "
}

/// What the privileged daemon will do on the app's behalf.
///
/// Every method is one-way-plus-reply; the helper streams progress back through
/// `HelperClientProtocol` on the same connection rather than returning it, so a
/// 20-minute `createinstallmedia` isn't a single silent call.
@objc public protocol HelperProtocol {

    /// Used to detect a stale daemon left behind by an earlier app version.
    func helperVersion(reply: @escaping (String) -> Void)

    /// Erase `disk` (a BSD name such as "disk4") to JHFS+/GPT named `volumeName`.
    ///
    /// - reply: `nil` on success, otherwise a human-readable failure.
    func eraseDisk(_ disk: String,
                   volumeName: String,
                   reply: @escaping (String?) -> Void)

    /// Run Apple's `createinstallmedia` from `installerAppPath` onto the volume
    /// named `volumeName`, streaming its output back to the client as it goes.
    ///
    /// - reply: `nil` on success, otherwise a human-readable failure.
    func createInstallMedia(installerAppPath: String,
                            volumeName: String,
                            reply: @escaping (String?) -> Void)

    /// Abandon the running operation, if any.
    func cancelCurrentOperation(reply: @escaping (Bool) -> Void)

    /// Try to create a file at `volumePath` and report why not.
    ///
    /// Exists so the app can show the user which side of the divide is blocked —
    /// itself or the daemon — instead of both failing with the same opaque
    /// "Operation not permitted" and leaving the cause to guesswork.
    func probeWrite(volumePath: String, reply: @escaping (String?) -> Void)
}

/// Callbacks the helper makes back into the app while work is in flight.
@objc public protocol HelperClientProtocol {
    func helperDidLog(_ line: String)
    func helperDidProgress(_ fraction: Double, status: String)
}
