import Foundation

struct GeminiSessionFile: Decodable {
    let sessionId: String?
    let startTime: String?
    let lastUpdated: String?
    let messages: [GeminiMessage]?
}

struct GeminiMessage: Decodable {
    let timestamp: String?
    let type: String?
    let tokens: GeminiTokens?
    let model: String?
}

struct GeminiTokens: Decodable {
    let input: Int?
    let output: Int?
    let cached: Int?
    let thoughts: Int?
    let tool: Int?
    let total: Int?
}

struct GeminiDailyTokens {
    let date: Date
    let tokensByModel: [String: Int]
}

final class GeminiSessionParser {
    private let basePath: String
    private let fileManager: FileManager

    init(
        basePath: String = "\(NSHomeDirectory())/.gemini/tmp",
        fileManager: FileManager = .default
    ) {
        self.basePath = basePath
        self.fileManager = fileManager
    }

    var isGeminiCLIInstalled: Bool {
        fileManager.fileExists(atPath: "\(NSHomeDirectory())/.gemini")
    }

    var sessionFileCount: Int {
        findSessionFiles().count
    }

    var lastSessionDate: Date? {
        let files = findSessionFiles()
        return files.compactMap { fileModificationDate($0) }.max()
    }

    func parse() -> (dailyTokens: [DailyTokenEntry], modelSummaries: [ModelSummary]) {
        let files = findSessionFiles()
        var dailyMap: [String: [String: Int]] = [:] // date -> modelId -> tokens
        var modelTotals: [String: ModelTokenAccumulator] = [:]
        var seenSessions: Set<String> = []

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for filePath in files {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
                  let session = try? JSONDecoder().decode(GeminiSessionFile.self, from: data),
                  let messages = session.messages else {
                continue
            }

            // Deduplicate by sessionId
            if let sessionId = session.sessionId {
                guard seenSessions.insert(sessionId).inserted else { continue }
            }

            for message in messages where message.type == "gemini" {
                guard let tokens = message.tokens,
                      let modelName = message.model,
                      let timestamp = message.timestamp else {
                    continue
                }

                let totalTokens = (tokens.input ?? 0)
                    + (tokens.output ?? 0)

                guard totalTokens > 0 else { continue }

                let dateKey: String
                if let date = isoFormatter.date(from: timestamp) {
                    dateKey = dateFormatter.string(from: date)
                } else {
                    let fallbackFormatter = ISO8601DateFormatter()
                    fallbackFormatter.formatOptions = [.withInternetDateTime]
                    if let date = fallbackFormatter.date(from: timestamp) {
                        dateKey = dateFormatter.string(from: date)
                    } else {
                        continue
                    }
                }

                dailyMap[dateKey, default: [:]][modelName, default: 0] += totalTokens

                var acc = modelTotals[modelName] ?? ModelTokenAccumulator()
                acc.inputTokens += tokens.input ?? 0
                acc.outputTokens += tokens.output ?? 0
                acc.cacheRead += tokens.cached ?? 0
                acc.reasoning += tokens.thoughts ?? 0
                modelTotals[modelName] = acc
            }
        }

        let dailyTokens: [DailyTokenEntry] = dailyMap.flatMap { (dateStr, models) -> [DailyTokenEntry] in
            guard let date = dateFormatter.date(from: dateStr) else { return [] }
            return models.map { (modelId, tokens) in
                DailyTokenEntry(
                    id: "\(dateStr)-\(modelId)",
                    date: date,
                    modelId: modelId,
                    tokens: tokens
                )
            }
        }.sorted { $0.date < $1.date }

        let modelSummaries: [ModelSummary] = modelTotals.map { (modelId, acc) in
            ModelSummary(
                id: modelId,
                displayName: modelId,
                inputTokens: acc.inputTokens,
                outputTokens: acc.outputTokens,
                cacheRead: acc.cacheRead,
                cacheWrite: acc.reasoning,
                costUSD: 0
            )
        }.sorted { $0.totalTokens > $1.totalTokens }

        return (dailyTokens, modelSummaries)
    }

    // MARK: - Private

    private func findSessionFiles() -> [String] {
        guard fileManager.fileExists(atPath: basePath) else { return [] }

        var results: [String] = []
        guard let enumerator = fileManager.enumerator(atPath: basePath) else { return [] }

        while let relativePath = enumerator.nextObject() as? String {
            if relativePath.hasSuffix(".json") && relativePath.contains("/chats/") {
                results.append("\(basePath)/\(relativePath)")
            }
        }

        return results
    }

    private func fileModificationDate(_ path: String) -> Date? {
        try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }
}

private struct ModelTokenAccumulator {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheRead: Int = 0
    var reasoning: Int = 0
}
