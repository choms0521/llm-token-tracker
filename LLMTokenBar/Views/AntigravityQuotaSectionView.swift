import SwiftUI

/// 오류를 사용자에게 보여줄 문구로 바꾼다. 서버 메시지는 보조 문구로만, 길이를 제한해 보여준다.
enum AntigravityQuotaPresentation {
    static func title(for error: AntigravityQuotaError) -> String {
        switch error {
        case .serverNotRunning: return String(localized: "Antigravity CLI (agy) is not running")
        case .unreachable: return String(localized: "Could not reach the agy language server")
        case .badResponse: return String(localized: "agy returned an unexpected response")
        }
    }

    static func detail(for error: AntigravityQuotaError) -> String? {
        guard case .badResponse(let message) = error, !message.isEmpty else { return nil }
        return String(message.prefix(Constants.Antigravity.errorDetailMaxLength))
    }

    /// 서버와 끊긴 채 마지막 값을 보여줄 때의 안내 문구. 연결 중이면 nil.
    static func staleBanner(status: AntigravityConnectionStatus, timeString: String) -> String? {
        switch status {
        case .connected, .checking:
            return nil
        case .notRunning:
            return String(localized: "agy not running — showing values from \(timeString)")
        case .error(let error):
            let reason = title(for: error)
            return String(localized: "Refresh failed: \(reason) — showing values from \(timeString)")
        }
    }

    struct BucketRow: Identifiable {
        let id: String
        let bucket: AntigravityQuotaBucket
    }

    struct GroupRow: Identifiable {
        let id: String
        let group: AntigravityQuotaGroup
    }

    /// 그룹 이름이 겹쳐도 ForEach 식별자가 겹치지 않도록 순번을 붙인다.
    static func groupRows(for groups: [AntigravityQuotaGroup]) -> [GroupRow] {
        groups.enumerated().map { index, group in
            GroupRow(id: "\(index)-\(group.displayName)", group: group)
        }
    }

    /// 5시간·주간 창이 하나라도 있으면 카드로, 아니면 목록으로 그린다.
    static func showsAsCards(_ group: AntigravityQuotaGroup) -> Bool {
        group.bucket(for: .fiveHour) != nil || group.bucket(for: .weekly) != nil
    }

    /// bucketId가 비어 있어도 ForEach 식별자가 겹치지 않도록 그룹 이름과 순번으로 대체한다.
    static func rows(for group: AntigravityQuotaGroup) -> [BucketRow] {
        group.buckets.enumerated().map { index, bucket in
            BucketRow(id: bucket.id.isEmpty ? "\(group.displayName)-\(index)" : bucket.id, bucket: bucket)
        }
    }
}

/// 팝오버의 Gemini(Antigravity) 구역. agy 언어 서버에서 받은 한도를 그린다.
struct AntigravityQuotaSectionView: View {
    @ObservedObject var store: AntigravityQuotaStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if let summary = store.summary {
                groupCards(summary)
                    .opacity(store.isStale ? Constants.UI.staleContentOpacity : 1)
                footer
            } else {
                statusPlaceholder
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: Provider.gemini.iconName)
                .font(.pretendard(size: 10))
                .foregroundStyle(.blue)
            Text(verbatim: "Gemini (Antigravity)")
                .font(.pretendard(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func groupCards(_ summary: AntigravityQuotaSummary) -> some View {
        if summary.groups.isEmpty {
            hintBox(primary: String(localized: "No quota data"), secondary: nil)
        }

        if let gemini = summary.geminiGroup {
            if AntigravityQuotaPresentation.showsAsCards(gemini) {
                if let session = store.sessionBucket(in: gemini) {
                    card(session, label: String(localized: "Session Usage (5 Hours)"))
                }
                if let weekly = store.weeklyBucket(in: gemini) {
                    card(weekly, label: String(localized: "Weekly Usage (7 Days)"))
                }
            } else {
                compactGroup(gemini)
            }
        }

        ForEach(AntigravityQuotaPresentation.groupRows(for: summary.otherGroups)) { row in
            compactGroup(row.group)
        }
    }

    private func card(_ bucket: AntigravityQuotaBucket, label: String) -> some View {
        UsageCardView(entry: UsageEntry(
            label: label,
            sublabel: sublabel,
            utilization: bucket.usedPercent,
            resetsAt: bucket.resetsAt
        ))
    }

    private var sublabel: String {
        store.planName.map { "Antigravity \($0)" } ?? "Antigravity"
    }

    private func compactGroup(_ group: AntigravityQuotaGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.displayName)
                .font(.pretendard(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(AntigravityQuotaPresentation.rows(for: group)) { row in
                ModelUsageRow(model: ModelUsage(
                    id: row.id,
                    modelName: Self.windowLabel(row.bucket.window),
                    utilization: row.bucket.usedPercent,
                    resetsAt: row.bucket.resetsAt
                ))
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusPlaceholder: some View {
        switch store.status {
        case .checking:
            hintBox(primary: String(localized: "Checking Antigravity CLI (agy)"), secondary: nil)
        case .notRunning:
            hintBox(
                primary: String(localized: "Antigravity CLI (agy) is not running"),
                secondary: String(localized: "Start agy to see quota")
            )
        case .error(let error):
            hintBox(
                primary: AntigravityQuotaPresentation.title(for: error),
                secondary: AntigravityQuotaPresentation.detail(for: error)
            )
        case .connected:
            EmptyView()
        }
    }

    private func hintBox(primary: String, secondary: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(primary)
                .font(.pretendard(size: 11))
                .foregroundStyle(.secondary)
            if let secondary {
                Text(secondary)
                    .font(.pretendard(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 표시 중인 값의 기준 시각. 서버와 끊겼으면 낡은 값임을 알린다.
    private var footer: some View {
        HStack(spacing: 6) {
            if let fetchedAt = store.lastFetchedAt {
                let timeString = TimeFormatter.dataTimeString(from: fetchedAt)
                let banner = AntigravityQuotaPresentation.staleBanner(status: store.status, timeString: timeString)
                Text(banner ?? String(localized: "As of \(timeString)"))
                    .font(.pretendard(size: 10))
                    .foregroundStyle(banner == nil ? Color.secondary : Color.orange)
            }

            if store.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 4)
    }

    private static func windowLabel(_ window: AntigravityQuotaWindow) -> String {
        switch window {
        case .fiveHour: return String(localized: "5 Hours")
        case .weekly: return String(localized: "Weekly")
        case .other(let raw): return raw
        }
    }
}
