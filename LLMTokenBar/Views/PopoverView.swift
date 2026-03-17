import SwiftUI

struct PopoverView: View {
    @ObservedObject var manager: UsagePollingManager
    @ObservedObject var tokenStats: TokenStatsService
    var onOpenSettings: () -> Void

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
                    .font(.system(size: 14, weight: .bold))

                Spacer()

                Button(action: { onOpenSettings() }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
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
                            .font(.system(size: 12))
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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var contentView: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let error = manager.errorMessage {
                    errorBanner(error)
                }

                if let session = manager.claudeUsage.sessionUsage {
                    UsageCardView(entry: session)
                }

                if let weekly = manager.claudeUsage.weeklyUsage {
                    UsageCardView(entry: weekly)
                }

                if !manager.syncStatus.isConnected {
                    disconnectedView
                }
            }
            .padding(12)
        }
    }

    private var modelBreakdownView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("모델별 사용량 (최근 7일)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(tokenStats.recentModelUsages) { entry in
                LocalModelUsageRow(entry: entry)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 11))

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var disconnectedView: some View {
        VStack(spacing: 8) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)

            Text("Claude CLI에 로그인하세요")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text("~/.claude/.credentials.json 파일이 필요합니다")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}
