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
        // 주간 창(7일)보다 오래된 세션 로그는 한도 표시에 쓸모가 없으므로 하루 여유를 두고 잘라낸다.
        static let rateLimitLookbackDays = 8
        static let rateLimitLookback: TimeInterval = TimeInterval(rateLimitLookbackDays) * 24 * 3600
        // 변경된 파일만 다시 읽으므로 짧은 주기로 폴링해도 부담이 없다.
        static let rateLimitPollInterval: TimeInterval = 60
        static let fullUtilizationPercent: Double = 100
    }

    enum MiniMax {
        static let usageURL = "https://www.minimax.io/v1/api/openplatform/coding_plan/remains"
        static let apiKeyEnvVar = "MINIMAX_API_KEY"
        // coding_plan/remains 응답의 텍스트(코딩) 플랜 모델 식별자.
        // 2026-06 기준 "general"/"video"로 내려옴.
        static let targetModelName = "general"
        // 구버전 응답 호환: 과거에는 모델명이 "MiniMax-M..." 접두사로 내려왔음.
        static let legacyModelPrefix = "MiniMax-M"
        static let modelPrefixes = ["minimax", "hailuo"]
    }

    enum Kimi {
        static let usageURL = "https://api.kimi.com/coding/v1/usages"
        static let apiKeyEnvVar = "KIMI_API_KEY"
        // Kimi Code CLI는 세션별 wire 로그에 토큰 사용량을 기록한다.
        // ~/.kimi (구버전)는 마이그레이션 이후 사용량을 남기지 않으므로 제외한다.
        static let sessionBasePath = "\(NSHomeDirectory())/.kimi-code/sessions"
        static let configPath = "\(NSHomeDirectory())/.kimi-code"
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
