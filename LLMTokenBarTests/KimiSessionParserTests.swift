import XCTest
@testable import LLM_Token_Bar

final class KimiSessionParserTests: XCTestCase {
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

    // MARK: - Model ID normalization

    func testNormalizeModelIdStripsProviderPrefix() {
        XCTAssertEqual(KimiSessionParser.normalizeModelId("kimi-code/k3"), "kimi-k3")
    }

    func testNormalizeModelIdKeepsExistingKimiPrefix() {
        XCTAssertEqual(KimiSessionParser.normalizeModelId("kimi-code/kimi-for-coding"), "kimi-for-coding")
    }

    func testNormalizeModelIdFallsBackWhenMissing() {
        XCTAssertEqual(KimiSessionParser.normalizeModelId(nil), "kimi-unknown")
        XCTAssertEqual(KimiSessionParser.normalizeModelId("kimi-code/"), "kimi-unknown")
    }

    /// provider 필터는 모델 ID에 "kimi"가 포함되는지로 판별하므로 접두사가 반드시 유지되어야 한다.
    func testNormalizedModelIdAlwaysContainsProviderKeyword() {
        for raw in ["kimi-code/k3", "kimi-code/kimi-for-coding", "k2", nil] {
            XCTAssertTrue(KimiSessionParser.normalizeModelId(raw).contains("kimi"))
        }
    }

    // MARK: - Parsing

    func testParseAggregatesTurnUsageRecords() throws {
        try writeWireFile(
            agent: "main",
            lines: [
                usageRecord(model: "kimi-code/k3", inputOther: 100, output: 50, cacheRead: 1000, cacheCreation: 200),
                usageRecord(model: "kimi-code/k3", inputOther: 20, output: 10, cacheRead: 300, cacheCreation: 0),
            ]
        )

        let parser = KimiSessionParser(basePath: temporaryDirectory.path)
        let result = parser.parse()

        let summary = try XCTUnwrap(result.modelSummaries.first { $0.id == "kimi-k3" })
        XCTAssertEqual(summary.inputTokens, 120)
        XCTAssertEqual(summary.outputTokens, 60)
        XCTAssertEqual(summary.cacheRead, 1300)
        XCTAssertEqual(summary.cacheWrite, 200)

        let entry = try XCTUnwrap(result.dailyTokens.first { $0.modelId == "kimi-k3" })
        XCTAssertEqual(entry.tokens, 1680)          // 120 + 60 + 1300 + 200
        XCTAssertEqual(entry.tokensNoCache, 180)    // 120 + 60
    }

    /// 서브 에이전트의 wire.jsonl도 실제 사용량이므로 함께 집계된다.
    func testParseIncludesSubagentWireFiles() throws {
        try writeWireFile(
            agent: "main",
            lines: [usageRecord(model: "kimi-code/k3", inputOther: 100, output: 0, cacheRead: 0, cacheCreation: 0)]
        )
        try writeWireFile(
            agent: "worker",
            lines: [usageRecord(model: "kimi-code/k3", inputOther: 400, output: 0, cacheRead: 0, cacheCreation: 0)]
        )

        let parser = KimiSessionParser(basePath: temporaryDirectory.path)
        let summary = try XCTUnwrap(parser.parse().modelSummaries.first { $0.id == "kimi-k3" })
        XCTAssertEqual(summary.inputTokens, 500)
    }

    /// 누적 스코프가 추가되더라도 턴 사용량과 중복 합산되어서는 안 된다.
    func testParseIgnoresNonTurnUsageScopes() throws {
        try writeWireFile(
            agent: "main",
            lines: [
                usageRecord(model: "kimi-code/k3", inputOther: 100, output: 0, cacheRead: 0, cacheCreation: 0),
                usageRecord(model: "kimi-code/k3", inputOther: 100, output: 0, cacheRead: 0, cacheCreation: 0, scope: "session"),
            ]
        )

        let parser = KimiSessionParser(basePath: temporaryDirectory.path)
        let summary = try XCTUnwrap(parser.parse().modelSummaries.first { $0.id == "kimi-k3" })
        XCTAssertEqual(summary.inputTokens, 100)
    }

    func testParseSkipsUnrelatedLinesAndZeroUsage() throws {
        try writeWireFile(
            agent: "main",
            lines: [
                #"{"type":"llm.request","model":"k3","time":1784540286301}"#,
                "not json at all",
                usageRecord(model: "kimi-code/k3", inputOther: 0, output: 0, cacheRead: 0, cacheCreation: 0),
            ]
        )

        let parser = KimiSessionParser(basePath: temporaryDirectory.path)
        let result = parser.parse()
        XCTAssertTrue(result.modelSummaries.isEmpty)
        XCTAssertTrue(result.dailyTokens.isEmpty)
    }

    func testParseGroupsEntriesByLocalDay() throws {
        let day1 = Date(timeIntervalSince1970: 1_784_540_305)  // 2026-07-20 (KST 기준 오후)
        let day2 = day1.addingTimeInterval(60 * 60 * 24 * 3)

        try writeWireFile(
            agent: "main",
            lines: [
                usageRecord(model: "kimi-code/k3", inputOther: 100, output: 0, cacheRead: 0, cacheCreation: 0, date: day1),
                usageRecord(model: "kimi-code/k3", inputOther: 200, output: 0, cacheRead: 0, cacheCreation: 0, date: day2),
            ]
        )

        let parser = KimiSessionParser(basePath: temporaryDirectory.path)
        let entries = parser.parse().dailyTokens
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.tokens), [100, 200])
        XCTAssertTrue(entries[0].date < entries[1].date)
    }

    func testParseReturnsEmptyWhenBasePathMissing() {
        let parser = KimiSessionParser(basePath: "/nonexistent")
        let result = parser.parse()
        XCTAssertTrue(result.dailyTokens.isEmpty)
        XCTAssertTrue(result.modelSummaries.isEmpty)
    }

    // MARK: - Helpers

    private func writeWireFile(agent: String, lines: [String]) throws {
        let dir = temporaryDirectory
            .appendingPathComponent("wd_project_abc123", isDirectory: true)
            .appendingPathComponent("session_\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(agent, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("wire.jsonl")
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: file)
    }

    private func usageRecord(
        model: String,
        inputOther: Int,
        output: Int,
        cacheRead: Int,
        cacheCreation: Int,
        scope: String = "turn",
        date: Date = Date(timeIntervalSince1970: 1_784_540_305)
    ) -> String {
        let millis = Int(date.timeIntervalSince1970 * 1000)
        return """
        {"type":"usage.record","model":"\(model)","usage":{"inputOther":\(inputOther),"output":\(output),\
        "inputCacheRead":\(cacheRead),"inputCacheCreation":\(cacheCreation)},"usageScope":"\(scope)","time":\(millis)}
        """
    }
}
