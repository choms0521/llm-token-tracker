import Foundation
import OSLog

private let logger = Logger(subsystem: "com.llmtokenbar", category: "UsageHistory")

@MainActor
final class UsageHistoryStore: ObservableObject {
    @Published var snapshots: [UsageSnapshot] = []

    private let storePath: String
    private let maxAge: TimeInterval = 7 * 24 * 3600
    private let now: () -> Date
    private let fileManager: FileManager

    init(
        storePath: String? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.now = now

        let resolvedStorePath: String
        if let storePath {
            resolvedStorePath = storePath
        } else {
            let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
            ).first!.appendingPathComponent("LLMTokenBar")

            try? fileManager.createDirectory(
                at: appSupport,
                withIntermediateDirectories: true
            )

            resolvedStorePath = appSupport.appendingPathComponent("usage-history.json").path
        }

        self.storePath = resolvedStorePath
        loadFromDisk()
    }

    func recordCodexLimits(_ limits: CodexRateLimits) {
        recordCodexSnapshot(
            sessionUtilization: limits.primary?.usedPercent,
            weeklyUtilization: limits.secondary?.usedPercent,
            timestamp: now()
        )
    }

    func recordCodexSnapshot(
        sessionUtilization: Double?,
        weeklyUtilization: Double?,
        timestamp: Date
    ) {
        // Avoid duplicate timestamps
        let isDuplicate = snapshots.contains { s in
            s.provider == .openai
                && abs(s.timestamp.timeIntervalSince(timestamp)) < 1
        }
        guard !isDuplicate else { return }

        let snapshot = UsageSnapshot(
            timestamp: timestamp,
            provider: .openai,
            sessionUtilization: sessionUtilization,
            weeklyUtilization: weeklyUtilization,
            modelUtilizations: [:]
        )
        snapshots.append(snapshot)
        pruneOld()
        saveToDisk()
    }

    func recordCodexSnapshots(_ codexSnapshots: [CodexSessionParser.RateLimitSnapshot]) {
        guard !codexSnapshots.isEmpty else { return }

        var changed = false
        var existingTimestampsBySecond = Dictionary(grouping: snapshots.filter { $0.provider == .openai }) { snapshot in
            Int(snapshot.timestamp.timeIntervalSince1970.rounded(.down))
        }.mapValues { snapshots in
            snapshots.map(\.timestamp)
        }

        for codexSnapshot in codexSnapshots {
            let timestamp = codexSnapshot.timestamp
            let timestampKey = Int(timestamp.timeIntervalSince1970.rounded(.down))
            let isDuplicate = ((timestampKey - 1)...(timestampKey + 1)).contains { key in
                existingTimestampsBySecond[key]?.contains { existing in
                    abs(existing.timeIntervalSince(timestamp)) < 1
                } ?? false
            }
            guard !isDuplicate else { continue }

            snapshots.append(UsageSnapshot(
                timestamp: timestamp,
                provider: .openai,
                sessionUtilization: codexSnapshot.limits.primary?.usedPercent,
                weeklyUtilization: codexSnapshot.limits.secondary?.usedPercent,
                modelUtilizations: [:]
            ))
            existingTimestampsBySecond[timestampKey, default: []].append(timestamp)
            changed = true
        }

        guard changed else { return }
        pruneOld()
        saveToDiskInBackground(snapshots)
    }

    func record(from usage: UsageData) {
        var modelUtils: [String: Double] = [:]
        for model in usage.modelUsages {
            modelUtils[model.modelName.lowercased()] = model.utilization
        }

        let snapshot = UsageSnapshot(
            timestamp: now(),
            provider: usage.provider,
            sessionUtilization: usage.sessionUsage?.utilization,
            weeklyUtilization: usage.weeklyUsage?.utilization,
            modelUtilizations: modelUtils
        )

        snapshots.append(snapshot)
        pruneOld()
        saveToDisk()
    }

    func snapshots(for range: TimeRange, provider: Provider? = nil) -> [UsageSnapshot] {
        let cutoff = now().addingTimeInterval(-range.seconds)
        return snapshots.filter { snapshot in
            snapshot.timestamp >= cutoff
                && (provider == nil || snapshot.provider == provider)
        }
    }

    func availableModels(for provider: Provider? = nil) -> [ModelMetric] {
        var seen = Set<String>()
        var result: [ModelMetric] = []

        for snapshot in snapshots {
            if let p = provider, snapshot.provider != p { continue }
            for (modelName, _) in snapshot.modelUtilizations {
                let key = "\(snapshot.provider.rawValue):\(modelName)"
                if !seen.contains(key) {
                    seen.insert(key)
                    result.append(ModelMetric(
                        provider: snapshot.provider,
                        modelName: modelName.capitalized
                    ))
                }
            }
        }

        return result.sorted { $0.displayName < $1.displayName }
    }

    private func pruneOld() {
        let cutoff = now().addingTimeInterval(-maxAge)
        snapshots = snapshots.filter { $0.timestamp >= cutoff }
    }

    private func loadFromDisk() {
        guard fileManager.fileExists(atPath: storePath) else { return }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: storePath))
        } catch {
            logger.error("히스토리 파일 읽기 실패 (\(self.storePath)): \(error.localizedDescription)")
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            snapshots = try decoder.decode([UsageSnapshot].self, from: data)
        } catch {
            logger.error("히스토리 JSON 파싱 실패: \(error.localizedDescription)")
            snapshots = []
        }
        pruneOld()
    }

    private func saveToDisk() {
        Self.write(snapshots: snapshots, to: storePath)
    }

    private func saveToDiskInBackground(_ snapshots: [UsageSnapshot]) {
        let storePath = storePath
        Task.detached(priority: .utility) {
            Self.write(snapshots: snapshots, to: storePath)
        }
    }

    private nonisolated static func write(snapshots: [UsageSnapshot], to storePath: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        let data: Data
        do {
            data = try encoder.encode(snapshots)
        } catch {
            logger.error("히스토리 인코딩 실패: \(error.localizedDescription)")
            return
        }

        do {
            try data.write(to: URL(fileURLWithPath: storePath), options: .atomic)
        } catch {
            logger.error("히스토리 저장 실패 (\(storePath)): \(error.localizedDescription)")
        }
    }
}
