import Foundation
import OSLog

private let logger = Logger(subsystem: "com.llmtokenbar", category: "ClaudeSessionParser")

// MARK: - JSONL Line Models

private struct ClaudeJSONLLine: Decodable {
    let timestamp: String?
    let sessionId: String?
    let message: ClaudeMessagePayload?
}

private struct ClaudeMessagePayload: Decodable {
    let id: String?
    let model: String?
    let role: String?
    let usage: ClaudeTokenUsage?
}

private struct ClaudeTokenUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }
}

// MARK: - Parser

final class ClaudeSessionParser {
    private let basePath: String
    private let fileManager: FileManager

    init(
        basePath: String = "\(NSHomeDirectory())/.claude/projects",
        fileManager: FileManager = .default
    ) {
        self.basePath = basePath
        self.fileManager = fileManager
    }

    var isClaudeCLIInstalled: Bool {
        fileManager.fileExists(atPath: "\(NSHomeDirectory())/.claude")
    }

    var sessionFileCount: Int {
        findSessionFiles().count
    }

    var lastSessionDate: Date? {
        findSessionFiles().compactMap { fileModificationDate($0) }.max()
    }

    func parse() -> (dailyTokens: [DailyTokenEntry], modelSummaries: [ModelSummary]) {
        let files = findSessionFiles()
        var dailyMap: [String: [String: Int]] = [:]
        var modelTotals: [String: ClaudeModelAccumulator] = [:]

        // Collect last usage per message ID (streaming writes multiple entries per message)
        var messageSnapshots: [String: MessageSnapshot] = [:]

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackISOFormatter = ISO8601DateFormatter()
        fallbackISOFormatter.formatOptions = [.withInternetDateTime]

        let decoder = JSONDecoder()

        for filePath in files {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
                continue
            }

            let lines = data.split(separator: UInt8(ascii: "\n"))

            for lineData in lines {
                guard let line = try? decoder.decode(ClaudeJSONLLine.self, from: Data(lineData)),
                      let message = line.message,
                      message.role == "assistant",
                      let usage = message.usage,
                      let model = message.model,
                      let messageId = message.id,
                      let timestamp = line.timestamp else {
                    continue
                }

                let input = usage.inputTokens ?? 0
                let output = usage.outputTokens ?? 0
                let cacheRead = usage.cacheReadInputTokens ?? 0
                let cacheWrite = usage.cacheCreationInputTokens ?? 0

                guard input + output + cacheRead + cacheWrite > 0 else { continue }

                // Keep first entry only: it has the actual API-reported usage
                // Later entries accumulate tool_use outputs and inflate the count
                guard messageSnapshots[messageId] == nil else { continue }
                messageSnapshots[messageId] = MessageSnapshot(
                    model: model,
                    timestamp: timestamp,
                    input: input,
                    output: output,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite
                )
            }
        }

        // Aggregate deduplicated messages
        for (_, snapshot) in messageSnapshots {
            let dateKey: String
            if let date = isoFormatter.date(from: snapshot.timestamp) {
                dateKey = dateFormatter.string(from: date)
            } else if let date = fallbackISOFormatter.date(from: snapshot.timestamp) {
                dateKey = dateFormatter.string(from: date)
            } else {
                continue
            }

            let effectiveTokens = snapshot.input + snapshot.output
            dailyMap[dateKey, default: [:]][snapshot.model, default: 0] += effectiveTokens

            var acc = modelTotals[snapshot.model] ?? ClaudeModelAccumulator()
            acc.inputTokens += snapshot.input
            acc.outputTokens += snapshot.output
            acc.cacheRead += snapshot.cacheRead
            acc.cacheWrite += snapshot.cacheWrite
            modelTotals[snapshot.model] = acc
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
                cacheWrite: acc.cacheWrite,
                costUSD: 0
            )
        }.sorted { $0.totalTokens > $1.totalTokens }

        logger.info("Claude 세션 파싱 완료: \(files.count)개 파일, \(modelSummaries.count)개 모델")

        return (dailyTokens, modelSummaries)
    }

    // MARK: - Private

    private func findSessionFiles() -> [String] {
        guard fileManager.fileExists(atPath: basePath) else { return [] }

        var results: [String] = []
        guard let enumerator = fileManager.enumerator(atPath: basePath) else { return [] }

        while let relativePath = enumerator.nextObject() as? String {
            if relativePath.hasSuffix(".jsonl") {
                results.append("\(basePath)/\(relativePath)")
            }
        }

        return results
    }

    private func fileModificationDate(_ path: String) -> Date? {
        try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }
}

private struct MessageSnapshot {
    let model: String
    let timestamp: String
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
}

private struct ClaudeModelAccumulator {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
}
