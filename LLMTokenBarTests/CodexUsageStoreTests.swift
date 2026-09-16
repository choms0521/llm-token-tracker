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

/// 성공 리포트나 지정한 오류를 돌려주는 가짜 실시간 리포터. 결과는 폴링 도중 바꿀 수 있다.
private final class FakeLiveReporter: CodexLiveUsageReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<CodexSessionParser.RateLimitReport, Error>
    private var count = 0

    init(_ result: Result<CodexSessionParser.RateLimitReport, Error>) {
        self.result = result
    }

    var callCount: Int { lock.withLock { count } }

    func setResult(_ result: Result<CodexSessionParser.RateLimitReport, Error>) {
        lock.withLock { self.result = result }
    }

    func fetchReport() async throws -> CodexSessionParser.RateLimitReport {
        try lock.withLock {
            count += 1
            return try result.get()
        }
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

    // MARK: - Live API vs log fallback

    @MainActor
    func testLiveSuccessUsesLiveValuesAndMarksSourceLive() async throws {
        let liveLimits = CodexRateLimits(
            primary: CodexRateLimit(usedPercent: 5, windowMinutes: 10080, resetsAt: weeklyReset),
            secondary: nil,
            planType: "pro"
        )
        let liveReport = report(limits: liveLimits, limitReachedAt: nil)
        // 파서(로그)는 다른 값을 주도록 해, 실제로 실시간 값이 쓰였는지 구분한다.
        let parser = FakeRateLimitReporter(report: sessionReport(used: 100, resetsAt: futureReset))
        let store = CodexUsageStore(
            parser: parser,
            service: FakeLiveReporter(.success(liveReport)),
            now: { [now] in now }
        )

        store.refresh()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.lastSource, .live)
        XCTAssertEqual(store.weeklyUtilization, 5)
        XCTAssertNil(store.sessionUtilization)
        XCTAssertEqual(parser.callCount, 0, "실시간이 성공하면 파서를 부르지 않는다")
    }

    @MainActor
    func testLiveUnauthorizedFallsBackToLog() async throws {
        let parser = FakeRateLimitReporter(report: sessionReport(used: 93, resetsAt: futureReset))
        let store = CodexUsageStore(
            parser: parser,
            service: FakeLiveReporter(.failure(CodexUsageError.unauthorized)),
            now: { [now] in now }
        )

        store.refresh()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.lastSource, .log)
        XCTAssertEqual(store.sessionUtilization, 93)
        XCTAssertEqual(parser.callCount, 1)
    }

    @MainActor
    func testLiveGenericFailureFallsBackToLog() async throws {
        struct Boom: Error {}
        let parser = FakeRateLimitReporter(report: sessionReport(used: 77, resetsAt: futureReset))
        let store = CodexUsageStore(
            parser: parser,
            service: FakeLiveReporter(.failure(Boom())),
            now: { [now] in now }
        )

        store.refresh()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.lastSource, .log)
        XCTAssertEqual(store.sessionUtilization, 77)
    }

    @MainActor
    func testLiveEmptyUsageFallsBackToLog() async throws {
        // 서비스가 내용상 빈 응답을 emptyUsage로 던지면 스토어는 로그로 폴백해야 한다.
        let parser = FakeRateLimitReporter(report: sessionReport(used: 88, resetsAt: futureReset))
        let store = CodexUsageStore(
            parser: parser,
            service: FakeLiveReporter(.failure(CodexUsageError.emptyUsage)),
            now: { [now] in now }
        )

        store.refresh()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.lastSource, .log)
        XCTAssertEqual(store.sessionUtilization, 88)
        XCTAssertEqual(parser.callCount, 1)
    }

    @MainActor
    func testLiveFailsAndLogEmptyKeepsPreviousValues() async throws {
        let liveLimits = CodexRateLimits(
            primary: CodexRateLimit(usedPercent: 5, windowMinutes: 10080, resetsAt: weeklyReset),
            secondary: nil,
            planType: "pro"
        )
        let service = FakeLiveReporter(.success(report(limits: liveLimits, limitReachedAt: nil)))
        let store = CodexUsageStore(
            parser: FakeRateLimitReporter(
                report: CodexSessionParser.RateLimitReport(snapshots: [], latest: nil, limitReachedAt: nil)
            ),
            service: service,
            now: { [now] in now }
        )

        // 1) 실시간 성공으로 값을 채운다.
        store.refresh()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.weeklyUtilization, 5)

        // 2) 이제 실시간 실패 + 로그 빈 리포트여도 마지막 값을 지우지 않고 플래그도 내린다.
        service.setResult(.failure(CodexUsageError.unauthorized))
        store.refresh()
        try await waitUntilIdle(store)

        XCTAssertFalse(store.isRefreshing)
        // 값은 이전(실시간) 것을 유지하되, 출처는 로그로 내려 신선도 신호("로그 기준")를 띄운다.
        XCTAssertEqual(store.weeklyUtilization, 5)
        XCTAssertEqual(store.lastSource, .log, "실시간 실패 후 폴백은 값은 유지하되 출처를 log로 표시한다")
    }

    @MainActor
    func testLoadHistoryRebuildsFromParserThenRefreshesLiveOnce() async throws {
        // 파서(로그)는 전체 시계열(2점)을 준다.
        let older = CodexRateLimits(
            primary: CodexRateLimit(usedPercent: 40, windowMinutes: 300, resetsAt: futureReset),
            secondary: CodexRateLimit(usedPercent: 50, windowMinutes: 10080, resetsAt: weeklyReset),
            planType: "plus"
        )
        let newer = CodexRateLimits(
            primary: CodexRateLimit(usedPercent: 60, windowMinutes: 300, resetsAt: futureReset),
            secondary: CodexRateLimit(usedPercent: 55, windowMinutes: 10080, resetsAt: weeklyReset),
            planType: "plus"
        )
        let s1 = CodexSessionParser.RateLimitSnapshot(timestamp: snapshotDate.addingTimeInterval(-120), limits: older)
        let s2 = CodexSessionParser.RateLimitSnapshot(timestamp: snapshotDate, limits: newer)
        let parserReport = CodexSessionParser.RateLimitReport(snapshots: [s1, s2], latest: s2, limitReachedAt: nil)
        let parser = FakeRateLimitReporter(report: parserReport)

        // 실시간은 다른 값을 준다.
        let liveLimits = CodexRateLimits(
            primary: CodexRateLimit(usedPercent: 5, windowMinutes: 10080, resetsAt: weeklyReset),
            secondary: nil,
            planType: "pro"
        )
        let live = FakeLiveReporter(.success(report(limits: liveLimits, limitReachedAt: nil)))

        let historyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-history.json").path
        let history = UsageHistoryStore(storePath: historyPath, now: { [now] in now })

        let store = CodexUsageStore(parser: parser, service: live, now: { [now] in now })
        store.configure(historyStore: history)

        store.loadHistory()
        try await waitUntil("live refresh ran after rebuild") { live.callCount >= 1 }
        try await waitUntilIdle(store)

        // 이력은 파서 전체 시계열(2점)로 재구성됐다.
        let openaiSnapshots = history.snapshots.filter { $0.provider == .openai }
        XCTAssertGreaterThanOrEqual(openaiSnapshots.count, 2, "loadHistory는 로그 전체 시계열로 이력을 재구성해야 한다")
        XCTAssertEqual(parser.callCount, 1, "이력 재구성은 파서를 정확히 한 번 쓴다")
        XCTAssertEqual(live.callCount, 1, "재구성 후 실시간을 정확히 한 번 갱신한다")
        // 마지막 화면 값은 실시간이 덮어쓴다.
        XCTAssertEqual(store.lastSource, .live)
        XCTAssertEqual(store.weeklyUtilization, 5)
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
