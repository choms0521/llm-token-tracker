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
            return "Claude 자격증명을 찾을 수 없습니다. Claude Code CLI에 다시 로그인한 뒤 Sync Credentials를 눌러주세요."
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
    private let fileManager: FileManager
    private let cliCredentialsPath: String
    private let fileCachePathOverride: URL?
    private let keychainDataProvider: () -> Data?

    init(
        fileManager: FileManager = .default,
        cliCredentialsPath: String = Constants.Claude.credentialsPath,
        fileCachePath: URL? = nil,
        keychainDataProvider: @escaping () -> Data? = ClaudeAuthService.defaultKeychainData
    ) {
        self.fileManager = fileManager
        self.cliCredentialsPath = cliCredentialsPath
        self.fileCachePathOverride = fileCachePath
        self.keychainDataProvider = keychainDataProvider
    }

    func loadCredentials() async throws -> String {
        if let cached = cachedOAuth, !cached.isExpired {
            return cached.accessToken
        }

        let oauth = try readCredentials()
        cachedOAuth = oauth
        return oauth.accessToken
    }

    func reloadCredentials() async throws -> String {
        cachedOAuth = nil
        clearFileCache()
        return try await loadCredentials()
    }

    func getSyncStatus() async -> SyncStatus {
        let inspection = inspectCredentials()

        if let candidate = inspection.validCredential {
            let oauth = candidate.oauth
            let tokenPrefix = String(oauth.accessToken.prefix(6))
            let maskedToken = "\(tokenPrefix)••••••••"

            return SyncStatus(
                provider: .claude,
                isConnected: true,
                lastSyncedAt: Date(),
                subscription: oauth.subscriptionType,
                maskedToken: maskedToken,
                scopes: oauth.scopes ?? [],
                rateLimitTier: oauth.rateLimitTier,
                credentialSource: candidate.source,
                expiresAt: oauth.expiresAtDate,
                statusMessage: "Using \(candidate.source.displayName)",
                recoverySuggestion: nil
            )
        }

        if let candidate = inspection.expiredCredential {
            let source = candidate.source
            let expiresAt = candidate.oauth.expiresAtDate
            return .disconnected(
                for: .claude,
                credentialSource: source,
                expiresAt: expiresAt,
                statusMessage: "Stored token in \(source.displayName) expired at \(Self.formatDate(expiresAt)).",
                recoverySuggestion: "Run `claude` in Terminal to sign in again, then click Sync Credentials."
            )
        }

        return .disconnected(
            for: .claude,
            statusMessage: "No Claude credentials were found in cache, CLI files, or Claude Code Keychain.",
            recoverySuggestion: "Run `claude` in Terminal to sign in, then click Sync Credentials."
        )
    }

    // MARK: - Credential Reading (File Cache → CLI File → Claude Code Keychain)

    private func readCredentials() throws -> ClaudeOAuth {
        let inspection = inspectCredentials()

        if let candidate = inspection.validCredential {
            if candidate.source != .appCache {
                saveToFileCache(candidate.oauth)
            }
            return candidate.oauth
        }

        if let expired = inspection.expiredCredential {
            throw AuthError.tokenRefreshFailed(
                "\(expired.source.displayName)에 저장된 토큰이 만료되었습니다. Claude Code CLI에서 다시 로그인한 뒤 Sync Credentials를 눌러주세요."
            )
        }

        throw AuthError.credentialsNotFound
    }

    private var fileCachePath: URL {
        if let fileCachePathOverride {
            return fileCachePathOverride
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("LLMTokenBar", isDirectory: true)
        return dir.appendingPathComponent("claude-oauth-cache.json")
    }

    private func readFromFileCache() -> ClaudeOAuth? {
        let path = fileCachePath
        guard fileManager.fileExists(atPath: path.path) else { return nil }
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
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(oauth)
            try data.write(to: path, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch {
            logger.warning("파일 캐시 저장 실패: \(error.localizedDescription)")
        }
    }

    private func clearFileCache() {
        try? fileManager.removeItem(at: fileCachePath)
    }

    private func readFromClaudeKeychain() -> ClaudeOAuth? {
        guard let data = keychainDataProvider() else { return nil }
        return parseCredentialData(data)
    }

    private nonisolated static func defaultKeychainData() -> Data? {
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

        return data
    }

    private func readFromCLIFile() -> ClaudeOAuth? {
        guard fileManager.fileExists(atPath: cliCredentialsPath) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: cliCredentialsPath))
            return parseCredentialData(data)
        } catch {
            logger.error("자격증명 파일 읽기 실패 (\(self.cliCredentialsPath)): \(error.localizedDescription)")
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

    private func inspectCredentials() -> ClaudeCredentialInspection {
        let candidates = [
            readCandidate(from: .appCache),
            readCandidate(from: .cliFile),
            readCandidate(from: .claudeKeychain),
        ].compactMap { $0 }

        return ClaudeCredentialInspection(
            validCredential: candidates.first(where: { !$0.oauth.isExpired }),
            expiredCredential: candidates.first(where: { $0.oauth.isExpired })
        )
    }

    private func readCandidate(from source: ClaudeCredentialSource) -> ClaudeCredentialCandidate? {
        let oauth: ClaudeOAuth?
        switch source {
        case .appCache:
            oauth = readFromFileCache()
        case .cliFile:
            oauth = readFromCLIFile()
        case .claudeKeychain:
            oauth = readFromClaudeKeychain()
        }

        guard let oauth else { return nil }
        return ClaudeCredentialCandidate(source: source, oauth: oauth)
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

}

private struct ClaudeCredentialCandidate {
    let source: ClaudeCredentialSource
    let oauth: ClaudeOAuth
}

private struct ClaudeCredentialInspection {
    let validCredential: ClaudeCredentialCandidate?
    let expiredCredential: ClaudeCredentialCandidate?
}
