import XCTest
@testable import LLM_Token_Bar

final class AntigravityQuotaPresentationTests: XCTestCase {
    func testStaleBannerDependsOnStatus() throws {
        let time = "12:34"

        XCTAssertNil(AntigravityQuotaPresentation.staleBanner(status: .connected, timeString: time))

        let notRunning = try XCTUnwrap(AntigravityQuotaPresentation.staleBanner(status: .notRunning, timeString: time))
        XCTAssertTrue(notRunning.contains(time))

        let failed = try XCTUnwrap(AntigravityQuotaPresentation.staleBanner(status: .error(.unreachable), timeString: time))
        XCTAssertTrue(failed.contains(time))
        XCTAssertTrue(failed.contains(AntigravityQuotaPresentation.title(for: .unreachable)))
        XCTAssertNotEqual(notRunning, failed)
    }

    func testErrorDetailIsTruncatedAndOnlyForServerMessages() {
        let long = String(repeating: "x", count: Constants.Antigravity.errorDetailMaxLength + 50)

        XCTAssertEqual(AntigravityQuotaPresentation.detail(for: .badResponse(long))?.count, Constants.Antigravity.errorDetailMaxLength)
        XCTAssertNil(AntigravityQuotaPresentation.detail(for: .badResponse("")))
        XCTAssertNil(AntigravityQuotaPresentation.detail(for: .unreachable))
        XCTAssertNil(AntigravityQuotaPresentation.detail(for: .serverNotRunning))
    }

    func testRowIdsAreUniqueEvenWhenBucketIdsAreEmpty() {
        let group = AntigravityQuotaGroup(displayName: "Other", buckets: [
            AntigravityQuotaBucket(id: "", displayName: "a", window: .fiveHour, usedPercent: 1, resetsAt: nil),
            AntigravityQuotaBucket(id: "", displayName: "b", window: .weekly, usedPercent: 2, resetsAt: nil),
            AntigravityQuotaBucket(id: "x", displayName: "c", window: .weekly, usedPercent: 3, resetsAt: nil),
        ])

        let ids = AntigravityQuotaPresentation.rows(for: group).map(\.id)

        XCTAssertEqual(Set(ids).count, 3)
        XCTAssertEqual(ids.last, "x")
    }


    func testCheckingStatusHasNoStaleBanner() {
        XCTAssertNil(AntigravityQuotaPresentation.staleBanner(status: .checking, timeString: "12:34"))
    }

    func testGroupRowIdsAreUniqueForDuplicateNames() {
        let groups = [
            AntigravityQuotaGroup(displayName: "Same", buckets: []),
            AntigravityQuotaGroup(displayName: "Same", buckets: []),
            AntigravityQuotaGroup(displayName: "", buckets: []),
        ]

        let ids = AntigravityQuotaPresentation.groupRows(for: groups).map(\.id)

        XCTAssertEqual(Set(ids).count, 3)
    }

    func testGeminiGroupWithoutKnownWindowsFallsBackToCompactList() {
        let known = AntigravityQuotaGroup(displayName: "Gemini", buckets: [
            AntigravityQuotaBucket(id: "gemini-5h", displayName: "", window: .fiveHour, usedPercent: 0, resetsAt: nil),
        ])
        let unknown = AntigravityQuotaGroup(displayName: "Gemini", buckets: [
            AntigravityQuotaBucket(id: "gemini-daily", displayName: "", window: .other("daily"), usedPercent: 0, resetsAt: nil),
        ])

        XCTAssertTrue(AntigravityQuotaPresentation.showsAsCards(known))
        XCTAssertFalse(AntigravityQuotaPresentation.showsAsCards(unknown))
    }
}
