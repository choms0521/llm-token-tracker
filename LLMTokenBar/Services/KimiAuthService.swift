import Foundation
import OSLog

private let logger = Logger(subsystem: "com.llmtokenbar", category: "KimiAuth")

@MainActor
final class KimiAuthService: AuthServiceProtocol {
    let provider = Provider.kimi
    private var cachedApiKey: String?

    func loadCredentials() async throws -> String {
        if let cached = cachedApiKey {
            return cached
        }
        return try await reloadCredentials()
    }

    func reloadCredentials() async throws -> String {
        if let apiKey = loadFromKeychain(), !apiKey.isEmpty {
            cachedApiKey = apiKey
            return apiKey
        }

        if let envKey = ProcessInfo.processInfo.environment[Constants.Kimi.apiKeyEnvVar],
           !envKey.isEmpty {
            saveToKeychain(envKey)
            cachedApiKey = envKey
            return envKey
        }

        throw KimiError.apiKeyNotFound
    }

    func getSyncStatus() async -> SyncStatus {
        do {
            let apiKey = try await loadCredentials()
            let masked = String(apiKey.prefix(8)) + "..."
            return SyncStatus(
                provider: .kimi,
                isConnected: true,
                lastSyncedAt: Date(),
                subscription: "Kimi Code",
                maskedToken: masked,
                scopes: [],
                rateLimitTier: nil
            )
        } catch {
            return .disconnected(for: .kimi)
        }
    }

    func saveApiKey(_ apiKey: String) {
        saveToKeychain(apiKey)
        cachedApiKey = apiKey
    }

    func clearApiKey() {
        try? KeychainService.shared.delete(
            service: Constants.Keychain.serviceName,
            account: Constants.Keychain.kimiAccount
        )
        cachedApiKey = nil
    }

    // MARK: - Keychain

    private func loadFromKeychain() -> String? {
        guard let data = try? KeychainService.shared.load(
            service: Constants.Keychain.serviceName,
            account: Constants.Keychain.kimiAccount
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveToKeychain(_ apiKey: String) {
        guard let data = apiKey.data(using: .utf8) else { return }
        do {
            try KeychainService.shared.save(
                data,
                service: Constants.Keychain.serviceName,
                account: Constants.Keychain.kimiAccount
            )
        } catch {
            logger.error("Keychain 저장 실패: \(error.localizedDescription)")
        }
    }
}

enum KimiError: LocalizedError {
    case apiKeyNotFound
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .apiKeyNotFound:
            return "Kimi API key not configured"
        case .apiError(let code, let message):
            return "Kimi API error (\(code)): \(message)"
        }
    }
}
