import SwiftUI

struct OpenAISettingsView: View {
    private let parser = CodexSessionParser()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Codex CLI")
                    .font(.title2.bold())

                Text("Reads Codex CLI local session data to display token usage")
                    .foregroundStyle(.secondary)
                    .font(.pretendard(size: 12))

                cliStatusBanner
                sessionInfoView
                dataSourceInfo
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cliStatusBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(parser.isCodexCLIInstalled ? .green : .red)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(parser.isCodexCLIInstalled ? "Codex CLI Detected" : "Codex CLI Not Installed")
                    .font(.pretendard(size: 13, weight: .medium))

                Text(parser.isCodexCLIInstalled
                     ? "~/.codex/ directory exists"
                     : "Install and log in to Codex CLI")
                    .font(.pretendard(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(parser.isCodexCLIInstalled ? .green.opacity(0.1) : .red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var sessionInfoView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session Data")
                .font(.pretendard(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            DetailRow(
                icon: "doc.text",
                label: String(localized: "Session Files"),
                value: String(localized: "\(parser.sessionFileCount) files")
            )

            if let lastDate = parser.lastSessionDate {
                DetailRow(
                    icon: "clock",
                    label: String(localized: "Last CLI Usage"),
                    value: TimeFormatter.syncTimeString(from: lastDate)
                )
            }

            DetailRow(
                icon: "arrow.triangle.2.circlepath",
                label: String(localized: "Last Sync"),
                value: TimeFormatter.syncTimeString(from: Date())
            )

            DetailRow(
                icon: "folder",
                label: String(localized: "Data Path"),
                value: "~/.codex/sessions/"
            )
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var dataSourceInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                Text("Data Source Info")
                    .font(.pretendard(size: 12, weight: .medium))
            }

            VStack(alignment: .leading, spacing: 4) {
                BulletText("Parses session logs stored locally by Codex CLI")
                BulletText("View with OpenAI filter in Token Stats tab")
                BulletText("Real-time rate limit queries are not supported")
            }
            .padding(.leading, 4)
        }
        .padding(12)
        .background(.blue.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
