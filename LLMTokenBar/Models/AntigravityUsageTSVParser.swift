import Foundation

/// `agy --print /usage`의 TSV 출력(그룹, 창 이름, 남은 비율, 초기화 시각)을 모델로 바꾼다.
/// 형식이 조금이라도 다르면 0%로 꾸며 내지 않고 badResponse로 거절한다.
enum AntigravityUsageTSVParser {
    private static let columnCount = 4

    static func parse(_ output: String, fetchedAt: Date) throws -> AntigravityQuotaFetchResult {
        // Swift는 "\r\n"을 한 글자로 보므로 줄 나누기 전에 "\n"으로 통일한다.
        var lines = output.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        guard !lines.isEmpty else { throw invalid("empty output") }

        var groupNames: [String] = []
        var bucketsByGroup: [String: [AntigravityQuotaBucket]] = [:]

        for (index, line) in lines.enumerated() {
            let row = index + 1
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count == columnCount else { throw invalid("row \(row): expected \(columnCount) columns") }

            let group = columns[0]
            let label = columns[1]
            guard isValidName(group), isValidName(label) else { throw invalid("row \(row): invalid name") }
            guard let remaining = remainingPercent(columns[2]) else { throw invalid("row \(row): invalid percent") }
            guard let resetsAt = date(columns[3]) else { throw invalid("row \(row): invalid reset time") }

            let window = window(for: label)
            var buckets = bucketsByGroup[group] ?? []
            guard !buckets.contains(where: { $0.window == window }) else {
                throw invalid("row \(row): duplicate window")
            }
            if buckets.isEmpty { groupNames.append(group) }
            buckets.append(AntigravityQuotaBucket(
                id: "\(group)\t\(label)",
                displayName: label,
                window: window,
                usedPercent: 100 - remaining,
                resetsAt: resetsAt
            ))
            bucketsByGroup[group] = buckets
        }

        let groups = groupNames.map { AntigravityQuotaGroup(displayName: $0, buckets: bucketsByGroup[$0] ?? []) }
        return AntigravityQuotaFetchResult(
            summary: AntigravityQuotaSummary(groups: groups, fetchedAt: fetchedAt),
            planName: nil
        )
    }

    private static func invalid(_ reason: String) -> AntigravityQuotaError {
        .badResponse("agy usage output: \(reason)")
    }

    /// 자르면 서로 다른 이름이 합쳐질 수 있으므로, 비었거나 너무 긴 이름은 거절한다.
    private static func isValidName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespaces).isEmpty
            && value.count <= Constants.Antigravity.serverStringMaxLength
    }

    private static func window(for label: String) -> AntigravityQuotaWindow {
        switch label.lowercased() {
        case "weekly limit remaining": return .weekly
        case "five hour limit remaining": return .fiveHour
        default: return .other(label)
        }
    }

    /// "75.5%" 형식만 받는다. 0~100 범위의 유한한 값이 아니면 nil.
    private static func remainingPercent(_ text: String) -> Double? {
        guard text.hasSuffix("%") else { return nil }
        let number = text.dropLast()
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let value = Double(number), value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    private static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
