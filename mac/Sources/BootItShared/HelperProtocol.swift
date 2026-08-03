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
    public static let version = "7"

    /// The app's Developer ID team. Both sides pin the other to this.
    public static let teamIdentifier = "MD4M4DL5PP"

    public static let appBundleID    = "au.media.bootit"
    public static let helperBundleID = "au.media.bootit.helper"

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

    /// Code-signing requirement the helper demands of anything connecting to it.
    ///
    /// Without this, any process on the machine could open the Mach service and
    /// ask a root daemon to erase a disk. `anchor apple generic` pins it to a
    /// real Apple-issued certificate chain, the marker OIDs to a Developer ID
    /// build, the leaf OU to this team, and the identifier to this app — an
    /// attacker would need our signing key, not merely a copy of the binary.
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

    /// Domain for every failure the daemon reports.
    public static let errorDomain = "au.media.bootit.helper"

    /// Build the daemon's reply for a failure.
    public static func failure(_ reason: HelperFailure, _ message: String) -> NSError {
        NSError(domain: errorDomain,
                code: reason.rawValue,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Why a privileged operation failed.
///
/// This used to be a magic prefix on the message string — the app matched
/// `"NEEDS_FULL_DISK_ACCESS: "` and sliced it back off. Three reviewers flagged
/// it independently, and they were right: a contract carried in the first 24
/// characters of a human-readable sentence breaks the moment anyone rewords the
/// sentence, and nothing in the type system says so.
///
/// `@objc` cannot carry a Swift enum over XPC, but `NSError` round-trips
/// natively, so the distinction the app must *act* on travels as a code while
/// the text stays free to change.
@objc public enum HelperFailure: Int {
    /// Something went wrong doing the work itself.
    case operationFailed = 1
    /// A guard rejected the request before any work started.
    case refused = 2
    /// The one failure the user can actually fix themselves.
    ///
    /// `createinstallmedia` writes a `.IAPhysicalMedia` cookie to the root of
    /// the target volume, and TCC gates writes to removable volumes. A daemon
    /// has no GUI session, so it is never *prompted* for that access — it is
    /// silently denied with EPERM, which surfaces as an opaque "Operation not
    /// permitted" a long way from its cause.
    case needsFullDiskAccess = 3
    /// Another operation already holds this disk.
    case busy = 4
}

/// Builds the XPC interface both sides use.
///
/// No explicit class whitelisting: measured, not assumed — a reply parameter
/// typed `NSError?` already gets `NSError` in its allowed set, inferred from the
/// signature, so calling `setClasses` for it is a no-op dressed as a safeguard.
///
/// The constraint that *is* real: an `NSError`'s `userInfo` values must
/// themselves be allowed classes. `HelperInfo.failure` only ever puts a string
/// in there. Anything richer would need whitelisting here.
public enum HelperInterface {
    public static func make() -> NSXPCInterface {
        NSXPCInterface(with: HelperProtocol.self)
    }
}

/// What the privileged daemon will do on the app's behalf.
///
/// Every method is one-way-plus-reply; the helper streams progress back through
/// `HelperClientProtocol` on the same connection rather than returning it, so a
/// 20-minute `createinstallmedia` isn't a single silent call.
@objc public protocol HelperProtocol {

    /// Used to detect a stale daemon left behind by an earlier app version.
    func helperVersion(reply: @escaping (String) -> Void)

    /// Hash of the binary this daemon is actually *running*, captured at launch.
    ///
    /// The version constant only catches a stale daemon if someone remembers to
    /// bump it, and twice now nobody did — leaving a running daemon serving old
    /// code while the app, seeing matching versions, happily kept talking to it.
    /// A fingerprint taken at process start cannot be forgotten: replacing the
    /// app bundle changes the file on disk while the running daemon keeps
    /// reporting what it launched with, so the mismatch is self-evident.
    func helperFingerprint(reply: @escaping (String) -> Void)

    /// Erase `disk` (a BSD name such as "disk4") to JHFS+/GPT named `volumeName`.
    ///
    /// - reply: `nil` on success, otherwise an error in `HelperInfo.errorDomain`
    ///   whose code is a `HelperFailure`.
    func eraseDisk(_ disk: String,
                   volumeName: String,
                   reply: @escaping (NSError?) -> Void)

    /// Run Apple's `createinstallmedia` from `installerAppPath` onto the volume
    /// named `volumeName`, streaming its output back to the client as it goes.
    ///
    /// - reply: `nil` on success, otherwise an error in `HelperInfo.errorDomain`
    ///   whose code is a `HelperFailure`.
    func createInstallMedia(installerAppPath: String,
                            volumeName: String,
                            reply: @escaping (NSError?) -> Void)

    /// Abandon the running operation, if any.
    func cancelCurrentOperation(reply: @escaping (Bool) -> Void)

    /// Try to create a file at `volumePath` and report why not.
    ///
    /// Exists so the app can show the user which side of the divide is blocked —
    /// itself or the daemon — instead of both failing with the same opaque
    /// "Operation not permitted" and leaving the cause to guesswork.
    ///
    /// - reply: `nil` if the daemon can write there, otherwise the reason.
    func probeWrite(volumePath: String, reply: @escaping (NSError?) -> Void)
}

/// Callbacks the helper makes back into the app while work is in flight.
@objc public protocol HelperClientProtocol {
    func helperDidLog(_ line: String)
    func helperDidProgress(_ fraction: Double, status: String)

    /// One measurement of the copy in flight, JSON-encoded `CopySample`.
    ///
    /// A separate channel from `helperDidProgress` because it carries a
    /// different kind of claim. `helperDidProgress` says "the bar is here";
    /// this says "here is what the device did, decide for yourself". The
    /// daemon deliberately does no interpretation — it measures and sends, and
    /// the state machine that turns samples into words lives in the app where
    /// it can be replayed from a recorded trace instead of from hardware.
    ///
    /// Carried as `Data` rather than as a `@objc` parameter list so the sample
    /// can gain a column without another shipped-pair version mismatch.
    func helperDidSample(_ payload: Data)
}
