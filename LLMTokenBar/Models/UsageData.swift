import Foundation

struct UsageData: Equatable {
    let provider: Provider
    let sessionUsage: UsageEntry?
    let weeklyUsage: UsageEntry?
    let modelUsages: [ModelUsage]
    let lastUpdated: Date

    static func empty(for provider: Provider) -> UsageData {
        UsageData(
            provider: provider,
            sessionUsage: nil,
            weeklyUsage: nil,
            modelUsages: [],
            lastUpdated: Date()
        )
    }
}

struct UsageEntry: Equatable {
    let label: String
    let sublabel: String
    let utilization: Double // 0.0 - 100.0
    let resetsAt: Date?
}

struct ModelUsage: Identifiable, Equatable {
    let id: String
    let modelName: String
    let utilization: Double
    let resetsAt: Date?
}

struct ClaudeUsageResponse: Decodable {
    let fiveHour: UsageBucket?
    let sevenDay: UsageBucket?
    let sevenDaySonnet: UsageBucket?
    let sevenDayOpus: UsageBucket?
    let sevenDayHaiku: UsageBucket?
    let sevenDayOauthApps: UsageBucket?
    let sevenDayCowork: UsageBucket?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
        case sevenDayHaiku = "seven_day_haiku"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayCowork = "seven_day_cowork"
        case extraUsage = "extra_usage"
    }
}

struct ExtraUsage: Decodable {
    let isEnabled: Bool?
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }
}

struct UsageBucket: Decodable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetsAtDate: Date? {
        guard let resetsAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: resetsAt) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: resetsAt)
    }
}
