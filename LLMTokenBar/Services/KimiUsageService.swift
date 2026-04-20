import Foundation
import OSLog

private let logger = Logger(subsystem: "com.llmtokenbar", category: "KimiUsage")

@MainActor
final class KimiUsageService: UsageServiceProtocol {
    let provider = Provider.kimi
    private let authService: KimiAuthService

    init(authService: KimiAuthService) {
        self.authService = authService
    }

    func fetchUsage() async throws -> UsageData {
        let apiKey = try await authService.loadCredentials()

        do {
            return try await fetchWithKey(apiKey)
        } catch UsageError.unauthorized {
            let reloadedKey = try await authService.reloadCredentials()
            if reloadedKey != apiKey {
                return try await fetchWithKey(reloadedKey)
            }
            throw UsageError.unauthorized
        } catch UsageError.rateLimited(let retryAfter) {
            let reloadedKey = try await authService.reloadCredentials()
            if reloadedKey != apiKey {
                return try await fetchWithKey(reloadedKey)
            }
            throw UsageError.rateLimited(retryAfter: retryAfter)
        }
    }

    private func fetchWithKey(_ apiKey: String, retryCount: Int = 0) async throws -> UsageData {
        guard let url = URL(string: Constants.Kimi.usageURL) else {
            throw UsageError.invalidResponse(0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

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
            if retryCount < 1 {
                let delay: TimeInterval = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(TimeInterval.init) ?? 3.0
                try await Task.sleep(for: .seconds(min(delay, 10.0)))
                return try await fetchWithKey(apiKey, retryCount: retryCount + 1)
            }
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            throw UsageError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageError.invalidResponse(httpResponse.statusCode)
        }
    }

    private func parseResponse(_ data: Data) throws -> UsageData {
        let response: KimiUsageResponse
        do {
            response = try JSONDecoder().decode(KimiUsageResponse.self, from: data)
        } catch {
            if let rawJSON = String(data: data, encoding: .utf8) {
                logger.error("Kimi decoding failed. Raw response: \(rawJSON)")
            }
            logger.error("Kimi decoding error: \(error)")
            throw UsageError.decodingError(error)
        }

        // 5h window (limits[0])
        let sessionUsage: UsageEntry? = response.limits.first.map { entry in
            let detail = entry.detail
            let windowLabel = entry.window?.displayLabel ?? "Session"
            return UsageEntry(
                label: windowLabel,
                sublabel: "Kimi Code (\(detail.usedInt)/\(detail.limitInt))",
                utilization: detail.utilization,
                resetsAt: detail.resetsAtDate
            )
        }

        // Weekly usage
        let weekly = response.usage
        let weeklyUsage = UsageEntry(
            label: String(localized: "Weekly Usage"),
            sublabel: "Kimi Code (\(weekly.usedInt)/\(weekly.limitInt))",
            utilization: weekly.utilization,
            resetsAt: weekly.resetsAtDate
        )

        return UsageData(
            provider: .kimi,
            sessionUsage: sessionUsage,
            weeklyUsage: weeklyUsage,
            modelUsages: [],
            lastUpdated: Date()
        )
    }
}
