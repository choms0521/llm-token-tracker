import Foundation
import OSLog
import Security

private let logger = Logger(subsystem: "com.llmtokenbar", category: "ClaudeAuth")

enum AuthError: LocalizedError {
    case credentialsNotFound
    case invalidCredentials
    case tokenRefreshFailed(String)
    case networkError(Error)
    case keychainAccessRequiresUserConsent

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
        case .keychainAccessRequiresUserConsent:
            return "Claude Code 키체인 접근 승인이 필요합니다. Settings > Claude > Sync Credentials를 눌러 허용해주세요."
        }
    }
}

/// Outcome of reading the Claude Code credential item from the Keychain.
enum ClaudeKeychainReadResult: Equatable {
    case found(Data)
    case notFound
    case needsUserConsent(OSStatus)
    case unavailable(OSStatus)
}

@MainActor
final class ClaudeAuthService: AuthServiceProtocol {
    let provider = Provider.claude
    private var cachedOAuth: ClaudeOAuth?
    private let fileManager: FileManager
    private let cliCredentialsPath: String
    private let fileCachePathOverride: URL?
    private let keychainReader: (KeychainInteractionMode) -> ClaudeKeychainReadResult

    init(
        fileManager: FileManager = .default,
        cliCredentialsPath: String = Constants.Claude.credentialsPath,
        fileCachePath: URL? = nil,
        keychainReader: @escaping (KeychainInteractionMode) -> ClaudeKeychainReadResult = ClaudeAuthService.defaultKeychainRead
    ) {
        self.fileManager = fileManager
        self.cliCredentialsPath = cliCredentialsPath
        self.fileCachePathOverride = fileCachePath
        self.keychainReader = keychainReader
    }

    convenience init(
        fileManager: FileManager = .default,
        cliCredentialsPath: String = Constants.Claude.credentialsPath,
        fileCachePath: URL? = nil,
        keychainDataProvider: @escaping () -> Data?
    ) {
        self.init(
            fileManager: fileManager,
            cliCredentialsPath: cliCredentialsPath,
            fileCachePath: fileCachePath,
            keychainReader: { _ in keychainDataProvider().map { .found($0) } ?? .notFound }
        )
    }

    /// Set when a background Keychain read needed user consent; cleared once the Keychain is readable.
    private(set) var keychainConsentHint: String?

    private static let keychainConsentSuggestion =
        "Open Settings > Claude > Sync Credentials and allow Keychain access when macOS asks."

    /// Credential sources re-read on reload or explicit sync. The app cache comes last so a newer
    /// external token replaces it, while a still-valid cache survives a failed re-read.
    private static let refreshOrder: [ClaudeCredentialSource] = [.cliFile, .claudeKeychain, .appCache]

    /// Explicit user action (Settings > Claude > Sync Credentials). The only path allowed to show
    /// the macOS Keychain authorization dialog.
    func syncCredentialsFromUserAction() async -> SyncStatus {
        let inspection = inspectCredentials(sources: Self.refreshOrder, mode: .userInitiated)
        if let candidate = inspection.validCredential {
            keychainConsentHint = nil
            adopt(candidate)
        }
        return makeSyncStatus(from: inspection)
    }

    func loadCredentials() async throws -> String {
        if let cached = cachedOAuth, !cached.isExpired {
            return cached.accessToken
        }

        let oauth = try readCredentials()
        cachedOAuth = oauth
        return oauth.accessToken
    }

    /// Background re-read after 401/429. Never shows Keychain UI and keeps the current valid
    /// token until a valid replacement is found.
    func reloadCredentials() async throws -> String {
        let inspection = inspectCredentials(sources: Self.refreshOrder, mode: .background)
        if let candidate = inspection.validCredential {
            adopt(candidate)
            return candidate.oauth.accessToken
        }
        if let cached = cachedOAuth, !cached.isExpired {
            return cached.accessToken
        }
        throw Self.error(for: inspection)
    }

    func getSyncStatus() async -> SyncStatus {
        makeSyncStatus(from: inspectCredentials(sources: ClaudeCredentialSource.discoveryOrder, mode: .background))
    }

