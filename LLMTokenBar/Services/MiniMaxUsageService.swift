import Foundation

@MainActor
final class MiniMaxUsageService: UsageServiceProtocol {
    let provider = Provider.minimax
    private let authService: MiniMaxAuthService

    init(authService: MiniMaxAuthService) {
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
        guard let url = URL(string: Constants.MiniMax.usageURL) else {
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
        let response: MiniMaxUsageResponse
        do {
            response = try JSONDecoder().decode(MiniMaxUsageResponse.self, from: data)
        } catch {
            throw UsageError.decodingError(error)
        }

        if response.baseResp.statusCode != 0 {
            throw MiniMaxError.apiError(
                statusCode: response.baseResp.statusCode,
                message: response.baseResp.statusMsg
            )
        }

        guard let model = response.modelRemains.first(where: {
            $0.modelName.hasPrefix(Constants.MiniMax.targetModelPrefix)
        }) else {
            return .empty(for: .minimax)
        }

        let intervalUsed = model.currentIntervalTotalCount - model.currentIntervalUsageCount
        let sessionUsage = UsageEntry(
            label: String(localized: "Session Usage"),
            sublabel: "\(model.modelName) (\(intervalUsed)/\(model.currentIntervalTotalCount))",
            utilization: model.intervalUtilization,
            resetsAt: model.intervalResetsAt
        )

        let weeklyUsed = model.currentWeeklyTotalCount - model.currentWeeklyUsageCount
        let weeklyUsage = UsageEntry(
            label: String(localized: "Weekly Usage"),
            sublabel: "\(model.modelName) (\(weeklyUsed)/\(model.currentWeeklyTotalCount))",
            utilization: model.weeklyUtilization,
            resetsAt: model.weeklyResetsAt
        )

        return UsageData(
            provider: .minimax,
            sessionUsage: sessionUsage,
            weeklyUsage: weeklyUsage,
            modelUsages: [],
            lastUpdated: Date()
        )
    }
}
