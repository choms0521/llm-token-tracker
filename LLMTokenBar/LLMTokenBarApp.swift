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
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let pollingManager = UsagePollingManager()
        let history = UsageHistoryStore()
        let stats = TokenStatsService()
        stats.reload()
        self.manager = pollingManager
        self.historyStore = history
        self.tokenStats = stats

        statusBarController = StatusBarController(manager: pollingManager, historyStore: history, tokenStats: stats)

        pollingManager.$claudeUsage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] usage in
                self?.updateStatusBar(usage: usage)
                self?.tokenStats?.reload()

                if usage.sessionUsage != nil || usage.weeklyUsage != nil {
                    self?.historyStore?.record(from: usage)
                }
            }
            .store(in: &cancellables)

        pollingManager.startPolling()
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager?.stopPolling()
    }

    private func updateStatusBar(usage: UsageData) {
        let metric = UserDefaults.standard.string(forKey: "statusBarMetric") ?? "session"

        let value: Double? = switch metric {
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

        if let value {
            statusBarController?.updateStatusText("\(Int(value))%")
        } else {
            statusBarController?.updateStatusText("")
        }
    }
}
