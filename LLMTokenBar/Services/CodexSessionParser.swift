import Foundation

// MARK: - JSONL Line Models

private struct CodexJSONLLine: Decodable {
    let timestamp: String
    let type: String
    let payload: CodexPayload
}

private struct CodexPayload: Decodable {
    // session_meta
    let id: String?

    // turn_context
    let model: String?

    // event_msg
    let type: String?
    let info: CodexTokenInfo?

    enum CodingKeys: String, CodingKey {
        case id, model, type, info
    }
}

private struct CodexTokenInfo: Decodable {
    let totalTokenUsage: CodexTokenUsage?
    let lastTokenUsage: CodexTokenUsage?

    enum CodingKeys: String, CodingKey {
        case totalTokenUsage = "total_token_usage"
        case lastTokenUsage = "last_token_usage"
    }
}

private struct CodexEventMsgPayload: Decodable {
    let type: String?
    let info: CodexTokenInfo?
    let rateLimits: CodexRateLimits?

    enum CodingKeys: String, CodingKey {
        case type, info
        case rateLimits = "rate_limits"
    }
}

private struct CodexEventMsgLine: Decodable {
    let type: String
    let payload: CodexEventMsgPayload
}

struct CodexRateLimits: Decodable {
    let primary: CodexRateLimit?
    let secondary: CodexRateLimit?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case primary, secondary
        case planType = "plan_type"
    }
}

struct CodexRateLimit: Decodable {
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }
}

private struct CodexTokenUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cachedInputTokens: Int?
    let reasoningOutputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
    }
}

// MARK: - Parser

final class CodexSessionParser {
    private let basePath: String
    private let fileManager: FileManager

    init(
        basePath: String = Constants.Codex.sessionBasePath,
        fileManager: FileManager = .default
    ) {
        self.basePath = basePath
        self.fileManager = fileManager
    }

    var isCodexCLIInstalled: Bool {
        fileManager.fileExists(atPath: Constants.Codex.configPath)
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
        var modelTotals: [String: CodexModelAccumulator] = [:]
        var seenSessions: Set<String> = []

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
            var sessionId: String?
            var currentModel: String = "unknown"

            // First pass: extract sessionId for dedup
            for lineData in lines {
                if let line = try? decoder.decode(CodexJSONLLine.self, from: Data(lineData)),
                   line.type == "session_meta",
                   let id = line.payload.id {
                    sessionId = id
                    break
                }
            }

            // Deduplicate by sessionId
            if let sessionId {
                guard seenSessions.insert(sessionId).inserted else { continue }
            }

            // Track the last total_token_usage per session (cumulative, no duplication)
            var lastTimestamp: String?
            var lastTotal: CodexTokenUsage?

            for lineData in lines {
                guard let line = try? decoder.decode(CodexJSONLLine.self, from: Data(lineData)) else {
                    continue
                }

                switch line.type {
                case "turn_context":
                    if let model = line.payload.model {
                        currentModel = model
                    }

                case "event_msg":
                    guard line.payload.type == "token_count",
                          let total = line.payload.info?.totalTokenUsage else {
                        continue
                    }
                    lastTimestamp = line.timestamp
                    lastTotal = total

                default:
                    break
                }
            }

            // Use the final cumulative total for the entire session
            guard let usage = lastTotal, let timestamp = lastTimestamp else { continue }

            let input = usage.inputTokens ?? 0
            let output = usage.outputTokens ?? 0
            let cached = usage.cachedInputTokens ?? 0
            let newInput = input - cached
            let effectiveTokens = newInput + output
            guard effectiveTokens > 0 else { continue }

            let dateKey: String
            if let date = isoFormatter.date(from: timestamp) {
                dateKey = dateFormatter.string(from: date)
            } else if let date = fallbackISOFormatter.date(from: timestamp) {
                dateKey = dateFormatter.string(from: date)
            } else {
                continue
            }

            dailyMap[dateKey, default: [:]][currentModel, default: 0] += effectiveTokens

            var acc = modelTotals[currentModel] ?? CodexModelAccumulator()
            acc.inputTokens += newInput
            acc.outputTokens += output
            acc.cachedTokens += cached
            acc.reasoningTokens += usage.reasoningOutputTokens ?? 0
            modelTotals[currentModel] = acc
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
                cacheRead: acc.cachedTokens,
                cacheWrite: acc.reasoningTokens,
                costUSD: 0
            )
        }.sorted { $0.totalTokens > $1.totalTokens }

        return (dailyTokens, modelSummaries)
    }

    func latestRateLimits() -> CodexRateLimits? {
        allRateLimitSnapshots().last?.limits
    }

    struct RateLimitSnapshot {
        let timestamp: Date
        let limits: CodexRateLimits
    }

    func allRateLimitSnapshots() -> [RateLimitSnapshot] {
        let files = findSessionFiles()
        let decoder = JSONDecoder()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        var snapshots: [RateLimitSnapshot] = []

        for filePath in files {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
                continue
            }

            let lines = data.split(separator: UInt8(ascii: "\n"))
            for lineData in lines {
                guard let eventLine = try? decoder.decode(CodexEventMsgLine.self, from: Data(lineData)),
                      eventLine.type == "event_msg",
                      eventLine.payload.type == "token_count",
                      let limits = eventLine.payload.rateLimits,
                      limits.primary != nil else {
                    continue
                }

                // Parse timestamp from the line
                if let rawLine = try? decoder.decode(CodexJSONLLine.self, from: Data(lineData)) {
                    let date: Date?
                    if let d = isoFormatter.date(from: rawLine.timestamp) {
                        date = d
                    } else {
                        date = fallbackFormatter.date(from: rawLine.timestamp)
                    }

                    if let date {
                        snapshots.append(RateLimitSnapshot(timestamp: date, limits: limits))
                    }
                }
            }
        }

        return snapshots.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Private

    private func findSessionFiles() -> [String] {
        guard fileManager.fileExists(atPath: basePath) else { return [] }

        var results: [String] = []
        guard let enumerator = fileManager.enumerator(atPath: basePath) else { return [] }

        while let relativePath = enumerator.nextObject() as? String {
            if relativePath.hasSuffix(".jsonl") && relativePath.contains("rollout-") {
                results.append("\(basePath)/\(relativePath)")
            }
        }

        return results
    }

    private func fileModificationDate(_ path: String) -> Date? {
        try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }
}

private struct CodexModelAccumulator {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cachedTokens: Int = 0
    var reasoningTokens: Int = 0
}
