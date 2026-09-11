import XCTest
@testable import LLM_Token_Bar

/// URLSession 요청을 가로채 미리 정한 응답을 돌려주는 스텁.
private final class StubURLProtocol: URLProtocol {
    enum Reply {
        case response(status: Int, body: Data)
        case failure(URLError.Code)
        /// 본문을 보낸 뒤 끝내지 않는다. 수신 중 크기 제한이 걸리는지 확인할 때 쓴다.
        case bodyWithoutFinish(Data)
        /// 지정한 시간만큼 기다린 뒤 연결 실패를 돌려준다.
        case delayedFailure(TimeInterval)
        case redirect(to: String)
    }

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String: Reply] = [:]
        private var requestedURLs: [String] = []

        func set(_ replies: [String: Reply]) {
            lock.lock(); defer { lock.unlock() }
            self.replies = replies
            requestedURLs = []
        }

        func reply(for url: String) -> Reply? {
            lock.lock(); defer { lock.unlock() }
            requestedURLs.append(url)
            return replies[url]
        }

        var requests: [String] {
            lock.lock(); defer { lock.unlock() }
            return requestedURLs
        }
    }

    private static let registry = Registry()

    static func install(_ replies: [String: Reply]) {
        registry.set(replies)
    }

    static var requestedURLs: [String] { registry.requests }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        switch Self.registry.reply(for: url) {
        case .response(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .bodyWithoutFinish(let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
        case .delayedFailure(let seconds):
            Thread.sleep(forTimeInterval: seconds)
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        case .redirect(let location):
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": location])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: location)!), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
    }
}

private struct FixedLocator: AntigravityEndpointLocating {
    let urls: [String]

    func locateEndpoints() -> [URL] {
        urls.compactMap(URL.init(string:))
    }
}

final class AntigravityQuotaClientTests: XCTestCase {
    private let rpc = Constants.Antigravity.rpcPath + Constants.Antigravity.quotaSummaryRPC
    private let statusRPC = Constants.Antigravity.rpcPath + Constants.Antigravity.userStatusRPC
    private let summaryBody = Data("""
    {"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.75}]}]}}
    """.utf8)
    private let errorBody = Data("""
    {"code":"unimplemented","message":"boom"}
    """.utf8)
    private let planBody = Data("""
    {"userStatus":{"planStatus":{"planInfo":{"planName":"Pro"}}}}
    """.utf8)

    private func makeClient(_ urls: [String], deadline: TimeInterval = Constants.Antigravity.refreshDeadline) -> AntigravityQuotaClient {
        AntigravityQuotaClient(
            locator: FixedLocator(urls: urls),
            now: { Date(timeIntervalSince1970: 1_788_400_000) },
            protocolClasses: [StubURLProtocol.self],
            refreshDeadline: deadline
        )
    }

    func testFallsBackToNextEndpointWhenFirstIsUnreachable() async throws {
        StubURLProtocol.install([
            "https://127.0.0.1:1" + rpc: .failure(.cannotConnectToHost),
            "https://127.0.0.1:2" + rpc: .response(status: 200, body: summaryBody),
            "https://127.0.0.1:2" + statusRPC: .response(status: 200, body: planBody),
        ])
        let client = makeClient(["https://127.0.0.1:1", "https://127.0.0.1:2"])

        let result = try await client.fetchQuota()

        XCTAssertEqual(result.summary.geminiGroup?.buckets.first?.usedPercent ?? 0, 25, accuracy: 0.001)
        XCTAssertEqual(result.planName, "Pro")
        XCTAssertEqual(result.summary.fetchedAt, Date(timeIntervalSince1970: 1_788_400_000))
    }

    func testStopsAfterFirstSuccessfulEndpoint() async throws {
        StubURLProtocol.install([
            "https://127.0.0.1:1" + rpc: .response(status: 200, body: summaryBody),
        ])
        let client = makeClient(["https://127.0.0.1:1", "https://127.0.0.1:2"])

        _ = try await client.fetchQuota()

        XCTAssertFalse(StubURLProtocol.requestedURLs.contains { $0.hasPrefix("https://127.0.0.1:2") })
    }

    func testNon200ResponseBecomesBadResponseWithServerMessage() async {
        StubURLProtocol.install([
            "https://127.0.0.1:1" + rpc: .response(status: 501, body: errorBody),
        ])
        let client = makeClient(["https://127.0.0.1:1"])

        await assertThrows(client) { XCTAssertEqual($0, .badResponse("boom")) }
    }

    func testPrefersBadResponseOverConnectionFailureWhenAllEndpointsFail() async {
        StubURLProtocol.install([
            "https://127.0.0.1:1" + rpc: .response(status: 501, body: errorBody),
            "https://127.0.0.1:2" + rpc: .failure(.cannotConnectToHost),
        ])
        let client = makeClient(["https://127.0.0.1:1", "https://127.0.0.1:2"])

        await assertThrows(client) { XCTAssertEqual($0, .badResponse("boom")) }
    }

    func testAllEndpointsUnreachableThrowsUnreachable() async {
        StubURLProtocol.install([:])
        let client = makeClient(["https://127.0.0.1:1"])

        await assertThrows(client) { XCTAssertEqual($0, .unreachable) }
    }

    /// 본문이 끝나기 전에 제한을 넘기면 바로 중단해야 한다. 다 받은 뒤 검사하면 요청 제한 시간까지 기다리게 된다.
    func testOversizedBodyIsRejectedWhileStreaming() async {
        let huge = Data(repeating: UInt8(ascii: "{"), count: Constants.Antigravity.maxResponseBytes + 1)
        StubURLProtocol.install([
            "https://127.0.0.1:1" + rpc: .bodyWithoutFinish(huge),
        ])
        let client = makeClient(["https://127.0.0.1:1"])
        let started = Date()

        await assertThrows(client) {
            guard case .badResponse = $0 else { return XCTFail("expected badResponse, got \($0)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), Constants.Antigravity.requestTimeout - 1)
    }

    func testStopsProbingWhenRefreshDeadlinePasses() async {
        StubURLProtocol.install([
            "https://127.0.0.1:1" + rpc: .delayedFailure(0.4),
            "https://127.0.0.1:2" + rpc: .delayedFailure(0.4),
            "https://127.0.0.1:3" + rpc: .response(status: 200, body: summaryBody),
        ])
        let client = makeClient(["https://127.0.0.1:1", "https://127.0.0.1:2", "https://127.0.0.1:3"], deadline: 0.5)

        await assertThrows(client) { XCTAssertEqual($0, .unreachable) }
        XCTAssertFalse(StubURLProtocol.requestedURLs.contains { $0.hasPrefix("https://127.0.0.1:3") })
    }

    func testRedirectToRemoteHostIsNotFollowed() async {
        StubURLProtocol.install([
            "https://127.0.0.1:1" + rpc: .redirect(to: "https://example.com/quota"),
        ])
        let client = makeClient(["https://127.0.0.1:1"])

        await assertThrows(client) {
            guard case .badResponse = $0 else { return XCTFail("expected badResponse, got \($0)") }
        }
        XCTAssertFalse(StubURLProtocol.requestedURLs.contains { $0.contains("example.com") })
    }

    func testNoEndpointsMeansServerNotRunning() async {
        let client = makeClient([])

        await assertThrows(client) { XCTAssertEqual($0, .serverNotRunning) }
    }

    private func assertThrows(_ client: AntigravityQuotaClient, _ check: (AntigravityQuotaError) -> Void) async {
        do {
            _ = try await client.fetchQuota()
            XCTFail("expected an error")
        } catch let error as AntigravityQuotaError {
            check(error)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}

final class LoopbackTrustPolicyTests: XCTestCase {
    func testAcceptsServerTrustOnlyForLoopbackHosts() {
        XCTAssertTrue(LoopbackTrustPolicy.shouldAccept(host: "127.0.0.1", authenticationMethod: NSURLAuthenticationMethodServerTrust))
        XCTAssertTrue(LoopbackTrustPolicy.shouldAccept(host: "localhost", authenticationMethod: NSURLAuthenticationMethodServerTrust))
        XCTAssertFalse(LoopbackTrustPolicy.shouldAccept(host: "example.com", authenticationMethod: NSURLAuthenticationMethodServerTrust))
        XCTAssertFalse(LoopbackTrustPolicy.shouldAccept(host: "127.0.0.1.evil.com", authenticationMethod: NSURLAuthenticationMethodServerTrust))
    }

    func testRejectsNonServerTrustChallengesEvenOnLoopback() {
        XCTAssertFalse(LoopbackTrustPolicy.shouldAccept(host: "127.0.0.1", authenticationMethod: NSURLAuthenticationMethodHTTPBasic))
        XCTAssertFalse(LoopbackTrustPolicy.shouldAccept(host: "localhost", authenticationMethod: NSURLAuthenticationMethodClientCertificate))
    }
}
