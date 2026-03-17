import SwiftUI
import Charts

struct UsageHistoryView: View {
    @ObservedObject var historyStore: UsageHistoryStore
    @State private var selectedRange: TimeRange = .twentyFourHours
    @State private var selectedProvider: Provider? = .claude
    @State private var showSession = true
    @State private var showWeekly = true
    @State private var selectedModels: Set<String> = []

    private var filteredSnapshots: [UsageSnapshot] {
        historyStore.snapshots(for: selectedRange, provider: selectedProvider)
    }

    private var availableModels: [ModelMetric] {
        historyStore.availableModels(for: selectedProvider)
    }

    private var dateRange: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "M월 d일, a h:mm"
        let end = Date()
        let start = end.addingTimeInterval(-selectedRange.seconds)
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerView
                providerSelector
                chartSection
                legendView
                metricToggles
            }
            .padding(24)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("사용 기록")
                    .font(.title2.bold())
                Text("시간 경과에 따른 사용량 추적")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $selectedRange) {
                ForEach(TimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 100)
        }
    }

    // MARK: - Provider Selector

    private var providerSelector: some View {
        HStack(spacing: 0) {
            providerTab(nil, label: "전체")
            providerTab(.claude, label: Provider.claude.displayName)
            providerTab(.openai, label: Provider.openai.displayName)
        }
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func providerTab(_ provider: Provider?, label: String) -> some View {
        Button(action: {
            selectedProvider = provider
            selectedModels = []
        }) {
            Text(label)
                .font(.system(size: 12, weight: selectedProvider == provider ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .background(selectedProvider == provider ? Color.accentColor.opacity(0.15) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.xyaxis.line")
                    .foregroundStyle(.secondary)
                Text("사용량 개요")
                    .font(.system(size: 13, weight: .medium))
            }

            if filteredSnapshots.isEmpty {
                emptyChartView
            } else {
                chartView
            }

            Text(dateRange)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var emptyChartView: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.downtrend.xyaxis")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("선택한 범위에 데이터 없음")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("사용량 데이터가 90초마다 자동으로 기록됩니다")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
    }

    private var chartView: some View {
        Chart {
            if showSession {
                ForEach(filteredSnapshots.filter { $0.sessionUtilization != nil }) { s in
                    LineMark(
                        x: .value("시간", s.timestamp),
                        y: .value("사용량", s.sessionUtilization ?? 0),
                        series: .value("유형", "세션")
                    )
                    .foregroundStyle(.orange)
                    .interpolationMethod(.stepEnd)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }

            if showWeekly {
                ForEach(filteredSnapshots.filter { $0.weeklyUtilization != nil }) { s in
                    LineMark(
                        x: .value("시간", s.timestamp),
                        y: .value("사용량", s.weeklyUtilization ?? 0),
                        series: .value("유형", "주간")
                    )
                    .foregroundStyle(.blue)
                    .interpolationMethod(.stepEnd)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }
            }

            ForEach(Array(selectedModels), id: \.self) { modelName in
                let color = colorForModel(modelName)
                ForEach(filteredSnapshots.filter {
                    $0.modelUtilizations[modelName.lowercased()] != nil
                }) { s in
                    LineMark(
                        x: .value("시간", s.timestamp),
                        y: .value("사용량", s.modelUtilizations[modelName.lowercased()] ?? 0),
                        series: .value("유형", modelName)
                    )
                    .foregroundStyle(color)
                    .interpolationMethod(.stepEnd)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)%").font(.system(size: 9))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                AxisValueLabel(format: xAxisFormat).font(.system(size: 9))
            }
        }
        .frame(height: 220)
    }

    private var xAxisFormat: Date.FormatStyle {
        switch selectedRange {
        case .oneHour, .sixHours: return .dateTime.hour().minute()
        case .twentyFourHours: return .dateTime.hour()
        case .sevenDays: return .dateTime.month().day()
        }
    }

    // MARK: - Legend

    private var legendView: some View {
        HStack(spacing: 16) {
            Spacer()
            if showSession {
                legendItem(color: .orange, label: "세션 사용량", dashed: false)
            }
            if showWeekly {
                legendItem(color: .blue, label: "주간 사용량", dashed: true)
            }
            ForEach(Array(selectedModels).sorted(), id: \.self) { name in
                legendItem(color: colorForModel(name), label: name, dashed: false)
            }
            Spacer()
        }
    }

    private func legendItem(color: Color, label: String, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            if dashed {
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 4, height: 2)
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 16, height: 2)
            }
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    // MARK: - Metric Toggles

    private var metricToggles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("표시할 지표")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ToggleChip(label: "세션 사용량", color: .orange, isOn: $showSession)
                ToggleChip(label: "주간 사용량", color: .blue, isOn: $showWeekly)
            }

            if !availableModels.isEmpty {
                Text("모델별")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)

                FlowLayout(spacing: 8) {
                    ForEach(availableModels) { model in
                        let isSelected = selectedModels.contains(model.modelName)
                        let color = colorForModel(model.modelName)

                        Button(action: {
                            if isSelected {
                                selectedModels.remove(model.modelName)
                            } else {
                                selectedModels.insert(model.modelName)
                            }
                        }) {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(isSelected ? color : .gray.opacity(0.3))
                                    .frame(width: 6, height: 6)
                                Text(model.displayName)
                                    .font(.system(size: 11))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(isSelected ? color.opacity(0.1) : .clear)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(
                                    isSelected ? color.opacity(0.3) : .gray.opacity(0.2),
                                    lineWidth: 1
                                )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Helpers

    private func colorForModel(_ name: String) -> Color {
        switch name.lowercased() {
        case "opus": return .purple
        case "sonnet": return .green
        case "haiku": return .teal
        case "flash": return .yellow
        case "pro": return .indigo
        case "gpt-4", "gpt-4o": return .mint
        default: return .gray
        }
    }
}

struct ToggleChip: View {
    let label: String
    let color: Color
    @Binding var isOn: Bool

    var body: some View {
        Button(action: { isOn.toggle() }) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isOn ? color : .gray.opacity(0.3))
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isOn ? color.opacity(0.1) : .clear)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(
                    isOn ? color.opacity(0.3) : .gray.opacity(0.2),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (i, pos) in result.positions.enumerated() {
            subviews[i].place(
                at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (positions, CGSize(width: maxX, height: y + rowHeight))
    }
}
