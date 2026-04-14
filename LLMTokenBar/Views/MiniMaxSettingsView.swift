import SwiftUI

struct MiniMaxSettingsView: View {
    let syncStatus: SyncStatus

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("MiniMax API")
                    .font(.title2.bold())

                Text("Environment variable based authentication")
                    .foregroundStyle(.secondary)

                syncStatusBanner

                if syncStatus.isConnected {
                    accountDetailsView
                } else {
                    disconnectedGuideView
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var syncStatusBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(syncStatus.isConnected ? .green : .red)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(syncStatus.isConnected ? "API Key Configured" : "Not Configured")
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

            if let token = syncStatus.maskedToken {
                DetailRow(icon: "key", label: "API Key", value: token)
            }

            if let sub = syncStatus.subscription {
                DetailRow(icon: "person.crop.circle", label: "Plan", value: sub)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var disconnectedGuideView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.pretendard(size: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text("MINIMAX_API_KEY environment variable required")
                        .font(.pretendard(size: 11))
                        .foregroundStyle(.secondary)

                    Text("Set the environment variable and restart the app")
                        .font(.pretendard(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Text("export MINIMAX_API_KEY=\"your-api-key\"")
                .font(.system(size: 11, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .textSelection(.enabled)
        }
        .padding(12)
        .background(.blue.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
