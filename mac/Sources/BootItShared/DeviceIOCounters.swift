import Foundation
import IOKit
import IOKit.storage

/// Cumulative bytes the block layer has written to a physical device.
///
/// The one signal measured to track the actual write. The filesystem's used
/// bytes cannot: JHFS+ allocates the extents up front, so `statvfs` jumped
/// +16.65 GB in 60 seconds on a drive taking ~9 MB/s and then reported nothing
/// for the remaining 33 minutes. This counter took a steady 535 MB/min across
/// the same stretch.
///
/// Two properties it does **not** have, both of which the caller has to respect:
///
/// - **No process attribution.** It counts everything written to the device,
///   including anything else on the machine touching it. For a drive BootIt has
///   just erased and holds a claim on, that is close to nothing — but it is not
///   nothing by construction.
/// - **No durability guarantee.** It counts bytes handed to the driver, not
///   bytes committed to flash.
///
/// It is also cumulative for the life of the *attachment*, not the run: a fresh
/// reading means nothing without a baseline, and it restarts if the device
/// re-enumerates. `CopyProgressModel` owns both of those concerns.
public enum DeviceIOCounters {

    /// Bytes written to `disk` ("disk4") since it was attached, or nil if the
    /// device does not publish statistics.
    public static func bytesWritten(onDisk disk: String) -> Int64? {
        statistic(onDisk: disk, key: bytesWrittenKey)
    }

    /// `Statistics` lives on the `IOBlockStorageDriver`, which sits *above* the
    /// `IOMedia` node a BSD name resolves to — so this walks up the service plane
    /// to find it. Partition nodes ("disk4s2") resolve to a child of the same
    /// driver, so either name works.
    static func statistic(onDisk disk: String, key: String) -> Int64? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, disk) else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
                == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        let media = IOIteratorNext(iterator)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }

        guard let driver = blockStorageDriver(above: media) else { return nil }
        defer { IOObjectRelease(driver) }

        guard let stats = IORegistryEntryCreateCFProperty(
            driver, statisticsKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] else { return nil }
        return (stats[key] as? NSNumber)?.int64Value
    }

    /// Nearest `IOBlockStorageDriver` at or above `service`. Caller releases.
    private static func blockStorageDriver(above service: io_object_t) -> io_object_t? {
        var current = service
        IOObjectRetain(current)
        // Bounded: a storage stack is a handful of nodes deep, and an unbounded
        // walk up the plane would spin on a registry that changed underneath it.
        for _ in 0..<16 {
            if IOObjectConformsTo(current, "IOBlockStorageDriver") != 0 { return current }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard result == KERN_SUCCESS, parent != IO_OBJECT_NULL else { return nil }
            current = parent
        }
        IOObjectRelease(current)
        return nil
    }

    // Spelled out rather than imported: these are C `#define`s in
    // <IOKit/storage/IOBlockStorageDriver.h>, which Swift does not surface as
    // constants. Verified against `ioreg -c IOBlockStorageDriver -r -w0`.
    static let statisticsKey = "Statistics"
    static let bytesWrittenKey = "Bytes (Write)"
}
