import Foundation

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
        guard fileManager.fileExists(atPath: storePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: storePath)) else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        snapshots = (try? decoder.decode([UsageSnapshot].self, from: data)) ?? []
        pruneOld()
    }

    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        guard let data = try? encoder.encode(snapshots) else { return }
        try? data.write(to: URL(fileURLWithPath: storePath), options: .atomic)
    }
}
