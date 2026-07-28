import Foundation
import OSLog

private let logger = Logger(subsystem: "com.llmtokenbar", category: "TokenStats")

@MainActor
final class TokenStatsService: ObservableObject {
    @Published var modelSummaries: [ModelSummary] = []
    @Published var dailyTokens: [DailyTokenEntry] = []
    @Published var totalCost: Double = 0
    @Published var isLoading: Bool = false
    @Published var lastSyncedAt: Date?

    private let claudeParser: ClaudeSessionParser
    private let geminiParser: GeminiSessionParser
    private let codexParser: CodexSessionParser
    private let kimiParser: KimiSessionParser
    private var currentReloadTask: Task<Void, Never>?

    private static let cacheInterval: TimeInterval = 3600 // 1시간
    private static let defaultCachePath: String? = {
        guard let baseDir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let appSupport = baseDir.appendingPathComponent("LLMTokenBar")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("token-stats-cache.json").path
    }()
    private let cachePath: String?

    init(
        claudeParser: ClaudeSessionParser = ClaudeSessionParser(),
        geminiParser: GeminiSessionParser = GeminiSessionParser(),
        codexParser: CodexSessionParser = CodexSessionParser(),
        kimiParser: KimiSessionParser = KimiSessionParser(),
        cachePath: String? = defaultCachePath
    ) {
        self.claudeParser = claudeParser
        self.geminiParser = geminiParser
        self.codexParser = codexParser
        self.kimiParser = kimiParser
        self.cachePath = cachePath
        if cachePath != nil {
            loadCache()
        }
    }

    /// 캐시가 유효하면 스킵, 만료되었으면 파싱
    func reload() {
        if let lastSync = lastSyncedAt,
           Date().timeIntervalSince(lastSync) < Self.cacheInterval {
            return
        }
        forceReload()
    }

    /// 캐시 무시하고 강제 파싱
    func forceReload() {
        currentReloadTask?.cancel()
        isLoading = true

        let startTime = ContinuousClock.now

        currentReloadTask = Task.detached(priority: .utility) { [claudeParser, geminiParser, codexParser, kimiParser] in
            let result = await Self.parseInBackground(
                claude: claudeParser,
                gemini: geminiParser,
                codex: codexParser,
                kimi: kimiParser
            )

            let elapsed = ContinuousClock.now - startTime
            if elapsed < .milliseconds(500) {
                try? await Task.sleep(for: .milliseconds(500) - elapsed)
            }

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.dailyTokens = result.tokens
                self.modelSummaries = result.summaries
                self.totalCost = result.cost
                self.lastSyncedAt = Date()
                self.isLoading = false
                self.saveCache()
            }
        }
    }

    // MARK: - Cache

    private func saveCache() {
        guard let cachePath else { return }
        let cache = TokenStatsCache(
            lastSyncedAt: lastSyncedAt ?? Date(),
            dailyTokens: dailyTokens,
            modelSummaries: modelSummaries,
            totalCost: totalCost
        )
        Task.detached(priority: .utility) {
            Self.writeCache(cache, to: cachePath)
        }
    }

    private static nonisolated func writeCache(_ cache: TokenStatsCache, to path: String) {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadCache() {
        guard let cachePath,
              FileManager.default.fileExists(atPath: cachePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath)) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cache = try? decoder.decode(TokenStatsCache.self, from: data) else { return }
        dailyTokens = cache.dailyTokens
        modelSummaries = cache.modelSummaries
        totalCost = cache.totalCost
        lastSyncedAt = cache.lastSyncedAt
    }

    private static nonisolated func parseInBackground(
        claude: ClaudeSessionParser,
        gemini: GeminiSessionParser,
        codex: CodexSessionParser,
        kimi: KimiSessionParser
    ) async -> (tokens: [DailyTokenEntry], summaries: [ModelSummary], cost: Double) {
        let claudeData = claude.parse()
        let geminiData = gemini.parse()
        let codexData = codex.parse()
        let kimiData = kimi.parse()

        var tokens: [DailyTokenEntry] = []
        tokens.append(contentsOf: claudeData.dailyTokens)
        tokens.append(contentsOf: geminiData.dailyTokens)
        tokens.append(contentsOf: codexData.dailyTokens)
        tokens.append(contentsOf: kimiData.dailyTokens)
        tokens.sort { $0.date < $1.date }

        var summaries: [ModelSummary] = []
        summaries.append(contentsOf: claudeData.modelSummaries)
        summaries.append(contentsOf: geminiData.modelSummaries)
        summaries.append(contentsOf: codexData.modelSummaries)
        summaries.append(contentsOf: kimiData.modelSummaries)
        summaries.sort { $0.totalTokens > $1.totalTokens }

        let cost = summaries.reduce(0) { $0 + $1.costUSD }
        return (tokens, summaries, cost)
    }

    var allModelIds: [String] {
        Array(Set(dailyTokens.map(\.modelId))).sorted()
    }

    var recentModelUsages: [RecentModelUsage] {
        recentModelUsages(includeCache: UserDefaults.standard.bool(forKey: "includeCacheTokens"))
    }

    func recentModelUsages(includeCache: Bool) -> [RecentModelUsage] {
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let recentTokens = dailyTokens.filter { $0.date >= sevenDaysAgo }

        var tokensByModel: [String: Int] = [:]
        for entry in recentTokens {
            tokensByModel[entry.modelId, default: 0] += entry.effectiveTokens(includeCache: includeCache)
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
