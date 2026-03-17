import XCTest
@testable import LLM_Token_Bar

final class TimeFormatterTests: XCTestCase {
    func testResetTimeStringReturnsEmptyForNilDate() {
        XCTAssertEqual(TimeFormatter.resetTimeString(from: nil), "")
    }

    func testRemainingTimeStringReturnsSoonResetForPastDate() {
        let pastDate = Date().addingTimeInterval(-60)

        XCTAssertEqual(TimeFormatter.remainingTimeString(from: pastDate), "곧 리셋")
    }

    func testRemainingTimeStringFormatsHoursAndMinutes() {
        let futureDate = Date().addingTimeInterval((2 * 3600) + (30 * 60))
        let result = TimeFormatter.remainingTimeString(from: futureDate)

        XCTAssertTrue(result.hasPrefix("2시간"), "Unexpected string: \(result)")
        XCTAssertTrue(result.contains("분 남음"), "Unexpected string: \(result)")
    }

    func testSyncTimeStringReturnsRecentForFreshDate() {
        let freshDate = Date().addingTimeInterval(-10)

        XCTAssertEqual(TimeFormatter.syncTimeString(from: freshDate), "방금 동기화됨")
    }
}
