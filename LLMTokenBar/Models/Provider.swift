import Foundation

enum Provider: String, CaseIterable, Identifiable, Codable {
    case claude
    case gemini
    case openai
    case minimax

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .openai: return "OpenAI"
        case .minimax: return "MiniMax"
        }
    }

    var iconName: String {
        switch self {
        case .claude: return "brain.head.profile"
        case .gemini: return "sparkles"
        case .openai: return "cpu"
        case .minimax: return "wand.and.stars"
        }
    }

    var accentColorName: String {
        switch self {
        case .claude: return "ClaudeOrange"
        case .gemini: return "GeminiBlue"
        case .openai: return "OpenAIGreen"
        case .minimax: return "MiniMaxPurple"
        }
    }
}
