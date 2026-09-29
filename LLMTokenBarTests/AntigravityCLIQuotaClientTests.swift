import XCTest
@testable import LLM_Token_Bar

/// 받은 호출을 기록하고 정해 둔 결과를 돌려주는 가짜 실행기.
private final class FakeCommandRunner: AntigravityCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: Result<AntigravityCommandResult, Error>
    private var storedInvocations: [AntigravityCommandInvocation] = []

    init(_ outcome: Result<AntigravityCommandResult, Error>) {
        self.outcome = outcome
    }

    var invocations: [AntigravityCommandInvocation] {
        lock.withLock { storedInvocations }
    }

    func run(_ invocation: AntigravityCommandInvocation) async throws -> AntigravityCommandResult {
        lock.withLock { storedInvocations.append(invocation) }
        return try outcome.get()
    }
}

final class AntigravityCLIQuotaClientTests: XCTestCase {
    private let agyURL = URL(fileURLWithPath: "/Users/tester/.local/bin/agy")
    private let fetchedAt = Date(timeIntervalSince1970: 1_790_000_000)
    private let sampleOutput = """
        Gemini Models\tFive hour limit remaining\t80%\t2026-09-29T12:00:00Z
        Gemini Models\tWeekly limit remaining\t55%\t2026-10-03T00:00:00Z

        """

    private func makeClient(
        runner: FakeCommandRunner,
        executable: URL?
    ) -> AntigravityCLIQuotaClient {
        let fetchedAt = self.fetchedAt
        return AntigravityCLIQuotaClient(
            runner: runner,
            locateExecutable: { executable },
            environment: ["HOME": "/Users/tester", "PATH": "/usr/bin:/bin"],
            now: { fetchedAt }
        )
    }

    private func success(_ output: String, status: Int32 = 0) -> FakeCommandRunner {
        FakeCommandRunner(.success(AntigravityCommandResult(exitStatus: status, output: Data(output.utf8))))
    }

