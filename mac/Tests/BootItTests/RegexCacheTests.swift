import XCTest
@testable import BootIt

final class RegexCacheTests: XCTestCase {

    func testFirstCaptureReturnsGroup() {
        XCTAssertEqual(RegexCache.firstCapture("Progress 42% done", #"(\d+)%"#), "42")
    }

    func testFirstCaptureReturnsNilWhenNoMatch() {
        XCTAssertNil(RegexCache.firstCapture("no percentage here", #"(\d+)%"#))
    }

    func testLastCapturePicksFinalMatch() {
        XCTAssertEqual(RegexCache.lastCapture("10% ... 55% ... 90%", #"(\d+)%"#), "90")
    }

    func testAllGroupsReturnsEveryMatchWithGroups() {
        let groups = RegexCache.allGroups("a=1 b=2 c=3", #"(\w)=(\d)"#)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0][1], "a")
        XCTAssertEqual(groups[0][2], "1")
        XCTAssertEqual(groups[2][1], "c")
    }

    func testRepeatedPatternUsesCacheConsistently() {
        // Second call hits the cached compiled expression.
        XCTAssertEqual(RegexCache.firstCapture("x9", #"(\d)"#), "9")
        XCTAssertEqual(RegexCache.firstCapture("y8", #"(\d)"#), "8")
    }
}
