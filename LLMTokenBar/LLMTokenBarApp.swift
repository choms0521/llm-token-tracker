import SwiftUI
import Combine

@main
struct LLMTokenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var manager: UsagePollingManager?
    private var historyStore: UsageHistoryStore?
    private var tokenStats: TokenStatsService?
    private var displayConfig: ProviderDisplayConfig?
    private var codexUsage: CodexUsageStore?
    private var cancellables = Set<AnyCancellable>()
    private var displaySettingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let pollingManager = UsagePollingManager()
        let history = UsageHistoryStore()
        let stats = TokenStatsService()
        let providerConfig = ProviderDisplayConfig()
        let codexUsage = CodexUsageStore()
        codexUsage.configure(historyStore: history)
        stats.reload()
        self.manager = pollingManager
        self.historyStore = history
        self.tokenStats = stats
        self.displayConfig = providerConfig
        self.codexUsage = codexUsage

        statusBarController = StatusBarController(
            manager: pollingManager,
            historyStore: history,
            tokenStats: stats,
            displayConfig: providerConfig,
            codexUsage: codexUsage
        )

        pollingManager.$claudeUsage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] usage in
                self?.updateStatusBar()
                self?.tokenStats?.reload()

                if usage.sessionUsage != nil || usage.weeklyUsage != nil {
                    self?.historyStore?.record(from: usage)
                }
            }
            .store(in: &cancellables)

        codexUsage.$latestLimits
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusBar()
            }
            .store(in: &cancellables)

        pollingManager.$minimaxUsage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] usage in
                self?.updateStatusBar()

                if usage.sessionUsage != nil || usage.weeklyUsage != nil {
                    self?.historyStore?.record(from: usage)
                }
            }
            .store(in: &cancellables)

        pollingManager.$kimiUsage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] usage in
                self?.updateStatusBar()

                if usage.sessionUsage != nil || usage.weeklyUsage != nil {
                    self?.historyStore?.record(from: usage)
                }
            }
            .store(in: &cancellables)

        displaySettingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusBar()
            }
        }

        pollingManager.startPolling()

        codexUsage.loadHistory()
        codexUsage.startPolling()
        updateStatusBar()
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager?.stopPolling()
        codexUsage?.stopPolling()
        if let displaySettingsObserver {
            NotificationCenter.default.removeObserver(displaySettingsObserver)
        }
    }

    private func updateStatusBar() {
        let providerRawValue = UserDefaults.standard.string(forKey: StatusBarUsageProvider.storageKey)
            ?? StatusBarUsageProvider.defaultValue.rawValue
        let provider = StatusBarUsageProvider(rawValue: providerRawValue) ?? .claude
        let rawMetric = UserDefaults.standard.string(forKey: "statusBarMetric") ?? "session"
        let metric = normalizedStatusBarMetric(rawMetric, for: provider)

        let value = statusBarValue(for: provider, metric: metric)

        if let value {
            statusBarController?.updateStatusText("\(Int(value))%")
            statusBarController?.updateUtilization(value)
        } else {
            statusBarController?.updateStatusText("")
            statusBarController?.updateUtilization(0)
        }
    }

    private func normalizedStatusBarMetric(_ metric: String, for provider: StatusBarUsageProvider) -> String {
        guard let statusBarMetric = StatusBarMetric(rawValue: metric),
              provider.supportedStatusBarMetrics.contains(statusBarMetric) else {
            return StatusBarMetric.session.rawValue
        }
        return statusBarMetric.rawValue
    }

    private func statusBarValue(for provider: StatusBarUsageProvider, metric: String) -> Double? {
        switch provider {
        case .claude:
            return usageValue(from: manager?.claudeUsage, metric: metric)
        case .openai:
            return codexValue(metric: metric)
        case .minimax:
            return usageValue(from: manager?.minimaxUsage, metric: metric)
        case .kimi:
            return usageValue(from: manager?.kimiUsage, metric: metric)
        }
    }

    private func usageValue(from usage: UsageData?, metric: String) -> Double? {
        guard let usage else { return nil }

        return switch metric {
        case "session":
            usage.sessionUsage?.utilization
        case "weekly":
            usage.weeklyUsage?.utilization
        case "opus":
            usage.modelUsages.first(where: { $0.id == "opus" })?.utilization
        case "sonnet":
            usage.modelUsages.first(where: { $0.id == "sonnet" })?.utilization
        case "haiku":
            usage.modelUsages.first(where: { $0.id == "haiku" })?.utilization
        default:
            usage.sessionUsage?.utilization
        }
    }

    private func codexValue(metric: String) -> Double? {
        guard let limits = codexUsage?.latestLimits else { return nil }

        switch metric {
        case "session":
            return limits.primary?.usedPercent
        case "weekly":
            return limits.secondary?.usedPercent
        default:
            return nil
        }
    }
}
