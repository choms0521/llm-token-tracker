import Foundation

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

    static func disconnected(for provider: Provider) -> SyncStatus {
        SyncStatus(
            provider: provider,
            isConnected: false,
            lastSyncedAt: nil,
            subscription: nil,
            maskedToken: nil,
            scopes: [],
            rateLimitTier: nil
        )
    }
}
