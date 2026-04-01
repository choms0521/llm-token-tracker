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
    func testReloadParsesClaudeSessionData() async throws {
        let claudeDir = temporaryDirectory.appendingPathComponent("claude-projects", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let sessionFile = claudeDir.appendingPathComponent("test-session.jsonl")
        try makeSampleClaudeJSONL().data(using: .utf8)!.write(to: sessionFile)

        let service = TokenStatsService(
            claudeParser: ClaudeSessionParser(basePath: claudeDir.path),
            geminiParser: GeminiSessionParser(basePath: "/nonexistent"),
            codexParser: CodexSessionParser(basePath: "/nonexistent")
        )
        service.reload()

        let loaded = expectation(description: "Token stats reloaded")
        Task { @MainActor in
            while service.isLoading {
                try? await Task.sleep(for: .milliseconds(50))
            }
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 5.0)

        XCTAssertFalse(service.modelSummaries.isEmpty)
        XCTAssertFalse(service.dailyTokens.isEmpty)

        let opusSummary = service.modelSummaries.first { $0.id == "claude-opus-4-6" }
        XCTAssertNotNil(opusSummary)
        XCTAssertEqual(opusSummary?.inputTokens, 50)
        XCTAssertEqual(opusSummary?.outputTokens, 100)
        XCTAssertEqual(opusSummary?.cacheRead, 1000)
        XCTAssertEqual(opusSummary?.cacheWrite, 200)
    }

    @MainActor
    func testReloadDeduplicatesByMessageId() async throws {
        let claudeDir = temporaryDirectory.appendingPathComponent("claude-projects", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let sessionFile = claudeDir.appendingPathComponent("test-session.jsonl")
        try makeDuplicateMessageJSONL().data(using: .utf8)!.write(to: sessionFile)

        let service = TokenStatsService(
            claudeParser: ClaudeSessionParser(basePath: claudeDir.path),
            geminiParser: GeminiSessionParser(basePath: "/nonexistent"),
            codexParser: CodexSessionParser(basePath: "/nonexistent")
        )
        service.reload()

        let loaded = expectation(description: "Dedup reload completed")
        Task { @MainActor in
            while service.isLoading {
                try? await Task.sleep(for: .milliseconds(50))
            }
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 5.0)

        // Should use last entry's output (500) — final cumulative usage
        let summary = service.modelSummaries.first { $0.id == "claude-opus-4-6" }
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.outputTokens, 500)
    }

    @MainActor
    func testReloadClearsExistingStateWhenNoFiles() async throws {
        let service = TokenStatsService(
            claudeParser: ClaudeSessionParser(basePath: "/nonexistent"),
            geminiParser: GeminiSessionParser(basePath: "/nonexistent"),
            codexParser: CodexSessionParser(basePath: "/nonexistent")
        )

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

        let loaded = expectation(description: "Clear state reload completed")
        Task { @MainActor in
            while service.isLoading {
                try? await Task.sleep(for: .milliseconds(50))
            }
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 5.0)

        XCTAssertTrue(service.modelSummaries.isEmpty)
        XCTAssertTrue(service.dailyTokens.isEmpty)
        XCTAssertEqual(service.totalCost, 0)
    }

    // MARK: - Test Data

    private func makeSampleClaudeJSONL() -> String {
        let ts = ISO8601DateFormatter().string(from: Date())
        return """
        {"timestamp":"\(ts)","message":{"id":"msg_001","model":"claude-opus-4-6","role":"assistant","usage":{"input_tokens":50,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}}}
        {"timestamp":"\(ts)","message":{"id":"msg_002","model":"claude-sonnet-4-6","role":"assistant","usage":{"input_tokens":30,"output_tokens":60,"cache_read_input_tokens":500,"cache_creation_input_tokens":100}}}
        """
    }

    private func makeDuplicateMessageJSONL() -> String {
        let ts = ISO8601DateFormatter().string(from: Date())
        return """
        {"timestamp":"\(ts)","message":{"id":"msg_dup","model":"claude-opus-4-6","role":"assistant","usage":{"input_tokens":50,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}}}
        {"timestamp":"\(ts)","message":{"id":"msg_dup","model":"claude-opus-4-6","role":"assistant","usage":{"input_tokens":50,"output_tokens":500,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}}}
        """
    }
}
