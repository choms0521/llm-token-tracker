import XCTest
@testable import LLM_Token_Bar

final class UsageHistoryStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        super.tearDown()
    }

    @MainActor
    func testRecordStoresSnapshotAndMakesModelAvailable() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let storeURL = temporaryDirectory.appendingPathComponent("usage-history.json")
        let store = UsageHistoryStore(storePath: storeURL.path, now: { now })

        store.record(from: sampleUsageData(timestamp: now))

        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(store.snapshots.first?.sessionUtilization, 12.5)
        XCTAssertEqual(store.availableModels(for: .claude).map(\.modelName), ["Opus"])
    }

    @MainActor
    func testSnapshotsFiltersByRangeAndProvider() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let oldSnapshot = UsageSnapshot(
            timestamp: now.addingTimeInterval(-(TimeRange.oneHour.seconds + 5)),
            provider: .claude,
            sessionUtilization: 10,
            weeklyUtilization: 20
        )
        let recentClaude = UsageSnapshot(
            timestamp: now.addingTimeInterval(-300),
            provider: .claude,
            sessionUtilization: 30,
            weeklyUtilization: 40
        )
        let recentOpenAI = UsageSnapshot(
            timestamp: now.addingTimeInterval(-100),
            provider: .openai,
            sessionUtilization: 50,
            weeklyUtilization: 60
        )

        let storeURL = temporaryDirectory.appendingPathComponent("usage-history.json")
        try writeSnapshots([oldSnapshot, recentClaude, recentOpenAI], to: storeURL)

        let store = UsageHistoryStore(storePath: storeURL.path, now: { now })

        XCTAssertEqual(store.snapshots(for: .oneHour).count, 2)
        XCTAssertEqual(store.snapshots(for: .oneHour, provider: .claude).count, 1)
        XCTAssertEqual(store.snapshots(for: .oneHour, provider: .openai).count, 1)
    }

    @MainActor
    func testInitializationPrunesSnapshotsOlderThanSevenDays() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expiredSnapshot = UsageSnapshot(
            timestamp: now.addingTimeInterval(-(8 * 24 * 3600)),
            provider: .claude,
            sessionUtilization: 10,
            weeklyUtilization: 20
        )
        let recentSnapshot = UsageSnapshot(
            timestamp: now.addingTimeInterval(-60),
            provider: .claude,
            sessionUtilization: 30,
            weeklyUtilization: 40
        )

        let storeURL = temporaryDirectory.appendingPathComponent("usage-history.json")
        try writeSnapshots([expiredSnapshot, recentSnapshot], to: storeURL)

        let store = UsageHistoryStore(storePath: storeURL.path, now: { now })

        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(store.snapshots.first?.timestamp, recentSnapshot.timestamp)
    }

    @MainActor
    func testRecordCodexSnapshotsRebuildsOpenAIHistoryWithWindowClassification() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let misclassified = UsageSnapshot(
            timestamp: now.addingTimeInterval(-600),
            provider: .openai,
            sessionUtilization: 16.0,
            weeklyUtilization: nil
        )
        let claudeSnapshot = UsageSnapshot(
            timestamp: now.addingTimeInterval(-500),
            provider: .claude,
            sessionUtilization: 30,
            weeklyUtilization: 40
        )

        let storeURL = temporaryDirectory.appendingPathComponent("usage-history.json")
        try writeSnapshots([misclassified, claudeSnapshot], to: storeURL)
        let store = UsageHistoryStore(storePath: storeURL.path, now: { now })

        let weeklyOnlyLimits = CodexRateLimits(
            primary: CodexRateLimit(usedPercent: 16.0, windowMinutes: 10080, resetsAt: nil),
            secondary: nil,
            planType: "plus"
        )
        store.recordCodexSnapshots([
            CodexSessionParser.RateLimitSnapshot(
                timestamp: now.addingTimeInterval(-600),
                limits: weeklyOnlyLimits
            )
        ])

        let openAISnapshots = store.snapshots.filter { $0.provider == .openai }
        XCTAssertEqual(openAISnapshots.count, 1)
        XCTAssertNil(openAISnapshots.first?.sessionUtilization)
        XCTAssertEqual(openAISnapshots.first?.weeklyUtilization, 16.0)
        XCTAssertEqual(store.snapshots.filter { $0.provider == .claude }.count, 1)
    }

    private func sampleUsageData(timestamp: Date) -> UsageData {
        UsageData(
            provider: .claude,
            sessionUsage: UsageEntry(
                label: "Session Usage",
                sublabel: "5-hour rolling window",
                utilization: 12.5,
                resetsAt: timestamp.addingTimeInterval(3600)
            ),
            weeklyUsage: UsageEntry(
                label: "All Models",
                sublabel: "Weekly",
                utilization: 52.0,
                resetsAt: timestamp.addingTimeInterval(7200)
            ),
            modelUsages: [
                ModelUsage(id: "opus", modelName: "Opus", utilization: 33.0, resetsAt: timestamp.addingTimeInterval(7200))
            ],
            lastUpdated: timestamp
        )
    }

    private func writeSnapshots(_ snapshots: [UsageSnapshot], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshots)
        try data.write(to: url)
    }
}
