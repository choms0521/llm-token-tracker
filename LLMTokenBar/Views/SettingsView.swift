import SwiftUI
import ServiceManagement

enum SettingsTab: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case gemini = "Gemini"
    case openai = "OpenAI"
    case history = "기록"
    case tokens = "토큰 통계"
    case general = "일반"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .claude: return "brain.head.profile"
        case .gemini: return "sparkles"
        case .openai: return "cpu"
        case .history: return "chart.line.uptrend.xyaxis"
        case .tokens: return "number.square"
        case .general: return "gearshape"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var manager: UsagePollingManager
    @ObservedObject var historyStore: UsageHistoryStore
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
            Section("인증 정보") {
                ForEach([SettingsTab.claude, .gemini, .openai], id: \.self) { tab in
                    Label(tab.rawValue, systemImage: tab.iconName)
                        .tag(tab)
                }
            }

            Section("설정") {
                Label("기록", systemImage: "chart.line.uptrend.xyaxis")
                    .tag(SettingsTab.history)
                Label("토큰 통계", systemImage: "number.square")
                    .tag(SettingsTab.tokens)
                Label("일반", systemImage: "gearshape")
                    .tag(SettingsTab.general)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 160)
        .safeAreaInset(edge: .bottom) {
            Button(action: { NSApp.terminate(nil) }) {
                Label("앱 종료", systemImage: "power")
                    .font(.system(size: 12))
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
                onSyncFromCLI: { manager.syncFromCLI() }
            )
        case .gemini:
            GeminiSettingsView()
        case .openai:
            OpenAISettingsView()
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
    var onSyncFromCLI: () -> Void = {}
    @State private var isSyncing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("CLI 계정")
                    .font(.title2.bold())

                Text("로그인된 \(provider.displayName) CLI 계정 동기화")
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
            Text("계정 세부정보")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text("아직 동기화된 자격 증명 없음")
                .font(.system(size: 13))
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
                    .font(.system(size: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude Code CLI에 로그인되어 있어야 합니다")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text("터미널에서 'claude' 명령으로 로그인 후 아래 버튼을 클릭하세요")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Button(action: {
                isSyncing = true
                onSyncFromCLI()
                Task {
                    try? await Task.sleep(for: .seconds(1))
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
                    Text("Keychain에서 동기화")
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
                Text(syncStatus.isConnected ? "CLI 계정 동기화됨" : "연결 안됨")
                    .font(.system(size: 13, weight: .medium))

                if let lastSync = syncStatus.lastSyncedAt {
                    Text(TimeFormatter.syncTimeString(from: lastSync))
                        .font(.system(size: 11))
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
            Text("계정 세부정보")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text("동기화된 CLI 자격 증명")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if let token = syncStatus.maskedToken {
                DetailRow(icon: "key", label: "액세스 토큰", value: token)
            }

            if let sub = syncStatus.subscription {
                DetailRow(icon: "person.crop.circle", label: "구독", value: sub)
            }

            if let tier = syncStatus.rateLimitTier {
                DetailRow(icon: "speedometer", label: "Rate Limit", value: tier)
            }

            if !syncStatus.scopes.isEmpty {
                DetailRow(
                    icon: "checkmark.shield",
                    label: "범위",
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
                Text("CLI 계정 동기화 정보")
                    .font(.system(size: 12, weight: .medium))
            }

            VStack(alignment: .leading, spacing: 4) {
                BulletText("프로필로 CLI 로그인 자동 전환")
                BulletText("CLI 및 앱 계정 동기화 유지")
                BulletText("프로필 전환 시 자격 증명 자동 새로 고침")
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
                Label("다시 동기화", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            Button(action: onDisconnect) {
                Label("제거", systemImage: "trash")
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
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .textSelection(.enabled)
            }
        }
    }
}

struct BulletText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

struct ComingSoonView: View {
    let provider: Provider

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: provider.iconName)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("\(provider.displayName) 지원 예정")
                .font(.title3.bold())

            Text("Phase 2에서 지원될 예정입니다")
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

    var displayName: String {
        switch self {
        case .brainHeadProfile: return "Brain Profile (기본)"
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
    case session = "세션 사용량 (5시간)"
    case weekly = "주간 사용량 (7일)"
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

    var body: some View {
        Form {
            Section("메뉴바 표시") {
                Picker("표시할 지표", selection: $statusBarMetric) {
                    Text("세션 사용량 (5시간)").tag("session")
                    Text("주간 사용량 (7일)").tag("weekly")
                    Divider()
                    Text("Opus (주간)").tag("opus")
                    Text("Sonnet (주간)").tag("sonnet")
                    Text("Haiku (주간)").tag("haiku")
                }
                .pickerStyle(.menu)

                Text("메뉴바 아이콘 옆에 표시되는 사용량 %를 선택합니다")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Section("메뉴바 아이콘") {
                Picker("아이콘", selection: $statusBarIcon) {
                    ForEach(StatusBarIcon.allCases) { icon in
                        Label(icon.displayName, systemImage: icon.rawValue)
                            .tag(icon.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("시작") {
                Toggle("로그인 시 자동 실행", isOn: Binding(
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

            Section("업데이트 주기") {
                Picker("폴링 간격", selection: $pollingInterval) {
                    Text("30초").tag(30.0)
                    Text("60초").tag(60.0)
                    Text("90초 (기본)").tag(90.0)
                    Text("120초").tag(120.0)
                    Text("300초").tag(300.0)
                }
            }

            Section("정보") {
                LabeledContent("버전", value: "1.0.0")
                LabeledContent("빌드", value: "1")
            }
        }
        .formStyle(.grouped)
        .padding(16)
    }
}