    private func assertThrows(
        _ expected: AntigravityQuotaError,
        from client: AntigravityCLIQuotaClient,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await client.fetchQuota()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AntigravityQuotaError, expected, file: file, line: line)
        }
    }

    func testRunsFixedUsageCommandWithoutShell() async throws {
        let runner = success(sampleOutput)

        _ = try await makeClient(runner: runner, executable: agyURL).fetchQuota()

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(invocation.executableURL, agyURL)
        XCTAssertEqual(invocation.arguments, ["--print", "/usage"])
        XCTAssertEqual(invocation.timeout, Constants.Antigravity.cliTimeout)
        XCTAssertEqual(invocation.environment, ["HOME": "/Users/tester", "PATH": "/usr/bin:/bin"])
    }

    func testRunsOutsideTheRepositoryInTemporaryDirectory() async throws {
        let runner = success(sampleOutput)

        _ = try await makeClient(runner: runner, executable: agyURL).fetchQuota()

        let directory = try XCTUnwrap(runner.invocations.first?.workingDirectory)
        XCTAssertEqual(directory.standardizedFileURL, FileManager.default.temporaryDirectory.standardizedFileURL)
    }

    func testParsesOutputThroughTSVParser() async throws {
        let result = try await makeClient(runner: success(sampleOutput), executable: agyURL).fetchQuota()

        let expected = try AntigravityUsageTSVParser.parse(sampleOutput, fetchedAt: fetchedAt)
        XCTAssertEqual(result, expected)
        XCTAssertEqual(result.summary.groups.first?.buckets.count, 2)
        XCTAssertNil(result.planName)
        XCTAssertEqual(result.summary.fetchedAt, fetchedAt)
    }

    func testMissingBinaryMeansNotRunningAndLaunchesNothing() async {
        let runner = success(sampleOutput)

        await assertThrows(.serverNotRunning, from: makeClient(runner: runner, executable: nil))
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testNonZeroExitIsBadResponseWithoutOutput() async {
        let runner = success("secret-looking diagnostic", status: 2)

        await assertThrows(.badResponse("agy exited with status 2"), from: makeClient(runner: runner, executable: agyURL))
    }

    func testMalformedOutputIsBadResponse() async {
        let client = makeClient(runner: success("not a table"), executable: agyURL)

        do {
            _ = try await client.fetchQuota()
            XCTFail("expected badResponse")
        } catch {
            guard case .badResponse? = error as? AntigravityQuotaError else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testRunnerFailuresMapToStableErrors() async {
        let cases: [(AntigravityCommandError, AntigravityQuotaError)] = [
            (.launchFailed, .unreachable),
            (.timedOut, .unreachable),
            (.outputLimitExceeded, .badResponse("agy output exceeded the size limit")),
            (.incompleteOutput, .badResponse("agy output did not finish")),
        ]
        for (runnerError, expected) in cases {
            let runner = FakeCommandRunner(.failure(runnerError))
            await assertThrows(expected, from: makeClient(runner: runner, executable: agyURL))
        }
    }

    /// agy 실행 한 번이 수 초 걸리므로 성공 시 폴링은 5분으로 둔다. 수동 갱신은 여전히 즉시 실행된다.
    func testSuccessPollingIntervalIsFiveMinutes() {
        XCTAssertEqual(Constants.Antigravity.pollInterval, 300)
        XCTAssertGreaterThan(Constants.Antigravity.pollInterval, Constants.Antigravity.cliTimeout * 10)
    }

    func testCancellationPassesThrough() async {
        let client = makeClient(runner: FakeCommandRunner(.failure(CancellationError())), executable: agyURL)

        do {
            _ = try await client.fetchQuota()
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

private struct CancelledClient: AntigravityQuotaFetching {
    func fetchQuota() async throws -> AntigravityQuotaFetchResult {
        throw CancellationError()
    }
}

@MainActor
final class AntigravityQuotaStoreCancellationTests: XCTestCase {
    func testCancelledRefreshLeavesStatusUnchangedAndAllowsNextRefresh() async throws {
        let store = AntigravityQuotaStore(client: CancelledClient())

        store.refresh()
        for _ in 0..<100 where store.isRefreshing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(store.isRefreshing)
        XCTAssertEqual(store.status, .checking)
    }
}

/// 설치된 실제 agy를 실행하는 선택형 통합 테스트. LLM_TOKEN_BAR_LIVE_AGY=1일 때만 돈다.
/// 네트워크를 쓰고 몇 초 걸리므로 기본 테스트 실행에서는 건너뛴다. 개수만 기록하고 계정 정보는 남기지 않는다.
final class AntigravityCLIQuotaClientLiveTests: XCTestCase {
    func testLiveUsageReportHasGeminiWindows() async throws {
        guard ProcessInfo.processInfo.environment["LLM_TOKEN_BAR_LIVE_AGY"] == "1" else {
            throw XCTSkip("Set LLM_TOKEN_BAR_LIVE_AGY=1 to run against the installed agy CLI")
        }
        let startedAt = Date()

        let result = try await AntigravityCLIQuotaClient().fetchQuota()

        let summary = result.summary
        let buckets = summary.groups.flatMap(\.buckets)
        XCTAssertFalse(summary.groups.isEmpty)
        XCTAssertNotNil(summary.geminiGroup)
        XCTAssertFalse(summary.geminiGroup?.buckets.isEmpty ?? true)
        XCTAssertGreaterThanOrEqual(summary.fetchedAt, startedAt)
        for bucket in buckets {
            XCTAssertTrue((0...100).contains(bucket.usedPercent), "usedPercent out of range")
            let resetsAt = try XCTUnwrap(bucket.resetsAt)
            // 초기화 시각은 지금 근처부터 몇 주 안쪽이어야 한다.
            XCTAssertGreaterThan(resetsAt, startedAt.addingTimeInterval(-3600))
            XCTAssertLessThan(resetsAt, startedAt.addingTimeInterval(60 * 24 * 3600))
        }
        print("live agy usage: \(summary.groups.count) groups, \(buckets.count) buckets")
    }
}

final class AntigravityExecutableLocatorTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    func testCandidatesPreferLocalBinThenAbsolutePathEntriesThenHomebrew() {
        let candidates = AntigravityExecutableLocator.candidates(
            home: home,
            searchPath: "/custom/bin::relative/bin:/usr/local/bin:/custom/bin"
        )

        XCTAssertEqual(candidates.map(\.path), [
            "/Users/tester/.local/bin/agy",
            "/custom/bin/agy",
            "/usr/local/bin/agy",
            "/opt/homebrew/bin/agy",
        ])
    }

    func testCandidatesWithoutSearchPath() {
        let candidates = AntigravityExecutableLocator.candidates(home: home, searchPath: nil)

        XCTAssertEqual(candidates.map(\.path), [
            "/Users/tester/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ])
    }

    func testLocateReturnsFirstExecutableCandidate() {
        let locator = AntigravityExecutableLocator(
            candidates: [URL(fileURLWithPath: "/a/agy"), URL(fileURLWithPath: "/b/agy"), URL(fileURLWithPath: "/c/agy")],
            isExecutable: { $0 != "/a/agy" }
        )

        XCTAssertEqual(locator.locate()?.path, "/b/agy")
    }

    func testLocateReturnsNilWhenNothingIsExecutable() {
        let locator = AntigravityExecutableLocator(
            candidates: [URL(fileURLWithPath: "/a/agy")],
            isExecutable: { _ in false }
        )

        XCTAssertNil(locator.locate())
    }

    func testEnvironmentKeepsOnlyAllowlistedKeys() {
        let environment = AntigravityCLIQuotaClient.childEnvironment(
            from: ["PATH": "/usr/bin", "LANG": "en_US.UTF-8", "SECRET_TOKEN": "x", "DYLD_INSERT_LIBRARIES": "y"],
            home: home
        )

        XCTAssertEqual(environment, ["PATH": "/usr/bin", "LANG": "en_US.UTF-8", "HOME": "/Users/tester"])
    }

    func testEnvironmentKeepsProxyAndCertificateSettings() {
        let proxySettings = [
            "HTTP_PROXY": "http://proxy:8080",
            "HTTPS_PROXY": "http://proxy:8443",
            "NO_PROXY": "localhost",
            "http_proxy": "http://proxy:8080",
            "https_proxy": "http://proxy:8443",
            "no_proxy": "localhost",
            "SSL_CERT_FILE": "/etc/ssl/cert.pem",
        ]

        let environment = AntigravityCLIQuotaClient.childEnvironment(
            from: proxySettings.merging(["API_KEY": "x", "DYLD_LIBRARY_PATH": "/tmp"]) { first, _ in first },
            home: home
        )

        XCTAssertEqual(environment, proxySettings.merging([
            "HOME": "/Users/tester",
            "PATH": Constants.Antigravity.fallbackSearchPath,
        ]) { first, _ in first })
    }

    func testEnvironmentFallsBackToSystemPath() {
        let environment = AntigravityCLIQuotaClient.childEnvironment(from: [:], home: home)

        XCTAssertEqual(environment["PATH"], Constants.Antigravity.fallbackSearchPath)
        XCTAssertEqual(environment["HOME"], "/Users/tester")
    }
}
