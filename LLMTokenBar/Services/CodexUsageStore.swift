import Foundation

@MainActor
final class CodexUsageStore: ObservableObject {
    @Published private(set) var latestLimits: CodexRateLimits?

    private weak var historyStore: UsageHistoryStore?
    private var refreshTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var timer: Timer?

    func configure(historyStore: UsageHistoryStore) {
        self.historyStore = historyStore
    }

    func loadHistory() {
        historyTask?.cancel()
        historyTask = Task.detached(priority: .utility) {
            let snapshots = CodexSessionParser().allRateLimitSnapshots()

            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.latestLimits = snapshots.last?.limits

                for snapshot in snapshots {
                    self.historyStore?.recordCodexSnapshot(
                        sessionUtilization: snapshot.limits.primary?.usedPercent,
                        weeklyUtilization: snapshot.limits.secondary?.usedPercent,
                        timestamp: snapshot.timestamp
                    )
                }
            }
        }
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task.detached(priority: .utility) {
            let limits = CodexSessionParser().latestRateLimits()

            await MainActor.run {
                guard !Task.isCancelled,
                      let limits,
                      limits.primary != nil else { return }

                self.latestLimits = limits
                self.historyStore?.recordCodexLimits(limits)
            }
        }
    }

    func startPolling(interval: TimeInterval = 60) {
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
        historyTask?.cancel()
    }
}
