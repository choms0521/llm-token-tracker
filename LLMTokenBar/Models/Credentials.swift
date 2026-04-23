import Foundation

enum ClaudeCredentialSource: String, Codable, Equatable {
    case appCache
    case cliFile
    case claudeKeychain

    var displayName: String {
        switch self {
        case .appCache:
            return "LLM Token Bar cache"
        case .cliFile:
            return "~/.claude/.credentials.json"
        case .claudeKeychain:
            return "Claude Code Keychain"
        }
    }
}

struct ClaudeCredentialsWrapper: Codable {
    let claudeAiOauth: ClaudeOAuth?
}

struct ClaudeOAuth: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Double // Unix timestamp in milliseconds
    let scopes: [String]?
    let subscriptionType: String?
    let rateLimitTier: String?

    var expiresAtDate: Date {
        Date(timeIntervalSince1970: expiresAt / 1000.0)
    }

    var isExpired: Bool {
        Date() >= expiresAtDate
    }
}

struct SyncStatus: Equatable {
    let provider: Provider
    let isConnected: Bool
    let lastSyncedAt: Date?
    let subscription: String?
    let maskedToken: String?
    let scopes: [String]
    let rateLimitTier: String?
    let credentialSource: ClaudeCredentialSource?
    let expiresAt: Date?
    let statusMessage: String?
    let recoverySuggestion: String?

    init(
        provider: Provider,
        isConnected: Bool,
        lastSyncedAt: Date?,
        subscription: String?,
        maskedToken: String?,
        scopes: [String],
        rateLimitTier: String?,
        credentialSource: ClaudeCredentialSource? = nil,
        expiresAt: Date? = nil,
        statusMessage: String? = nil,
        recoverySuggestion: String? = nil
    ) {
        self.provider = provider
        self.isConnected = isConnected
        self.lastSyncedAt = lastSyncedAt
        self.subscription = subscription
        self.maskedToken = maskedToken
        self.scopes = scopes
        self.rateLimitTier = rateLimitTier
        self.credentialSource = credentialSource
        self.expiresAt = expiresAt
        self.statusMessage = statusMessage
        self.recoverySuggestion = recoverySuggestion
    }

    static func disconnected(
        for provider: Provider,
        credentialSource: ClaudeCredentialSource? = nil,
        expiresAt: Date? = nil,
        statusMessage: String? = nil,
        recoverySuggestion: String? = nil
    ) -> SyncStatus {
        SyncStatus(
            provider: provider,
            isConnected: false,
            lastSyncedAt: nil,
            subscription: nil,
            maskedToken: nil,
            scopes: [],
            rateLimitTier: nil,
            credentialSource: credentialSource,
            expiresAt: expiresAt,
            statusMessage: statusMessage,
            recoverySuggestion: recoverySuggestion
        )
    }
}
