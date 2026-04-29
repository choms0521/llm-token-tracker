import Foundation

enum Provider: String, CaseIterable, Identifiable, Codable, Sendable {
    case claude
    case gemini
    case openai
    case minimax
    case kimi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .openai: return "OpenAI"
        case .minimax: return "MiniMax"
        case .kimi: return "Kimi"
        }
    }

    var iconName: String {
        switch self {
        case .claude: return "brain.head.profile"
        case .gemini: return "sparkles"
        case .openai: return "cpu"
        case .minimax: return "wand.and.stars"
        case .kimi: return "moon.stars"
        }
    }

    var accentColorName: String {
        switch self {
        case .claude: return "ClaudeOrange"
        case .gemini: return "GeminiBlue"
        case .openai: return "OpenAIGreen"
        case .minimax: return "MiniMaxPurple"
        case .kimi: return "KimiBlue"
        }
    }
}

enum StatusBarUsageProvider: String, CaseIterable, Identifiable, Sendable {
    case claude
    case openai
    case minimax
    case kimi

    static let storageKey = "statusBarProvider"
    static let defaultValue = StatusBarUsageProvider.claude

    var id: String { rawValue }

    var provider: Provider {
        switch self {
        case .claude: return .claude
        case .openai: return .openai
        case .minimax: return .minimax
        case .kimi: return .kimi
        }
    }

    var displayName: String {
        switch self {
        case .openai:
            return "Codex"
        default:
            return provider.displayName
        }
    }

    var supportedStatusBarMetrics: [StatusBarMetric] {
        switch self {
        case .claude:
            return StatusBarMetric.allCases
        case .openai, .minimax, .kimi:
            return [.session, .weekly]
        }
    }
}

enum StatusBarMetric: String, CaseIterable, Identifiable, Sendable {
    case session
    case weekly
    case opus
    case sonnet
    case haiku

    var id: String { rawValue }
}
