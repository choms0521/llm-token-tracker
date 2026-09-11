import SwiftUI

struct GeminiSettingsView: View {
    private let parser = GeminiSessionParser()
    @ObservedObject var antigravity: AntigravityQuotaStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Gemini CLI")
                    .font(.title2.bold())

                Text("Reads Gemini CLI local session data to display token usage")
                    .foregroundStyle(.secondary)
                    .font(.pretendard(size: 12))

                antigravityQuotaInfo
                cliStatusBanner
                sessionInfoView
                dataSourceInfo
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { antigravity.refresh() }
    }

    private var antigravityStatusText: String {
        switch antigravity.status {
        case .checking: return String(localized: "Checking Antigravity CLI (agy)")
        case .connected: return String(localized: "Antigravity CLI (agy) is running")
        case .notRunning: return String(localized: "Antigravity CLI (agy) is not running")
        case .error(let error): return AntigravityQuotaPresentation.title(for: error)
        }
    }

    private var antigravityStatusColor: Color {
        switch antigravity.status {
        case .checking: return .gray
        case .connected: return .green
        case .notRunning: return .red
        case .error: return .orange
        }
    }

    private var antigravityQuotaInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(antigravityStatusColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Antigravity Quota")
                        .font(.pretendard(size: 13, weight: .medium))
                    Text(antigravityStatusText)
                        .font(.pretendard(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let planName = antigravity.planName {
                DetailRow(icon: "person.crop.circle", label: String(localized: "Plan"), value: planName)
            }

            if let fetchedAt = antigravity.lastFetchedAt {
                DetailRow(
                    icon: "clock",
                    label: String(localized: "Last Sync"),
                    value: TimeFormatter.dataTimeString(from: fetchedAt)
                )
            }

            Text("Quota is read from the local agy language server. No login required.")
                .font(.pretendard(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var cliStatusBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(parser.isGeminiCLIInstalled ? .green : .red)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(parser.isGeminiCLIInstalled ? "Gemini CLI Detected" : "Gemini CLI Not Installed")
                    .font(.pretendard(size: 13, weight: .medium))

                Text(parser.isGeminiCLIInstalled
                     ? "~/.gemini/ directory exists"
                     : "Install and log in to Gemini CLI")
                    .font(.pretendard(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(parser.isGeminiCLIInstalled ? .green.opacity(0.1) : .red.opacity(0.1))
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
                value: "~/.gemini/tmp/"
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
                BulletText("Parses session logs stored locally by Gemini CLI")
                BulletText("View with Gemini filter in Token Stats tab")
                BulletText("Antigravity quota is queried from the local agy language server")
            }
            .padding(.leading, 4)
        }
        .padding(12)
        .background(.blue.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
