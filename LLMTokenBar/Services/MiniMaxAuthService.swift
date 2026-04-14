import Foundation
import OSLog

private let logger = Logger(subsystem: "com.llmtokenbar", category: "MiniMaxAuth")

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
        // 1순위: Keychain
        if let apiKey = loadFromKeychain(), !apiKey.isEmpty {
            cachedApiKey = apiKey
            return apiKey
        }

        // 2순위: 환경변수 (fallback, 터미널 실행 시)
        if let envKey = ProcessInfo.processInfo.environment[Constants.MiniMax.apiKeyEnvVar],
           !envKey.isEmpty {
            // 환경변수에서 읽은 키를 Keychain에 저장
            saveToKeychain(envKey)
            cachedApiKey = envKey
            return envKey
        }

        throw MiniMaxError.apiKeyNotFound
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

    func saveApiKey(_ apiKey: String) {
        saveToKeychain(apiKey)
        cachedApiKey = apiKey
    }

    func clearApiKey() {
        try? KeychainService.shared.delete(
            service: Constants.Keychain.serviceName,
            account: Constants.Keychain.minimaxAccount
        )
        cachedApiKey = nil
    }

    // MARK: - Keychain

    private func loadFromKeychain() -> String? {
        guard let data = try? KeychainService.shared.load(
            service: Constants.Keychain.serviceName,
            account: Constants.Keychain.minimaxAccount
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveToKeychain(_ apiKey: String) {
        guard let data = apiKey.data(using: .utf8) else { return }
        do {
            try KeychainService.shared.save(
                data,
                service: Constants.Keychain.serviceName,
                account: Constants.Keychain.minimaxAccount
            )
        } catch {
            logger.error("Keychain 저장 실패: \(error.localizedDescription)")
        }
    }
}

enum MiniMaxError: LocalizedError {
    case apiKeyNotFound
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .apiKeyNotFound:
            return "MiniMax API key not configured"
        case .apiError(let code, let message):
            return "MiniMax API error (\(code)): \(message)"
        }
    }
}
