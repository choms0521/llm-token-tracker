import SwiftUI
import ServiceManagement

enum SettingsTab: String, CaseIterable, Identifiable {
    case claude
    case gemini
    case openai
    case minimax
    case display
    case history
    case tokens
    case general

    var id: String { rawValue }

    var localizedName: LocalizedStringKey {
        switch self {
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .openai: return "OpenAI"
        case .minimax: return "MiniMax"
        case .display: return "Display"
        case .history: return "History"
        case .tokens: return "Token Stats"
        case .general: return "General"
        }
    }

    var iconName: String {
        switch self {
        case .claude: return "brain.head.profile"
        case .gemini: return "sparkles"
        case .openai: return "cpu"
        case .minimax: return "wand.and.stars"
        case .display: return "square.stack.3d.up"
        case .history: return "chart.line.uptrend.xyaxis"
        case .tokens: return "number.square"
        case .general: return "gearshape"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var manager: UsagePollingManager
    @ObservedObject var historyStore: UsageHistoryStore
    @ObservedObject var displayConfig: ProviderDisplayConfig
    @State private var selectedTab: SettingsTab = .claude

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .frame(
            width: Constants.UI.settingsWidth,
            height: Constants.UI.settingsHeight
        )
    }

    private var sidebar: some View {
        List(selection: $selectedTab) {
            Section("Credentials") {
                ForEach([SettingsTab.claude, .gemini, .openai, .minimax], id: \.self) { tab in
                    Label(tab.localizedName, systemImage: tab.iconName)
                        .tag(tab)
                }
            }

            Section("Settings") {
                Label("Display", systemImage: "square.stack.3d.up")
                    .tag(SettingsTab.display)
                Label("History", systemImage: "chart.line.uptrend.xyaxis")
                    .tag(SettingsTab.history)
                Label("Token Stats", systemImage: "number.square")
                    .tag(SettingsTab.tokens)
                Label("General", systemImage: "gearshape")
                    .tag(SettingsTab.general)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 160)
        .safeAreaInset(edge: .bottom) {
            Button(action: { NSApp.terminate(nil) }) {
                Label("Quit App", systemImage: "power")
                    .font(.pretendard(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedTab {
        case .claude:
            CLISyncDetailView(
                provider: .claude,
                syncStatus: manager.syncStatus,
                onResync: { Task { await manager.resync() } },
                onDisconnect: { manager.disconnect() },
                onSyncFromCLI: { await manager.syncFromCLI() }
            )
        case .gemini:
            GeminiSettingsView()
        case .openai:
            OpenAISettingsView()
        case .minimax:
            MiniMaxSettingsView(syncStatus: manager.minimaxSyncStatus)
        case .display:
            ProviderDisplaySettingsView(config: displayConfig)
        case .history:
            UsageHistoryView(historyStore: historyStore)
        case .tokens:
            TokenStatsView()
        case .general:
            GeneralSettingsView()
        }
    }
}

struct CLISyncDetailView: View {
    let provider: Provider
    let syncStatus: SyncStatus
    var onResync: () -> Void
    var onDisconnect: () -> Void
    var onSyncFromCLI: () async -> Void = {}
    @State private var isSyncing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("CLI Account")
                    .font(.title2.bold())

                Text("Sync logged-in \(provider.displayName) CLI account")
                    .foregroundStyle(.secondary)

                syncStatusBanner

                if syncStatus.isConnected {
                    accountDetailsView
                    syncInfoView
                    actionButtons
                } else {
                    disconnectedDetailsView
                    syncFromCLIView
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var disconnectedDetailsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Account Details")
                .font(.pretendard(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text("No synced credentials yet")
                .font(.pretendard(size: 13))
                .foregroundStyle(.primary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var syncFromCLIView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.pretendard(size: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Must be logged in to Claude Code CLI")
                        .font(.pretendard(size: 11))
                        .foregroundStyle(.secondary)

                    Text("Log in with 'claude' command in terminal, then click below")
                        .font(.pretendard(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Button(action: {
                isSyncing = true
                Task {
                    await onSyncFromCLI()
                    isSyncing = false
                }
            }) {
                HStack(spacing: 6) {
                    if isSyncing {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text("Sync from Keychain")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(isSyncing)
        }
        .padding(12)
        .background(.blue.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var syncStatusBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(syncStatus.isConnected ? .green : .red)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(syncStatus.isConnected ? "CLI Account Synced" : "Not Connected")
                    .font(.pretendard(size: 13, weight: .medium))

                if let lastSync = syncStatus.lastSyncedAt {
                    Text(TimeFormatter.syncTimeString(from: lastSync))
                        .font(.pretendard(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(syncStatus.isConnected ? .green.opacity(0.1) : .red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var accountDetailsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Account Details")
                .font(.pretendard(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text("Synced CLI Credentials")
                .font(.pretendard(size: 11))
                .foregroundStyle(.secondary)

            if let token = syncStatus.maskedToken {
                DetailRow(icon: "key", label: String(localized: "Access Token"), value: token)
            }

            if let sub = syncStatus.subscription {
                DetailRow(icon: "person.crop.circle", label: String(localized: "Subscription"), value: sub)
            }

            if let tier = syncStatus.rateLimitTier {
                DetailRow(icon: "speedometer", label: "Rate Limit", value: tier)
            }

            if !syncStatus.scopes.isEmpty {
                DetailRow(
                    icon: "checkmark.shield",
                    label: String(localized: "Scopes"),
                    value: syncStatus.scopes.joined(separator: ", ")
                )
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var syncInfoView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                Text("CLI Account Sync Info")
                    .font(.pretendard(size: 12, weight: .medium))
            }

            VStack(alignment: .leading, spacing: 4) {
                BulletText("Auto-switch CLI login by profile")
                BulletText("Keep CLI and app accounts in sync")
                BulletText("Auto-refresh credentials on profile switch")
            }
            .padding(.leading, 4)
        }
        .padding(12)
        .background(.blue.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(action: onResync) {
                Label("Resync", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            Button(action: onDisconnect) {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }
}

struct DetailRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.pretendard(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.pretendard(size: 10))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.pretendard(size: 12, weight: .medium))
                    .textSelection(.enabled)
            }
        }
    }
}

struct BulletText: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text)
        }
        .font(.pretendard(size: 11))
        .foregroundStyle(.secondary)
    }
}

struct ComingSoonView: View {
    let provider: Provider

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: provider.iconName)
                .font(.pretendard(size: 40))
                .foregroundStyle(.secondary)

            Text("\(provider.displayName) Coming Soon")
                .font(.title3.bold())

            Text("Coming in Phase 2")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum StatusBarIcon: String, CaseIterable, Identifiable {
    case brainHeadProfile = "brain.head.profile"
    case brain = "brain"
    case cpu = "cpu"
    case memorychip = "memorychip"
    case gauge = "gauge.with.needle"
    case chartBar = "chart.bar.fill"
    case sparkles = "sparkles"
    case wandAndStars = "wand.and.stars"
    case atom = "atom"
    case function = "function"

    var id: String { rawValue }

    static let `default`: StatusBarIcon = .brainHeadProfile

    var displayName: LocalizedStringKey {
        switch self {
        case .brainHeadProfile: return "Brain Profile (Default)"
        case .brain: return "Brain"
        case .cpu: return "CPU"
        case .memorychip: return "Memory Chip"
        case .gauge: return "Gauge"
        case .chartBar: return "Chart"
        case .sparkles: return "Sparkles"
        case .wandAndStars: return "Wand & Stars"
        case .atom: return "Atom"
        case .function: return "Function"
        }
    }
}

enum StatusBarMetric: String, CaseIterable, Identifiable {
    case session
    case weekly
    case opus = "Opus"
    case sonnet = "Sonnet"
    case haiku = "Haiku"

    var id: String { rawValue }
}

struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("pollingInterval") private var pollingInterval = 90.0
    @AppStorage("statusBarMetric") private var statusBarMetric = "session"
    @AppStorage("statusBarIcon") private var statusBarIcon = StatusBarIcon.default.rawValue
    @AppStorage("iconMode") private var iconMode = "static"
    @AppStorage("includeCacheTokens") private var includeCacheTokens = true
    @State private var showRestartAlert = false

    var body: some View {
        Form {
            Section("Menu Bar Display") {
                Picker("Metric to Display", selection: $statusBarMetric) {
                    Text("Session Usage (5 Hours)").tag("session")
                    Text("Weekly Usage (7 Days)").tag("weekly")
                    Divider()
                    Text("Opus (Weekly)").tag("opus")
                    Text("Sonnet (Weekly)").tag("sonnet")
                    Text("Haiku (Weekly)").tag("haiku")
                }
                .pickerStyle(.menu)

                Text("Select usage % displayed next to the menu bar icon")
                    .font(.pretendard(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Section("Menu Bar Icon") {
                Picker("Icon Mode", selection: $iconMode) {
                    Text("Static (SF Symbol)").tag("static")
                    Divider()
                    ForEach(AnimatedIconTheme.allCases) { theme in
                        Text(theme.localizedName).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.menu)

                if iconMode == "static" {
                    Picker("Icon", selection: $statusBarIcon) {
                        ForEach(StatusBarIcon.allCases) { icon in
                            Label(icon.displayName, systemImage: icon.rawValue)
                                .tag(icon.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                } else {
                    Text("Animation speed changes based on token usage")
                        .font(.pretendard(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Language") {
                Picker("App Language", selection: Binding(
                    get: {
                        UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first ?? "system"
                    },
                    set: { newValue in
                        if newValue == "system" {
                            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                        } else {
                            UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
                        }
                        showRestartAlert = true
                    }
                )) {
                    Text("System Default").tag("system")
                    Divider()
                    Text("English").tag("en")
                    Text("한국어").tag("ko")
                }
                .pickerStyle(.menu)

                Text("Restart the app to apply the language change")
                    .font(.pretendard(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            launchAtLogin = newValue
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                ))
            }

            Section("Token Count") {
                Toggle("Include cached tokens", isOn: $includeCacheTokens)

                Text("When enabled, cached tokens are included in usage counts. Cached tokens count toward rate limits.")
                    .font(.pretendard(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Section("Update Interval") {
                Picker("Polling Interval", selection: $pollingInterval) {
                    Text("30 sec").tag(30.0)
                    Text("60 sec").tag(60.0)
                    Text("90 sec (Default)").tag(90.0)
                    Text("120 sec").tag(120.0)
                    Text("300 sec").tag(300.0)
                }
            }

            Section("Info") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–")
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .alert("Restart Required", isPresented: $showRestartAlert) {
            Button("Restart Now") {
                let url = URL(fileURLWithPath: Bundle.main.bundlePath)
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
                    DispatchQueue.main.async {
                        NSApp.terminate(nil)
                    }
                }
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("The app needs to restart to apply the language change.")
        }
    }
}
