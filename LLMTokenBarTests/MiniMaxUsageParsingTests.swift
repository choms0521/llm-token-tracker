import XCTest
@testable import LLM_Token_Bar

final class MiniMaxUsageParsingTests: XCTestCase {
    private func decode(_ json: String) throws -> MiniMaxUsageResponse {
        try JSONDecoder().decode(MiniMaxUsageResponse.self, from: Data(json.utf8))
    }

    // 2026-06 기준 실제 API 응답: model_name이 "general"/"video"이고
    // count는 0, remaining_percent로 잔여 비율을 제공한다.
    private let currentFormatJSON = """
    {
        "model_remains": [
            {
                "start_time": 1780549200000,
                "end_time": 1780567200000,
                "remains_time": 7060148,
                "current_interval_total_count": 0,
                "current_interval_usage_count": 0,
                "current_weekly_total_count": 0,
                "current_weekly_usage_count": 0,
                "weekly_start_time": 1780272000000,
                "weekly_end_time": 1780876800000,
                "weekly_remains_time": 316660148,
                "model_name": "general",
                "current_interval_remaining_percent": 99,
                "current_weekly_remaining_percent": 80
            },
            {
                "start_time": 1780531200000,
                "end_time": 1780617600000,
                "remains_time": 57460148,
                "current_interval_total_count": 0,
                "current_interval_usage_count": 0,
                "current_weekly_total_count": 0,
                "current_weekly_usage_count": 0,
                "weekly_start_time": 1780272000000,
                "weekly_end_time": 1780876800000,
                "weekly_remains_time": 316660148,
                "model_name": "video",
                "current_interval_remaining_percent": 100,
                "current_weekly_remaining_percent": 100
            }
        ],
        "base_resp": { "status_code": 0, "status_msg": "success" }
    }
    """

    func testSelectsGeneralModel() throws {
        let response = try decode(currentFormatJSON)
        let general = response.modelRemains.first { $0.modelName == Constants.MiniMax.targetModelName }
        XCTAssertNotNil(general, "'general' 모델을 응답에서 찾아야 한다")
        XCTAssertEqual(general?.modelName, "general")
    }

    func testRemainingPercentMapsToUtilization() throws {
        let response = try decode(currentFormatJSON)
        let general = try XCTUnwrap(response.modelRemains.first { $0.modelName == "general" })
        // remaining 99% -> 사용률 1%, remaining 80% -> 사용률 20%
        XCTAssertEqual(general.intervalUtilization, 1.0, accuracy: 0.001)
        XCTAssertEqual(general.weeklyUtilization, 20.0, accuracy: 0.001)
    }

    func testRemainingPercentIsClamped() throws {
        let json = """
        {
            "model_remains": [{
                "start_time": 0, "end_time": 0, "remains_time": 0,
                "current_interval_total_count": 0, "current_interval_usage_count": 0,
                "current_weekly_total_count": 0, "current_weekly_usage_count": 0,
                "weekly_start_time": 0, "weekly_end_time": 0, "weekly_remains_time": 0,
                "model_name": "general",
                "current_interval_remaining_percent": 150,
                "current_weekly_remaining_percent": -10
            }],
            "base_resp": { "status_code": 0, "status_msg": "success" }
        }
        """
        let response = try decode(json)
        let general = try XCTUnwrap(response.modelRemains.first { $0.modelName == "general" })
        // 150 -> clamp 100 -> 사용률 0%, -10 -> clamp 0 -> 사용률 100%
        XCTAssertEqual(general.intervalUtilization, 0.0, accuracy: 0.001)
        XCTAssertEqual(general.weeklyUtilization, 100.0, accuracy: 0.001)
    }

    // 구버전(count 기반) 응답 폴백: remaining_percent가 없으면 count로 계산한다.
    func testLegacyCountFallback() throws {
        let json = """
        {
            "model_remains": [{
                "start_time": 0, "end_time": 0, "remains_time": 0,
                "current_interval_total_count": 4500,
                "current_interval_usage_count": 4050,
                "current_weekly_total_count": 4500,
                "current_weekly_usage_count": 4500,
                "weekly_start_time": 0, "weekly_end_time": 0, "weekly_remains_time": 0,
                "model_name": "general"
            }],
            "base_resp": { "status_code": 0, "status_msg": "success" }
        }
        """
        let response = try decode(json)
        let general = try XCTUnwrap(response.modelRemains.first { $0.modelName == "general" })
        // usage_count는 '잔여 횟수' 의미: total 4500, 잔여 4050 -> 사용 450 -> 10%
        XCTAssertEqual(general.intervalUtilization, 10.0, accuracy: 0.001)
        // 잔여 4500 == total -> 사용 0 -> 0%
        XCTAssertEqual(general.weeklyUtilization, 0.0, accuracy: 0.001)
    }

    func testResetDatesFromMilliseconds() throws {
        let response = try decode(currentFormatJSON)
        let general = try XCTUnwrap(response.modelRemains.first { $0.modelName == "general" })
        XCTAssertEqual(general.intervalResetsAt.timeIntervalSince1970, 1780567200.0, accuracy: 0.001)
        XCTAssertEqual(general.weeklyResetsAt.timeIntervalSince1970, 1780876800.0, accuracy: 0.001)
    }
}
