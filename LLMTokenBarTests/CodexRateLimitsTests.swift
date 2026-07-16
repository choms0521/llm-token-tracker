import XCTest
@testable import LLM_Token_Bar

final class CodexRateLimitsTests: XCTestCase {
    func testClassifiesLegacyLayoutBySessionAndWeeklyWindows() throws {
        let limits = try decodeLimits("""
        {
            "primary": {"used_percent": 42.0, "window_minutes": 300, "resets_at": 1751500000},
            "secondary": {"used_percent": 12.0, "window_minutes": 10080, "resets_at": 1752000000},
            "plan_type": "plus"
        }
        """)

        XCTAssertEqual(limits.sessionLimit?.usedPercent, 42.0)
        XCTAssertEqual(limits.weeklyLimit?.usedPercent, 12.0)
    }

    func testClassifiesWeeklyOnlyLayoutWithWeeklyPrimary() throws {
        let limits = try decodeLimits("""
        {
            "limit_id": "codex",
            "primary": {"used_percent": 16.0, "window_minutes": 10080, "resets_at": 1784695362},
            "secondary": null,
            "plan_type": "plus"
        }
        """)

        XCTAssertNil(limits.sessionLimit)
        XCTAssertEqual(limits.weeklyLimit?.usedPercent, 16.0)
        XCTAssertEqual(limits.weeklyLimit?.resetsAt, 1784695362)
    }

    func testClassifiesSessionOnlyLayoutWithSessionPrimary() throws {
        let limits = try decodeLimits("""
        {
            "primary": {"used_percent": 55.0, "window_minutes": 300, "resets_at": 1751500000},
            "secondary": null
        }
        """)

        XCTAssertEqual(limits.sessionLimit?.usedPercent, 55.0)
        XCTAssertNil(limits.weeklyLimit)
    }

    func testFallsBackToPositionalLayoutWhenWindowsAreMissing() throws {
        let limits = try decodeLimits("""
        {
            "primary": {"used_percent": 33.0},
            "secondary": {"used_percent": 7.0}
        }
        """)

        XCTAssertEqual(limits.sessionLimit?.usedPercent, 33.0)
        XCTAssertEqual(limits.weeklyLimit?.usedPercent, 7.0)
    }

    func testSessionLimitLiftedOnlyWhenWeeklyWindowExistsWithoutSessionWindow() throws {
        let weeklyOnly = try decodeLimits("""
        {"primary": {"used_percent": 17.0, "window_minutes": 10080}, "secondary": null}
        """)
        XCTAssertTrue(weeklyOnly.isSessionLimitLifted)

        let bothWindows = try decodeLimits("""
        {
            "primary": {"used_percent": 42.0, "window_minutes": 300},
            "secondary": {"used_percent": 12.0, "window_minutes": 10080}
        }
        """)
        XCTAssertFalse(bothWindows.isSessionLimitLifted)

        let sessionOnly = try decodeLimits("""
        {"primary": {"used_percent": 42.0, "window_minutes": 300}, "secondary": null}
        """)
        XCTAssertFalse(sessionOnly.isSessionLimitLifted)

        let empty = try decodeLimits("""
        {"primary": null, "secondary": null}
        """)
        XCTAssertFalse(empty.isSessionLimitLifted)
    }

    private func decodeLimits(_ json: String) throws -> CodexRateLimits {
        try JSONDecoder().decode(CodexRateLimits.self, from: Data(json.utf8))
    }
}
