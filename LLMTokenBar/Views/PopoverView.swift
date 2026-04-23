import SwiftUI

struct PopoverView: View {
    @ObservedObject var manager: UsagePollingManager
    @ObservedObject var tokenStats: TokenStatsService
    @ObservedObject var displayConfig: ProviderDisplayConfig
    var onOpenSettings: () -> Void
    private let codexParser = CodexSessionParser()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            Divider()
            contentView
        }
        .frame(width: Constants.UI.popoverWidth)
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("LLM Token Bar")
                    .font(.pretendard(size: 14, weight: .bold))

                Spacer()

                Button(action: { onOpenSettings() }) {
                    Image(systemName: "gearshape")
                        .font(.pretendard(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button(action: { manager.refresh() }) {
                    if manager.isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.pretendard(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(manager.isLoading)
            }

            HStack(spacing: 4) {
                Circle()
                    .fill(manager.syncStatus.isConnected ? .green : .red)
                    .frame(width: 6, height: 6)

                Text(manager.syncStatus.isConnected
                     ? "All Systems Operational"
                     : "Disconnected")
                    .font(.pretendard(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var contentView: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(displayConfig.items.filter(\.isEnabled)) { item in
                    providerSection(for: item.provider)
                }

                if !tokenStats.recentModelUsages.isEmpty {
                    modelBreakdownView
                }

                let enabledProviders = displayConfig.enabledProviders()
                let disconnectedProviders = enabledProviders.filter { provider in
                    switch provider {
                    case .claude: return !manager.syncStatus.isConnected
                    case .minimax: return !manager.minimaxSyncStatus.isConnected
                    case .kimi: return !manager.kimiSyncStatus.isConnected
                    case .openai, .gemini: return false
                    }
                }
                if !enabledProviders.isEmpty && disconnectedProviders.count == enabledProviders.count {
                    ForEach(disconnectedProviders, id: \.self) { provider in
                        disconnectedHint(for: provider)
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func providerSection(for provider: Provider) -> some View {
        switch provider {
        case .claude:
            claudeSection
        case .openai:
            codexRateLimitView
        case .minimax:
            minimaxUsageView
        case .kimi:
            kimiUsageView
        case .gemini:
            EmptyView()
        }
    }

    @ViewBuilder
    private var claudeSection: some View {
        if manager.syncStatus.isConnected {
            VStack(alignment: .leading, spacing: 6) {
                providerHeader(name: "Claude", icon: "brain.head.profile", color: .orange)

                if let error = manager.errorMessage {
                    errorBanner(error)
                }

                if let session = manager.claudeUsage.sessionUsage {
                    UsageCardView(entry: session)
                }

                if let weekly = manager.claudeUsage.weeklyUsage {
                    UsageCardView(entry: weekly)
                }
            }
        }
    }

    private var modelBreakdownView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Token Usage (Last 7 Days)")
                .font(.pretendard(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(tokenStats.recentModelUsages) { entry in
                LocalModelUsageRow(entry: entry)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func providerHeader(name: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.pretendard(size: 10))
                .foregroundStyle(color)
            Text(name)
                .font(.pretendard(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var codexRateLimitView: some View {
        if let limits = codexParser.latestRateLimits() {
            VStack(alignment: .leading, spacing: 6) {
                providerHeader(name: "OpenAI Codex", icon: "cpu", color: .green)

                if let primary = limits.primary {
                    let resetDate = primary.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                    let isReset = resetDate.map { $0 < Date() } ?? false
                    UsageCardView(entry: UsageEntry(
                        label: String(localized: "Session Usage (5 Hours)"),
                        sublabel: "Codex \(limits.planType ?? "plus")",
                        utilization: isReset ? 0 : (primary.usedPercent ?? 0),
                        resetsAt: isReset ? nil : resetDate
                    ))
                }

                if let secondary = limits.secondary {
                    let resetDate = secondary.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                    let isReset = resetDate.map { $0 < Date() } ?? false
                    UsageCardView(entry: UsageEntry(
                        label: String(localized: "Weekly Usage (7 Days)"),
                        sublabel: "Codex \(limits.planType ?? "plus")",
                        utilization: isReset ? 0 : (secondary.usedPercent ?? 0),
                        resetsAt: isReset ? nil : resetDate
                    ))
                }
            }
        }
    }

    @ViewBuilder
    private var minimaxUsageView: some View {
        if manager.minimaxSyncStatus.isConnected {
            VStack(alignment: .leading, spacing: 6) {
                providerHeader(name: "MiniMax", icon: "wand.and.stars", color: .purple)

                if let error = manager.minimaxErrorMessage {
                    errorBanner(error)
                }

                if let session = manager.minimaxUsage.sessionUsage {
                    UsageCardView(entry: session)
                }

                if let weekly = manager.minimaxUsage.weeklyUsage {
                    UsageCardView(entry: weekly)
                }
            }
        }
    }

    @ViewBuilder
    private var kimiUsageView: some View {
        if manager.kimiSyncStatus.isConnected {
            VStack(alignment: .leading, spacing: 6) {
                providerHeader(name: "Kimi", icon: "moon.stars", color: .blue)

                if let error = manager.kimiErrorMessage {
                    errorBanner(error)
                }

                if let session = manager.kimiUsage.sessionUsage {
                    UsageCardView(entry: session)
                }

                if let weekly = manager.kimiUsage.weeklyUsage {
                    UsageCardView(entry: weekly)
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.pretendard(size: 11))

            Text(message)
                .font(.pretendard(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func disconnectedHint(for provider: Provider) -> some View {
        VStack(spacing: 8) {
            Image(systemName: provider.iconName)
                .font(.pretendard(size: 24))
                .foregroundStyle(.secondary)

            switch provider {
            case .claude:
                Text("Please log in to Claude CLI")
                    .font(.pretendard(size: 12))
                    .foregroundStyle(.secondary)
                if let statusMessage = manager.syncStatus.statusMessage {
                    Text(statusMessage)
                        .font(.pretendard(size: 10))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                if let suggestion = manager.syncStatus.recoverySuggestion {
                    Text(suggestion)
                        .font(.pretendard(size: 10))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Open Settings > Claude and click Sync Credentials after logging in.")
                        .font(.pretendard(size: 10))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            case .minimax:
                Text("MiniMax API key not configured")
                    .font(.pretendard(size: 12))
                    .foregroundStyle(.secondary)
                Text("Set API key in Settings > MiniMax")
                    .font(.pretendard(size: 10))
                    .foregroundStyle(.tertiary)
            case .kimi:
                Text("Kimi API key not configured")
                    .font(.pretendard(size: 12))
                    .foregroundStyle(.secondary)
                Text("Set API key in Settings > Kimi")
                    .font(.pretendard(size: 10))
                    .foregroundStyle(.tertiary)
            default:
                Text("\(provider.displayName) not connected")
                    .font(.pretendard(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}
