import BootItShared
import XCTest
@testable import BootIt

final class FormattingTests: XCTestCase {

    func testBytesHumanScalesThroughUnits() {
        XCTAssertEqual(bytesHuman(0), "0.0 B")
        XCTAssertEqual(bytesHuman(512), "512.0 B")
        XCTAssertEqual(bytesHuman(1000), "1.0 KB")
        XCTAssertEqual(bytesHuman(1500), "1.5 KB")
        XCTAssertEqual(bytesHuman(1_000_000), "1.0 MB")
        XCTAssertEqual(bytesHuman(3_000_000_000), "3.0 GB")
    }

    func testBytesHumanReachesTerabytes() {
        XCTAssertEqual(bytesHuman(2_000_000_000_000), "2.0 TB")
    }

    /// The number BootIt prints for a drive has to match the number macOS
    /// prints for the same drive. A real 64 GB SanDisk reports 61,524,148,224
    /// bytes; `diskutil info` calls that 61.5 GB, and so must this. Formatting
    /// it as 57.3 GB (base 1024 wearing base-1000 labels) meant the erase screen
    /// disagreed with Disk Utility about which drive you were looking at.
    func testDriveSizesMatchWhatDiskUtilityReports() {
        XCTAssertEqual(bytesHuman(61_524_148_224), "61.5 GB")
        XCTAssertEqual(bytesHuman(31_914_983_424), "31.9 GB")
        XCTAssertEqual(bytesHuman(2_000_398_934_016), "2.0 TB")
    }

    func testUnitBoundariesRollOverAtAThousand() {
        XCTAssertEqual(bytesHuman(999), "999.0 B")
        XCTAssertEqual(bytesHuman(1000), "1.0 KB")
        XCTAssertEqual(bytesHuman(999_999_999), "1000.0 MB")
    }
}
