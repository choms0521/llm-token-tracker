import XCTest
@testable import LLM_Token_Bar

final class TokenStatsServiceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        super.tearDown()
    }

    @MainActor
    func testReloadParsesModelSummariesAndDailyTokens() throws {
        let statsURL = temporaryDirectory.appendingPathComponent("stats-cache.json")
        try makeSampleStatsJSON().data(using: .utf8)?.write(to: statsURL)

        let service = TokenStatsService(statsPath: statsURL.path)
        service.reload()

        XCTAssertEqual(service.modelSummaries.count, 2)
        XCTAssertEqual(service.modelSummaries.first?.id, "claude-sonnet-4")
        XCTAssertEqual(service.totalCost, 2.25, accuracy: 0.0001)
        XCTAssertEqual(service.dailyTokens.count, 3)
        XCTAssertEqual(service.recentModelUsages.first?.modelId, "claude-sonnet-4")
    }

    @MainActor
    func testReloadClearsExistingStateWhenFileIsMissing() {
        let statsURL = temporaryDirectory.appendingPathComponent("missing.json")
        let service = TokenStatsService(statsPath: statsURL.path)

        service.modelSummaries = [
            ModelSummary(
                id: "stale",
                displayName: "stale",
                inputTokens: 1,
                outputTokens: 1,
                cacheRead: 1,
                cacheWrite: 1,
                costUSD: 1
            )
        ]
        service.dailyTokens = [
            DailyTokenEntry(id: "stale", date: Date(), modelId: "stale", tokens: 1)
        ]
        service.totalCost = 99

        service.reload()

        XCTAssertTrue(service.modelSummaries.isEmpty)
        XCTAssertTrue(service.dailyTokens.isEmpty)
        XCTAssertEqual(service.totalCost, 0)
    }

    private func makeSampleStatsJSON() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        let today = formatter.string(from: Date())
        let yesterday = formatter.string(from: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())

        return """
        {
          "version": 1,
          "dailyModelTokens": [
            {
              "date": "\(yesterday)",
              "tokensByModel": {
                "claude-sonnet-4": 1200,
                "claude-opus-4-1": 800
              }
            },
            {
              "date": "\(today)",
              "tokensByModel": {
                "claude-sonnet-4": 1500
              }
            }
          ],
          "modelUsage": {
            "claude-opus-4-1": {
              "inputTokens": 100,
              "outputTokens": 200,
              "cacheReadInputTokens": 50,
              "cacheCreationInputTokens": 25,
              "costUSD": 0.75
            },
            "claude-sonnet-4": {
              "inputTokens": 300,
              "outputTokens": 400,
              "cacheReadInputTokens": 150,
              "cacheCreationInputTokens": 75,
              "costUSD": 1.5
            }
          }
        }
        """
    }
}
