import Foundation
import Security

enum AuthError: LocalizedError {
    case credentialsNotFound
    case invalidCredentials
    case tokenRefreshFailed(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            return "Claude CLI 자격증명을 찾을 수 없습니다"
        case .invalidCredentials:
            return "잘못된 자격증명 형식입니다"
        case .tokenRefreshFailed(let reason):
            return "토큰 갱신 실패: \(reason)"
        case .networkError(let error):
            return "네트워크 오류: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class ClaudeAuthService: AuthServiceProtocol {
    let provider = Provider.claude
    private var cachedOAuth: ClaudeOAuth?

    func loadCredentials() async throws -> String {
        if let cached = cachedOAuth, !cached.isExpired {
            return cached.accessToken
        }

        let oauth = try readCredentials()

        if oauth.isExpired {
            throw AuthError.tokenRefreshFailed("토큰이 만료되었습니다. CLI에서 다시 로그인하세요.")
        }

        cachedOAuth = oauth
        return oauth.accessToken
    }

    func reloadCredentials() async throws -> String {
        cachedOAuth = nil
        return try await loadCredentials()
    }

    func getSyncStatus() async -> SyncStatus {
        do {
            let oauth = try readCredentials()

            let tokenPrefix = String(oauth.accessToken.prefix(14))
            let maskedToken = "\(tokenPrefix)••••"

            return SyncStatus(
                provider: .claude,
                isConnected: true,
                lastSyncedAt: Date(),
                subscription: oauth.subscriptionType,
                maskedToken: maskedToken,
                scopes: oauth.scopes ?? [],
                rateLimitTier: oauth.rateLimitTier
            )
        } catch {
            return .disconnected(for: .claude)
        }
    }

    // MARK: - Credential Reading (Keychain → File fallback)

    private func readCredentials() throws -> ClaudeOAuth {
        // Try Keychain first (primary on macOS)
        if let oauth = readFromKeychain() {
            return oauth
        }

        // Fallback to file
        if let oauth = readFromFile() {
            return oauth
        }

        throw AuthError.credentialsNotFound
    }

    private func readFromKeychain() -> ClaudeOAuth? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return parseCredentialData(data)
    }

    private func readFromFile() -> ClaudeOAuth? {
        let path = Constants.Claude.credentialsPath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }

        return parseCredentialData(data)
    }

    private func parseCredentialData(_ data: Data) -> ClaudeOAuth? {
        // Try nested format: { "claudeAiOauth": { ... } }
        if let wrapper = try? JSONDecoder().decode(ClaudeCredentialsWrapper.self, from: data),
           let oauth = wrapper.claudeAiOauth {
            return oauth
        }

        // Try flat format: { "accessToken": ..., "refreshToken": ... }
        if let oauth = try? JSONDecoder().decode(ClaudeOAuth.self, from: data) {
            return oauth
        }

        return nil
    }

}
