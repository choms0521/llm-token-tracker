import Foundation

struct StatsCache: Decodable {
    let version: Int?
    let dailyActivity: [DailyActivity]?
    let dailyModelTokens: [DailyModelTokens]?
    let modelUsage: [String: ModelTokenUsage]?
    let totalSessions: Int?
    let totalMessages: Int?
}

struct DailyActivity: Decodable {
    let date: String
    let messageCount: Int
    let sessionCount: Int
    let toolCallCount: Int
}

struct DailyModelTokens: Decodable {
    let date: String
    let tokensByModel: [String: Int]
}

struct ModelTokenUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int
    let webSearchRequests: Int?
    let costUSD: Double?

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadInputTokens + cacheCreationInputTokens
    }

    var displayName: String { "" } // set externally
}

struct ModelSummary: Identifiable {
    let id: String // model ID e.g. "claude-opus-4-6"
    let displayName: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheRead: Int
    let cacheWrite: Int
    let costUSD: Double

    var totalTokens: Int {
        inputTokens + outputTokens + cacheRead + cacheWrite
    }

    static func from(modelId: String, usage: ModelTokenUsage) -> ModelSummary {
        ModelSummary(
            id: modelId,
            displayName: Self.formatModelName(modelId),
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheRead: usage.cacheReadInputTokens,
            cacheWrite: usage.cacheCreationInputTokens,
            costUSD: usage.costUSD ?? 0
        )
    }

    private static func formatModelName(_ id: String) -> String {
        // "claude-opus-4-6" -> "claude-opus-4-6"
        // Keep as-is for clarity, matches tokscale format
        id
    }
}

struct DailyTokenEntry: Identifiable {
    let id: String
    let date: Date
    let modelId: String
    let tokens: Int

    var displayModelName: String { modelId }
}
