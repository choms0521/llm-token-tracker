import Foundation
import OSLog

private let logger = Logger(subsystem: "com.llmtokenbar", category: "TokenStats")

@MainActor
final class TokenStatsService: ObservableObject {
    @Published var modelSummaries: [ModelSummary] = []
    @Published var dailyTokens: [DailyTokenEntry] = []
    @Published var totalCost: Double = 0
    @Published var isLoading: Bool = false

    private let claudeParser: ClaudeSessionParser
    private let geminiParser: GeminiSessionParser
    private let codexParser: CodexSessionParser
    private var currentReloadTask: Task<Void, Never>?

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
        currentReloadTask?.cancel()
        isLoading = true

        currentReloadTask = Task.detached(priority: .utility) { [claudeParser, geminiParser, codexParser] in
            let result = await Self.parseInBackground(
                claude: claudeParser,
                gemini: geminiParser,
                codex: codexParser
            )

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.dailyTokens = result.tokens
                self.modelSummaries = result.summaries
                self.totalCost = result.cost
                self.isLoading = false
            }
        }
    }

    private static nonisolated func parseInBackground(
        claude: ClaudeSessionParser,
        gemini: GeminiSessionParser,
        codex: CodexSessionParser
    ) async -> (tokens: [DailyTokenEntry], summaries: [ModelSummary], cost: Double) {
        let claudeData = claude.parse()
        let geminiData = gemini.parse()
        let codexData = codex.parse()

        var tokens: [DailyTokenEntry] = []
        tokens.append(contentsOf: claudeData.dailyTokens)
        tokens.append(contentsOf: geminiData.dailyTokens)
        tokens.append(contentsOf: codexData.dailyTokens)
        tokens.sort { $0.date < $1.date }

        var summaries: [ModelSummary] = []
        summaries.append(contentsOf: claudeData.modelSummaries)
        summaries.append(contentsOf: geminiData.modelSummaries)
        summaries.append(contentsOf: codexData.modelSummaries)
        summaries.sort { $0.totalTokens > $1.totalTokens }

        let cost = summaries.reduce(0) { $0 + $1.costUSD }
        return (tokens, summaries, cost)
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
