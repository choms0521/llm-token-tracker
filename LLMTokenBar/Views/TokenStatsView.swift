import SwiftUI
import Charts

enum ChartTimeRange: String, CaseIterable, Identifiable {
    case daily
    case monthly

    var id: String { rawValue }

    var localizedName: LocalizedStringKey {
        switch self {
        case .daily: return "Daily"
        case .monthly: return "Monthly"
        }
    }
}

/// 토큰 통계 상단의 필터 칩. "전체"를 제외한 나머지는 Display 설정의 순서와 표시 여부를 그대로 따른다.
struct ProviderFilter: Identifiable, Equatable {
    static let allID = "all"

    /// nil이면 "전체" 필터.
    let provider: Provider?
    /// Display 설정에서 꺼져 있어 평소에는 감춰 두는 provider.
    let isHidden: Bool

    var id: String { provider?.rawValue ?? Self.allID }

    /// Display 설정의 순서를 그대로 따르되, 꺼진 provider는 시크릿을 해제했을 때만 노출한다.
    /// 노출될 때도 원래 자리에 그대로 끼어들어 두 화면의 순서가 어긋나지 않는다.
    static func makeFilters(
        items: [ProviderDisplayItem],
        showsHiddenProviders: Bool
    ) -> [ProviderFilter] {
        let ordered = items.map {
            ProviderFilter(provider: $0.provider, isHidden: !$0.isEnabled)
        }
        return [ProviderFilter(provider: nil, isHidden: false)]
            + ordered.filter { showsHiddenProviders || !$0.isHidden }
    }
}

struct TokenStatsView: View {
    @ObservedObject var config: ProviderDisplayConfig
    @StateObject private var service = TokenStatsService()
    @State private var selectedMonth: DateComponents = {
        let cal = Calendar.current
        return cal.dateComponents([.year, .month], from: Date())
    }()
    @State private var selectedProvider: String = ProviderFilter.allID
    @State private var chartTimeRange: ChartTimeRange = .daily
    @State private var showsHiddenProviders = false
    @AppStorage("includeCacheTokens") private var includeCacheTokens = true

    private var providerFilters: [ProviderFilter] {
        ProviderFilter.makeFilters(
            items: config.items,
            showsHiddenProviders: showsHiddenProviders
        )
    }

    private var hasHiddenProviders: Bool {
        config.items.contains { !$0.isEnabled }
    }

    private func matchesProvider(_ modelId: String) -> Bool {
        // "전체"는 Display 설정에서 꺼둔 provider의 토큰까지 항상 포함한다.
        guard selectedProvider != ProviderFilter.allID else { return true }
        let provider = selectedProvider
        let id = modelId.lowercased()
        if provider == "openai" {
            return id.hasPrefix("gpt") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") || id.hasPrefix("chatgpt")
        }
        if provider == "minimax" {
            return id.contains("minimax") || id.contains("hailuo")
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
            monthlyMap[key, default: [:]][entry.modelId, default: 0] += entry.effectiveTokens(includeCache: includeCacheTokens)
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
            tokensByModel[entry.modelId, default: 0] += entry.effectiveTokens(includeCache: includeCacheTokens)
        }
        return tokensByModel
            .map { MonthlyModelSummary(id: $0.key, displayName: $0.key, totalTokens: $0.value) }
            .sorted { $0.totalTokens > $1.totalTokens }
    }

    private var filteredTotalTokens: Int {
        filteredModelSummaries.reduce(0) { $0 + $1.totalTokens }
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter
    }()

