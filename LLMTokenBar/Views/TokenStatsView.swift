import SwiftUI
import Charts

enum ChartTimeRange: String, CaseIterable, Identifiable {
    case daily = "일별"
    case monthly = "월별"

    var id: String { rawValue }
}

struct TokenStatsView: View {
    @StateObject private var service = TokenStatsService()
    @State private var selectedMonth: DateComponents = {
        let cal = Calendar.current
        return cal.dateComponents([.year, .month], from: Date())
    }()
    @State private var selectedProvider: String? = nil
    @State private var chartTimeRange: ChartTimeRange = .daily

    private static let providerFilters: [(id: String?, label: String)] = [
        (nil, "전체"),
        ("claude", "Claude"),
        ("gemini", "Gemini"),
        ("openai", "OpenAI"),
    ]

    private func matchesProvider(_ modelId: String) -> Bool {
        guard let provider = selectedProvider else { return true }
        let id = modelId.lowercased()
        if provider == "openai" {
            return id.hasPrefix("gpt") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") || id.hasPrefix("chatgpt")
        }
        return id.contains(provider)
    }

    // MARK: - Daily filtered data

    private var filteredDailyTokens: [DailyTokenEntry] {
        let cal = Calendar.current
        return service.dailyTokens.filter { entry in
            let dc = cal.dateComponents([.year, .month], from: entry.date)
            return dc.year == selectedMonth.year
                && dc.month == selectedMonth.month
                && matchesProvider(entry.modelId)
        }
    }

    // MARK: - Monthly aggregated data