    private func makeSyncStatus(from inspection: ClaudeCredentialInspection) -> SyncStatus {
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
                recoverySuggestion: keychainConsentHint
            )
        }

        if let keychainStatus = Self.keychainIssueStatus(for: inspection) {
            return keychainStatus
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

    private static func keychainIssueStatus(for inspection: ClaudeCredentialInspection) -> SyncStatus? {
        switch inspection.keychainIssue {
        case .needsUserConsent:
            return .disconnected(
                for: .claude,
                credentialSource: .claudeKeychain,
                statusMessage: "Claude Code Keychain access needs your approval.",
                recoverySuggestion: keychainConsentSuggestion
            )
        case .unavailable(let status) where inspection.expiredCredential == nil:
            return .disconnected(
                for: .claude,
                credentialSource: .claudeKeychain,
                statusMessage: "Claude Code Keychain could not be read (OSStatus \(status)).",
                recoverySuggestion: keychainConsentSuggestion
            )
        default:
            return nil
        }
    }

    // MARK: - Credential Reading (File Cache → CLI File → Claude Code Keychain)

    private func readCredentials() throws -> ClaudeOAuth {
        let inspection = inspectCredentials(sources: ClaudeCredentialSource.discoveryOrder, mode: .background)

        if let candidate = inspection.validCredential {
            if candidate.source != .appCache {
                saveToFileCache(candidate.oauth)
            }
            return candidate.oauth
        }

        throw Self.error(for: inspection)
    }

    private func adopt(_ candidate: ClaudeCredentialCandidate) {
        if candidate.source != .appCache {
            saveToFileCache(candidate.oauth)
        }
        cachedOAuth = candidate.oauth
    }

    private static func error(for inspection: ClaudeCredentialInspection) -> AuthError {
        if case .needsUserConsent = inspection.keychainIssue {
            return .keychainAccessRequiresUserConsent
        }
        if let expired = inspection.expiredCredential {
            return .tokenRefreshFailed(
                "\(expired.source.displayName)에 저장된 토큰이 만료되었습니다. Claude Code CLI에서 다시 로그인한 뒤 Sync Credentials를 눌러주세요."
            )
        }
        return .credentialsNotFound
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

    private func readFromClaudeKeychain(
        mode: KeychainInteractionMode,
        issue: inout ClaudeKeychainReadResult?
    ) -> ClaudeOAuth? {
        let result = keychainReader(mode)
        switch result {
        case .found(let data):
            keychainConsentHint = nil
            return parseCredentialData(data)
        case .notFound:
            keychainConsentHint = nil
        case .needsUserConsent(let status):
            logger.info("Claude Code Keychain read needs user consent (OSStatus: \(status))")
            keychainConsentHint = Self.keychainConsentSuggestion
            issue = result
        case .unavailable(let status):
            logger.warning("Claude Code Keychain read unavailable (OSStatus: \(status))")
            issue = result
        }
        return nil
    }

    nonisolated static func classifyKeychainRead(status: OSStatus, data: Data?) -> ClaudeKeychainReadResult {
        switch status {
        case errSecSuccess:
            return data.map { .found($0) } ?? .unavailable(status)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed, errSecUserCanceled:
            return .needsUserConsent(status)
        default:
            return .unavailable(status)
        }
    }

    /// Reads the Claude Code CLI item inside the shared interaction scope. `.background` never
    /// shows UI; if the scope cannot be established the query is not executed.
    nonisolated static func defaultKeychainRead(_ mode: KeychainInteractionMode) -> ClaudeKeychainReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        do {
            return try KeychainInteractionGuard.shared.perform(mode) {
                var result: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                return classifyKeychainRead(status: status, data: result as? Data)
            }
        } catch let error as KeychainInteractionError {
            logger.error("Keychain interaction scope failed: \(error.localizedDescription)")
            return .unavailable(error.status)
        } catch {
            logger.error("Keychain interaction scope failed unexpectedly")
            return .unavailable(errSecInternalError)
        }
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

    private func inspectCredentials(
        sources: [ClaudeCredentialSource],
        mode: KeychainInteractionMode
    ) -> ClaudeCredentialInspection {
        var expiredCredential: ClaudeCredentialCandidate?
        var keychainIssue: ClaudeKeychainReadResult?

        for source in sources {
            let oauth: ClaudeOAuth?
            switch source {
            case .appCache:
                oauth = readFromFileCache()
            case .cliFile:
                oauth = readFromCLIFile()
            case .claudeKeychain:
                oauth = readFromClaudeKeychain(mode: mode, issue: &keychainIssue)
            }
            guard let oauth else { continue }

            let candidate = ClaudeCredentialCandidate(source: source, oauth: oauth)
            if !oauth.isExpired {
                return ClaudeCredentialInspection(
                    validCredential: candidate,
                    expiredCredential: expiredCredential,
                    keychainIssue: keychainIssue
                )
            }
            if expiredCredential == nil {
                expiredCredential = candidate
            }
        }

        return ClaudeCredentialInspection(
            validCredential: nil,
            expiredCredential: expiredCredential,
            keychainIssue: keychainIssue
        )
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
    let keychainIssue: ClaudeKeychainReadResult?
}
