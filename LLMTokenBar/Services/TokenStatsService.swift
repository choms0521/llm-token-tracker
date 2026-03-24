import Foundation
import OSLog

private let logger = Logger(subsystem: "com.llmtokenbar", category: "TokenStats")

@MainActor
final class TokenStatsService: ObservableObject {
    @Published var modelSummaries: [ModelSummary] = []
    @Published var dailyTokens: [DailyTokenEntry] = []
    @Published var totalCost: Double = 0

    private let claudeParser: ClaudeSessionParser
    private let geminiParser: GeminiSessionParser
    private let codexParser: CodexSessionParser

    init(
        claudeParser: ClaudeSessionParser = ClaudeSessionParser(),
        geminiParser: GeminiSessionParser = GeminiSessionParser(),
        codexParser: CodexSessionParser = CodexSessionParser()
    ) {
        self.claudeParser = claudeParser
        self.geminiParser = geminiParser
        self.codexParser = codexParser
    }

    func reload() {
        modelSummaries = []
        dailyTokens = []
        totalCost = 0

        // Claude: parse JSONL messages directly
        let claudeData = claudeParser.parse()
        dailyTokens.append(contentsOf: claudeData.dailyTokens)
        modelSummaries.append(contentsOf: claudeData.modelSummaries)

        // Gemini local session data
        let geminiData = geminiParser.parse()
        dailyTokens.append(contentsOf: geminiData.dailyTokens)
        modelSummaries.append(contentsOf: geminiData.modelSummaries)

        // Codex local session data
        let codexData = codexParser.parse()
        dailyTokens.append(contentsOf: codexData.dailyTokens)
        modelSummaries.append(contentsOf: codexData.modelSummaries)

        dailyTokens.sort { $0.date < $1.date }
        modelSummaries.sort { $0.totalTokens > $1.totalTokens }
        totalCost = modelSummaries.reduce(0) { $0 + $1.costUSD }
    }

    var allModelIds: [String] {
        Array(Set(dailyTokens.map(\.modelId))).sorted()
    }

    var recentModelUsages: [RecentModelUsage] {
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let recentTokens = dailyTokens.filter { $0.date >= sevenDaysAgo }

        var tokensByModel: [String: Int] = [:]
        for entry in recentTokens {
            tokensByModel[entry.modelId, default: 0] += entry.tokens
        }

        return tokensByModel
            .map { RecentModelUsage(id: $0.key, modelId: $0.key, tokens: $0.value) }
            .sorted { $0.tokens > $1.tokens }
    }
}

struct RecentModelUsage: Identifiable {
    let id: String
    let modelId: String
    let tokens: Int

    var displayName: String {
        formatModelName(modelId)
    }

    private func formatModelName(_ id: String) -> String {
        if id.hasPrefix("gemini-") {
            // "gemini-3-flash-preview" → "Gemini-3-Flash"
            return id.replacingOccurrences(of: "-preview", with: "")
                .split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: "-")
        }
        if id.hasPrefix("gpt-") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") {
            // "gpt-5.4" → "GPT-5.4", "o3-mini" → "O3-Mini"
            return id.split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: "-")
        }
        // "claude-opus-4-6" → "Opus-4-6"
        return id
            .replacingOccurrences(of: "claude-", with: "")
            .components(separatedBy: "-")
            .prefix(3)
            .joined(separator: "-")
            .capitalized
    }

    var formattedTokens: String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.0fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }
}
