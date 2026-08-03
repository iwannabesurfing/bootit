@testable import BootItShared
import XCTest

/// The IOKit reader, checked against the machine it runs on.
///
/// The boot disk is the only device guaranteed to exist on a CI runner, so that
/// is what these assert against. They verify the registry walk finds an
/// `IOBlockStorageDriver` and reads a plausible counter — the part that breaks
/// silently if a key is misspelled or the plane traversal is wrong.
final class DeviceIOCountersTests: XCTestCase {

    func testReadsAWriteCounterForTheBootDisk() throws {
        let bytes = try XCTUnwrap(DeviceIOCounters.bytesWritten(onDisk: "disk0"),
                                  "no IOBlockStorageDriver statistics for the boot disk")
        // A booted Mac has written something and cannot have written an exabyte.
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertLessThan(bytes, 1_000_000_000_000_000)
    }

    func testTheCounterOnlyEverGoesUpWhileTheDeviceStaysAttached() throws {
        let first = try XCTUnwrap(DeviceIOCounters.bytesWritten(onDisk: "disk0"))
        let second = try XCTUnwrap(DeviceIOCounters.bytesWritten(onDisk: "disk0"))
        XCTAssertGreaterThanOrEqual(second, first)
    }

    func testAPartitionResolvesToItsWholeDiskDriver() throws {
        // "disk0s1" hangs off the same IOBlockStorageDriver as "disk0", so the
        // upward walk has to find it from either name.
        let whole = DeviceIOCounters.bytesWritten(onDisk: "disk0")
        let partition = DeviceIOCounters.bytesWritten(onDisk: "disk0s1")
        XCTAssertNotNil(whole)
        XCTAssertNotNil(partition)
    }

    func testAnUnknownDeviceReadsAsMissingRatherThanZero() {
        // Zero would be indistinguishable from a device that has written
        // nothing, and would silently become a baseline of 0.
        XCTAssertNil(DeviceIOCounters.bytesWritten(onDisk: "disk9999"))
    }

    func testMisspellingAStatisticsKeyReadsAsMissing() {
        // The keys are string literals copied out of a C header. If one is ever
        // wrong this is what it looks like — nil, not a wrong number.
        XCTAssertNil(DeviceIOCounters.statistic(onDisk: "disk0", key: "Bytes (Written)"))
    }

    func testTheProcessCounterReadsThisProcess() throws {
        let bytes = try XCTUnwrap(ProcessIOCounters.bytesWritten(pid: getpid()))
        XCTAssertGreaterThanOrEqual(bytes, 0)
        XCTAssertNil(ProcessIOCounters.bytesWritten(pid: 999_999))
    }
}
