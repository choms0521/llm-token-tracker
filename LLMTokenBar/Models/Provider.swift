import Foundation

enum Provider: String, CaseIterable, Identifiable, Codable {
    case claude
    case gemini
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .openai: return "OpenAI"
        }
    }

    var iconName: String {
        switch self {
        case .claude: return "brain.head.profile"
        case .gemini: return "sparkles"
        case .openai: return "cpu"
        }
    }

    var accentColorName: String {
        switch self {
        case .claude: return "ClaudeOrange"
        case .gemini: return "GeminiBlue"
        case .openai: return "OpenAIGreen"
        }
    }
}
