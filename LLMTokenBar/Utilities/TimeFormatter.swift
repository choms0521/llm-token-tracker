import Foundation

enum TimeFormatter {
    /// 데이터 기준 시각 표시용. 오늘이면 시각만, 아니면 날짜와 시각을 현지 형식으로 돌려준다.
    static func dataTimeString(from date: Date) -> String {
        let template = Calendar.current.isDateInToday(date) ? "jm" : "Mdjm"
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = DateFormatter.dateFormat(
            fromTemplate: template,
            options: 0,
            locale: Locale.current
        ) ?? "HH:mm"
        return formatter.string(from: date)
    }

    static func resetTimeString(from date: Date?) -> String {
        guard let date else { return "" }

        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = DateFormatter.dateFormat(
            fromTemplate: "hmma",
            options: 0,
            locale: Locale.current
        ) ?? "h:mm a"

        if calendar.isDateInToday(date) {
            let timeStr = formatter.string(from: date)
            return String(localized: "Resets today at \(timeStr)")
        }

        if calendar.isDateInTomorrow(date) {
            let timeStr = formatter.string(from: date)
            return String(localized: "Resets tomorrow at \(timeStr)")
        }

        formatter.dateFormat = DateFormatter.dateFormat(
            fromTemplate: "MdEhmma",
            options: 0,
            locale: Locale.current
        ) ?? "MMM d, h:mm a"
        let timeStr = formatter.string(from: date)
        return String(localized: "Resets \(timeStr)")
    }

    static func remainingTimeString(from date: Date?) -> String {
        guard let date else { return "" }

        let now = Date()
        let remaining = date.timeIntervalSince(now)

        guard remaining > 0 else { return String(localized: "Resets soon") }

        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60

        if hours > 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return String(localized: "\(days) days \(remainingHours) hours remaining")
        }

        if hours > 0 {
            return String(localized: "\(hours) hours \(minutes) minutes remaining")
        }

        return String(localized: "\(minutes) minutes remaining")
    }

    static func syncTimeString(from date: Date?) -> String {
        guard let date else { return String(localized: "Never synced") }

        let now = Date()
        let elapsed = now.timeIntervalSince(date)

        if elapsed < 60 {
            return String(localized: "Just synced")
        }

        let minutes = Int(elapsed) / 60
        let hours = minutes / 60

        if hours > 0 {
            return String(localized: "Synced \(hours) hours \(minutes % 60) minutes ago")
        }

        return String(localized: "Synced \(minutes) minutes ago")
    }
}
