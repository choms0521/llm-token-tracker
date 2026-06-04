import Foundation

enum Constants {
    enum Claude {
        static let credentialsPath = "\(NSHomeDirectory())/.claude/.credentials.json"
        static let usageURL = "https://api.anthropic.com/api/oauth/usage"
        static let betaHeader = "oauth-2025-04-20"
    }

    enum Polling {
        static let successInterval: TimeInterval = 600      // 10분
        static let failureInterval: TimeInterval = 300      // 5분
        static let rateLimitBaseInterval: TimeInterval = 600 // 10분 base
        static let rateLimitMaxInterval: TimeInterval = 1800 // 30분 max
    }

    enum Gemini {
        static let sessionBasePath = "\(NSHomeDirectory())/.gemini/tmp"
        static let configPath = "\(NSHomeDirectory())/.gemini"
    }

    enum Codex {
        static let sessionBasePath = "\(NSHomeDirectory())/.codex/sessions"
        static let configPath = "\(NSHomeDirectory())/.codex"
    }

    enum MiniMax {
        static let usageURL = "https://www.minimax.io/v1/api/openplatform/coding_plan/remains"
        static let apiKeyEnvVar = "MINIMAX_API_KEY"
        // coding_plan/remains 응답의 텍스트(코딩) 플랜 모델 식별자.
        // 과거에는 "MiniMax-M..." 모델명을 내려주었으나 2026-06 기준 "general"/"video"로 변경됨.
        static let targetModelName = "general"
        static let modelPrefixes = ["minimax", "hailuo"]
    }

    enum Kimi {
        static let usageURL = "https://api.kimi.com/coding/v1/usages"
        static let apiKeyEnvVar = "KIMI_API_KEY"
    }

    enum Keychain {
        static let serviceName = "com.llmtokenbar.credentials"
        static let claudeAccount = "claude-oauth"
        static let geminiAccount = "gemini-apikey"
        static let minimaxAccount = "minimax-apikey"
        static let kimiAccount = "kimi-apikey"
    }

    enum UI {
        static let popoverWidth: CGFloat = 320
        static let popoverHeight: CGFloat = 420
        static let settingsWidth: CGFloat = 700
        static let settingsHeight: CGFloat = 750
    }
}
