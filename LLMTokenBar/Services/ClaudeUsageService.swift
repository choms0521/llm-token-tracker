import Foundation

enum UsageError: LocalizedError {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case networkError(Error)
    case invalidResponse(Int)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Unauthorized - token may be expired"
        case .rateLimited:
            return "Rate limited - try again later"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse(let code):
            return "Invalid response: HTTP \(code)"
        case .decodingError(let error):
            return "Decoding error: \(error.localizedDescription)"
        }
    }

    var retryAfterInterval: TimeInterval? {
        if case .rateLimited(let retryAfter) = self {
            return retryAfter
        }
        return nil
    }
}

@MainActor
final class ClaudeUsageService: UsageServiceProtocol {
    let provider = Provider.claude
    private let authService: ClaudeAuthService
    private let session: URLSession

    init(authService: ClaudeAuthService, session: URLSession = .shared) {
        self.authService = authService
        self.session = session
    }

    func fetchUsage() async throws -> UsageData {
        let accessToken = try await authService.loadCredentials()

        do {
            return try await fetchWithToken(accessToken)
        } catch UsageError.unauthorized {
            authService.markCredentialRejected(accessToken)
            // Rejected tokens are excluded, so a reload can only return a different credential.
            let reloadedToken = try await authService.reloadCredentials()
            do {
                return try await fetchWithToken(reloadedToken)
            } catch UsageError.unauthorized {
                authService.markCredentialRejected(reloadedToken)
                throw UsageError.unauthorized
            }
        } catch UsageError.rateLimited(let retryAfter) {
            // Local re-read only: no further HTTP until the cooldown ends, even with a new token.
            _ = try? await authService.reloadCredentials()
            throw UsageError.rateLimited(retryAfter: retryAfter)
        }
    }

    private func fetchWithToken(_ token: String) async throws -> UsageData {
        let url = URL(string: Constants.Claude.usageURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Constants.Claude.betaHeader, forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.networkError(URLError(.badServerResponse))
        }

        switch httpResponse.statusCode {
        case 200:
            return try Self.parseResponse(data)
        case 401:
            throw UsageError.unauthorized
        case 429:
            let retryAfter = Self.parseRetryAfter(httpResponse.value(forHTTPHeaderField: "Retry-After"))
            throw UsageError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageError.invalidResponse(httpResponse.statusCode)
        }
    }

    /// Retry-After as delta-seconds or HTTP-date. Malformed, negative or non-finite values give nil.
    nonisolated static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let seconds = TimeInterval(text) {
            return seconds.isFinite && seconds >= 0 ? seconds : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: text) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    nonisolated static func parseResponse(_ data: Data) throws -> UsageData {
        let response: ClaudeUsageResponse
        do {
            response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        } catch {
            throw UsageError.decodingError(error)
        }

        let sessionUsage = response.fiveHour.map { bucket in
            UsageEntry(
                label: String(localized: "Session Usage"),
                sublabel: String(localized: "5-hour rolling window"),
                utilization: bucket.utilization,
                resetsAt: bucket.resetsAtDate
            )
        }

        let weeklyUsage = response.sevenDay.map { bucket in
            UsageEntry(
                label: String(localized: "All Models"),
                sublabel: String(localized: "Weekly"),
                utilization: bucket.utilization,
                resetsAt: bucket.resetsAtDate
            )
        }

        var modelUsages: [ModelUsage] = []

        if let opus = response.sevenDayOpus {
            modelUsages.append(ModelUsage(
                id: "opus",
                modelName: "Opus",
                utilization: opus.utilization,
                resetsAt: opus.resetsAtDate
            ))
        }

        if let sonnet = response.sevenDaySonnet {
            modelUsages.append(ModelUsage(
                id: "sonnet",
                modelName: "Sonnet",
                utilization: sonnet.utilization,
                resetsAt: sonnet.resetsAtDate
            ))
        }

        if let haiku = response.sevenDayHaiku {
            modelUsages.append(ModelUsage(
                id: "haiku",
                modelName: "Haiku",
                utilization: haiku.utilization,
                resetsAt: haiku.resetsAtDate
            ))
        }

        // is_active is intentionally ignored: the live Fable weekly_scoped entry reports false.
        // Only global (surface == nil) model-scoped limits with percent in exactly 0...100 are shown.
        for limit in response.limits ?? [] where limit.kind == "weekly_scoped" {
            guard limit.scope?.surface == nil,
                  let name = limit.scope?.model?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  limit.percent.isFinite, (0...100).contains(limit.percent)
            else { continue }
            let id = name.lowercased()
            guard !modelUsages.contains(where: { $0.id == id }) else { continue }
            modelUsages.append(ModelUsage(
                id: id,
                modelName: name,
                utilization: limit.percent,
                resetsAt: limit.resetsAtDate
            ))
        }

        return UsageData(
            provider: .claude,
            sessionUsage: sessionUsage,
            weeklyUsage: weeklyUsage,
            modelUsages: modelUsages,
            lastUpdated: Date()
        )
    }
}
