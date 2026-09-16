import XCTest
@testable import LLM_Token_Bar

final class CodexUsageServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - Fixtures

    /// 실제 `GET /backend-api/wham/usage` 200 응답 구조(개인 식별 정보는 가짜 값으로 대체).
    /// 주간 창만 있고(5시간 세션 없음), Spark 보조 풀(additional_rate_limits)이 포함돼 있다.
    private let liveUsageJSON = """
    {
      "user_id": "user-FAKE",
      "account_id": "00000000-0000-0000-0000-000000000000",
      "email": "fake@example.com",
      "plan_type": "pro",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {
          "used_percent": 5,
          "limit_window_seconds": 604800,
          "reset_after_seconds": 604022,
          "reset_at": 1790148462
        },
        "secondary_window": null
      },
      "additional_rate_limits": [
        {
          "limit_name": "GPT-5.3-Codex-Spark",
          "metered_feature": "codex_bengalfox",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 0,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 18000,
              "reset_at": 1789562441
            },
            "secondary_window": {
              "used_percent": 0,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 604800,
              "reset_at": 1790149241
            }
          }
        }
      ],
      "credits": { "has_credits": false, "unlimited": false, "balance": "0" },
      "spend_control": { "reached": false, "individual_limit": null },
      "rate_limit_reached_type": null
    }
    """

    // MARK: - Decoding & mapping

    func testFetchMapsWeeklyOnlyResponseToRateLimits() async throws {
        let service = makeService(status: 200, body: liveUsageJSON)

        let report = try await service.fetchReport()
        let limits = try XCTUnwrap(report.latest?.limits)

        XCTAssertEqual(limits.planType, "pro")
        XCTAssertNil(limits.limitName)
        XCTAssertTrue(limits.isMainPlanBucket)

        // primary_window(주간, 604800s → 10080분)이 주간 창으로 분류된다.
        XCTAssertEqual(limits.weeklyLimit?.usedPercent, 5)
        XCTAssertEqual(limits.weeklyLimit?.windowMinutes, 10080)
        XCTAssertEqual(limits.weeklyLimit?.resetsAt, 1790148462)

        // 세션(5시간) 창은 없고, 한도 해제 상태로 표시된다.
        XCTAssertNil(limits.sessionLimit)
        XCTAssertTrue(limits.isSessionLimitLifted)

        XCTAssertNil(report.limitReachedAt)
    }

    /// Spark(additional_rate_limits, 18000s → 300분)가 세션 창으로 새어 들어오면 안 된다.
    func testSparkBucketDoesNotLeakIntoSessionWindow() async throws {
        let service = makeService(status: 200, body: liveUsageJSON)

        let report = try await service.fetchReport()
        let limits = try XCTUnwrap(report.latest?.limits)

        XCTAssertNil(limits.sessionLimit, "Spark 보조 풀이 5시간 세션 창으로 새면 안 된다")
        XCTAssertTrue(limits.isSessionLimitLifted)
    }

    func testLimitReachedFlagProducesLimitReachedAt() async throws {
        let body = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "limit_reached": true,
            "primary_window": { "used_percent": 100, "limit_window_seconds": 604800, "reset_at": 1790148462 },
            "secondary_window": null
          },
          "rate_limit_reached_type": "primary"
        }
        """
        let service = makeService(status: 200, body: body)

        let report = try await service.fetchReport()

        XCTAssertEqual(report.limitReachedAt, now)
        XCTAssertEqual(report.latest?.limits.weeklyLimit?.usedPercent, 100)
    }

    func testMissingResetAtIsDerivedFromResetAfterSeconds() async throws {
        let body = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": { "used_percent": 42, "limit_window_seconds": 18000, "reset_after_seconds": 3600 },
            "secondary_window": { "used_percent": 10, "limit_window_seconds": 604800, "reset_after_seconds": 100000 }
          }
        }
        """
        let service = makeService(status: 200, body: body)

        let report = try await service.fetchReport()
        let limits = try XCTUnwrap(report.latest?.limits)

        // reset_at이 없으면 now + reset_after_seconds로 유도한다.
        XCTAssertEqual(limits.sessionLimit?.resetsAt, Int(now.timeIntervalSince1970) + 3600)
        XCTAssertEqual(limits.weeklyLimit?.resetsAt, Int(now.timeIntervalSince1970) + 100000)
    }

    // MARK: - HTTP status handling

    func testUnauthorizedThrowsUnauthorized() async throws {
        let service = makeService(status: 401, body: "{}")

        await assertThrows(CodexUsageError.unauthorized) {
            _ = try await service.fetchReport()
        }
    }

    func testNon2xxThrowsInvalidResponse() async throws {
        let service = makeService(status: 500, body: "{}")

        await assertThrows(CodexUsageError.invalidResponse(statusCode: 500)) {
            _ = try await service.fetchReport()
        }
    }

    /// 2xx라도 rate_limit이 null이면 표시할 창이 없으므로 emptyUsage를 던져 폴백을 유도한다.
    func testNullRateLimitThrowsEmptyUsage() async throws {
        let service = makeService(status: 200, body: #"{"plan_type":"pro","rate_limit":null}"#)

        await assertThrows(CodexUsageError.emptyUsage) {
            _ = try await service.fetchReport()
        }
    }

    /// 두 창이 모두 없는 rate_limit도 emptyUsage로 취급한다.
    func testBothWindowsAbsentThrowsEmptyUsage() async throws {
        let body = #"{"plan_type":"pro","rate_limit":{"primary_window":null,"secondary_window":null}}"#
        let service = makeService(status: 200, body: body)

        await assertThrows(CodexUsageError.emptyUsage) {
            _ = try await service.fetchReport()
        }
    }

    // MARK: - Auth

    func testMissingAuthFileThrowsNotAuthenticated() async throws {
        let service = CodexUsageService(
            authPath: "/nonexistent/path/auth.json",
            transport: { _ in (Data(), Self.httpResponse(200)) },
            now: { [now] in now }
        )

        await assertThrows(CodexUsageError.notAuthenticated) {
            _ = try await service.fetchReport()
        }
    }

    func testAuthHeadersAreSentFromAuthFile() async throws {
        let authPath = try writeTempAuth(accessToken: "tok-123", accountId: "acct-456")
        let captured = CapturedRequest()
        let body = liveUsageJSON
        let service = CodexUsageService(
            authPath: authPath,
            transport: { request in
                captured.request = request
                return (Data(body.utf8), Self.httpResponse(200))
            },
            now: { [now] in now }
        )

        _ = try await service.fetchReport()

        let request = try XCTUnwrap(captured.request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "acct-456")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    // MARK: - Helpers

    private func makeService(status: Int, body: String) -> CodexUsageService {
        let authPath = (try? writeTempAuth(accessToken: "tok", accountId: "acct")) ?? "/tmp/missing"
        return CodexUsageService(
            authPath: authPath,
            transport: { _ in (Data(body.utf8), Self.httpResponse(status)) },
            now: { [now] in now }
        )
    }

    private func writeTempAuth(accessToken: String, accountId: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("auth.json").path
        let json = """
        { "tokens": { "access_token": "\(accessToken)", "account_id": "\(accountId)" } }
        """
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private static func httpResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func assertThrows<E: Error & Equatable>(
        _ expected: E,
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected) to be thrown", file: file, line: line)
        } catch let error as E {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}

/// 캡처한 요청을 테스트 클로저에서 참조형으로 공유하기 위한 상자.
private final class CapturedRequest: @unchecked Sendable {
    var request: URLRequest?
}
