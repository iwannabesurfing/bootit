import Foundation

struct USBDisk: Identifiable, Hashable {
    let id: String        // e.g. /dev/disk4
    let name: String
    let sizeText: String
    var label: String { "\(id) — \(name) (\(sizeText))" }
    /// Just the BSD name ("disk4") — what a user sees in Disk Utility, and the
    /// identifier worth showing them before they erase the wrong thing.
    var deviceID: String { (id as NSString).lastPathComponent }
}

/// Lists external, physical, removable disks via `diskutil`. The internal
/// drive is never returned (we only ask diskutil for external physical media).
enum DiskLister {

    static let diskutil = "/usr/sbin/diskutil"

    static func external() -> [USBDisk] {
        let listed = Shell.run(diskutil, ["list", "-plist", "external", "physical"])
        guard listed.ok, let data = listed.out.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let wholeDisks = root["WholeDisks"] as? [String]
        else { return [] }

        var disks: [USBDisk] = []
        for ident in wholeDisks {
            let info = Shell.run(diskutil, ["info", "-plist", ident])
            guard info.ok, let idata = info.out.data(using: .utf8),
                  let plist = try? PropertyListSerialization.propertyList(from: idata, format: nil) as? [String: Any]
            else { continue }
            let size = (plist["TotalSize"] as? NSNumber)?.int64Value ?? 0
            let name = (plist["MediaName"] as? String) ?? ident
            disks.append(USBDisk(id: "/dev/\(ident)", name: name, sizeText: bytesHuman(size)))
        }
        return disks
    }
}
