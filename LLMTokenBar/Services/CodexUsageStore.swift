import Foundation

enum CodexLimitWindow: Equatable {
    case session
    case weekly
}

/// 화면에 표시 중인 값의 출처. 실시간 API가 성공하면 live, 로그 파서로 폴백하면 log.
enum CodexUsageSource: Equatable {
    case live
    case log
}

@MainActor
final class CodexUsageStore: ObservableObject {
    @Published private(set) var latestLimits: CodexRateLimits?
    /// 화면에 표시 중인 한도 값의 기준 시각(실시간 API는 조회 시각, 로그는 기록 시각).
    @Published private(set) var latestSnapshotAt: Date?
    /// 최신 스냅샷 이후 한도 도달 신호가 관측된 시각.
    @Published private(set) var limitReachedAt: Date?
    /// 표시 중인 값의 출처. 값이 아직 없으면 nil.
    @Published private(set) var lastSource: CodexUsageSource?
    @Published private(set) var isRefreshing = false

    private let parser: any CodexRateLimitReporting
    private let service: CodexLiveUsageReporting?
    private let now: () -> Date
    private weak var historyStore: UsageHistoryStore?
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private var lastRecordedSnapshotAt: Date?
    private var lastRecordedValues: (session: Double?, weekly: Double?)?

    init(
        parser: any CodexRateLimitReporting = CodexSessionParser(),
        service: CodexLiveUsageReporting? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.parser = parser
        self.service = service
        self.now = now
    }

    // MARK: - Display rules (메뉴 바와 팝오버가 같은 값을 읽도록 여기서만 계산한다)

    /// 한도가 소진된 창. 한도 도달 신호가 있거나 세션이 100%이면서 리셋 전일 때,
    /// 아직 리셋되지 않은 창 중 세션을 우선해 고른다.
    var limitReachedWindow: CodexLimitWindow? {
        guard limitReachedAt != nil || isSessionAtCapacity else { return nil }
        if isUnexpired(latestLimits?.sessionLimit) {
            return .session
        }
        if isUnexpired(latestLimits?.weeklyLimit) {
            return .weekly
        }
        return nil
    }

    var isLimitReached: Bool {
        limitReachedWindow != nil
    }

    /// 세션 창 사용률. 한도 정보가 없으면 nil, 리셋이 지났으면 0, 소진 창이면 100.
    var sessionUtilization: Double? {
        utilization(of: latestLimits?.sessionLimit, window: .session)
    }

    var weeklyUtilization: Double? {
        utilization(of: latestLimits?.weeklyLimit, window: .weekly)
    }

    /// 리셋이 지난 창은 nil을 돌려준다.
    var sessionResetsAt: Date? {
        resetDate(of: latestLimits?.sessionLimit)
    }

    var weeklyResetsAt: Date? {
        resetDate(of: latestLimits?.weeklyLimit)
    }

    // MARK: - Lifecycle

    func configure(historyStore: UsageHistoryStore) {
        self.historyStore = historyStore
    }

    func loadHistory() {
        // 먼저 로컬 로그로 이력을 재구성하고 화면을 채운다.
        refresh(recordHistory: true)
        // 재구성이 끝나면 곧바로 실시간 값으로 한 번 갱신해, 시작 시 오래된 로그 값이
        // 다음 폴링(liveUsagePollInterval)까지 남아 있지 않게 한다.
        // stopPolling이 취소할 수 있도록 후속 Task를 refreshTask에 담아 둔다.
        let rebuildTask = refreshTask
        refreshTask = Task { [weak self] in
            await rebuildTask?.value
            self?.refresh()
        }
    }

    /// 진행 중인 갱신이 있으면 새 요청은 무시하고 진행 중인 것을 취소하지 않는다(중복 폴링 방지).
    func refresh(recordHistory: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true

        let parser = self.parser
        let service = self.service

        // 이력 재구성(loadHistory)은 로그 전체 시계열이 필요하므로 반드시 파서를 쓴다.
        // 실시간 API는 현재 한 점만 주기 때문에 recordCodexSnapshots가 이력을 덮어써 버린다.
        if recordHistory {
            refreshTask = Task.detached(priority: .utility) { [weak self] in
                let report = parser.rateLimitReport()
                await MainActor.run {
                    self?.apply(report, source: .log, recordHistory: true)
                }
            }
            return
        }

        refreshTask = Task { [weak self] in
            let outcome = await Self.fetchReport(service: service, parser: parser)
            self?.apply(outcome.report, source: outcome.source, recordHistory: false)
        }
    }

