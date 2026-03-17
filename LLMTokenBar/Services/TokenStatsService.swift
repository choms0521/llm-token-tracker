import Foundation

@MainActor
final class TokenStatsService: ObservableObject {
    @Published var modelSummaries: [ModelSummary] = []
    @Published var dailyTokens: [DailyTokenEntry] = []
    @Published var totalCost: Double = 0

    private let statsPath: String
    private let fileManager: FileManager

    init(
        statsPath: String = "\(NSHomeDirectory())/.claude/stats-cache.json",
        fileManager: FileManager = .default
    ) {
        self.statsPath = statsPath
        self.fileManager = fileManager
    }

    func reload() {
        modelSummaries = []
        dailyTokens = []
        totalCost = 0

        guard fileManager.fileExists(atPath: statsPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: statsPath)) else {
            return
        }

        guard let stats = try? JSONDecoder().decode(StatsCache.self, from: data) else {
            return
        }

        // Model summaries
        if let modelUsage = stats.modelUsage {
            modelSummaries = modelUsage
                .map { ModelSummary.from(modelId: $0.key, usage: $0.value) }
                .sorted { $0.totalTokens > $1.totalTokens }

            totalCost = modelSummaries.reduce(0) { $0 + $1.costUSD }
        }

        // Daily tokens for chart
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        if let daily = stats.dailyModelTokens {
            var entries: [DailyTokenEntry] = []
            for day in daily {
                guard let date = dateFormatter.date(from: day.date) else { continue }
                for (modelId, tokens) in day.tokensByModel {
                    entries.append(DailyTokenEntry(
                        id: "\(day.date)-\(modelId)",
                        date: date,
                        modelId: modelId,
                        tokens: tokens
                    ))
                }
            }
            dailyTokens = entries.sorted { $0.date < $1.date }
        }
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
        modelId
            .replacingOccurrences(of: "claude-", with: "")
            .components(separatedBy: "-")
            .prefix(2)
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
