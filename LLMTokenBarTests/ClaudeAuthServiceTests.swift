import XCTest
@testable import LLM_Token_Bar

final class ClaudeAuthServiceTests: XCTestCase {
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
    func testLoadCredentialsFallsBackFromExpiredCacheToValidCLIFile() async throws {
        let cacheURL = temporaryDirectory.appendingPathComponent("claude-oauth-cache.json")
        let cliURL = temporaryDirectory.appendingPathComponent(".credentials.json")

        try makeCredential(
            accessToken: "cache-expired-token",
            expiresAt: Date().addingTimeInterval(-3600)
        ).write(to: cacheURL)
        try makeCredential(
            accessToken: "cli-valid-token",
            expiresAt: Date().addingTimeInterval(3600)
        ).write(to: cliURL)

        let service = ClaudeAuthService(
            cliCredentialsPath: cliURL.path,
            fileCachePath: cacheURL,
            keychainDataProvider: { nil }
        )

        let token = try await service.loadCredentials()
        XCTAssertEqual(token, "cli-valid-token")

        let cached = try JSONDecoder().decode(ClaudeOAuth.self, from: Data(contentsOf: cacheURL))
        XCTAssertEqual(cached.accessToken, "cli-valid-token")
    }

    @MainActor
    func testGetSyncStatusDoesNotReadKeychainWhenCacheIsValid() async throws {
        let cacheURL = temporaryDirectory.appendingPathComponent("claude-oauth-cache.json")
        let cliURL = temporaryDirectory.appendingPathComponent("missing.json")
        var keychainReadCount = 0

        try makeCredential(
            accessToken: "cache-valid-token",
            expiresAt: Date().addingTimeInterval(3600)
        ).write(to: cacheURL)

        let service = ClaudeAuthService(
            cliCredentialsPath: cliURL.path,
            fileCachePath: cacheURL,
            keychainDataProvider: {
                keychainReadCount += 1
                return nil
            }
        )

        let status = await service.getSyncStatus()
        XCTAssertTrue(status.isConnected)
        XCTAssertEqual(status.credentialSource, .appCache)
        XCTAssertEqual(keychainReadCount, 0)
    }

    @MainActor
    func testLoadCredentialsDoesNotReadKeychainWhenCLIFileIsValid() async throws {
        let cacheURL = temporaryDirectory.appendingPathComponent("claude-oauth-cache.json")
        let cliURL = temporaryDirectory.appendingPathComponent(".credentials.json")
        var keychainReadCount = 0

        try makeCredential(
            accessToken: "cli-valid-token",
            expiresAt: Date().addingTimeInterval(3600)
        ).write(to: cliURL)

        let service = ClaudeAuthService(
            cliCredentialsPath: cliURL.path,
            fileCachePath: cacheURL,
            keychainDataProvider: {
                keychainReadCount += 1
                return nil
            }
        )

        let token = try await service.loadCredentials()
        XCTAssertEqual(token, "cli-valid-token")
        XCTAssertEqual(keychainReadCount, 0)
    }

    @MainActor
    func testGetSyncStatusReportsConnectedKeychainSource() async {
        let cacheURL = temporaryDirectory.appendingPathComponent("claude-oauth-cache.json")
        let cliURL = temporaryDirectory.appendingPathComponent("missing.json")
        let keychainData = try? makeCredential(
            accessToken: "keychain-valid-token",
            expiresAt: Date().addingTimeInterval(3600)
        )

        let service = ClaudeAuthService(
            cliCredentialsPath: cliURL.path,
            fileCachePath: cacheURL,
            keychainDataProvider: { keychainData }
        )

        let status = await service.getSyncStatus()
        XCTAssertTrue(status.isConnected)
        XCTAssertEqual(status.credentialSource, .claudeKeychain)
        XCTAssertNotNil(status.expiresAt)
        XCTAssertEqual(status.maskedToken, "keycha••••••••")
    }

    @MainActor
    func testGetSyncStatusReportsExpiredCredentialAndRecoverySuggestion() async throws {
        let cacheURL = temporaryDirectory.appendingPathComponent("claude-oauth-cache.json")
        let cliURL = temporaryDirectory.appendingPathComponent(".credentials.json")

        try makeCredential(
            accessToken: "expired-cli-token",
            expiresAt: Date().addingTimeInterval(-7200)
        ).write(to: cliURL)

        let service = ClaudeAuthService(
            cliCredentialsPath: cliURL.path,
            fileCachePath: cacheURL,
            keychainDataProvider: { nil }
        )

        let status = await service.getSyncStatus()
        XCTAssertFalse(status.isConnected)
        XCTAssertEqual(status.credentialSource, .cliFile)
        XCTAssertNotNil(status.expiresAt)
        XCTAssertTrue(status.statusMessage?.contains("expired") == true)
        XCTAssertTrue(status.recoverySuggestion?.contains("Sync Credentials") == true)
    }

    @MainActor
    func testGetSyncStatusReportsMissingCredentials() async {
        let cacheURL = temporaryDirectory.appendingPathComponent("claude-oauth-cache.json")
        let cliURL = temporaryDirectory.appendingPathComponent("missing.json")

        let service = ClaudeAuthService(
            cliCredentialsPath: cliURL.path,
            fileCachePath: cacheURL,
            keychainDataProvider: { nil }
        )

        let status = await service.getSyncStatus()
        XCTAssertFalse(status.isConnected)
        XCTAssertNil(status.credentialSource)
        XCTAssertTrue(status.statusMessage?.contains("No Claude credentials") == true)
        XCTAssertTrue(status.recoverySuggestion?.contains("Run `claude`") == true)
    }

    private func makeCredential(accessToken: String, expiresAt: Date) throws -> Data {
        let credential = ClaudeOAuth(
            accessToken: accessToken,
            refreshToken: "refresh-\(accessToken)",
            expiresAt: expiresAt.timeIntervalSince1970 * 1000,
            scopes: ["org:create_api_key", "user:profile"],
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x"
        )
        return try JSONEncoder().encode(credential)
    }
}
