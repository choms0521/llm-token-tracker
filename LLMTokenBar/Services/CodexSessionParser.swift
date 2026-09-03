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

/// 한도 스캔 전용 라인 모델. token_count(rate_limits)와 task_complete(error)만 읽는다.
private struct CodexRateLimitScanLine: Decodable {
    let timestamp: String
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String?
        let rateLimits: CodexRateLimits?
        let error: ErrorInfo?

        enum CodingKeys: String, CodingKey {
            case type, error
            case rateLimits = "rate_limits"
        }
    }

    /// error 필드는 객체(`{"message": ...}`)와 문자열 두 형태가 모두 관찰되므로 둘 다 받는다.
    struct ErrorInfo: Decodable {
        let message: String?

        enum CodingKeys: String, CodingKey {
            case message
        }

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let text = try? single.decode(String.self) {
                message = text
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = try container.decodeIfPresent(String.self, forKey: .message)
        }
    }
}

struct CodexCredits: Decodable, Sendable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: String?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited, balance
    }
}

struct CodexRateLimits: Decodable, Sendable {
    let primary: CodexRateLimit?
    let secondary: CodexRateLimit?
    let planType: String?
    let credits: CodexCredits?
    let rateLimitReachedType: String?

    init(
        primary: CodexRateLimit? = nil,
        secondary: CodexRateLimit? = nil,
        planType: String? = nil,
        credits: CodexCredits? = nil,
        rateLimitReachedType: String? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.credits = credits
        self.rateLimitReachedType = rateLimitReachedType
    }

    enum CodingKeys: String, CodingKey {
        case primary, secondary, credits
        case planType = "plan_type"
        case rateLimitReachedType = "rate_limit_reached_type"
    }
}

struct CodexRateLimit: Decodable, Sendable {
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }
}

extension CodexRateLimits {
    // Codex CLI emits either the legacy layout (primary = 5h session,
    // secondary = weekly) or the newer layout (primary = weekly, secondary = null),
    // so limits are classified by window length instead of position.
    private static let sessionWindowMaxMinutes = 1440

    var sessionLimit: CodexRateLimit? {
        if let matched = firstLimit(where: { $0 <= Self.sessionWindowMaxMinutes }) {
            return matched
        }
        // Snapshots without window info follow the legacy positional layout
        if let primary, primary.windowMinutes == nil {
            return primary
        }
        return nil
    }

    var weeklyLimit: CodexRateLimit? {
        if let matched = firstLimit(where: { $0 > Self.sessionWindowMaxMinutes }) {
            return matched
        }
        // Snapshots without window info follow the legacy positional layout
        if let secondary, secondary.windowMinutes == nil {
            return secondary
        }
        return nil
    }

