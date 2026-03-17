import Foundation

enum UsageError: LocalizedError {
    case unauthorized
    case rateLimited
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
}

@MainActor
final class ClaudeUsageService: UsageServiceProtocol {
    let provider = Provider.claude
    private let authService: ClaudeAuthService

    init(authService: ClaudeAuthService) {
        self.authService = authService
    }

    func fetchUsage() async throws -> UsageData {
        let accessToken = try await authService.loadCredentials()

        do {
            return try await fetchWithToken(accessToken)
        } catch UsageError.rateLimited, UsageError.unauthorized {
            let reloadedToken = try await authService.reloadCredentials()
            if reloadedToken != accessToken {
                return try await fetchWithToken(reloadedToken)
            }
            throw UsageError.rateLimited
        }
    }

    private func fetchWithToken(_ token: String) async throws -> UsageData {
        let url = URL(string: Constants.Claude.usageURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Constants.Claude.betaHeader, forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.networkError(URLError(.badServerResponse))
        }

        switch httpResponse.statusCode {
        case 200:
            return try parseResponse(data)
        case 401:
            throw UsageError.unauthorized
        case 429:
            throw UsageError.rateLimited
        default:
            throw UsageError.invalidResponse(httpResponse.statusCode)
        }
    }

    private func parseResponse(_ data: Data) throws -> UsageData {
        let response: ClaudeUsageResponse
        do {
            response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        } catch {
            throw UsageError.decodingError(error)
        }

        let sessionUsage = response.fiveHour.map { bucket in
            UsageEntry(
                label: "세션 사용량",
                sublabel: "5시간 롤링 윈도우",
                utilization: bucket.utilization,
                resetsAt: bucket.resetsAtDate
            )
        }

        let weeklyUsage = response.sevenDay.map { bucket in
            UsageEntry(
                label: "모든 모델",
                sublabel: "주간",
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

        return UsageData(
            provider: .claude,
            sessionUsage: sessionUsage,
            weeklyUsage: weeklyUsage,
            modelUsages: modelUsages,
            lastUpdated: Date()
        )
    }
}