    private var monthlyTokenEntries: [DailyTokenEntry] {
        let cal = Calendar.current
        let filtered = service.dailyTokens.filter { matchesProvider($0.modelId) }

        var monthlyMap: [String: [String: Int]] = [:]
        for entry in filtered {
            let dc = cal.dateComponents([.year, .month], from: entry.date)
            guard let year = dc.year, let month = dc.month else { continue }
            let key = String(format: "%04d-%02d", year, month)
            monthlyMap[key, default: [:]][entry.modelId, default: 0] += entry.tokens
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM"

        return monthlyMap.flatMap { (monthStr, models) -> [DailyTokenEntry] in
            guard let date = dateFormatter.date(from: monthStr) else { return [] }
            return models.map { (modelId, tokens) in
                DailyTokenEntry(
                    id: "\(monthStr)-\(modelId)",
                    date: date,
                    modelId: modelId,
                    tokens: tokens
                )
            }
        }.sorted { $0.date < $1.date }
    }

    private var currentChartData: [DailyTokenEntry] {
        chartTimeRange == .daily ? filteredDailyTokens : monthlyTokenEntries
    }

    private var filteredModelSummaries: [MonthlyModelSummary] {
        let source = chartTimeRange == .daily ? filteredDailyTokens : monthlyTokenEntries
        var tokensByModel: [String: Int] = [:]
        for entry in source {
            tokensByModel[entry.modelId, default: 0] += entry.tokens
        }
        return tokensByModel
            .map { MonthlyModelSummary(id: $0.key, displayName: $0.key, totalTokens: $0.value) }
            .sorted { $0.totalTokens > $1.totalTokens }
    }

    private var filteredTotalTokens: Int {
        filteredModelSummaries.reduce(0) { $0 + $1.totalTokens }
    }

    private var monthLabel: String {
        guard let year = selectedMonth.year, let month = selectedMonth.month else {
            return ""
        }
        return "\(year)년 \(month)월"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerView
                providerSelector
                tokenChart
                modelBreakdown
            }
            .padding(24)
        }
        .onAppear { service.reload() }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("토큰 사용량")
                    .font(.title2.bold())
                Text("모델별 토큰 사용 통계 (로컬 데이터)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { service.reload() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Provider Selector

    private var providerSelector: some View {
        HStack(spacing: 0) {
            ForEach(Self.providerFilters, id: \.label) { filter in
                Button(action: { selectedProvider = filter.id }) {
                    Text(filter.label)
                        .font(.system(size: 12, weight: selectedProvider == filter.id ? .semibold : .regular))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .background(selectedProvider == filter.id ? Color.accentColor.opacity(0.15) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Chart

    private var tokenChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(.secondary)

                // Time range toggle
                Picker("", selection: $chartTimeRange) {
                    ForEach(ChartTimeRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 120)

                Spacer()

                if chartTimeRange == .daily {
                    monthPicker
                }
            }

            if currentChartData.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(chartTimeRange == .daily ? "\(monthLabel) 데이터 없음" : "데이터 없음")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 300)
                .frame(maxWidth: .infinity)
            } else if chartTimeRange == .daily {
                dailyChartContent
            } else {
                monthlyChartContent
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var dailyChartContent: some View {
        Chart(filteredDailyTokens) { entry in
            BarMark(
                x: .value("날짜", entry.date, unit: .day),
                y: .value("토큰", entry.tokens)
            )
            .foregroundStyle(by: .value("모델", entry.modelId))
        }
        .chartForegroundStyleScale { (modelId: String) -> Color in
            Self.colorForModelId(modelId)
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text(formatTokenCount(v))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                AxisValueLabel(format: .dateTime.month().day())
                    .font(.system(size: 9))
            }
        }
        .chartLegend(position: .bottom, spacing: 8)
        .frame(height: 300)
    }

    private var monthlyChartContent: some View {
        Chart(monthlyTokenEntries) { entry in
            BarMark(
                x: .value("월", entry.date, unit: .month),
                y: .value("토큰", entry.tokens)
            )
            .foregroundStyle(by: .value("모델", entry.modelId))
        }
        .chartForegroundStyleScale { (modelId: String) -> Color in
            Self.colorForModelId(modelId)
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text(formatTokenCount(v))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                AxisValueLabel(format: .dateTime.year().month(.abbreviated))
                    .font(.system(size: 9))
            }
        }
        .chartLegend(position: .bottom, spacing: 8)
        .frame(height: 300)
    }

    private var monthPicker: some View {
        HStack(spacing: 4) {
            Button(action: { shiftMonth(-1) }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)

            Text(monthLabel)
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 80)

            Button(action: { shiftMonth(1) }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .disabled(isCurrentMonth)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var isCurrentMonth: Bool {
        let cal = Calendar.current
        let now = cal.dateComponents([.year, .month], from: Date())
        return selectedMonth.year == now.year && selectedMonth.month == now.month
    }

    private func shiftMonth(_ delta: Int) {
        let cal = Calendar.current
        guard let date = cal.date(from: selectedMonth),
              let newDate = cal.date(byAdding: .month, value: delta, to: date) else {
            return
        }
        selectedMonth = cal.dateComponents([.year, .month], from: newDate)
    }

    // MARK: - Model Breakdown

    private var modelBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("모델별 사용량")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("합계: \(formatTokenCount(filteredTotalTokens))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
            }

            ForEach(filteredModelSummaries) { model in
                MonthlyModelRow(model: model, totalTokens: filteredTotalTokens)
            }

            if filteredModelSummaries.isEmpty {
                Text("모델 데이터 없음")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    static func colorForModelId(_ id: String) -> Color {
        if id.contains("opus-4-6") { return .orange }
        if id.contains("opus-4-5") { return .red }
        if id.contains("opus-4-1") { return .pink }
        if id.contains("sonnet") { return .purple }
        if id.contains("haiku") { return .teal }
        if id.contains("gemini") && id.contains("flash") { return .blue }
        if id.contains("gemini") && id.contains("pro") { return .cyan }
        if id.contains("gpt") { return .green }
        if id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") { return .mint }
        return .gray
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

struct MonthlyModelSummary: Identifiable {
    let id: String
    let displayName: String
    let totalTokens: Int
}

struct MonthlyModelRow: View {
    let model: MonthlyModelSummary
    let totalTokens: Int

    private var percentage: Double {
        totalTokens > 0 ? Double(model.totalTokens) / Double(totalTokens) * 100 : 0
    }

    var body: some View {
        HStack {
            Circle()
                .fill(TokenStatsView.colorForModelId(model.id))
                .frame(width: 8, height: 8)

            Text(model.displayName)
                .font(.system(size: 12, weight: .medium))

            Text("(\(String(format: "%.1f", percentage))%)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            Text(formatCount(model.totalTokens))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
