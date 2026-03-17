import Foundation

enum TimeFormatter {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        return formatter
    }()

    static func resetTimeString(from date: Date?) -> String {
        guard let date else { return "" }

        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            dateFormatter.dateFormat = "a h:mm"
            let timeStr = dateFormatter.string(from: date)
            return "Today \(timeStr) 리셋"
        }

        if calendar.isDateInTomorrow(date) {
            dateFormatter.dateFormat = "a h:mm"
            let timeStr = dateFormatter.string(from: date)
            return "Tomorrow \(timeStr) 리셋"
        }

        dateFormatter.dateFormat = "M월 d일, a h:mm"
        let timeStr = dateFormatter.string(from: date)
        return "\(timeStr) 리셋"
    }

    static func remainingTimeString(from date: Date?) -> String {
        guard let date else { return "" }

        let now = Date()
        let remaining = date.timeIntervalSince(now)

        guard remaining > 0 else { return "곧 리셋" }

        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60

        if hours > 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return "\(days)일 \(remainingHours)시간 남음"
        }

        if hours > 0 {
            return "\(hours)시간 \(minutes)분 남음"
        }

        return "\(minutes)분 남음"
    }

    static func syncTimeString(from date: Date?) -> String {
        guard let date else { return "동기화 안됨" }

        let now = Date()
        let elapsed = now.timeIntervalSince(date)

        if elapsed < 60 {
            return "방금 동기화됨"
        }

        let minutes = Int(elapsed) / 60
        let hours = minutes / 60

        if hours > 0 {
            return "\(hours)시간 \(minutes % 60)분 전 동기화"
        }

        return "\(minutes)분 전 동기화"
    }
}
