import Foundation

enum CodexLimitWindow: Equatable {
    case session
    case weekly
}

@MainActor
final class CodexUsageStore: ObservableObject {
    @Published private(set) var latestLimits: CodexRateLimits?
    /// 화면에 표시 중인 한도 값의 기준 시각(세션 로그에 기록된 시각).
    @Published private(set) var latestSnapshotAt: Date?
    /// 최신 스냅샷 이후 한도 도달 신호가 관측된 시각.
    @Published private(set) var limitReachedAt: Date?
    @Published private(set) var isRefreshing = false

    private let parser: any CodexRateLimitReporting
    private let now: () -> Date
    private weak var historyStore: UsageHistoryStore?
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private var lastRecordedSnapshotAt: Date?

    init(
        parser: any CodexRateLimitReporting = CodexSessionParser(),
        now: @escaping () -> Date = Date.init
    ) {
        self.parser = parser
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
        refresh(recordHistory: true)
    }

    /// 진행 중인 갱신이 있으면 새 요청은 합류시키고 취소하지 않는다.
    func refresh(recordHistory: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true

        let parser = self.parser
        refreshTask = Task.detached(priority: .utility) { [weak self] in
            let report = parser.rateLimitReport()

            await MainActor.run {
                self?.apply(report, recordHistory: recordHistory)
            }
        }
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
    private func apply(_ report: CodexSessionParser.RateLimitReport, recordHistory: Bool) {
        isRefreshing = false
        guard !Task.isCancelled, let latest = report.latest else { return }

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
        if rebuildHistory {
            historyStore?.recordCodexSnapshots(report.snapshots)
            lastRecordedSnapshotAt = latest.timestamp
            return
        }

        // 스냅샷 시각이 앞으로 나아갔을 때만 기록해 같은 값이 폴링마다 쌓이지 않게 한다.
        guard lastRecordedSnapshotAt.map({ latest.timestamp > $0 }) ?? true else { return }
        historyStore?.recordCodexSnapshot(
            sessionUtilization: latest.limits.sessionLimit?.usedPercent,
            weeklyUtilization: latest.limits.weeklyLimit?.usedPercent,
            timestamp: latest.timestamp
        )
        lastRecordedSnapshotAt = latest.timestamp
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
