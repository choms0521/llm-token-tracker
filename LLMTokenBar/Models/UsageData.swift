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

struct MiniMaxUsageResponse: Decodable {
    let modelRemains: [MiniMaxModelRemain]
    let baseResp: MiniMaxBaseResp

    enum CodingKeys: String, CodingKey {
        case modelRemains = "model_remains"
        case baseResp = "base_resp"
    }
}

struct MiniMaxBaseResp: Decodable {
    let statusCode: Int
    let statusMsg: String

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case statusMsg = "status_msg"
    }
}

struct MiniMaxModelRemain: Decodable {
    let modelName: String
    let startTime: Int64
    let endTime: Int64
    let remainsTime: Int64
    let currentIntervalTotalCount: Int
    let currentIntervalUsageCount: Int
    let currentWeeklyTotalCount: Int
    let currentWeeklyUsageCount: Int
    let weeklyStartTime: Int64
    let weeklyEndTime: Int64
    let weeklyRemainsTime: Int64

    enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case startTime = "start_time"
        case endTime = "end_time"
        case remainsTime = "remains_time"
        case currentIntervalTotalCount = "current_interval_total_count"
        case currentIntervalUsageCount = "current_interval_usage_count"
        case currentWeeklyTotalCount = "current_weekly_total_count"
        case currentWeeklyUsageCount = "current_weekly_usage_count"
        case weeklyStartTime = "weekly_start_time"
        case weeklyEndTime = "weekly_end_time"
        case weeklyRemainsTime = "weekly_remains_time"
    }

    // API 엔드포인트: /coding_plan/remains
    // usage_count 필드는 API 필드명과 달리 실제로는 '잔여 횟수'를 의미함.
    // 예: total=4500, usage_count=4500 → 4500번 남음 → 사용률 0%
    // 실제 API 테스트로 확인된 동작 (2026-04-14)

    var intervalUtilization: Double {
        guard currentIntervalTotalCount > 0 else { return 0 }
        let used = currentIntervalTotalCount - currentIntervalUsageCount
        return Double(used) / Double(currentIntervalTotalCount) * 100.0
    }

    var weeklyUtilization: Double {
        guard currentWeeklyTotalCount > 0 else { return 0 }
        let used = currentWeeklyTotalCount - currentWeeklyUsageCount
        return Double(used) / Double(currentWeeklyTotalCount) * 100.0
    }

    var intervalResetsAt: Date {
        Date(timeIntervalSince1970: Double(endTime) / 1000.0)
    }

    var weeklyResetsAt: Date {
        Date(timeIntervalSince1970: Double(weeklyEndTime) / 1000.0)
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