    private var monthLabel: String {
        guard let date = Calendar.current.date(from: selectedMonth) else { return "" }
        return Self.monthFormatter.string(from: date)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerView
                providerSelector
                todayUsageView
                tokenChart
                modelBreakdown
            }
            .padding(24)
        }
        .overlay {
            if service.isLoading {
                loadingOverlay
            }
        }
        .onAppear { service.reload() }
        .onChange(of: config.items) { _, _ in
            if !showsHiddenProviders {
                resetSelectionIfProviderHidden()
            }
        }
    }

    // MARK: - Loading Overlay

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.15)
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading statistics...")
                    .font(.pretendard(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Token Usage")
                        .font(.title2.bold())
                    Text("Token usage statistics by model (local data)")
                        .font(.pretendard(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Toggle("Include Cache", isOn: $includeCacheTokens)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.pretendard(size: 11))

                Button(action: { service.forceReload() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.pretendard(size: 12))
                }
                .buttonStyle(.plain)
                .disabled(service.isLoading)
            }

            if let lastSync = service.lastSyncedAt {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.pretendard(size: 10))
                    Text("Last synced: \(TimeFormatter.syncTimeString(from: lastSync))")
                        .font(.pretendard(size: 10))
                }
                .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Today Usage

    private var todayEntries: [DailyTokenEntry] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return service.dailyTokens.filter { entry in
            cal.isDate(entry.date, inSameDayAs: today) && matchesProvider(entry.modelId)
        }
    }

    private var todayTokensByModel: [(modelId: String, tokens: Int)] {
        var map: [String: Int] = [:]
        for entry in todayEntries {
            map[entry.modelId, default: 0] += entry.effectiveTokens(includeCache: includeCacheTokens)
        }
        return map.map { (modelId: $0.key, tokens: $0.value) }.sorted { $0.tokens > $1.tokens }
    }

    private var todayTotalTokens: Int {
        todayTokensByModel.reduce(0) { $0 + $1.tokens }
    }

    private var todayUsageView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "clock.fill")
                    .foregroundStyle(.orange)
                    .font(.pretendard(size: 12))
                Text("Today's Usage")
                    .font(.pretendard(size: 13, weight: .medium))
                Spacer()
                Text(formatTokenCount(todayTotalTokens))
                    .font(.pretendardMonospaced(size: 13, weight: .bold))
                    .foregroundStyle(.orange)
            }

            if todayTokensByModel.isEmpty {
                Text("No usage today")
                    .font(.pretendard(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } else {
                ForEach(todayTokensByModel, id: \.modelId) { item in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Self.colorForModelId(item.modelId))
                            .frame(width: 8, height: 8)
                        Text(item.modelId)
                            .font(.pretendard(size: 11, weight: .medium))
                        Spacer()
                        Text(formatTokenCount(item.tokens))
                            .font(.pretendardMonospaced(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Provider Selector

    /// 칩은 고유 너비를 유지하고, provider가 늘어나면 균등 분할 대신 가로 스크롤로 처리한다.
    /// 균등 분할이면 칩이 추가·제거될 때마다 나머지 칩 너비가 함께 변해 화면이 흔들린다.
    private var providerSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(providerFilters) { filter in
                    Button(action: { selectedProvider = filter.id }) {
                        providerFilterLabel(filter)
                    }
                    .buttonStyle(.plain)
                }

                if hasHiddenProviders {
                    Button(action: toggleHiddenProviders) {
                        Image(systemName: "ellipsis")
                            .font(.pretendard(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .background(chipBackground(isSelected: showsHiddenProviders))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(showsHiddenProviders
                          ? "Hide providers turned off in Display settings"
                          : "Show providers turned off in Display settings")
                }
            }
            .padding(3)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .animation(.easeInOut(duration: 0.18), value: showsHiddenProviders)
    }

    private func providerFilterLabel(_ filter: ProviderFilter) -> some View {
        let isSelected = selectedProvider == filter.id
        return ZStack {
            // 선택 시 글꼴이 굵어져도 칩 너비가 변하지 않도록 가장 굵은 상태로 자리를 잡아 둔다.
            filterText(filter)
                .font(.pretendard(size: 12, weight: .semibold))
                .hidden()

            filterText(filter)
                .font(.pretendard(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(filter.isHidden ? .secondary : .primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(chipBackground(isSelected: isSelected))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func filterText(_ filter: ProviderFilter) -> some View {
        if let provider = filter.provider {
            Text(provider.displayName)
        } else {
            Text("All")
        }
    }

    private func chipBackground(isSelected: Bool) -> Color {
        isSelected ? Color.accentColor.opacity(0.15) : .clear
    }

    private func toggleHiddenProviders() {
        showsHiddenProviders.toggle()
        if !showsHiddenProviders {
            resetSelectionIfProviderHidden()
        }
    }

    /// 감춰진 provider가 선택된 채로 칩이 사라져 필터 상태를 되돌릴 수 없게 되는 것을 막는다.
    private func resetSelectionIfProviderHidden() {
        guard let provider = Provider(rawValue: selectedProvider),
              !config.isEnabled(provider) else {
            return
        }
        selectedProvider = ProviderFilter.allID
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
                        Text(range.localizedName).tag(range)
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
                        .font(.pretendard(size: 28))
                        .foregroundStyle(.secondary)
                    Text(chartTimeRange == .daily
                         ? "No data for \(monthLabel)"
                         : "No data")
                        .font(.pretendard(size: 12))
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
                x: .value("Date", entry.date, unit: .day),
                y: .value("Tokens", entry.effectiveTokens(includeCache: includeCacheTokens))
            )
            .foregroundStyle(by: .value("Model", entry.modelId))
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
                            .font(.pretendard(size: 9))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                AxisValueLabel(format: .dateTime.month().day())
                    .font(.pretendard(size: 9))
            }
        }
        .chartLegend(position: .bottom, spacing: 8)
        .frame(height: 300)
    }

    private var monthlyChartContent: some View {
        Chart(monthlyTokenEntries) { entry in
            BarMark(
                x: .value("Month", entry.date, unit: .month),
                y: .value("Tokens", entry.effectiveTokens(includeCache: includeCacheTokens))
            )
            .foregroundStyle(by: .value("Model", entry.modelId))
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
                            .font(.pretendard(size: 9))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                AxisValueLabel(format: .dateTime.year().month(.abbreviated))
                    .font(.pretendard(size: 9))
            }
        }
        .chartLegend(position: .bottom, spacing: 8)
        .frame(height: 300)
    }

    private var monthPicker: some View {
        HStack(spacing: 4) {
            Button(action: { shiftMonth(-1) }) {
                Image(systemName: "chevron.left")
                    .font(.pretendard(size: 10))
            }
            .buttonStyle(.plain)

            Text(monthLabel)
                .font(.pretendard(size: 12, weight: .medium))
                .frame(minWidth: 80)

            Button(action: { shiftMonth(1) }) {
                Image(systemName: "chevron.right")
                    .font(.pretendard(size: 10))
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
                Text("Usage by Model")
                    .font(.pretendard(size: 13, weight: .medium))
                Spacer()
                Text("Total: \(formatTokenCount(filteredTotalTokens))")
                    .font(.pretendard(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
            }

            ForEach(filteredModelSummaries) { model in
                MonthlyModelRow(model: model, totalTokens: filteredTotalTokens)
            }

            if filteredModelSummaries.isEmpty {
                Text("No model data")
                    .font(.pretendard(size: 12))
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
        if id.contains("minimax") || id.contains("hailuo") { return .purple }
        if id.contains("kimi") { return .indigo }
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
                .font(.pretendard(size: 12, weight: .medium))

            Text("(\(String(format: "%.1f", percentage))%)")
                .font(.pretendard(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            Text(formatCount(model.totalTokens))
                .font(.pretendardMonospaced(size: 12, weight: .medium))
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
