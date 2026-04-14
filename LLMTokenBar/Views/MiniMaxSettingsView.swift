import SwiftUI

struct MiniMaxSettingsView: View {
    let syncStatus: SyncStatus
    let authService: MiniMaxAuthService
    var onResync: () async -> Void = {}

    @State private var apiKeyInput = ""
    @State private var isSaving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("MiniMax API")
                    .font(.title2.bold())

                Text("API key based authentication")
                    .foregroundStyle(.secondary)

                syncStatusBanner

                if syncStatus.isConnected {
                    accountDetailsView
                    actionButtons
                }

                apiKeyInputView
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

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(action: {
                Task { await onResync() }
            }) {
                Label("Resync", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)

            Button(action: {
                authService.clearApiKey()
                Task { await onResync() }
            }) {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    private var apiKeyInputView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: syncStatus.isConnected ? "key.fill" : "key")
                    .foregroundStyle(.purple)
                    .font(.pretendard(size: 12))
                Text(syncStatus.isConnected ? "Update API Key" : "Enter API Key")
                    .font(.pretendard(size: 12, weight: .medium))
            }

            HStack(spacing: 8) {
                SecureField("sk-cp-...", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                Button(action: {
                    guard !apiKeyInput.isEmpty else { return }
                    isSaving = true
                    authService.saveApiKey(apiKeyInput)
                    apiKeyInput = ""
                    Task {
                        await onResync()
                        isSaving = false
                    }
                }) {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(apiKeyInput.isEmpty || isSaving)
            }

            Text("API key is securely stored in Keychain")
                .font(.pretendard(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.purple.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
