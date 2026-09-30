import XCTest
@testable import LLM_Token_Bar

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String]))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let (status, headers) = Self.handler?(request) ?? (500, [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func bearer(_ request: URLRequest) -> String {
        (request.value(forHTTPHeaderField: "Authorization") ?? "").replacingOccurrences(of: "Bearer ", with: "")
    }
}

@MainActor
final class ClaudeAuthRecoveryTests: XCTestCase {
    private var dir: URL!
    private var cacheURL: URL { dir.appendingPathComponent("cache.json") }
    private var cliURL: URL { dir.appendingPathComponent("cli.json") }
    private var keychainResult: ClaudeKeychainReadResult = .notFound

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        StubURLProtocol.requests = []
        StubURLProtocol.handler = nil
        keychainResult = .notFound
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    private func credential(_ token: String) throws -> Data {
        try JSONEncoder().encode(ClaudeOAuth(
            accessToken: token, refreshToken: "r", expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000,
            scopes: nil, subscriptionType: nil, rateLimitTier: nil))
    }

    private func makeAuth() -> ClaudeAuthService {
        ClaudeAuthService(cliCredentialsPath: cliURL.path, fileCachePath: cacheURL, keychainReader: { [unowned self] _ in keychainResult })
    }

    private func makeUsage(_ auth: ClaudeAuthService) -> ClaudeUsageService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ClaudeUsageService(authService: auth, session: URLSession(configuration: config))
    }

    private var tokensSent: [String] { StubURLProtocol.requests.map(StubURLProtocol.bearer) }

    func testRejectedCacheWithConsentNeededSendsNoFurtherRequestAndDisconnects() async throws {
        try credential("A").write(to: cacheURL)
        keychainResult = .needsUserConsent(errSecInteractionNotAllowed)
        StubURLProtocol.handler = { _ in (401, [:]) }
        let auth = makeAuth()
        let usage = makeUsage(auth)

        do { _ = try await usage.fetchUsage(); XCTFail() } catch {}
        XCTAssertEqual(tokensSent, ["A"])
        do { _ = try await usage.fetchUsage(); XCTFail() } catch AuthError.keychainAccessRequiresUserConsent {}
        XCTAssertEqual(tokensSent, ["A"])
        let status = await auth.getSyncStatus()
        XCTAssertFalse(status.isConnected)
        XCTAssertNotNil(status.recoverySuggestion)
    }

    func testExplicitSyncPrefersKeychainOverOldCLIAndIgnoresCache() async throws {
        try credential("cache").write(to: cacheURL)
        try credential("oldA").write(to: cliURL)
        keychainResult = .found(try credential("B"))
        let auth = makeAuth()
        _ = await auth.syncCredentialsFromUserAction()
        let token = try await auth.loadCredentials()
        XCTAssertEqual(token, "B")
    }

    func testExplicitSyncDoesNotAdoptCacheOnlyCredential() async throws {
        try credential("cache").write(to: cacheURL)
        let status = await makeAuth().syncCredentialsFromUserAction()
        XCTAssertFalse(status.isConnected)
    }

    func testNon401ErrorsKeepTokenValid() async throws {
        try credential("A").write(to: cacheURL)
        let auth = makeAuth()
        let usage = makeUsage(auth)
        for code in [403, 429, 500] {
            StubURLProtocol.handler = { _ in (code, [:]) }
            do { _ = try await usage.fetchUsage(); XCTFail() } catch {}
        }
        let token = try await auth.loadCredentials()
        XCTAssertEqual(token, "A")
        XCTAssertEqual(tokensSent, ["A", "A", "A"])
    }

    func test401ThenRejectedReloadedTokenMarksBoth() async throws {
        try credential("A").write(to: cacheURL)
        keychainResult = .found(try credential("B"))
        StubURLProtocol.handler = { _ in (401, [:]) }
        let auth = makeAuth()
        let usage = makeUsage(auth)
        do { _ = try await usage.fetchUsage(); XCTFail() } catch UsageError.unauthorized {}
        XCTAssertEqual(tokensSent, ["A", "B"])
        StubURLProtocol.requests = []
        do { _ = try await usage.fetchUsage(); XCTFail() } catch {}
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func test429MakesSingleRequestWithRetryAfter() async throws {
        try credential("A").write(to: cacheURL)
        StubURLProtocol.handler = { _ in (429, ["Retry-After": "120"]) }
        let usage = makeUsage(makeAuth())
        do { _ = try await usage.fetchUsage(); XCTFail() } catch let UsageError.rateLimited(retryAfter) {
            XCTAssertEqual(retryAfter, 120)
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func test429WithNewReloadedTokenStillNoSecondRequest() async throws {
        try credential("A").write(to: cacheURL)
        keychainResult = .found(try credential("A"))
        StubURLProtocol.handler = { [unowned self] _ in
            try? credential("B").write(to: cliURL)
            return (429, [:])
        }
        let usage = makeUsage(makeAuth())
        do { _ = try await usage.fetchUsage(); XCTFail() } catch UsageError.rateLimited {}
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testRetryAfterParsing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ClaudeUsageService.parseRetryAfter("30", now: now), 30)
        XCTAssertNil(ClaudeUsageService.parseRetryAfter("-5", now: now))
        XCTAssertNil(ClaudeUsageService.parseRetryAfter("inf", now: now))
        XCTAssertNil(ClaudeUsageService.parseRetryAfter("nan", now: now))
        XCTAssertNil(ClaudeUsageService.parseRetryAfter("soon", now: now))
        XCTAssertNil(ClaudeUsageService.parseRetryAfter(nil, now: now))
        let future = Date(timeIntervalSince1970: 1_800_000_090)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        XCTAssertEqual(ClaudeUsageService.parseRetryAfter(f.string(from: future), now: now) ?? -1, 90, accuracy: 0.5)
    }

    func testFetchClaudeSkipsAllHTTPDuringCooldownAndKeepsMessage() async throws {
        try credential("A").write(to: cacheURL)
        StubURLProtocol.handler = { _ in (429, ["Retry-After": "300"]) }
        let auth = makeAuth()
        let manager = UsagePollingManager(claudeAuthService: auth, claudeUsageService: makeUsage(auth))
        await manager.fetchClaude()
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        manager.errorMessage = nil
        await manager.fetchClaude()
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertTrue(manager.errorMessage?.contains("자동 재시도") == true)
    }
}
