import XCTest
@testable import LLM_Token_Bar

final class CodexSnapshotFilterTests: XCTestCase {
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

    /// The Codex CLI interleaves two limit buckets in a single log stream:
    /// the main plan (`limit_id: codex`) and the Spark model (`limit_id: codex_bengalfox`),
    /// which has a separate, usually-idle pool. When a Spark snapshot happens to be the
    /// newest by timestamp, the app must still report the main plan's usage, not Spark's.
    func testLatestRateLimitsIgnoresSparkBucket() throws {
        let file = temporaryDirectory.appendingPathComponent("rollout-test.jsonl")
        try makeInterleavedFixture().data(using: .utf8)!.write(to: file)

        let parser = CodexSessionParser(basePath: temporaryDirectory.path)
        let limits = try XCTUnwrap(parser.latestRateLimits())

        // Main plan weekly usage, not the Spark bucket's 0%.
        XCTAssertEqual(limits.weeklyLimit?.usedPercent, 50.0)
    }

    func testAllSnapshotsExcludeSparkBucket() throws {
        let file = temporaryDirectory.appendingPathComponent("rollout-test.jsonl")
        try makeInterleavedFixture().data(using: .utf8)!.write(to: file)

        let parser = CodexSessionParser(basePath: temporaryDirectory.path)
        let snapshots = parser.allRateLimitSnapshots()

        XCTAssertFalse(snapshots.isEmpty)
        for snapshot in snapshots {
            XCTAssertEqual(snapshot.limits.weeklyLimit?.usedPercent, 50.0)
        }
    }

    // MARK: - Fixtures

    /// Session with a Spark snapshot as the newest line, main-plan snapshots earlier.
    private func makeInterleavedFixture() -> String {
        let meta = #"{"timestamp":"2026-09-10T08:00:00.000Z","type":"session_meta","payload":{"id":"test-session-1"}}"#
        let mainEarly = snapshotLine(
            timestamp: "2026-09-10T08:43:39.709Z",
            limitId: "codex",
            limitName: nil,
            primaryPercent: 50.0, primaryWindow: 10080,
            secondary: nil
        )
        let sparkNewest = snapshotLine(
            timestamp: "2026-09-10T08:44:01.838Z",
            limitId: "codex_bengalfox",
            limitName: "GPT-5.3-Codex-Spark",
            primaryPercent: 0.0, primaryWindow: 300,
            secondary: (percent: 0.0, window: 10080)
        )
        return [meta, mainEarly, sparkNewest].joined(separator: "\n") + "\n"
    }

    private func snapshotLine(
        timestamp: String,
        limitId: String,
        limitName: String?,
        primaryPercent: Double,
        primaryWindow: Int,
        secondary: (percent: Double, window: Int)?
    ) -> String {
        let secondaryJSON: String
        if let secondary {
            secondaryJSON = #"{"used_percent":\#(secondary.percent),"window_minutes":\#(secondary.window),"resets_at":1789634631}"#
        } else {
            secondaryJSON = "null"
        }
        let limitNameJSON = limitName.map { #""\#($0)""# } ?? "null"
        return #"""
        {"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"\#(limitId)","limit_name":\#(limitNameJSON),"primary":{"used_percent":\#(primaryPercent),"window_minutes":\#(primaryWindow),"resets_at":1789047831},"secondary":\#(secondaryJSON),"plan_type":"pro"}}}
        """#
    }
}
