import Foundation

/// Whether the person running BootIt can approve its privileged helper.
///
/// This settles a question that sat open across four sessions as "is
/// `SMAppService` registration admin-gated?". macOS answers it directly, in
/// `SMAppService.h`'s documentation for `registerAndReturnError`:
///
/// > If the service corresponds to a LaunchDaemon, the LaunchDaemon will not be
/// > bootstrapped until an admin approves the LaunchDaemon in System Settings.
///
/// So *registration* is not the gate. `register()` succeeds for anybody and
/// leaves the service in `.requiresApproval`. The **approval** is the gate, and
/// it belongs to an administrator. A standard user reaches a System Settings
/// switch they cannot complete — and every string this app had for that moment
/// said "your approval", naming nothing they would need to go and find.
///
/// Only the macOS path is affected. The Windows path writes through
/// `USBWriter` unprivileged and never registers a daemon, so a standard account
/// can build a Windows stick start to finish.
///
/// This warns rather than blocks. "An admin approves" does not say whether
/// System Settings offers a standard user an authentication sheet an
/// administrator could fill in beside them, and refusing to start would be
/// claiming an answer to a question the documentation does not settle.
enum AdminRights {

    /// Membership of the `admin` group, which is what macOS means by
    /// "administrator": `/etc/group` ships `admin:*:80:root`, and the Users &
    /// Groups pane's "Allow user to administer this computer" adds and removes
    /// membership of exactly that group.
    ///
    /// nil means "could not establish", and is never treated as "no". This
    /// drives a warning shown before a 14 GB download, so the failure to prefer
    /// is silence — telling an administrator they are not one would send them
    /// hunting for a second account they do not need.
    static func isAdministrator(user: String = NSUserName()) -> Bool? {
        guard let group = getgrnam("admin") else { return nil }
        let admin = Int32(bitPattern: group.pointee.gr_gid)
        guard let passwd = getpwnam(user) else { return nil }
        let primary = Int32(bitPattern: passwd.pointee.pw_gid)

        // `getgrouplist` reports the size it needs in `count` even when it
        // returns -1 for a buffer that was too small, so a short answer is
        // retried at the size it asked for. Reading the truncated list instead
        // is how an administrator with many group memberships gets reported as
        // an ordinary user — the one direction this must not get wrong.
        var capacity = Int32(64)
        for _ in 0..<2 {
            var groups = [Int32](repeating: 0, count: Int(capacity))
            var count = capacity
            let result = groups.withUnsafeMutableBufferPointer {
                getgrouplist(user, primary, $0.baseAddress, &count)
            }
            if result >= 0 { return groups.prefix(Int(count)).contains(admin) }
            capacity = count
        }
        return nil
    }
}
