import XCTest
@testable import LLM_Token_Bar

/// 결과를 바꿔 끼울 수 있고, 게이트를 닫아 두면 fetch가 완료되지 않는 가짜 클라이언트.
private final class FakeAntigravityClient: AntigravityQuotaFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<AntigravityQuotaFetchResult, AntigravityQuotaError>
    private var gateOpen = true
    private var storedFetchCount = 0

    init(result: Result<AntigravityQuotaFetchResult, AntigravityQuotaError>) {
        self.result = result
    }

    var fetchCount: Int {
        lock.withLock { storedFetchCount }
    }

    func set(_ newResult: Result<AntigravityQuotaFetchResult, AntigravityQuotaError>) {
        lock.withLock { result = newResult }
    }

    func closeGate() {
        lock.withLock { gateOpen = false }
    }

    func openGate() {
        lock.withLock { gateOpen = true }
    }

    func fetchQuota() async throws -> AntigravityQuotaFetchResult {
        recordFetch()
        while !isGateOpen {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return try currentResult().get()
    }

    private func recordFetch() {
        lock.withLock { storedFetchCount += 1 }
    }

    private func currentResult() -> Result<AntigravityQuotaFetchResult, AntigravityQuotaError> {
        lock.withLock { result }
    }

    private var isGateOpen: Bool {
        lock.withLock { gateOpen }
    }
}

private struct WaitTimeout: Error {}

@MainActor
final class AntigravityQuotaStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_400_000)

    func testSuccessfulRefreshPublishesSummaryPlanAndConnectedStatus() async throws {
        let client = FakeAntigravityClient(result: .success(sampleResult(planName: "Pro")))
        let store = AntigravityQuotaStore(client: client)

        store.refresh()
        try await waitUntil { !store.isRefreshing }

        XCTAssertEqual(store.status, .connected)
        XCTAssertEqual(store.planName, "Pro")
        XCTAssertEqual(store.lastFetchedAt, now)
        XCTAssertEqual(store.summary?.groups.count, 2)
        XCTAssertTrue(store.isConnected)
    }

    func testRefreshWhileInFlightIsCoalesced() async throws {
        let client = FakeAntigravityClient(result: .success(sampleResult(planName: nil)))
        client.closeGate()
        let store = AntigravityQuotaStore(client: client)

        store.refresh()
        store.refresh()
        store.refresh()
        try await waitUntil { client.fetchCount >= 1 }
        XCTAssertEqual(client.fetchCount, 1)
        XCTAssertTrue(store.isRefreshing)

        client.openGate()
        try await waitUntil { !store.isRefreshing }
        XCTAssertEqual(client.fetchCount, 1)

        store.refresh()
        try await waitUntil { !store.isRefreshing }
        XCTAssertEqual(client.fetchCount, 2)
    }

    func testServerNotRunningKeepsLastSummaryAndMarksNotRunning() async throws {
        let client = FakeAntigravityClient(result: .success(sampleResult(planName: "Pro")))
        let store = AntigravityQuotaStore(client: client)
        store.refresh()
        try await waitUntil { !store.isRefreshing }

        client.set(.failure(.serverNotRunning))
        store.refresh()
        try await waitUntil { !store.isRefreshing }

        XCTAssertEqual(store.status, .notRunning)
        XCTAssertFalse(store.isConnected)
        XCTAssertEqual(store.summary?.groups.count, 2)
        XCTAssertEqual(store.planName, "Pro")
    }

    func testErrorKeepsSummaryAndExposesMessage() async throws {
        let client = FakeAntigravityClient(result: .success(sampleResult(planName: nil)))
        let store = AntigravityQuotaStore(client: client)
        store.refresh()
        try await waitUntil { !store.isRefreshing }

        client.set(.failure(.badResponse("unimplemented")))
        store.refresh()
        try await waitUntil { !store.isRefreshing }

        XCTAssertEqual(store.status, .error(.badResponse("unimplemented")))
        XCTAssertNotNil(store.summary)
        XCTAssertTrue(store.isStale)
    }

    func testIsStaleOnlyWhenCachedSummaryOutlivesConnection() async throws {
        let client = FakeAntigravityClient(result: .failure(.serverNotRunning))
        let store = AntigravityQuotaStore(client: client)
        XCTAssertFalse(store.isStale)

        store.refresh()
        try await waitUntil { !store.isRefreshing }
        XCTAssertFalse(store.isStale, "no summary yet, nothing to be stale")

        client.set(.success(sampleResult(planName: nil)))
        store.refresh()
        try await waitUntil { !store.isRefreshing }
        XCTAssertFalse(store.isStale)

        client.set(.failure(.serverNotRunning))
        store.refresh()
        try await waitUntil { !store.isRefreshing }
        XCTAssertTrue(store.isStale)
        XCTAssertEqual(store.status, .notRunning)
    }

    func testBucketHelpersResolveWindowsOfGeminiGroup() async throws {
        let client = FakeAntigravityClient(result: .success(sampleResult(planName: nil)))
        let store = AntigravityQuotaStore(client: client)
        store.refresh()
        try await waitUntil { !store.isRefreshing }

        let gemini = try XCTUnwrap(store.geminiGroup)
        XCTAssertEqual(store.sessionBucket(in: gemini)?.id, "gemini-5h")
        XCTAssertEqual(store.weeklyBucket(in: gemini)?.id, "gemini-weekly")
        XCTAssertEqual(store.otherGroups.map(\.displayName), ["Claude and GPT models"])
    }

    // MARK: - Helpers

    private func sampleResult(planName: String?) -> AntigravityQuotaFetchResult {
        let reset = Date(timeIntervalSince1970: 1_788_519_701)
        let gemini = AntigravityQuotaGroup(displayName: "Gemini Models", buckets: [
            AntigravityQuotaBucket(id: "gemini-weekly", displayName: "Weekly", window: .weekly, usedPercent: 3, resetsAt: reset),
            AntigravityQuotaBucket(id: "gemini-5h", displayName: "5h", window: .fiveHour, usedPercent: 12, resetsAt: reset),
        ])
        let others = AntigravityQuotaGroup(displayName: "Claude and GPT models", buckets: [
            AntigravityQuotaBucket(id: "3p-5h", displayName: "5h", window: .fiveHour, usedPercent: 0, resetsAt: reset),
        ])
        return AntigravityQuotaFetchResult(
            summary: AntigravityQuotaSummary(groups: [gemini, others], fetchedAt: now),
            planName: planName
        )
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met within \(timeout)s")
                throw WaitTimeout()
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }


    func testInitialStatusIsCheckingUntilFirstFetchResolves() {
        let client = FakeAntigravityClient(result: .failure(.serverNotRunning))
        let store = AntigravityQuotaStore(client: client)

        XCTAssertEqual(store.status, .checking)
        XCTAssertFalse(store.isConnected)
        XCTAssertFalse(store.isStale)
    }
}
