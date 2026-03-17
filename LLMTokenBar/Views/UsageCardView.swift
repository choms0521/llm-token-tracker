import SwiftUI

struct UsageCardView: View {
    let entry: UsageEntry

    private var progressColor: Color {
        if entry.utilization >= 80 {
            return .red
        } else if entry.utilization >= 50 {
            return .orange
        }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(entry.sublabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(Int(entry.utilization))%")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(progressColor)
            }

            ProgressView(value: entry.utilization, total: 100)
                .tint(progressColor)
                .scaleEffect(y: 1.5)

            if let resetsAt = entry.resetsAt {
                Text(TimeFormatter.resetTimeString(from: resetsAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ModelUsageRow: View {
    let model: ModelUsage

    var body: some View {
        HStack {
            Text(model.modelName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()

            ProgressView(value: model.utilization, total: 100)
                .tint(model.utilization >= 50 ? .orange : .green)
                .frame(width: 80)

            Text("\(Int(model.utilization))%")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 36, alignment: .trailing)
        }
    }
}

struct LocalModelUsageRow: View {
    let entry: RecentModelUsage

    var body: some View {
        HStack {
            Text(entry.displayName)
                .font(.system(size: 12))
                .foregroundStyle(.primary)

            Spacer()

            Text(entry.formattedTokens)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
