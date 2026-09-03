import XCTest
@testable import LLM_Token_Bar

final class CodexSessionParserRateLimitTests: XCTestCase {
    private var sessionsRoot: URL!
    private let now = Date(timeIntervalSince1970: 1_788_416_400) // 2026-09-03T06:20:00Z
    private let futureReset = 1_788_417_967 // 2026-09-03T06:46:07Z
    private let pastReset = 1_788_400_000   // 2026-09-03T01:46:40Z

    override func setUp() {
        super.setUp()
        sessionsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: sessionsRoot.appendingPathComponent("2026/09/03", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        if let sessionsRoot {
            try? FileManager.default.removeItem(at: sessionsRoot)
        }
        super.tearDown()
    }

    // MARK: - Lookback window

    func testSkipsFilesOlderThanLookbackWindow() throws {
        let staleDate = now.addingTimeInterval(-30 * 24 * 3600)
        try writeRollout("rollout-old.jsonl", lines: [
            tokenCountLine(ts: "2026-08-01T00:00:00.000Z", sessionUsed: 50, sessionResetsAt: pastReset, weeklyUsed: 10)
        ], modifiedAt: staleDate)
        try writeRollout("rollout-new.jsonl", lines: [
            tokenCountLine(ts: "2026-09-03T06:00:00.000Z", sessionUsed: 20, sessionResetsAt: futureReset, weeklyUsed: 40)
        ], modifiedAt: now)

        let report = makeParser().rateLimitReport()

        XCTAssertEqual(report.snapshots.count, 1)
        XCTAssertEqual(report.latest?.limits.sessionLimit?.usedPercent, 20)
    }

    // MARK: - Prefilter

    func testKeepsSnapshotsAmongUnrelatedLines() throws {
        try writeRollout("rollout-mixed.jsonl", lines: [
            sessionMetaLine(ts: "2026-09-03T06:00:00.000Z"),
            noiseLine(ts: "2026-09-03T06:00:01.000Z"),
            tokenCountLine(ts: "2026-09-03T06:00:02.000Z", sessionUsed: 10, sessionResetsAt: futureReset, weeklyUsed: 40),
            noiseLine(ts: "2026-09-03T06:00:03.000Z"),
            "not json at all",
            tokenCountLine(ts: "2026-09-03T06:00:04.000Z", sessionUsed: 12, sessionResetsAt: futureReset, weeklyUsed: 41)
        ], modifiedAt: now)

        let report = makeParser().rateLimitReport()

        XCTAssertEqual(report.snapshots.map { $0.limits.sessionLimit?.usedPercent }, [10, 12])
        XCTAssertEqual(report.latest?.limits.weeklyLimit?.usedPercent, 41)
    }

    // MARK: - Null primary

    func testIgnoresNullPrimarySnapshotsButKeepsNewestNonNull() throws {
        try writeRollout("rollout-limit.jsonl", lines: [
            tokenCountLine(ts: "2026-09-03T06:07:46.000Z", sessionUsed: 93, sessionResetsAt: futureReset, weeklyUsed: 58),
            nullLimitsLine(ts: "2026-09-03T06:07:47.000Z"),
            tokenCountLine(ts: "2026-09-03T06:07:48.000Z", sessionUsed: 100, sessionResetsAt: futureReset, weeklyUsed: 58),
            nullLimitsLine(ts: "2026-09-03T06:07:50.000Z")
        ], modifiedAt: now)

        let report = makeParser().rateLimitReport()

        XCTAssertEqual(report.snapshots.count, 2)
        XCTAssertEqual(report.latest?.limits.sessionLimit?.usedPercent, 100)
        XCTAssertEqual(report.latest?.timestamp, date("2026-09-03T06:07:48.000Z"))
        XCTAssertNil(report.limitReachedAt)
    }

    // MARK: - Limit reached markers

    func testReportsLimitReachedFromUsageLimitError() throws {
        try writeRollout("rollout-limit.jsonl", lines: [
            tokenCountLine(ts: "2026-09-03T06:07:48.000Z", sessionUsed: 100, sessionResetsAt: futureReset, weeklyUsed: 58),
            nullLimitsLine(ts: "2026-09-03T06:12:22.000Z"),
            usageLimitErrorLine(ts: "2026-09-03T06:12:23.000Z")
        ], modifiedAt: now)

        let report = makeParser().rateLimitReport()

        XCTAssertEqual(report.limitReachedAt, date("2026-09-03T06:12:23.000Z"))
        XCTAssertEqual(report.latest?.timestamp, date("2026-09-03T06:07:48.000Z"))
    }

    func testReportsLimitReachedFromRateLimitReachedType() throws {
        try writeRollout("rollout-limit.jsonl", lines: [
            tokenCountLine(
                ts: "2026-09-03T06:07:48.000Z",
                sessionUsed: 100,
                sessionResetsAt: futureReset,
                weeklyUsed: 58,
                reachedType: "primary"
            )
        ], modifiedAt: now)

        let report = makeParser().rateLimitReport()

        XCTAssertEqual(report.limitReachedAt, date("2026-09-03T06:07:48.000Z"))
        XCTAssertEqual(report.latest?.limits.rateLimitReachedType, "primary")
    }

    func testIgnoresMarkerWhenSessionWindowAlreadyReset() throws {
        try writeRollout("rollout-limit.jsonl", lines: [
            tokenCountLine(ts: "2026-09-03T00:30:00.000Z", sessionUsed: 100, sessionResetsAt: pastReset, weeklyUsed: 58),
            usageLimitErrorLine(ts: "2026-09-03T00:31:00.000Z")
        ], modifiedAt: now)

        let report = makeParser().rateLimitReport()

        XCTAssertNil(report.limitReachedAt)
        XCTAssertEqual(report.latest?.limits.sessionLimit?.usedPercent, 100)
    }

    func testIgnoresMarkerOlderThanLatestSnapshot() throws {
        try writeRollout("rollout-limit.jsonl", lines: [
            usageLimitErrorLine(ts: "2026-09-03T05:00:00.000Z"),
            tokenCountLine(ts: "2026-09-03T06:00:00.000Z", sessionUsed: 5, sessionResetsAt: futureReset, weeklyUsed: 58)
        ], modifiedAt: now)

        let report = makeParser().rateLimitReport()

        XCTAssertNil(report.limitReachedAt)
    }

    func testDetectsUsageLimitErrorWithCapitalizedMessage() throws {
        try writeRollout("rollout-limit.jsonl", lines: [
            tokenCountLine(ts: "2026-09-03T06:07:48.000Z", sessionUsed: 100, sessionResetsAt: futureReset, weeklyUsed: 58),
            usageLimitErrorLine(ts: "2026-09-03T06:12:23.000Z", message: "Usage limit reached for this account.")
        ], modifiedAt: now)

        let report = makeParser().rateLimitReport()

        XCTAssertEqual(report.limitReachedAt, date("2026-09-03T06:12:23.000Z"))
    }

    func testReportsLimitReachedForWeeklyOnlyLayout() throws {
        try writeRollout("rollout-weekly.jsonl", lines: [
            weeklyOnlyLine(ts: "2026-09-03T06:07:48.000Z", weeklyUsed: 100, weeklyResetsAt: 1_788_748_909, reachedType: "primary")
        ], modifiedAt: now)

        let report = makeParser().rateLimitReport()

        XCTAssertNil(report.latest?.limits.sessionLimit)
        XCTAssertEqual(report.latest?.limits.weeklyLimit?.usedPercent, 100)
        XCTAssertEqual(report.limitReachedAt, date("2026-09-03T06:07:48.000Z"))
    }

    // MARK: - Timestamps

    func testParsesTimestampsWithoutFractionalSeconds() throws {
        try writeRollout("rollout-plain-ts.jsonl", lines: [
            tokenCountLine(ts: "2026-09-03T06:07:54Z", sessionUsed: 77, sessionResetsAt: futureReset, weeklyUsed: 58)
        ], modifiedAt: now)

        let report = makeParser().rateLimitReport()

        XCTAssertEqual(report.snapshots.count, 1)
        XCTAssertEqual(report.latest?.timestamp, Date(timeIntervalSince1970: 1_788_415_674))
        XCTAssertEqual(report.latest?.limits.sessionLimit?.usedPercent, 77)
    }

    // MARK: - Incremental cache

    func testIncrementalCacheReusesUnchangedFilesAndPicksUpAppendedLines() throws {
        let fileA = try writeRollout("rollout-a.jsonl", lines: [
            tokenCountLine(ts: "2026-09-03T06:00:00.000Z", sessionUsed: 10, sessionResetsAt: futureReset, weeklyUsed: 40)
        ], modifiedAt: now)
        try writeRollout("rollout-b.jsonl", lines: [
            tokenCountLine(ts: "2026-09-03T06:01:00.000Z", sessionUsed: 11, sessionResetsAt: futureReset, weeklyUsed: 40)
        ], modifiedAt: now)
        let parser = makeParser()

        let first = parser.rateLimitReport()
        XCTAssertEqual(parser.parsedRateLimitFileCount, 2)
        XCTAssertEqual(first.latest?.limits.sessionLimit?.usedPercent, 11)

        let second = parser.rateLimitReport()
        XCTAssertEqual(parser.parsedRateLimitFileCount, 2, "unchanged files must not be re-read")
        XCTAssertEqual(second.snapshots.count, 2)

        try appendLine(
            tokenCountLine(ts: "2026-09-03T06:05:00.000Z", sessionUsed: 42, sessionResetsAt: futureReset, weeklyUsed: 45),
            to: fileA,
            modifiedAt: now.addingTimeInterval(60)
        )

        let third = parser.rateLimitReport()
        XCTAssertEqual(parser.parsedRateLimitFileCount, 3, "only the changed file is re-read")
        XCTAssertEqual(third.snapshots.count, 3)
        XCTAssertEqual(third.latest?.limits.sessionLimit?.usedPercent, 42)
    }

    // MARK: - Helpers

    private func makeParser() -> CodexSessionParser {
        CodexSessionParser(basePath: sessionsRoot.path, now: { [now] in now })
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso)!
    }

