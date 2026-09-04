import XCTest
@testable import LLM_Token_Bar

final class AntigravityServerLocatorTests: XCTestCase {
    func testParsesPIDsFromPgrepOutput() {
        XCTAssertEqual(AntigravityServerLocator.parsePIDs("2784\n14650\n"), [2784, 14650])
        XCTAssertEqual(AntigravityServerLocator.parsePIDs(""), [])
        XCTAssertEqual(AntigravityServerLocator.parsePIDs("  \n"), [])
    }

    func testParsesListeningPortsFromLsofFieldOutput() {
        let output = "p2784\nf10\nn127.0.0.1:62114\nf11\nn127.0.0.1:62115\n"

        XCTAssertEqual(AntigravityServerLocator.parseListeningPorts(output), [62114, 62115])
    }

    func testListeningPortsAcceptLoopbackAndWildcardButRejectSpecificRemoteAddresses() {
        let output = "p1\nn127.0.0.1:5000\nn*:8080\nn127.0.0.1:5000\nn[::1]:5001\nn0.0.0.0:5002\nn[::]:5003\nn192.168.1.5:5004\nnlocalhost:5005\n"

        XCTAssertEqual(AntigravityServerLocator.parseListeningPorts(output), [5000, 8080, 5001, 5002, 5003, 5005])
    }

    /// TLS 포트에 평문 요청을 보내면 타임아웃까지 기다리지만, 평문 포트에 TLS 요청은 즉시 실패한다.
    func testEndpointsListHTTPSBeforeHTTPForEachPort() {
        let endpoints = AntigravityServerLocator.endpoints(for: [53301, 53302])

        XCTAssertEqual(endpoints.map(\.absoluteString), [
            "https://127.0.0.1:53301",
            "http://127.0.0.1:53301",
            "https://127.0.0.1:53302",
            "http://127.0.0.1:53302",
        ])
    }

    func testEndpointsProbeAtMostMaxPortsLowestFirst() {
        let endpoints = AntigravityServerLocator.endpoints(for: [9, 3, 7, 1, 5, 2])

        XCTAssertEqual(endpoints.count, Constants.Antigravity.maxProbedPorts * 2)
        XCTAssertEqual(endpoints.first?.absoluteString, "https://127.0.0.1:1")
        XCTAssertEqual(endpoints.last?.absoluteString, "http://127.0.0.1:5")
    }

    func testRunProcessReturnsStandardOutput() {
        XCTAssertEqual(AntigravityServerLocator.runProcess("/bin/echo", ["hello"]), "hello\n")
        XCTAssertEqual(AntigravityServerLocator.runProcess("/nonexistent/binary", []), "")
    }

    func testRunProcessTerminatesHungCommandWithinTimeout() {
        let started = Date()

        let output = AntigravityServerLocator.runProcess("/bin/sleep", ["10"])

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(output, "")
        XCTAssertLessThan(elapsed, Constants.Antigravity.commandTimeout + 1.5)
        XCTAssertGreaterThanOrEqual(elapsed, Constants.Antigravity.commandTimeout - 0.2)
    }

    func testNoProcessesMeansNoEndpoints() {
        let locator = AntigravityServerLocator(commandRunner: { _, _ in "" })

        XCTAssertEqual(locator.locateEndpoints(), [])
    }

    func testLocatorChainsPgrepIntoLsof() {
        let recorder = CommandRecorder()
        let locator = AntigravityServerLocator(commandRunner: { path, arguments in
            recorder.record([path] + arguments)
            return path.hasSuffix("pgrep") ? "2784\n" : "p2784\nn127.0.0.1:62114\n"
        })

        let endpoints = locator.locateEndpoints()

        XCTAssertEqual(endpoints.map(\.absoluteString), ["https://127.0.0.1:62114", "http://127.0.0.1:62114"])
        XCTAssertEqual(recorder.calls.first, [Constants.Antigravity.pgrepPath, "-x", Constants.Antigravity.processName])
        XCTAssertEqual(recorder.calls.last?.first, Constants.Antigravity.lsofPath)
        XCTAssertTrue(recorder.calls.last?.contains("2784") ?? false)
        XCTAssertTrue(recorder.calls.last?.contains("-b") ?? false)
        XCTAssertTrue(recorder.calls.last?.contains("-w") ?? false)
    }

    func testRunProcessKeepsLargeOutputInOrder() {
        let expected = (1...20000).map(String.init).joined(separator: "\n") + "\n"

        XCTAssertEqual(AntigravityServerLocator.runProcess("/usr/bin/seq", ["1", "20000"]), expected)
    }
}

/// @Sendable 클로저 안에서 호출 기록을 모으기 위한 잠금 상자.
private final class CommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String]] = []

    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func record(_ call: [String]) {
        lock.lock(); defer { lock.unlock() }
        storage.append(call)
    }
}
