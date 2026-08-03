import Foundation

/// The two questions that belong *before* the user commits to erasing a drive,
/// and the state of their answers.
///
/// Both were previously discoverable only after committing — one as a confusing
/// mid-run failure, the other behind Help → Privileged Helper… → Test USB
/// Access, which no first-run user has a reason to open. They are collected here
/// rather than spread across `AppModel` because they are the same thing at
/// different distances: *can this app still do the work it is about to promise?*
///
/// A value type, held in a single `@Published` property, so SwiftUI republishes
/// on any change without a nested-observable subscription — and so the decisions
/// below can be driven directly by a test with no app, no daemon and no drive.
/// Every mutation here is made on the main queue by its owner; nothing in this
/// type dispatches, because a value type owning a queue is how a reducer ends up
/// being written to from two threads at once.
struct InstallPreflight {

    /// How to read which file the bundled helper currently is. One closure for
    /// the reading taken at launch and every reading since, so a test drives the
    /// same path the app does rather than a parallel one that agrees with it.
    let bundleIdentity: () -> AppBundleWatch.Identity?

    /// How to ask whether the helper is being refused — and whether the question
    /// is worth asking at all. nil means "did not ask".
    let usbAccessProbe: () -> AccessDiagnostics.Report?

    /// The bundled helper binary as it was when this process launched.
    let launchIdentity: AppBundleWatch.Identity?

    /// True once the bundle this process launched from has been replaced on disk.
    ///
    /// Latched on purpose. The old bundle is gone the moment it is replaced, so
    /// nothing could put this back — and a flag that could flicker off would let
    /// the user through to a Start button that is not safe to press. Only
    /// relaunching clears it, which is exactly what it asks for.
    private(set) var appWasReplaced = false

    /// What a USB-access check found, when one has been run and found trouble.
    ///
    /// Nil for "fine", "not checked" and "could not be established" alike —
    /// those are the same thing as far as the screen is concerned, and an
    /// inconclusive probe must never be rendered as a problem. That mistake has
    /// its own regression test in `AccessDiagnosticsReportTests`.
    private(set) var usbAccessReport: AccessDiagnostics.Report?

    /// Bumped per probe: the user can pick a different drive while one is still
    /// in flight, and the slower answer must not overwrite the newer question.
    private var probeID = 0

    init(bundleIdentity: @escaping () -> AppBundleWatch.Identity? = InstallPreflight.currentBundleIdentity,
         usbAccessProbe: @escaping () -> AccessDiagnostics.Report? = InstallPreflight.defaultUSBAccessProbe) {
        self.bundleIdentity = bundleIdentity
        self.usbAccessProbe = usbAccessProbe
        self.launchIdentity = bundleIdentity()
    }

    // MARK: - Decisions

    /// An unreadable identity on either side is **not** a replacement. This
    /// gates the Start button, so the failure to prefer is refusing to make a
    /// claim: a build with no bundled helper to stat must not become a permanent
    /// "BootIt was updated" that no amount of reopening clears.
    mutating func noteBundleReading(_ current: AppBundleWatch.Identity?) {
        guard AppBundleWatch.wasReplaced(recorded: launchIdentity, current: current) else { return }
        appWasReplaced = true
    }

    mutating func beginProbe() -> Int {
        probeID += 1
        return probeID
    }

    mutating func acceptProbe(_ report: AccessDiagnostics.Report?, id: Int) {
        guard id == probeID else { return }   // superseded by a newer selection
        usbAccessReport = report?.outcome == .blocked ? report : nil
    }

    /// The access report describes a drive. Starting over deselects it, and a
    /// warning left behind would describe something nobody is looking at.
    /// `appWasReplaced` is pointedly not cleared: starting over does not
    /// un-replace the bundle.
    mutating func forgetDrive() {
        usbAccessReport = nil
    }

    // MARK: - The real sources

    static func currentBundleIdentity() -> AppBundleWatch.Identity? {
        AppBundleWatch.helperBinaryPath.flatMap { AppBundleWatch.identity(of: $0) }
    }

    /// Only when the daemon is *already* installed.
    ///
    /// `AccessDiagnostics.run()` calls `ensureReady()`, which registers the
    /// helper if it is not registered — so probing unconditionally would install
    /// a root LaunchDaemon and raise a macOS approval prompt because the user
    /// plugged in a stick, before they had pressed Start or agreed to anything.
    /// This guard is the whole reason the check is safe to run unprompted, not a
    /// tidiness check: remove it and selecting a drive installs a daemon.
    ///
    /// Not covered by a test, and it cannot honestly be: asserting it returns
    /// nil under XCTest would be asserting `SMAppService`'s behaviour in a test
    /// bundle, not this guard. Removing it to see a test fail would register a
    /// daemon on the machine running the suite.
    ///
    /// The population it declines to help is the one that has never installed
    /// the helper — who therefore cannot yet be refused by TCC, and who meet the
    /// same message at Start, on a path that already fails before erasing.
    static func defaultUSBAccessProbe() -> AccessDiagnostics.Report? {
        guard PrivilegedHelper.shared.status == .enabled else { return nil }
        return AccessDiagnostics.run()
    }
}
