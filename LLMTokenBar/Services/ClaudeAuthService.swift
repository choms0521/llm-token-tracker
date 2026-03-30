import Foundation
import OSLog
import Security

private let logger = Logger(subsystem: "com.llmtokenbar", category: "ClaudeAuth")

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
        clearFileCache()
        return try await loadCredentials()
    }

    func getSyncStatus() async -> SyncStatus {
        do {
            let oauth = try readCredentials()

            let tokenPrefix = String(oauth.accessToken.prefix(6))
            let maskedToken = "\(tokenPrefix)••••••••"

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

    // MARK: - Credential Reading (File Cache → CLI File → Claude Code Keychain)

    private func readCredentials() throws -> ClaudeOAuth {
        // 1. Try app's file cache first (no permission prompt, survives re-signing)
        if let oauth = readFromFileCache(), !oauth.isExpired {
            return oauth
        }

        // 2. Try CLI credentials file (no permission prompt)
        if let oauth = readFromCLIFile(), !oauth.isExpired {
            saveToFileCache(oauth)
            return oauth
        }

        // 3. Last resort: Claude Code's Keychain (may trigger macOS permission prompt)
        logger.info("파일 캐시/CLI 파일에서 유효한 토큰을 찾지 못해 Claude Code Keychain에 접근합니다")
        if let oauth = readFromClaudeKeychain(), !oauth.isExpired {
            saveToFileCache(oauth)
            return oauth
        }

        throw AuthError.credentialsNotFound
    }

    private var fileCachePath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("LLMTokenBar", isDirectory: true)
        return dir.appendingPathComponent("claude-oauth-cache.json")
    }

    private func readFromFileCache() -> ClaudeOAuth? {
        let path = fileCachePath
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        do {
            let data = try Data(contentsOf: path)
            return parseCredentialData(data)
        } catch {
            logger.debug("파일 캐시 읽기 실패: \(error.localizedDescription)")
            return nil
        }
    }

    private func saveToFileCache(_ oauth: ClaudeOAuth) {
        let path = fileCachePath
        do {
            let dir = path.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(oauth)
            try data.write(to: path, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch {
            logger.warning("파일 캐시 저장 실패: \(error.localizedDescription)")
        }
    }

    private func clearFileCache() {
        try? FileManager.default.removeItem(at: fileCachePath)
    }

    private func readFromClaudeKeychain() -> ClaudeOAuth? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                logger.warning("Keychain 조회 실패 (OSStatus: \(status))")
            }
            return nil
        }

        return parseCredentialData(data)
    }

    private func readFromCLIFile() -> ClaudeOAuth? {
        let path = Constants.Claude.credentialsPath
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return parseCredentialData(data)
        } catch {
            logger.error("자격증명 파일 읽기 실패 (\(path)): \(error.localizedDescription)")
            return nil
        }
    }

    private func parseCredentialData(_ data: Data) -> ClaudeOAuth? {
        let decoder = JSONDecoder()

        // Try nested format: { "claudeAiOauth": { ... } }
        do {
            let wrapper = try decoder.decode(ClaudeCredentialsWrapper.self, from: data)
            if let oauth = wrapper.claudeAiOauth {
                return oauth
            }
        } catch {
            logger.debug("Nested 형식 파싱 실패, flat 형식 시도: \(error.localizedDescription)")
        }

        // Try flat format: { "accessToken": ..., "refreshToken": ... }
        do {
            return try decoder.decode(ClaudeOAuth.self, from: data)
        } catch {
            logger.error("자격증명 파싱 실패 (모든 형식): \(error.localizedDescription)")
            return nil
        }
    }

}
