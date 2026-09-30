import XCTest
@testable import LLM_Token_Bar

final class ClaudeUsageServiceTests: XCTestCase {
    private func parse(_ json: String) throws -> UsageData {
        try ClaudeUsageService.parseResponse(Data(json.utf8))
    }

    private let fableLimits = """
    "limits": [
        {"kind": "session", "group": "session", "percent": 24, "severity": "normal",
         "resets_at": "2026-09-29T06:19:59.976000+00:00", "scope": null, "is_active": true},
        {"kind": "weekly_all", "group": "weekly", "percent": 15, "severity": "normal",
         "resets_at": "2026-10-01T17:59:59.976025+00:00", "scope": null, "is_active": false},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 9, "severity": "normal",
         "resets_at": "2026-10-01T17:59:59.976211+00:00",
         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": false}
    ]
    """

    func testFableWeeklyScopedLimitBecomesModelUsage() throws {
        let data = try parse("""
        {"five_hour": {"utilization": 24.0, "resets_at": "2026-09-29T06:19:59.992117+00:00"},
         "seven_day": {"utilization": 15.0, "resets_at": "2026-10-01T17:59:59.992141+00:00"},
         \(fableLimits)}
        """)

        XCTAssertEqual(data.modelUsages.count, 1)
        let fable = try XCTUnwrap(data.modelUsages.first)
        XCTAssertEqual(fable.id, "fable")
        XCTAssertEqual(fable.modelName, "Fable")
        XCTAssertEqual(fable.utilization, 9.0)
        let resets = try XCTUnwrap(fable.resetsAt)
        XCTAssertEqual(resets.timeIntervalSince1970, 1_790_877_599.976, accuracy: 0.01)
    }

    func testSessionAndWeeklyAllLimitsDoNotAddModelRows() throws {
        let data = try parse("""
        {"five_hour": {"utilization": 24.0, "resets_at": "2026-09-29T06:19:59+00:00"},
         "seven_day": {"utilization": 15.0, "resets_at": "2026-10-01T17:59:59+00:00"},
         "limits": [
            {"kind": "session", "percent": 24, "resets_at": "2026-09-29T06:19:59+00:00", "scope": null},
            {"kind": "weekly_all", "percent": 15, "resets_at": "2026-10-01T17:59:59+00:00", "scope": null}
        ]}
        """)
        XCTAssertTrue(data.modelUsages.isEmpty)
        XCTAssertEqual(data.sessionUsage?.utilization, 24.0)
        XCTAssertEqual(data.sessionUsage?.resetsAt?.timeIntervalSince1970, 1_790_662_799)
        XCTAssertEqual(data.weeklyUsage?.utilization, 15.0)
        XCTAssertEqual(data.weeklyUsage?.resetsAt?.timeIntervalSince1970, 1_790_877_599)
    }

    func testMissingOrNullLimitsKeepsLegacyModels() throws {
        let legacy = """
        "seven_day_opus": {"utilization": 30.0, "resets_at": "2026-10-01T17:59:59+00:00"},
        "seven_day_sonnet": {"utilization": 20.0, "resets_at": null}
        """
        for extra in ["", ", \"limits\": null"] {
            let data = try parse("{\(legacy)\(extra)}")
            XCTAssertEqual(data.modelUsages.map(\.id), ["opus", "sonnet"])
            XCTAssertEqual(data.modelUsages.map(\.utilization), [30.0, 20.0])
            XCTAssertEqual(data.modelUsages.first?.resetsAt?.timeIntervalSince1970, 1_790_877_599)
            XCTAssertNil(data.modelUsages.last?.resetsAt)
        }
    }

    func testLegacyModelIsNotDuplicatedByScopedLimit() throws {
        let data = try parse("""
        {"seven_day_opus": {"utilization": 30.0, "resets_at": null},
         "limits": [{"kind": "weekly_scoped", "percent": 31, "resets_at": null,
                     "scope": {"model": {"id": null, "display_name": "Opus"}, "surface": null}}]}
        """)
        XCTAssertEqual(data.modelUsages.map(\.id), ["opus"])
        XCTAssertEqual(data.modelUsages.first?.utilization, 30.0)
    }

