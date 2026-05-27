import XCTest
@testable import BootIt

final class FormattingTests: XCTestCase {

    func testBytesHumanScalesThroughUnits() {
        XCTAssertEqual(bytesHuman(0), "0.0 B")
        XCTAssertEqual(bytesHuman(512), "512.0 B")
        XCTAssertEqual(bytesHuman(1024), "1.0 KB")
        XCTAssertEqual(bytesHuman(1536), "1.5 KB")
        XCTAssertEqual(bytesHuman(1024 * 1024), "1.0 MB")
        XCTAssertEqual(bytesHuman(3 * 1024 * 1024 * 1024), "3.0 GB")
    }

    func testBytesHumanReachesTerabytes() {
        XCTAssertEqual(bytesHuman(2 * 1024 * 1024 * 1024 * 1024), "2.0 TB")
    }
}
