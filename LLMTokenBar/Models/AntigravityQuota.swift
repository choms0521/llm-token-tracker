import Foundation

enum AntigravityQuotaError: Error, Equatable, Sendable {
    case serverNotRunning
    case unreachable
    case badResponse(String)
}

enum AntigravityQuotaWindow: Equatable, Sendable {
    case fiveHour
    case weekly
    case other(String)

    /// 서버가 보낸 창 이름을 분류한다. 모르는 값은 그대로 보존한다.
    init(serverValue: String) {
        switch serverValue.lowercased() {
        case "5h": self = .fiveHour
        case "weekly": self = .weekly
        default: self = .other(serverValue)
        }
    }
}

struct AntigravityQuotaBucket: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let window: AntigravityQuotaWindow
    /// 0~100. remainingFraction이 없으면 아무것도 쓰지 않은 것으로 본다.
    let usedPercent: Double
    let resetsAt: Date?
}

struct AntigravityQuotaGroup: Identifiable, Equatable, Sendable {
    let displayName: String
    let buckets: [AntigravityQuotaBucket]

    var id: String { displayName }

    var isGemini: Bool {
        buckets.contains { $0.id.hasPrefix(Constants.Antigravity.geminiBucketPrefix) }
            || displayName.localizedCaseInsensitiveContains("gemini")
    }

    func bucket(for window: AntigravityQuotaWindow) -> AntigravityQuotaBucket? {
        buckets.first { $0.window == window }
    }
}

struct AntigravityQuotaSummary: Equatable, Sendable {
    let groups: [AntigravityQuotaGroup]
    let fetchedAt: Date

    var geminiGroup: AntigravityQuotaGroup? { groups.first(where: \.isGemini) }
    var otherGroups: [AntigravityQuotaGroup] { groups.filter { !$0.isGemini } }
}

struct AntigravityQuotaFetchResult: Equatable, Sendable {
    let summary: AntigravityQuotaSummary
    let planName: String?
}

// MARK: - Parsing

/// agy 언어 서버 응답을 모델로 바꾼다. 필드 형식이 도구마다 조금씩 달라 관대하게 받는다.
enum AntigravityQuotaParser {
    static func parseSummary(_ data: Data, fetchedAt: Date) throws -> AntigravityQuotaSummary {
        let envelope: SummaryEnvelope
        do {
            envelope = try JSONDecoder().decode(SummaryEnvelope.self, from: data)
        } catch {
            throw AntigravityQuotaError.badResponse(error.localizedDescription)
        }
        guard let response = envelope.response else {
            throw AntigravityQuotaError.badResponse(envelope.message ?? "missing response")
        }
        let groups = (response.groups ?? []).map(Self.group(from:))
        return AntigravityQuotaSummary(groups: groups, fetchedAt: fetchedAt)
    }

    static func parsePlanName(_ data: Data) -> String? {
        let envelope = try? JSONDecoder().decode(UserStatusEnvelope.self, from: data)
        return envelope?.userStatus?.planStatus?.planInfo?.planName
    }

    /// 오류 응답(`{"code":..., "message":...}`)의 메시지. 없으면 nil.
    static func errorMessage(in data: Data) -> String? {
        (try? JSONDecoder().decode(SummaryEnvelope.self, from: data))?.message
    }

    private static func group(from raw: RawGroup) -> AntigravityQuotaGroup {
        let buckets = (raw.buckets ?? [])
            .filter { $0.disabled != true }
            .map(Self.bucket(from:))
        return AntigravityQuotaGroup(displayName: clip(raw.displayName), buckets: buckets)
    }

    private static func bucket(from raw: RawBucket) -> AntigravityQuotaBucket {
        // remainingFraction이 없으면 참조 구현(CodexBar)과 같이 0% 사용으로 본다.
        let remaining = raw.remainingFraction ?? raw.remaining?.remainingFraction ?? 1
        let used = min(max((1 - remaining) * 100, 0), 100)
        return AntigravityQuotaBucket(
            id: clip(raw.bucketId),
            displayName: clip(raw.displayName),
            window: AntigravityQuotaWindow(serverValue: clip(raw.window)),
            usedPercent: used,
            resetsAt: raw.resetTime?.date
        )
    }
}

extension AntigravityQuotaParser {
    /// 서버 문자열은 길이를 제한해 받는다. 없으면 빈 문자열.
    fileprivate static func clip(_ value: String?) -> String {
        String((value ?? "").prefix(Constants.Antigravity.serverStringMaxLength))
    }
}

private struct SummaryEnvelope: Decodable {
    let response: RawSummary?
    let message: String?
}

private struct RawSummary: Decodable {
    let groups: [RawGroup]?
}

private struct RawGroup: Decodable {
    let displayName: String?
    let buckets: [RawBucket]?
}

private struct RawRemaining: Decodable {
    let remainingFraction: Double?
}

private struct RawBucket: Decodable {
    let bucketId: String?
    let displayName: String?
    let window: String?
    let remainingFraction: Double?
    let remaining: RawRemaining?
    let resetTime: RawTimestamp?
    let disabled: Bool?
}

/// ISO-8601(소수점 초 유무 모두)을 먼저 시도하고, 그다음 epoch 초(숫자 또는 숫자 문자열)를 받는다.
private struct RawTimestamp: Decodable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            date = Self.parse(text)
        } else if let seconds = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: seconds)
        } else {
            date = nil
        }
    }

    private static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) {
            return date
        }
        return Double(text).map { Date(timeIntervalSince1970: $0) }
    }
}

private struct UserStatusEnvelope: Decodable {
    let userStatus: RawUserStatus?
}

private struct RawUserStatus: Decodable {
    let planStatus: RawPlanStatus?
}

private struct RawPlanStatus: Decodable {
    let planInfo: RawPlanInfo?
}

private struct RawPlanInfo: Decodable {
    let planName: String?
}
