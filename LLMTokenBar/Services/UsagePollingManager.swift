import Foundation
import Combine

@MainActor
final class UsagePollingManager: ObservableObject {
    @Published var claudeUsage: UsageData
    @Published var syncStatus: SyncStatus
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let claudeAuthService: ClaudeAuthService
    private let claudeUsageService: ClaudeUsageService
    private var pollingTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var lastError: Error?

    init() {
        let authService = ClaudeAuthService()
        self.claudeAuthService = authService
        self.claudeUsageService = ClaudeUsageService(authService: authService)
        self.claudeUsage = .empty(for: .claude)
        self.syncStatus = .disconnected(for: .claude)
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
        Task {
            await fetchAll()
        }
    }

    private func fetchAll() async {
        isLoading = true
        errorMessage = nil

        syncStatus = await claudeAuthService.getSyncStatus()

        do {
            let usage = try await claudeUsageService.fetchUsage()
            claudeUsage = usage
            consecutiveFailures = 0
            lastError = nil
        } catch {
            consecutiveFailures += 1
            lastError = error
            errorMessage = error.localizedDescription

            let isRateLimited: Bool
            if case UsageError.rateLimited = error {
                isRateLimited = true
            } else {
                isRateLimited = false
            }
            if !isRateLimited && consecutiveFailures == 1 {
                claudeUsage = .empty(for: .claude)
            }
        }

        isLoading = false
    }

    private func nextPollInterval() -> TimeInterval {
        if consecutiveFailures == 0 {
            return Constants.Polling.successInterval
        }

        if let lastError, case UsageError.rateLimited = lastError {
            let backoff = Constants.Polling.rateLimitBaseInterval * pow(2.0, Double(consecutiveFailures - 1))
            return min(backoff, Constants.Polling.rateLimitMaxInterval)
        }

        return Constants.Polling.failureInterval
    }

    func resync() async {
        await fetchAll()
    }

    func disconnect() {
        try? KeychainService.shared.delete(
            service: Constants.Keychain.serviceName,
            account: Constants.Keychain.claudeAccount
        )
        claudeUsage = .empty(for: .claude)
        syncStatus = .disconnected(for: .claude)
    }

    func syncFromCLI() {
        // Re-read credentials from Keychain (no re-login needed)
        // Claude Code stores OAuth tokens in Keychain when user logs in via CLI
        Task {
            await fetchAll()
        }
    }

    var subscriptionLabel: String {
        syncStatus.subscription ?? "Unknown"
    }
}