    /// 실시간 API를 우선 시도하고 어떤 실패든(오프라인·401·타임아웃) 로컬 로그로 폴백한다.
    private static func fetchReport(
        service: CodexLiveUsageReporting?,
        parser: any CodexRateLimitReporting
    ) async -> (report: CodexSessionParser.RateLimitReport, source: CodexUsageSource) {
        if let service {
            do {
                return (try await service.fetchReport(), .live)
            } catch {
                // 폴백으로 진행한다.
            }
        }
        let report = await Task.detached(priority: .utility) { parser.rateLimitReport() }.value
        return (report, .log)
    }

    func startPolling(interval: TimeInterval = Constants.Codex.rateLimitPollInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Private

    /// 빈 리포트(최근 스냅샷 없음)는 마지막으로 알던 값을 지우지 않는다.
    private func apply(
        _ report: CodexSessionParser.RateLimitReport,
        source: CodexUsageSource,
        recordHistory: Bool
    ) {
        // 어떤 경로로 들어와도 여기서 플래그를 내려 폴링이 멈추지 않게 한다.
        isRefreshing = false
        guard !Task.isCancelled else { return }

        // 리포트가 비어 값을 갱신하지 못하더라도 출처는 반영한다. 그래야 실시간이 실패해
        // 로그로 폴백했을 때(로그마저 비어 값이 그대로여도) 팝오버가 "로그 기준" 신호를 띄운다.
        lastSource = source
        guard let latest = report.latest else { return }

        latestLimits = latest.limits
        latestSnapshotAt = latest.timestamp
        limitReachedAt = report.limitReachedAt
        record(report, latest: latest, rebuildHistory: recordHistory)
    }

    private func record(
        _ report: CodexSessionParser.RateLimitReport,
        latest: CodexSessionParser.RateLimitSnapshot,
        rebuildHistory: Bool
    ) {
        let values = (
            session: latest.limits.sessionLimit?.usedPercent,
            weekly: latest.limits.weeklyLimit?.usedPercent
        )

        if rebuildHistory {
            historyStore?.recordCodexSnapshots(report.snapshots)
            lastRecordedSnapshotAt = latest.timestamp
            lastRecordedValues = values
            return
        }

        // 스냅샷 시각이 앞으로 나아갔을 때만 기록한다.
        guard lastRecordedSnapshotAt.map({ latest.timestamp > $0 }) ?? true else { return }
        // 실시간 API는 조회 시각(now)으로 매번 시각이 갱신되므로, 값이 실제로 변했을 때만
        // 기록해 같은 값이 폴링마다 이력에 쌓이는 것을 막는다.
        if let last = lastRecordedValues, last.session == values.session, last.weekly == values.weekly {
            lastRecordedSnapshotAt = latest.timestamp
            return
        }
        historyStore?.recordCodexSnapshot(
            sessionUtilization: values.session,
            weeklyUtilization: values.weekly,
            timestamp: latest.timestamp
        )
        lastRecordedSnapshotAt = latest.timestamp
        lastRecordedValues = values
    }

    private var isSessionAtCapacity: Bool {
        guard let session = latestLimits?.sessionLimit, isUnexpired(session) else { return false }
        return (session.usedPercent ?? 0) >= Constants.Codex.fullUtilizationPercent
    }

    /// resets_at이 없으면 아직 리셋되지 않은 것으로 본다.
    private func isUnexpired(_ limit: CodexRateLimit?) -> Bool {
        guard let limit else { return false }
        guard let resetsAt = limit.resetsAt else { return true }
        return Date(timeIntervalSince1970: TimeInterval(resetsAt)) > now()
    }

    private func utilization(of limit: CodexRateLimit?, window: CodexLimitWindow) -> Double? {
        guard let limit else { return nil }
        guard isUnexpired(limit) else { return 0 }
        if limitReachedWindow == window {
            return Constants.Codex.fullUtilizationPercent
        }
        return limit.usedPercent ?? 0
    }

    private func resetDate(of limit: CodexRateLimit?) -> Date? {
        guard let limit, isUnexpired(limit), let resetsAt = limit.resetsAt else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(resetsAt))
    }
}
