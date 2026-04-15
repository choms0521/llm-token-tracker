import Foundation
import Combine

@MainActor
final class UsagePollingManager: ObservableObject {
    @Published var claudeUsage: UsageData
    @Published var minimaxUsage: UsageData
    @Published var syncStatus: SyncStatus
    @Published var minimaxSyncStatus: SyncStatus
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var minimaxErrorMessage: String?

    private let claudeAuthService: ClaudeAuthService
    private let claudeUsageService: ClaudeUsageService
    let minimaxAuth: MiniMaxAuthService
    private let minimaxUsageService: MiniMaxUsageService
    private var pollingTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var lastError: Error?
    private var rateLimitedUntil: Date?
    private var lastFetchTime: Date?
    private var isFetching = false
    private var lastUsageSnapshot: Double?
    private var stableCount = 0
    private var minimaxConsecutiveFailures = 0

    private let minimumFetchInterval: TimeInterval = 60  // 최소 60초 간격
    private let stableThreshold = 3  // 3회 연속 동일하면 안정 상태

    init() {
        let authService = ClaudeAuthService()
        self.claudeAuthService = authService
        self.claudeUsageService = ClaudeUsageService(authService: authService)
        self.claudeUsage = .empty(for: .claude)
        self.syncStatus = .disconnected(for: .claude)

        let mmAuthService = MiniMaxAuthService()
        self.minimaxAuth = mmAuthService
        self.minimaxUsageService = MiniMaxUsageService(authService: mmAuthService)
        self.minimaxUsage = .empty(for: .minimax)
        self.minimaxSyncStatus = .disconnected(for: .minimax)
    }

    func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchAll()

            while !Task.isCancelled {
                let interval = self.nextPollInterval()
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await self.fetchAll()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refresh() {
        if let rateLimitedUntil, Date() < rateLimitedUntil {
            let minutes = Int(ceil(rateLimitedUntil.timeIntervalSinceNow / 60))
            errorMessage = "Rate limit 해제 대기 중 (\(minutes)분 후)"
            return
        }
        Task {
            await fetchAll()
        }
    }

    private func fetchAll(force: Bool = false) async {
        // 중복 호출 방지
        guard !isFetching else { return }

        // 최소 간격 쓰로틀 (폴링 루프의 첫 호출은 예외, force 시 무시)
        if !force, let lastFetchTime {
            let elapsed = Date().timeIntervalSince(lastFetchTime)
            if elapsed < minimumFetchInterval {
                return
            }
        }

        isFetching = true
        isLoading = true
        errorMessage = nil
        minimaxErrorMessage = nil

        // Claude & MiniMax 병렬 네트워크 요청
        // 두 요청이 모두 끝난 뒤에만 로딩/중복 호출 상태를 해제
        async let claudeFetch: Void = fetchClaude()
        async let minimaxFetch: Void = fetchMiniMax()
        _ = await (claudeFetch, minimaxFetch)

        lastFetchTime = Date()
        isFetching = false
        isLoading = false
    }

    private func fetchClaude() async {
        syncStatus = await claudeAuthService.getSyncStatus()

        do {
            let usage = try await claudeUsageService.fetchUsage()
            claudeUsage = usage
            consecutiveFailures = 0
            lastError = nil
            rateLimitedUntil = nil

            let currentUtilization = usage.sessionUsage?.utilization
            if let current = currentUtilization, let last = lastUsageSnapshot,
               abs(current - last) < 0.01 {
                stableCount += 1
            } else {
                stableCount = 0
            }
            lastUsageSnapshot = currentUtilization
        } catch {
            consecutiveFailures += 1
            lastError = error

            let isRateLimited: Bool
            if case UsageError.rateLimited = error {
                isRateLimited = true
            } else {
                isRateLimited = false
            }

            if isRateLimited {
                if let usageError = error as? UsageError,
                   let retryAfter = usageError.retryAfterInterval {
                    rateLimitedUntil = Date().addingTimeInterval(retryAfter)
                } else {
                    let backoff = nextRateLimitBackoff()
                    rateLimitedUntil = Date().addingTimeInterval(backoff)
                }

                let hasCache = claudeUsage.sessionUsage != nil || !claudeUsage.modelUsages.isEmpty
                if hasCache {
                    let minutes = Int(ceil((rateLimitedUntil?.timeIntervalSinceNow ?? 600) / 60))
                    errorMessage = "Rate limit - \(minutes)분 후 자동 재시도"
                } else {
                    errorMessage = error.localizedDescription
                }
            } else {
                errorMessage = error.localizedDescription
                if consecutiveFailures == 1 {
                    claudeUsage = .empty(for: .claude)
                }
            }
        }
    }

    private func fetchMiniMax() async {
        minimaxSyncStatus = await minimaxAuth.getSyncStatus()

        guard minimaxSyncStatus.isConnected else { return }

        do {
            let usage = try await minimaxUsageService.fetchUsage()
            minimaxUsage = usage
            minimaxConsecutiveFailures = 0
            minimaxErrorMessage = nil
        } catch {
            minimaxConsecutiveFailures += 1

            let isRateLimited: Bool
            if case UsageError.rateLimited = error {
                isRateLimited = true
            } else {
                isRateLimited = false
            }

            if isRateLimited {
                // Rate limit 시 캐시된 데이터 유지
                let hasCache = minimaxUsage.sessionUsage != nil
                if hasCache {
                    minimaxErrorMessage = "Rate limit - 잠시 후 자동 재시도"
                } else {
                    minimaxErrorMessage = error.localizedDescription
                }
            } else {
                minimaxErrorMessage = error.localizedDescription
                if minimaxConsecutiveFailures == 1 {
                    minimaxUsage = .empty(for: .minimax)
                }
            }
        }
    }

    private func nextPollInterval() -> TimeInterval {
        if consecutiveFailures == 0 {
            // 적응형: 사용량 안정적이면 폴링 간격 늘리기
            if stableCount >= stableThreshold {
                return Constants.Polling.successInterval * 1.5  // 15분
            }
            return Constants.Polling.successInterval  // 10분
        }

        if let lastError, case UsageError.rateLimited = lastError {
            if let rateLimitedUntil {
                let remaining = rateLimitedUntil.timeIntervalSinceNow
                if remaining > 0 { return remaining }
            }
            return nextRateLimitBackoff()
        }

        return Constants.Polling.failureInterval
    }

    private func nextRateLimitBackoff() -> TimeInterval {
        let backoff = Constants.Polling.rateLimitBaseInterval * pow(2.0, Double(consecutiveFailures - 1))
        return min(backoff, Constants.Polling.rateLimitMaxInterval)
    }

    func resync() async {
        await fetchAll(force: true)
    }

    func disconnect() {
        try? KeychainService.shared.delete(
            service: Constants.Keychain.serviceName,
            account: Constants.Keychain.claudeAccount
        )
        claudeUsage = .empty(for: .claude)
        syncStatus = .disconnected(for: .claude)
    }

    func syncFromCLI() async {
        // Re-read credentials from Keychain (no re-login needed)
        // Claude Code stores OAuth tokens in Keychain when user logs in via CLI
        await fetchAll(force: true)
    }

    var subscriptionLabel: String {
        syncStatus.subscription ?? "Unknown"
    }
}
