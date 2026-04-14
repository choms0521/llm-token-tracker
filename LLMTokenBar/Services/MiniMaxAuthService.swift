import Foundation

@MainActor
final class MiniMaxAuthService: AuthServiceProtocol {
    let provider = Provider.minimax
    private var cachedApiKey: String?

    func loadCredentials() async throws -> String {
        if let cached = cachedApiKey {
            return cached
        }
        return try await reloadCredentials()
    }

    func reloadCredentials() async throws -> String {
        guard let apiKey = ProcessInfo.processInfo.environment[Constants.MiniMax.apiKeyEnvVar],
              !apiKey.isEmpty else {
            throw MiniMaxError.apiKeyNotFound
        }
        cachedApiKey = apiKey
        return apiKey
    }

    func getSyncStatus() async -> SyncStatus {
        do {
            let apiKey = try await loadCredentials()
            let masked = String(apiKey.prefix(8)) + "..."
            return SyncStatus(
                provider: .minimax,
                isConnected: true,
                lastSyncedAt: Date(),
                subscription: "Coding Plan",
                maskedToken: masked,
                scopes: [],
                rateLimitTier: nil
            )
        } catch {
            return .disconnected(for: .minimax)
        }
    }
}

enum MiniMaxError: LocalizedError {
    case apiKeyNotFound
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .apiKeyNotFound:
            return "MINIMAX_API_KEY environment variable not set"
        case .apiError(let code, let message):
            return "MiniMax API error (\(code)): \(message)"
        }
    }
}
