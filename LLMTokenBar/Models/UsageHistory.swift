import Foundation

struct UsageSnapshot: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let provider: Provider
    let sessionUtilization: Double?
    let weeklyUtilization: Double?
    let modelUtilizations: [String: Double] // e.g. "opus": 8.0, "sonnet": 6.0

    init(
        timestamp: Date = Date(),
        provider: Provider,
        sessionUtilization: Double? = nil,
        weeklyUtilization: Double? = nil,
        modelUtilizations: [String: Double] = [:]
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.provider = provider
        self.sessionUtilization = sessionUtilization
        self.weeklyUtilization = weeklyUtilization
        self.modelUtilizations = modelUtilizations
    }
}

enum UsageMetric: String, CaseIterable, Identifiable {
    case session = "세션 사용량"
    case weekly = "주간 사용량"

    var id: String { rawValue }
}

struct ModelMetric: Identifiable, Hashable {
    let provider: Provider
    let modelName: String

    var id: String { "\(provider.rawValue):\(modelName)" }
    var displayName: String { "\(provider.displayName) \(modelName)" }
}

enum TimeRange: String, CaseIterable, Identifiable {
    case oneHour = "1시간"
    case sixHours = "6시간"
    case twentyFourHours = "24시간"
    case sevenDays = "7일"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .oneHour: return 3600
        case .sixHours: return 21600
        case .twentyFourHours: return 86400
        case .sevenDays: return 604800
        }
    }
}
