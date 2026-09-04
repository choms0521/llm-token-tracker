import XCTest
@testable import LLM_Token_Bar

final class AntigravityQuotaParsingTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_788_400_000)

    /// 실제 agy 언어 서버 응답을 그대로 옮긴 fixture.
    private let realFixture = """
    {"response":{"groups":[{"displayName":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[{"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","description":"You have used some of your weekly limit, it will fully refresh in 6 days, 23 hours.","window":"weekly","remainingFraction":0.9997247,"resetTime":"2026-09-10T06:01:41Z"},{"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","description":"You have used some of your 5-hour limit, it will fully refresh in 4 hours, 59 minutes.","window":"5h","remainingFraction":0.9983478,"resetTime":"2026-09-03T11:01:41Z"}]},{"displayName":"Claude and GPT models","description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS","buckets":[{"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":1,"resetTime":"2026-09-10T06:01:55Z"},{"bucketId":"3p-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":1,"resetTime":"2026-09-03T11:01:55Z"}]}],"description":"Within each group, models share a weekly limit and a 5-hour limit."}}
    """

    func testParsesRealFixtureIntoGroupsAndBuckets() throws {
        let summary = try parse(realFixture)

        XCTAssertEqual(summary.groups.count, 2)
        XCTAssertEqual(summary.fetchedAt, fetchedAt)

        let gemini = try XCTUnwrap(summary.geminiGroup)
        XCTAssertEqual(gemini.displayName, "Gemini Models")
        XCTAssertEqual(summary.otherGroups.map(\.displayName), ["Claude and GPT models"])

        let session = try XCTUnwrap(gemini.bucket(for: .fiveHour))
        XCTAssertEqual(session.id, "gemini-5h")
        XCTAssertEqual(session.usedPercent, 0.165, accuracy: 0.001)
        XCTAssertEqual(session.resetsAt, Date(timeIntervalSince1970: 1_788_433_301))

        let weekly = try XCTUnwrap(gemini.bucket(for: .weekly))
        XCTAssertEqual(weekly.id, "gemini-weekly")
        XCTAssertEqual(weekly.usedPercent, 0.0275, accuracy: 0.001)
    }

    func testGeminiGroupIsFoundByBucketPrefixEvenWithoutGeminiInName() throws {
        let summary = try parse("""
        {"response":{"groups":[{"displayName":"Group A","buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.5}]}]}}
        """)

        XCTAssertEqual(summary.geminiGroup?.displayName, "Group A")
    }

    func testMissingRemainingFractionMeansNothingUsed() throws {
        let summary = try parse("""
        {"response":{"groups":[{"displayName":"G","buckets":[{"bucketId":"gemini-5h","window":"5h","resetTime":"2026-09-03T11:01:41Z"}]}]}}
        """)

        XCTAssertEqual(summary.groups[0].buckets[0].usedPercent, 0)
    }

    func testZeroRemainingFractionMeansFullyUsed() throws {
        let summary = try parse("""
        {"response":{"groups":[{"displayName":"G","buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":0}]}]}}
        """)

        XCTAssertEqual(summary.groups[0].buckets[0].usedPercent, 100)
    }

    func testNestedRemainingFractionIsAccepted() throws {
        let summary = try parse("""
        {"response":{"groups":[{"displayName":"G","buckets":[{"bucketId":"gemini-5h","window":"5h","remaining":{"remainingFraction":0.82}}]}]}}
        """)

        XCTAssertEqual(summary.groups[0].buckets[0].usedPercent, 18, accuracy: 0.001)
    }

    func testDisabledBucketsAreSkipped() throws {
        let summary = try parse("""
        {"response":{"groups":[{"displayName":"G","buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.5,"disabled":true},{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.9}]}]}}
        """)

        XCTAssertEqual(summary.groups[0].buckets.map(\.id), ["gemini-weekly"])
    }

    func testResetTimeAcceptsEpochNumberAndNumericString() throws {
        let summary = try parse("""
        {"response":{"groups":[{"displayName":"G","buckets":[{"bucketId":"a","window":"5h","resetTime":1788519701},{"bucketId":"b","window":"weekly","resetTime":"1788519701"}]}]}}
        """)

        let expected = Date(timeIntervalSince1970: 1_788_519_701)
        XCTAssertEqual(summary.groups[0].buckets[0].resetsAt, expected)
        XCTAssertEqual(summary.groups[0].buckets[1].resetsAt, expected)
    }

    func testResetTimeAcceptsFractionalSeconds() throws {
        let summary = try parse("""
        {"response":{"groups":[{"displayName":"G","buckets":[{"bucketId":"a","window":"5h","resetTime":"2026-09-03T11:01:41.250Z"}]}]}}
        """)

        let resetsAt = try XCTUnwrap(summary.groups[0].buckets[0].resetsAt)
        XCTAssertEqual(resetsAt.timeIntervalSince1970, 1_788_433_301.25, accuracy: 0.001)
    }

    func testUnknownWindowIsKeptAsOther() throws {
        let summary = try parse("""
        {"response":{"groups":[{"displayName":"G","buckets":[{"bucketId":"a","window":"monthly","remainingFraction":0.4}]}]}}
        """)

        XCTAssertEqual(summary.groups[0].buckets[0].window, .other("monthly"))
    }

    func testTopLevelErrorEnvelopeThrowsBadResponseWithMessage() {
        let json = """
        {"code":"unimplemented","message":"unimplemented: unimplemented (error ID: e89a)"}
        """

        XCTAssertThrowsError(try parse(json)) { error in
            XCTAssertEqual(error as? AntigravityQuotaError, .badResponse("unimplemented: unimplemented (error ID: e89a)"))
        }
    }

    func testPlanNameIsExtractedFromUserStatus() {
        let json = """
        {"userStatus":{"name":"Test User","email":"user@example.com","planStatus":{"planInfo":{"teamsTier":"TEAMS_TIER_PRO","planName":"Pro"}}}}
        """

        XCTAssertEqual(AntigravityQuotaParser.parsePlanName(Data(json.utf8)), "Pro")
        XCTAssertNil(AntigravityQuotaParser.parsePlanName(Data("{}".utf8)))
    }

    private func parse(_ json: String) throws -> AntigravityQuotaSummary {
        try AntigravityQuotaParser.parseSummary(Data(json.utf8), fetchedAt: fetchedAt)
    }


    func testOverlongServerStringsAreClipped() throws {
        let limit = Constants.Antigravity.serverStringMaxLength
        let long = String(repeating: "n", count: limit + 40)
        let summary = try parse("""
        {"response":{"groups":[{"displayName":"\(long)","buckets":[{"bucketId":"gemini-\(long)","displayName":"\(long)","window":"\(long)","remainingFraction":0.5}]}]}}
        """)

        let group = summary.groups[0]
        let bucket = group.buckets[0]
        XCTAssertEqual(group.displayName.count, limit)
        XCTAssertEqual(bucket.id.count, limit)
        XCTAssertEqual(bucket.displayName.count, limit)
        guard case .other(let window) = bucket.window else { return XCTFail("expected other window") }
        XCTAssertEqual(window.count, limit)
        XCTAssertNotNil(summary.geminiGroup, "clipped bucket id still keeps the gemini prefix")
    }
}
