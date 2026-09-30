import XCTest
@testable import LLM_Token_Bar

final class AntigravityUsageTSVParserTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_000)

    private let valid = [
        "Gemini Models\tWeekly Limit Remaining\t100%\t2026-10-06T05:47:23Z",
        "Gemini Models\tFive Hour Limit Remaining\t75.5%\t2026-09-29T10:47:23Z",
        "Claude and GPT models\tWeekly Limit Remaining\t0%\t2026-10-06T06:41:11Z",
        "Claude and GPT models\tFive Hour Limit Remaining\t100%\t2026-09-29T11:41:11.500Z",
    ].joined(separator: "\n")

    private func assertBadResponse(_ output: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try AntigravityUsageTSVParser.parse(output, fetchedAt: fetchedAt), file: file, line: line) { error in
            guard case AntigravityQuotaError.badResponse = error else {
                return XCTFail("unexpected error \(error)", file: file, line: line)
            }
        }
    }

    func testParsesValidRows() throws {
        let result = try AntigravityUsageTSVParser.parse(valid + "\n", fetchedAt: fetchedAt)
        XCTAssertNil(result.planName)
        XCTAssertEqual(result.summary.fetchedAt, fetchedAt)
        XCTAssertEqual(result.summary.groups.map(\.displayName), ["Gemini Models", "Claude and GPT models"])

        let gemini = try XCTUnwrap(result.summary.geminiGroup)
        XCTAssertEqual(gemini.buckets.map(\.window), [.weekly, .fiveHour])
        XCTAssertEqual(gemini.bucket(for: .weekly)?.usedPercent, 0)
        XCTAssertEqual(try XCTUnwrap(gemini.bucket(for: .fiveHour)?.usedPercent), 24.5, accuracy: 0.0001)
        XCTAssertEqual(gemini.bucket(for: .weekly)?.resetsAt, ISO8601DateFormatter().date(from: "2026-10-06T05:47:23Z"))

        let other = try XCTUnwrap(result.summary.otherGroups.first)
        XCTAssertEqual(other.bucket(for: .weekly)?.usedPercent, 100)
        XCTAssertEqual(other.bucket(for: .fiveHour)?.resetsAt?.timeIntervalSince1970 ?? 0,
                       ISO8601DateFormatter().date(from: "2026-09-29T11:41:11Z")!.timeIntervalSince1970 + 0.5,
                       accuracy: 0.001)

        let ids = result.summary.groups.flatMap(\.buckets).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testAcceptsCRLF() throws {
        let result = try AntigravityUsageTSVParser.parse(valid.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n", fetchedAt: fetchedAt)
        XCTAssertEqual(result.summary.groups.count, 2)
    }

    func testRejectsWrongColumnCount() {
        assertBadResponse("Gemini Models\tWeekly Limit Remaining\t100%")
        assertBadResponse("Gemini Models\tWeekly Limit Remaining\t100%\t2026-10-06T05:47:23Z\textra")
    }

    func testRejectsEmptyOutput() {
        assertBadResponse("")
        assertBadResponse("\n\n")
    }

    func testRejectsInvalidPercent() {
        for value in ["100", "NaN%", "inf%", "101%", "-1%", "abc%", "%"] {
            assertBadResponse("G\tWeekly Limit Remaining\t\(value)\t2026-10-06T05:47:23Z")
        }
    }

    func testRejectsInvalidDate() {
        assertBadResponse("G\tWeekly Limit Remaining\t50%\tnot-a-date")
        assertBadResponse("G\tWeekly Limit Remaining\t50%\t")
    }

    func testKeepsUnknownWindowLabel() throws {
        let result = try AntigravityUsageTSVParser.parse("G\tMonthly Limit Remaining\t40%\t2026-10-06T05:47:23Z", fetchedAt: fetchedAt)
        let bucket = try XCTUnwrap(result.summary.groups.first?.buckets.first)
        XCTAssertEqual(bucket.window, .other("Monthly Limit Remaining"))
        XCTAssertEqual(bucket.usedPercent, 60)
    }

    func testRejectsDuplicateWindowInGroup() {
        assertBadResponse("""
        G\tWeekly Limit Remaining\t50%\t2026-10-06T05:47:23Z
        G\tWeekly Limit Remaining\t40%\t2026-10-06T05:47:23Z
        """)
    }

    func testRejectsOverlongAndBlankNames() {
        let long = String(repeating: "a", count: 81)
        assertBadResponse("\(long)\tWeekly Limit Remaining\t50%\t2026-10-06T05:47:23Z")
        assertBadResponse("G\t\(long)\t50%\t2026-10-06T05:47:23Z")
        assertBadResponse("  \tWeekly Limit Remaining\t50%\t2026-10-06T05:47:23Z")
    }

    func testErrorDoesNotEchoServerContent() {
        XCTAssertThrowsError(try AntigravityUsageTSVParser.parse("secret-token\tx", fetchedAt: fetchedAt)) { error in
            guard case AntigravityQuotaError.badResponse(let message) = error else { return XCTFail() }
            XCTAssertFalse(message.contains("secret-token"))
        }
    }
}
