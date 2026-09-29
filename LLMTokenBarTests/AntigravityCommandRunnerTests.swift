import XCTest
@testable import LLM_Token_Bar

/// 실제 자식 프로세스로 실행기의 종료, 제한 시간, 취소, 출력 상한을 확인한다.
/// 회귀가 테스트 전체를 멈추지 않도록 제한 시간은 모두 1초 안쪽으로 둔다.
final class AntigravityCommandRunnerTests: XCTestCase {
    private let runner = AntigravityProcessRunner(killGrace: 0.3, drainGrace: 0.2, maxOutputBytes: 64 * 1024)

    private func invocation(
        _ path: String,
        _ arguments: [String] = [],
        timeout: TimeInterval = 1
    ) -> AntigravityCommandInvocation {
        AntigravityCommandInvocation(
            executableURL: URL(fileURLWithPath: path),
            arguments: arguments,
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: timeout
        )
    }

    func testCollectsStdoutAndExitStatus() async throws {
        let result = try await runner.run(invocation("/bin/echo", ["hello"]))

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "hello\n")
    }

    /// 짧은 출력의 자식은 종료 알림이 마지막 출력보다 먼저 올 수 있다. 출력이 한 번도 빠지지 않아야 한다.
    func testShortOutputIsNeverLostToTerminationRace() async throws {
        let expected = "Gemini\tWeekly limit remaining\t55%\t2026-10-03T00:00:00Z\n"

        for _ in 0..<50 {
            let result = try await runner.run(invocation("/usr/bin/printf", ["%s", expected]))

            XCTAssertEqual(result.exitStatus, 0)
            XCTAssertEqual(String(decoding: result.output, as: UTF8.self), expected)
        }
    }

    /// 자식이 출력을 일찍 닫고 오래 살아 있어도 읽기 핸들러가 빈 청크로 CPU를 태우지 않아야 한다.
    func testEarlyEndOfOutputDoesNotSpinWhileChildRuns() async throws {
        let cpuBefore = Self.processCPUTime()

        // exec로 같은 pid가 표준 출력을 닫은 채 계속 산다.
        let result = try await runner.run(invocation(
            "/bin/sh",
            ["-c", "echo hi; exec >&-; exec /bin/sleep 0.8"],
            timeout: 3
        ))

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "hi\n")
        XCTAssertLessThan(Self.processCPUTime() - cpuBefore, 0.3)
    }

    /// 자식이 끝났는데 손자가 파이프를 물고 있어 EOF가 오지 않으면 일부 출력을 성공으로 돌려주지 않는다.
    func testMissingEndOfOutputIsNotReportedAsSuccess() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-runner-test-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let outcome = await Result {
            try await runner.run(invocation(
                "/bin/sh",
                ["-c", "echo partial; /bin/sleep 5 & echo $! > \"$1\"; exit 0", "sh", pidFile.path],
                timeout: 3
            ))
        }
        await Self.stopProcess(recordedIn: pidFile)

        XCTAssertThrowsError(try outcome.get()) { error in
            XCTAssertEqual(error as? AntigravityCommandError, .incompleteOutput)
        }
    }

    func testReportsNonZeroExitStatus() async throws {
        let result = try await runner.run(invocation("/usr/bin/false"))

        XCTAssertEqual(result.exitStatus, 1)
    }

    func testStdinIsClosedSoReadersFinishImmediately() async throws {
        let started = Date()

        let result = try await runner.run(invocation("/bin/cat", timeout: 0.8))

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertTrue(result.output.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8)
    }

    func testUsesGivenWorkingDirectoryAndEnvironment() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()

        let pwd = try await runner.run(AntigravityCommandInvocation(
            executableURL: URL(fileURLWithPath: "/bin/pwd"),
            arguments: [],
            workingDirectory: directory,
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 1
        ))
        let env = try await runner.run(AntigravityCommandInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [],
            workingDirectory: directory,
            environment: ["ONLY_VAR": "1"],
            timeout: 1
        ))

        let printed = String(decoding: pwd.output, as: UTF8.self).trimmingCharacters(in: .newlines)
        XCTAssertEqual(URL(fileURLWithPath: printed).resolvingSymlinksInPath().path, directory.path)
        XCTAssertEqual(String(decoding: env.output, as: UTF8.self), "ONLY_VAR=1\n")
    }

    func testMissingExecutableFailsToLaunch() async {
        do {
            _ = try await runner.run(invocation("/nonexistent/agy"))
            XCTFail("expected launch failure")
        } catch {
            XCTAssertEqual(error as? AntigravityCommandError, .launchFailed)
        }
    }

    func testTimeoutStopsChild() async {
        let started = Date()

        do {
            _ = try await runner.run(invocation("/bin/sleep", ["30"], timeout: 0.3))
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? AntigravityCommandError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testTimeoutEscalatesToKillWhenTerminateIsIgnored() async {
        let started = Date()

        do {
            // 셸은 테스트에서만 쓴다. 무시된 TERM은 exec 뒤에도 유지된다.
            _ = try await runner.run(invocation("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 30"], timeout: 0.3))
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? AntigravityCommandError, .timedOut)
        }
        // timeout 0.3 + killGrace 0.3 + 여유
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testOutputBeyondLimitStopsChild() async {
        let started = Date()

        do {
            _ = try await runner.run(invocation("/usr/bin/yes", timeout: 1))
            XCTFail("expected output limit")
        } catch {
            XCTAssertEqual(error as? AntigravityCommandError, .outputLimitExceeded)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testCancellationStopsChild() async {
        let runner = self.runner
        let command = invocation("/bin/sleep", ["30"], timeout: 1)
        let started = Date()
        let task = Task { try await runner.run(command) }

        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let result = await task.result

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.9)
    }

    func testAlreadyCancelledTaskDoesNotLaunch() async {
        let runner = self.runner
        let command = invocation("/bin/sleep", ["30"], timeout: 1)
        let started = Date()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(command)
        }

        let result = await task.result

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    // MARK: - Helpers

    /// 이 테스트 프로세스의 사용자 + 시스템 CPU 시간(초).
    private static func processCPUTime() -> TimeInterval {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = TimeInterval(usage.ru_utime.tv_sec) + TimeInterval(usage.ru_utime.tv_usec) / 1_000_000
        let system = TimeInterval(usage.ru_stime.tv_sec) + TimeInterval(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    /// 테스트 셸이 기록한 손자 프로세스를 멈추고 사라질 때까지 잠깐 기다린다.
    private static func stopProcess(recordedIn pidFile: URL) async {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return }
        kill(pid, SIGKILL)
        for _ in 0..<40 where kill(pid, 0) == 0 {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}
