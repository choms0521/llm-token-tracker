import Foundation

// MARK: - Wire Log Line Models

/// Kimi Code CLI가 `sessions/<workdir>/<session>/agents/<agent>/wire.jsonl`에 남기는 한 줄.
/// 토큰 사용량은 `usage.record` 타입에만 담긴다.
private struct KimiWireLine: Decodable {
    let type: String
    let model: String?
    let usage: KimiWireUsage?
    let usageScope: String?
    let time: Double?
}

private struct KimiWireUsage: Decodable {
    let inputOther: Int?
    let output: Int?
    let inputCacheRead: Int?
    let inputCacheCreation: Int?

    var cachedTokens: Int {
        (inputCacheRead ?? 0) + (inputCacheCreation ?? 0)
    }

    var uncachedTokens: Int {
        (inputOther ?? 0) + (output ?? 0)
    }

    var totalTokens: Int {
        uncachedTokens + cachedTokens
    }
}

// MARK: - Parser

final class KimiSessionParser: @unchecked Sendable {
    /// 턴 단위로 기록되는 사용량 스코프. 누적 스코프가 추가되더라도 중복 합산하지 않도록 이 값만 받는다.
    private static let turnScope = "turn"

    private let basePath: String
    private let fileManager: FileManager

    init(
        basePath: String = Constants.Kimi.sessionBasePath,
        fileManager: FileManager = .default
    ) {
        self.basePath = basePath
        self.fileManager = fileManager
    }

    var isKimiCLIInstalled: Bool {
        fileManager.fileExists(atPath: Constants.Kimi.configPath)
    }

    var sessionFileCount: Int {
        findWireFiles().count
    }

    var lastSessionDate: Date? {
        findWireFiles().compactMap { fileModificationDate($0) }.max()
    }

    func parse() -> (dailyTokens: [DailyTokenEntry], modelSummaries: [ModelSummary]) {
        let files = findWireFiles()
        var dailyMap: [String: [String: (withCache: Int, noCache: Int)]] = [:]
        var modelTotals: [String: KimiModelAccumulator] = [:]

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let decoder = JSONDecoder()

        for filePath in files {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
                continue
            }

            for lineData in data.split(separator: UInt8(ascii: "\n")) {
                guard let line = try? decoder.decode(KimiWireLine.self, from: Data(lineData)),
                      line.type == "usage.record",
                      line.usageScope == nil || line.usageScope == Self.turnScope,
                      let usage = line.usage,
                      let timeMillis = line.time else {
                    continue
                }

                let totalTokens = usage.totalTokens
                guard totalTokens > 0 else { continue }

                let modelId = Self.normalizeModelId(line.model)
                let date = Date(timeIntervalSince1970: timeMillis / 1000)
                let dateKey = dateFormatter.string(from: date)

                var entry = dailyMap[dateKey, default: [:]][modelId, default: (0, 0)]
                entry.withCache += totalTokens
                entry.noCache += usage.uncachedTokens
                dailyMap[dateKey, default: [:]][modelId] = entry

                var acc = modelTotals[modelId] ?? KimiModelAccumulator()
                acc.inputTokens += usage.inputOther ?? 0
                acc.outputTokens += usage.output ?? 0
                acc.cacheRead += usage.inputCacheRead ?? 0
                acc.cacheWrite += usage.inputCacheCreation ?? 0
                modelTotals[modelId] = acc
            }
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
                cacheRead: acc.cacheRead,
                cacheWrite: acc.cacheWrite,
                costUSD: 0
            )
        }.sorted { $0.totalTokens > $1.totalTokens }

        return (dailyTokens, modelSummaries)
    }

    // MARK: - Private

    /// `kimi-code/k3` → `kimi-k3`, `kimi-code/kimi-for-coding` → `kimi-for-coding`.
    /// provider 필터가 모델 ID에 "kimi"가 포함되는지로 판별하므로 접두사를 보장한다.
    static func normalizeModelId(_ raw: String?) -> String {
        let fallback = "kimi-unknown"
        guard let raw else { return fallback }

        // 빈 조각을 남겨야 "kimi-code/"처럼 모델명이 비어 있는 입력을 폴백으로 넘길 수 있다.
        let name = raw.split(separator: "/", omittingEmptySubsequences: false).last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return fallback }

        return name.lowercased().hasPrefix("kimi") ? name : "kimi-\(name)"
    }

    private func findWireFiles() -> [String] {
        guard fileManager.fileExists(atPath: basePath) else { return [] }

        var results: [String] = []
        guard let enumerator = fileManager.enumerator(atPath: basePath) else { return [] }

        while let relativePath = enumerator.nextObject() as? String {
            // 서브 에이전트도 각자의 wire.jsonl을 남기며, 모두 실제 사용량이므로 함께 집계한다.
            if relativePath.hasSuffix("wire.jsonl") {
                results.append("\(basePath)/\(relativePath)")
            }
        }

        return results
    }

    private func fileModificationDate(_ path: String) -> Date? {
        try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }
}

private struct KimiModelAccumulator {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
}
