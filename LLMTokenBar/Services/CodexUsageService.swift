import Foundation

// MARK: - Errors

enum CodexUsageError: Error, Equatable {
    /// auth.json이 없거나 access_token/account_id를 읽을 수 없음.
    case notAuthenticated
    /// 401. 토큰이 만료됐거나 유효하지 않음. 호출자는 로컬 로그로 폴백해야 한다.
    case unauthorized
    /// 2xx가 아닌 응답.
    case invalidResponse(statusCode: Int)
    /// 2xx지만 사용량 창(primary/secondary)이 하나도 없음. 표시할 값이 없으므로 폴백해야 한다.
    case emptyUsage
}

// MARK: - Live usage response

/// `GET /backend-api/wham/usage` 응답. 메인 플랜 창(primary/secondary)만 사용하고
/// additional_rate_limits(Spark 등 보조 모델 풀)는 의도적으로 매핑하지 않는다.
private struct CodexUsageResponse: Decodable {
    let planType: String?
    let rateLimit: RateLimitDetails?
    let rateLimitReachedType: String?
    let credits: CodexCredits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case rateLimitReachedType = "rate_limit_reached_type"
        case credits
    }

    struct RateLimitDetails: Decodable {
        let limitReached: Bool?
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case limitReached = "limit_reached"
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct Window: Decodable {
        let usedPercent: Double?
        let limitWindowSeconds: Int?
        let resetAfterSeconds: Int?
        let resetAt: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }

        /// 세션 로그의 CodexRateLimit(window_minutes/resets_at)과 같은 모양으로 변환한다.
        func toRateLimit(now: Date) -> CodexRateLimit {
            let windowMinutes = limitWindowSeconds.map { $0 / 60 }
            // resets_at이 없으면 now + reset_after_seconds로 유도한다. nil을 그대로 두면
            // isUnexpired가 "리셋되지 않음"으로 보아 카드가 얼어붙기 때문이다.
            let resets = resetAt
                ?? resetAfterSeconds.map { Int(now.timeIntervalSince1970) + $0 }
            return CodexRateLimit(usedPercent: usedPercent, windowMinutes: windowMinutes, resetsAt: resets)
        }
    }

    func toRateLimits(now: Date) -> CodexRateLimits {
        CodexRateLimits(
            primary: rateLimit?.primaryWindow?.toRateLimit(now: now),
            secondary: rateLimit?.secondaryWindow?.toRateLimit(now: now),
            planType: planType,
            credits: credits,
            rateLimitReachedType: rateLimitReachedType,
            // 메인 플랜 버킷임을 표시(Spark 같은 보조 풀은 limit_name이 붙는다).
            limitName: nil
        )
    }

    var isLimitReached: Bool {
        rateLimit?.limitReached == true || rateLimitReachedType != nil
    }
}

// MARK: - Service

protocol CodexLiveUsageReporting: Sendable {
    func fetchReport() async throws -> CodexSessionParser.RateLimitReport
}

/// Codex 실시간 사용량을 ChatGPT 백엔드에서 읽어 로그 파서와 같은 RateLimitReport로 돌려준다.
/// auth.json은 매 호출마다 새로 읽어 CLI가 갱신한 토큰을 그대로 사용한다(앱은 refresh하지 않음).
final class CodexUsageService: CodexLiveUsageReporting, Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let authPath: String
    private let usageURL: URL
    private let transport: Transport
    private let now: @Sendable () -> Date

    init(
        authPath: String = Constants.Codex.authPath,
        usageURLString: String = Constants.Codex.liveUsageURL,
        transport: @escaping Transport = CodexUsageService.defaultTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authPath = authPath
        self.usageURL = URL(string: usageURLString)!
        self.transport = transport
        self.now = now
    }

    func fetchReport() async throws -> CodexSessionParser.RateLimitReport {
        let auth = try loadAuth()

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(auth.accountId, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let (data, http) = try await transport(request)

        if http.statusCode == 401 {
            throw CodexUsageError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CodexUsageError.invalidResponse(statusCode: http.statusCode)
        }

        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        let timestamp = now()
        let limits = response.toRateLimits(now: timestamp)
        // 2xx라도 표시할 창이 하나도 없으면(rate_limit null 등) 실패로 취급해 로그로 폴백하게 한다.
        // 그렇지 않으면 빈 스냅샷이 화면을 비우고 폴백도 일어나지 않는다.
        guard limits.primary != nil || limits.secondary != nil else {
            throw CodexUsageError.emptyUsage
        }
        let snapshot = CodexSessionParser.RateLimitSnapshot(timestamp: timestamp, limits: limits)
        return CodexSessionParser.RateLimitReport(
            snapshots: [snapshot],
            latest: snapshot,
            limitReachedAt: response.isLimitReached ? timestamp : nil
        )
    }

    // MARK: - Auth

    private struct CodexAuth {
        let accessToken: String
        let accountId: String
    }

    private func loadAuth() throws -> CodexAuth {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty,
              let accountId = tokens["account_id"] as? String, !accountId.isEmpty else {
            throw CodexUsageError.notAuthenticated
        }
        return CodexAuth(accessToken: accessToken, accountId: accountId)
    }

    // MARK: - Transport

    static let defaultTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexUsageError.invalidResponse(statusCode: -1)
        }
        return (data, http)
    }

    // 서버가 originator("codex_cli_rs")로 게이팅할 수 있어 코덱스 CLI의 User-Agent 형식을 따른다.
    private static let userAgent = "codex_cli_rs/0.154.0 (macOS) LLMTokenBar"
}
