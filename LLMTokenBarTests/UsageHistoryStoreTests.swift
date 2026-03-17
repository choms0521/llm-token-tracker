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

    private func sampleUsageData(timestamp: Date) -> UsageData {
        UsageData(
            provider: .claude,
            sessionUsage: UsageEntry(
                label: "세션 사용량",
                sublabel: "5시간 롤링 윈도우",
                utilization: 12.5,
                resetsAt: timestamp.addingTimeInterval(3600)
            ),
            weeklyUsage: UsageEntry(
                label: "모든 모델",
                sublabel: "주간",
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
