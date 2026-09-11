import XCTest
@testable import LLM_Token_Bar

/// 고정된 리포트를 돌려주는 가짜 파서. gated이면 rateLimitReport()가 세마포어를 기다린다.
private final class FakeRateLimitReporter: CodexRateLimitReporting, @unchecked Sendable {
    let gate: DispatchSemaphore?
    private let lock = NSLock()
    private var count = 0
    private var currentReport: CodexSessionParser.RateLimitReport

    init(report: CodexSessionParser.RateLimitReport, gated: Bool = false) {
        currentReport = report
        gate = gated ? DispatchSemaphore(value: 0) : nil
    }

    var callCount: Int {
        lock.withLock { count }
    }

    func setReport(_ report: CodexSessionParser.RateLimitReport) {
        lock.withLock { currentReport = report }
    }

    func rateLimitReport() -> CodexSessionParser.RateLimitReport {
        lock.withLock { count += 1 }
        gate?.wait()
        return lock.withLock { currentReport }
    }
}

final class CodexUsageStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_416_400)          // 2026-09-03T06:20:00Z
    private let snapshotDate = Date(timeIntervalSince1970: 1_788_415_674)
    private let futureReset = 1_788_417_967
    private let pastReset = 1_788_400_000
    private let weeklyReset = 1_788_748_909

    // MARK: - Coalescing

    @MainActor
    func testRefreshWhileInFlightIsCoalescedNotCancelled() async throws {
        let reporter = FakeRateLimitReporter(
            report: sessionReport(used: 100, resetsAt: futureReset, markerOffset: 300),
            gated: true
        )
        let store = CodexUsageStore(parser: reporter, now: { [now] in now })

        store.refresh()
        store.refresh()
        try await waitUntil("first refresh started") { reporter.callCount >= 1 }

        XCTAssertTrue(store.isRefreshing)
        XCTAssertEqual(reporter.callCount, 1, "second refresh must coalesce into the in-flight one")

        reporter.gate?.signal()
        try await waitUntilIdle(store)

        XCTAssertEqual(reporter.callCount, 1)
        XCTAssertEqual(store.latestLimits?.sessionLimit?.usedPercent, 100)
        XCTAssertEqual(store.latestSnapshotAt, snapshotDate)
        XCTAssertNotNil(store.limitReachedAt)
        XCTAssertTrue(store.isLimitReached)
    }

    @MainActor
    func testRefreshRunsAgainAfterPreviousCompletes() async throws {
        let reporter = FakeRateLimitReporter(report: sessionReport(used: 100, resetsAt: futureReset), gated: true)
        let store = CodexUsageStore(parser: reporter, now: { [now] in now })

        store.refresh()
        reporter.gate?.signal()
        try await waitUntilIdle(store)

        store.refresh()
        reporter.gate?.signal()
        try await waitUntilIdle(store)

        XCTAssertEqual(reporter.callCount, 2)
    }

    // MARK: - Display rules

    @MainActor
    func testSessionAtCapacityBeforeResetResolvesSessionWindow() async throws {
        let store = try await loadedStore(sessionReport(used: 100, resetsAt: futureReset))

        XCTAssertEqual(store.limitReachedWindow, .session)
        XCTAssertTrue(store.isLimitReached)
        XCTAssertEqual(store.sessionUtilization, 100)
        XCTAssertEqual(store.sessionResetsAt, Date(timeIntervalSince1970: TimeInterval(futureReset)))
        XCTAssertEqual(store.weeklyUtilization, 58)
    }

    @MainActor
    func testSessionAtCapacityAfterResetResolvesNothing() async throws {
        let store = try await loadedStore(sessionReport(used: 100, resetsAt: pastReset))

        XCTAssertNil(store.limitReachedWindow)
        XCTAssertFalse(store.isLimitReached)
        XCTAssertEqual(store.sessionUtilization, 0)
        XCTAssertNil(store.sessionResetsAt)
    }

    @MainActor
    func testExpiredSessionWindowReadsZeroWhileWeeklyKeepsValue() async throws {
        let store = try await loadedStore(sessionReport(used: 93, resetsAt: pastReset))

        XCTAssertEqual(store.sessionUtilization, 0, "menu bar and popover must both read 0 after reset")
        XCTAssertNil(store.sessionResetsAt)
        XCTAssertEqual(store.weeklyUtilization, 58)
        XCTAssertEqual(store.weeklyResetsAt, Date(timeIntervalSince1970: TimeInterval(weeklyReset)))
        XCTAssertNil(store.limitReachedWindow)
    }

    @MainActor
    func testWeeklyOnlyLayoutWithMarkerResolvesWeeklyWindow() async throws {
        let limits = CodexRateLimits(
            primary: CodexRateLimit(usedPercent: 100, windowMinutes: 10080, resetsAt: weeklyReset),
            secondary: nil,
            planType: "plus",
            rateLimitReachedType: "primary"
        )
        let store = try await loadedStore(report(limits: limits, limitReachedAt: snapshotDate))

        XCTAssertEqual(store.limitReachedWindow, .weekly)
        XCTAssertNil(store.sessionUtilization)
        XCTAssertEqual(store.weeklyUtilization, 100)
        XCTAssertEqual(store.weeklyResetsAt, Date(timeIntervalSince1970: TimeInterval(weeklyReset)))
    }

    // MARK: - Empty report

    @MainActor
    func testEmptyReportKeepsLastKnownValues() async throws {
        let reporter = FakeRateLimitReporter(report: sessionReport(used: 100, resetsAt: futureReset, markerOffset: 300))
        let store = CodexUsageStore(parser: reporter, now: { [now] in now })
        store.refresh()
        try await waitUntilIdle(store)

        reporter.setReport(CodexSessionParser.RateLimitReport(snapshots: [], latest: nil, limitReachedAt: nil))
        store.refresh()
        try await waitUntilIdle(store)

        XCTAssertEqual(reporter.callCount, 2)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertEqual(store.latestLimits?.sessionLimit?.usedPercent, 100)
        XCTAssertEqual(store.latestSnapshotAt, snapshotDate)
        XCTAssertNotNil(store.limitReachedAt)
    }

    // MARK: - Helpers

    @MainActor
    private func loadedStore(_ report: CodexSessionParser.RateLimitReport) async throws -> CodexUsageStore {
        let store = CodexUsageStore(parser: FakeRateLimitReporter(report: report), now: { [now] in now })
        store.refresh()
        try await waitUntilIdle(store)
        return store
    }

    @MainActor
    private func waitUntilIdle(_ store: CodexUsageStore) async throws {
        try await waitUntil("store left isRefreshing") { !store.isRefreshing }
    }

    @MainActor
    private func waitUntil(_ description: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting: \(description)")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func sessionReport(
        used: Double,
        resetsAt: Int,
        markerOffset: TimeInterval? = nil
    ) -> CodexSessionParser.RateLimitReport {
        let limits = CodexRateLimits(
            primary: CodexRateLimit(usedPercent: used, windowMinutes: 300, resetsAt: resetsAt),
            secondary: CodexRateLimit(usedPercent: 58, windowMinutes: 10080, resetsAt: weeklyReset),
            planType: "plus"
        )
        return report(limits: limits, limitReachedAt: markerOffset.map { snapshotDate.addingTimeInterval($0) })
    }

    private func report(limits: CodexRateLimits, limitReachedAt: Date?) -> CodexSessionParser.RateLimitReport {
        let snapshot = CodexSessionParser.RateLimitSnapshot(timestamp: snapshotDate, limits: limits)
        return CodexSessionParser.RateLimitReport(snapshots: [snapshot], latest: snapshot, limitReachedAt: limitReachedAt)
    }
}
