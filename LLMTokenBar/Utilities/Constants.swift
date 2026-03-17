import Foundation

enum Constants {
    enum Claude {
        static let credentialsPath = "\(NSHomeDirectory())/.claude/.credentials.json"
        static let usageURL = "https://api.anthropic.com/api/oauth/usage"
        static let betaHeader = "oauth-2025-04-20"
    }

    enum Polling {
        static let successInterval: TimeInterval = 300
        static let failureInterval: TimeInterval = 30
        static let rateLimitBaseInterval: TimeInterval = 300
        static let rateLimitMaxInterval: TimeInterval = 900
    }

    enum Keychain {
        static let serviceName = "com.llmtokenbar.credentials"
        static let claudeAccount = "claude-oauth"
    }

    enum UI {
        static let popoverWidth: CGFloat = 320
        static let popoverHeight: CGFloat = 420
        static let settingsWidth: CGFloat = 700
        static let settingsHeight: CGFloat = 750
    }
}