    func testSurfaceScopedLimitWithoutModelIsIgnored() throws {
        let data = try parse("""
        {"limits": [{"kind": "weekly_scoped", "percent": 50, "resets_at": null,
                     "scope": {"model": null, "surface": "claude_code"}},
                    {"kind": "weekly_scoped", "percent": 40, "resets_at": null,
                     "scope": {"model": {"id": null, "display_name": ""}, "surface": null}}]}
        """)
        XCTAssertTrue(data.modelUsages.isEmpty)
    }

    func testDuplicateScopedModelIsListedOnce() throws {
        let entry = """
        {"kind": "weekly_scoped", "percent": 9, "resets_at": null,
         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}}
        """
        let data = try parse("{\"limits\": [\(entry), \(entry)]}")
        XCTAssertEqual(data.modelUsages.map(\.id), ["fable"])
    }

    func testUnknownOrMalformedLimitEntriesDoNotBreakUsage() throws {
        let data = try parse("""
        {"five_hour": {"utilization": 24.0, "resets_at": null},
         "limits": [{"kind": "brand_new_kind", "unexpected": {"x": 1}},
                    {"kind": 7, "percent": "bad"},
                    "junk",
                    {"kind": "weekly_scoped", "percent": 9, "resets_at": "not-a-date",
                     "scope": {"model": {"display_name": "Fable"}, "extra": true}}]}
        """)
        XCTAssertEqual(data.sessionUsage?.utilization, 24.0)
        XCTAssertEqual(data.modelUsages.map(\.id), ["fable"])
        XCTAssertNil(data.modelUsages.first?.resetsAt)
    }

    func testModelScopedLimitWithSurfaceIsNotGlobalQuota() throws {
        let data = try parse("""
        {"limits": [{"kind": "weekly_scoped", "percent": 9, "resets_at": null,
                     "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": "claude_code"}}]}
        """)
        XCTAssertTrue(data.modelUsages.isEmpty)
    }

    func testModelNameIsTrimmedAndBlankNameIgnored() throws {
        let data = try parse("""
        {"limits": [{"kind": "weekly_scoped", "percent": 9, "resets_at": null,
                     "scope": {"model": {"display_name": "  Fable \\n"}, "surface": null}},
                    {"kind": "weekly_scoped", "percent": 9, "resets_at": null,
                     "scope": {"model": {"display_name": "   "}, "surface": null}}]}
        """)
        XCTAssertEqual(data.modelUsages.map(\.modelName), ["Fable"])
        XCTAssertEqual(data.modelUsages.map(\.id), ["fable"])
    }

    func testOutOfRangePercentIsSkippedNotClamped() throws {
        let data = try parse("""
        {"limits": [{"kind": "weekly_scoped", "percent": 101, "resets_at": null,
                     "scope": {"model": {"display_name": "Fable"}, "surface": null}},
                    {"kind": "weekly_scoped", "percent": -1, "resets_at": null,
                     "scope": {"model": {"display_name": "Nova"}, "surface": null}},
                    {"kind": "weekly_scoped", "percent": 100, "resets_at": null,
                     "scope": {"model": {"display_name": "Edge"}, "surface": null}}]}
        """)
        XCTAssertEqual(data.modelUsages.map(\.id), ["edge"])
        XCTAssertEqual(data.modelUsages.first?.utilization, 100.0)
    }

    func testNonArrayLimitsKeepsLegacyUsage() throws {
        let data = try parse("""
        {"five_hour": {"utilization": 24.0, "resets_at": null},
         "seven_day_opus": {"utilization": 30.0, "resets_at": null},
         "limits": {"unexpected": "object"}}
        """)
        XCTAssertEqual(data.sessionUsage?.utilization, 24.0)
        XCTAssertEqual(data.modelUsages.map(\.id), ["opus"])
    }

    func testMalformedLegacyBucketStillThrows() {
        XCTAssertThrowsError(try parse("""
        {"five_hour": {"utilization": "bad"}}
        """))
    }
}