    @discardableResult
    private func writeRollout(_ name: String, lines: [String], modifiedAt: Date) throws -> URL {
        let url = sessionsRoot.appendingPathComponent("2026/09/03/\(name)")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        return url
    }

    private func appendLine(_ line: String, to url: URL, modifiedAt: Date) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }

    private func tokenCountLine(
        ts: String,
        sessionUsed: Double,
        sessionResetsAt: Int,
        weeklyUsed: Double,
        reachedType: String? = nil
    ) -> String {
        let reached = reachedType.map { "\"\($0)\"" } ?? "null"
        return """
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":5}},"rate_limits":{"limit_id":"premium","primary":{"used_percent":\(sessionUsed),"window_minutes":300,"resets_at":\(sessionResetsAt)},"secondary":{"used_percent":\(weeklyUsed),"window_minutes":10080,"resets_at":1788748909},"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"plan_type":"plus","rate_limit_reached_type":\(reached)}}}
        """
    }

    private func nullLimitsLine(ts: String) -> String {
        """
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"premium","primary":null,"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"plan_type":"plus","rate_limit_reached_type":null}}}
        """
    }

    private func usageLimitErrorLine(
        ts: String,
        message: String = "You've hit your usage limit. Upgrade to Pro or try again at 3:46 PM."
    ) -> String {
        """
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":null,"error":{"message":"\(message)"}}}
        """
    }

    private func weeklyOnlyLine(ts: String, weeklyUsed: Double, weeklyResetsAt: Int, reachedType: String?) -> String {
        let reached = reachedType.map { "\"\($0)\"" } ?? "null"
        return """
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"premium","primary":{"used_percent":\(weeklyUsed),"window_minutes":10080,"resets_at":\(weeklyResetsAt)},"secondary":null,"credits":null,"plan_type":"plus","rate_limit_reached_type":\(reached)}}}
        """
    }

    private func sessionMetaLine(ts: String) -> String {
        """
        {"timestamp":"\(ts)","type":"session_meta","payload":{"id":"session-1","cwd":"/tmp"}}
        """
    }

    private func noiseLine(ts: String) -> String {
        """
        {"timestamp":"\(ts)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"rate_limits are not mentioned here as a key"}]}}
        """
    }
}