    private func firstLimit(where matchesWindow: (Int) -> Bool) -> CodexRateLimit? {
        [primary, secondary].compactMap { $0 }.first { limit in
            guard let minutes = limit.windowMinutes else { return false }
            return matchesWindow(minutes)
        }
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

protocol CodexRateLimitReporting: Sendable {
    func rateLimitReport() -> CodexSessionParser.RateLimitReport
}

final class CodexSessionParser: CodexRateLimitReporting, @unchecked Sendable {
    private let basePath: String
    private let fileManager: FileManager
    private let now: () -> Date

    // 한도 스캔 결과 캐시. (수정 시각, 크기)가 같은 파일은 다시 읽지 않는다.
    private let cacheLock = NSLock()
    private var rateLimitCache: [String: RateLimitFileCacheEntry] = [:]
    private var rateLimitParsedFiles = 0

    init(
        basePath: String = Constants.Codex.sessionBasePath,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.basePath = basePath
        self.fileManager = fileManager
        self.now = now
    }

    /// 지금까지 한도 스캔에서 실제로 읽은 파일 수. 캐시 동작 검증용.
    var parsedRateLimitFileCount: Int {
        cacheLock.withLock { rateLimitParsedFiles }
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
        var dailyMap: [String: [String: (withCache: Int, noCache: Int)]] = [:]
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
            let tokensWithCache = input + output
            let tokensNoCache = (input - cached) + output
            guard tokensWithCache > 0 else { continue }

            let dateKey: String
            if let date = isoFormatter.date(from: timestamp) {
                dateKey = dateFormatter.string(from: date)
            } else if let date = fallbackISOFormatter.date(from: timestamp) {
                dateKey = dateFormatter.string(from: date)
            } else {
                continue
            }

            var entry = dailyMap[dateKey, default: [:]][currentModel, default: (0, 0)]
            entry.withCache += tokensWithCache
            entry.noCache += max(0, tokensNoCache)
            dailyMap[dateKey, default: [:]][currentModel] = entry

            var acc = modelTotals[currentModel] ?? CodexModelAccumulator()
            acc.inputTokens += input
            acc.outputTokens += output
            acc.cachedTokens += cached
            acc.reasoningTokens += usage.reasoningOutputTokens ?? 0
            modelTotals[currentModel] = acc
        }

        let dailyTokens: [DailyTokenEntry] = dailyMap.flatMap { (dateStr, models) -> [DailyTokenEntry] in
            guard let date = dateFormatter.date(from: dateStr) else { return [] }
            return models.map { (modelId, pair) in
                DailyTokenEntry(
                    id: "\(dateStr)-\(modelId)",
                    date: date,
                    modelId: modelId,
                    tokens: pair.withCache,
                    tokensNoCache: pair.noCache
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

    // MARK: - Rate Limits

    struct RateLimitSnapshot: Sendable {
        let timestamp: Date
        let limits: CodexRateLimits
    }

    struct RateLimitReport: Sendable {
        /// primary가 있는 스냅샷만, 시각 오름차순.
        let snapshots: [RateLimitSnapshot]
        let latest: RateLimitSnapshot?
        /// 최신 스냅샷 이후에 한도 도달 신호가 있고 세션 창이 아직 리셋되지 않았을 때만 채워진다.
        let limitReachedAt: Date?
    }

    func latestRateLimits() -> CodexRateLimits? {
        rateLimitReport().latest?.limits
    }

    func allRateLimitSnapshots() -> [RateLimitSnapshot] {
        rateLimitReport().snapshots
    }

    func rateLimitReport() -> RateLimitReport {
        let cutoff = now().addingTimeInterval(-Constants.Codex.rateLimitLookback)
        let candidates = rateLimitCandidates(modifiedAfter: cutoff)

        cacheLock.lock()
        defer { cacheLock.unlock() }

        let entries = candidates.map { cachedOrParsedEntry(for: $0) }
        rateLimitCache = Dictionary(
            uniqueKeysWithValues: zip(candidates.map(\.path), entries)
        )

        let snapshots = entries.flatMap(\.snapshots).sorted { $0.timestamp < $1.timestamp }
        let latest = snapshots.last
        return RateLimitReport(
            snapshots: snapshots,
            latest: latest,
            limitReachedAt: activeLimitMarker(entries.flatMap(\.limitMarkers), latest: latest)
        )
    }

    // MARK: - Rate Limit Scanning (private)

    private struct RateLimitFileCandidate {
        let path: String
        let modificationDate: Date
        let fileSize: Int
    }

    private struct RateLimitFileCacheEntry {
        let modificationDate: Date
        let fileSize: Int
        let snapshots: [RateLimitSnapshot]
        let limitMarkers: [Date]
    }

    private static let rateLimitsNeedle = Data("\"rate_limits\"".utf8)
    private static let taskCompleteNeedle = Data("\"task_complete\"".utf8)

    private func rateLimitCandidates(modifiedAfter cutoff: Date) -> [RateLimitFileCandidate] {
        findSessionFiles().compactMap { path in
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let modificationDate = attributes[.modificationDate] as? Date,
                  modificationDate >= cutoff else {
                return nil
            }
            let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
            return RateLimitFileCandidate(path: path, modificationDate: modificationDate, fileSize: fileSize)
        }
    }

    /// cacheLock을 잡은 상태에서만 호출한다.
    private func cachedOrParsedEntry(for candidate: RateLimitFileCandidate) -> RateLimitFileCacheEntry {
        if let cached = rateLimitCache[candidate.path],
           cached.modificationDate == candidate.modificationDate,
           cached.fileSize == candidate.fileSize {
            return cached
        }
        rateLimitParsedFiles += 1
        return parseRateLimitFile(candidate)
    }

    private func parseRateLimitFile(_ candidate: RateLimitFileCandidate) -> RateLimitFileCacheEntry {
        var snapshots: [RateLimitSnapshot] = []
        var markers: [Date] = []

        if let data = try? Data(contentsOf: URL(fileURLWithPath: candidate.path), options: .mappedIfSafe) {
            let decoder = JSONDecoder()
            let timestamps = TimestampParser()
            for lineData in data.split(separator: UInt8(ascii: "\n")) {
                guard Self.lineMayContainRateLimitEvent(lineData),
                      let line = try? decoder.decode(CodexRateLimitScanLine.self, from: Data(lineData)),
                      line.type == "event_msg",
                      let timestamp = timestamps.date(from: line.timestamp) else {
                    continue
                }
                Self.collect(line.payload, at: timestamp, snapshots: &snapshots, markers: &markers)
            }
        }

        return RateLimitFileCacheEntry(
            modificationDate: candidate.modificationDate,
            fileSize: candidate.fileSize,
            snapshots: snapshots,
            limitMarkers: markers
        )
    }

    /// JSON 디코드 전에 이벤트 종류 바이트 검색으로 걸러 낸다. 세션 로그 대부분은 대화 내용이라 여기서 탈락한다.
    private static func lineMayContainRateLimitEvent(_ lineData: Data) -> Bool {
        lineData.range(of: rateLimitsNeedle) != nil || lineData.range(of: taskCompleteNeedle) != nil
    }

    private static func collect(
        _ payload: CodexRateLimitScanLine.Payload,
        at timestamp: Date,
        snapshots: inout [RateLimitSnapshot],
        markers: inout [Date]
    ) {
        switch payload.type {
        case "token_count":
            guard let limits = payload.rateLimits else { return }
            if limits.primary != nil {
                snapshots.append(RateLimitSnapshot(timestamp: timestamp, limits: limits))
            }
            if limits.rateLimitReachedType != nil {
                markers.append(timestamp)
            }

        case "task_complete":
            let message = payload.error?.message ?? ""
            if message.range(of: "usage limit", options: .caseInsensitive) != nil {
                markers.append(timestamp)
            }

        default:
            break
        }
    }

    /// 최신 스냅샷보다 늦은 한도 도달 신호 중 가장 최근 것.
    /// 신호가 어느 창을 가리키는지는 알 수 없으므로, 세션 창이 있으면 세션 창을 기준으로 삼고
    /// 주간 창만 있는 레이아웃에서는 주간 창을 기준으로 삼아 그 창이 리셋됐으면 낡은 신호로 버린다.
    /// (세션이 리셋된 뒤에도 주간 창을 근거로 신호를 살려 두면 주간 한도가 소진된 것처럼 보이기 때문이다.)
    private func activeLimitMarker(_ markers: [Date], latest: RateLimitSnapshot?) -> Date? {
        guard let latest,
              let governing = latest.limits.sessionLimit ?? latest.limits.weeklyLimit,
              isUnexpired(governing) else {
            return nil
        }
        return markers.filter { $0 >= latest.timestamp }.max()
    }

    /// resets_at이 없으면 아직 리셋되지 않은 것으로 본다.
    private func isUnexpired(_ limit: CodexRateLimit) -> Bool {
        guard let resetsAt = limit.resetsAt else { return true }
        return Date(timeIntervalSince1970: TimeInterval(resetsAt)) > now()
    }

    /// 파일 하나를 읽는 동안 재사용하는 타임스탬프 파서. 소수점 초가 있는 형식과 없는 형식을 모두 받는다.
    private struct TimestampParser {
        private let fractional: ISO8601DateFormatter
        private let plain: ISO8601DateFormatter

        init() {
            fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
        }

        func date(from raw: String) -> Date? {
            fractional.date(from: raw) ?? plain.date(from: raw)
        }
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
