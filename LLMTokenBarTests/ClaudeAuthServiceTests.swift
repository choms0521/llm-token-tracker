import Security
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

    @MainActor
    func testAutomaticLoadStatusAndReloadNeverAllowKeychainUI() async {
        let recorder = KeychainReadRecorder(result: .notFound)
        let service = makeService(recorder: recorder)

        _ = try? await service.loadCredentials()
        _ = await service.getSyncStatus()
        _ = try? await service.reloadCredentials()

        XCTAssertFalse(recorder.modes.isEmpty)
        XCTAssertTrue(recorder.modes.allSatisfy { $0 == .background }, "modes: \(recorder.modes)")
    }

    @MainActor
    func testUserSyncAllowsKeychainUIOnceAndPopulatesCache() async throws {
        let token = "keychain-user-token"
        let recorder = KeychainReadRecorder(
            result: .found(try makeCredential(accessToken: token, expiresAt: Date().addingTimeInterval(3600)))
        )
        let service = makeService(recorder: recorder)

        let status = await service.syncCredentialsFromUserAction()
        XCTAssertTrue(status.isConnected)
        XCTAssertEqual(recorder.modes, [.userInitiated])

        let loaded = try await service.loadCredentials()
        _ = await service.getSyncStatus()
        XCTAssertEqual(loaded, token)
        XCTAssertEqual(recorder.modes, [.userInitiated])
        XCTAssertEqual(try cachedToken(), token)
        XCTAssertNil(service.keychainConsentHint)
    }

    @MainActor
    func testKeychainConsentRequiredIsReportedAsActionableStatus() async {
        let recorder = KeychainReadRecorder(result: .needsUserConsent(errSecInteractionNotAllowed))
        let service = makeService(recorder: recorder)

        let status = await service.getSyncStatus()
        XCTAssertFalse(status.isConnected)
        XCTAssertEqual(status.credentialSource, .claudeKeychain)
        XCTAssertFalse(status.statusMessage?.contains("No Claude credentials") == true)
        XCTAssertTrue(status.recoverySuggestion?.contains("Settings > Claude > Sync Credentials") == true)

        do {
            _ = try await service.loadCredentials()
            XCTFail("Expected consent error")
        } catch AuthError.keychainAccessRequiresUserConsent {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(recorder.modes.allSatisfy { $0 == .background })
    }

    @MainActor
    func testFailedBackgroundReloadPreservesValidCache() async throws {
        let recorder = KeychainReadRecorder(result: .needsUserConsent(errSecInteractionNotAllowed))
        try makeCredential(accessToken: "cache-valid-token", expiresAt: Date().addingTimeInterval(3600))
            .write(to: cacheURL)
        let service = makeService(recorder: recorder)

        let token = try await service.loadCredentials()
        let reloaded = try await service.reloadCredentials()

        XCTAssertEqual(token, "cache-valid-token")
        XCTAssertEqual(reloaded, "cache-valid-token")
        XCTAssertEqual(try cachedToken(), "cache-valid-token")
        XCTAssertTrue(recorder.modes.allSatisfy { $0 == .background })
        XCTAssertTrue(service.keychainConsentHint?.contains("Settings > Claude > Sync Credentials") == true)

        try makeCredential(accessToken: "cli-user-token", expiresAt: Date().addingTimeInterval(7200))
            .write(to: cliURL)
        let status = await service.syncCredentialsFromUserAction()
        XCTAssertTrue(status.isConnected)
        XCTAssertNil(service.keychainConsentHint)
    }

    @MainActor
    func testReloadReplacesCacheWithNewerCLICredential() async throws {
        let recorder = KeychainReadRecorder(result: .notFound)
        try makeCredential(accessToken: "cache-old-token", expiresAt: Date().addingTimeInterval(3600))
            .write(to: cacheURL)
        let service = makeService(recorder: recorder)
        _ = try await service.loadCredentials()

        try makeCredential(accessToken: "cli-new-token", expiresAt: Date().addingTimeInterval(7200))
            .write(to: cliURL)
        let reloaded = try await service.reloadCredentials()

        XCTAssertEqual(reloaded, "cli-new-token")
        XCTAssertEqual(try cachedToken(), "cli-new-token")
        XCTAssertTrue(recorder.modes.isEmpty)
    }

    func testKeychainStatusClassification() {
        let data = Data("x".utf8)
        XCTAssertEqual(ClaudeAuthService.classifyKeychainRead(status: errSecSuccess, data: data), .found(data))
        XCTAssertEqual(ClaudeAuthService.classifyKeychainRead(status: errSecItemNotFound, data: nil), .notFound)
        XCTAssertEqual(
            ClaudeAuthService.classifyKeychainRead(status: errSecInteractionNotAllowed, data: nil),
            .needsUserConsent(errSecInteractionNotAllowed)
        )
        XCTAssertEqual(
            ClaudeAuthService.classifyKeychainRead(status: errSecAuthFailed, data: nil),
            .needsUserConsent(errSecAuthFailed)
        )
        XCTAssertEqual(
            ClaudeAuthService.classifyKeychainRead(status: errSecUserCanceled, data: nil),
            .needsUserConsent(errSecUserCanceled)
        )
        XCTAssertEqual(ClaudeAuthService.classifyKeychainRead(status: errSecParam, data: nil), .unavailable(errSecParam))
    }

    @MainActor
    func testManagerUserSyncHelperUsesUserInitiatedKeychainRead() async throws {
        let recorder = KeychainReadRecorder(
            result: .found(try makeCredential(accessToken: "manager-token", expiresAt: Date().addingTimeInterval(3600)))
        )
        let manager = UsagePollingManager(claudeAuthService: makeService(recorder: recorder))

        await manager.performUserInitiatedClaudeSync()

        XCTAssertEqual(recorder.modes, [.userInitiated])
        XCTAssertTrue(manager.syncStatus.isConnected)
        XCTAssertEqual(manager.syncStatus.credentialSource, .claudeKeychain)
    }

    private var cacheURL: URL { temporaryDirectory.appendingPathComponent("claude-oauth-cache.json") }
    private var cliURL: URL { temporaryDirectory.appendingPathComponent(".credentials.json") }

    @MainActor
    private func makeService(recorder: KeychainReadRecorder) -> ClaudeAuthService {
        ClaudeAuthService(
            cliCredentialsPath: cliURL.path,
            fileCachePath: cacheURL,
            keychainReader: { mode in recorder.read(mode) }
        )
    }

    private func cachedToken() throws -> String {
        try JSONDecoder().decode(ClaudeOAuth.self, from: Data(contentsOf: cacheURL)).accessToken
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

private final class KeychainReadRecorder {
    private(set) var modes: [KeychainInteractionMode] = []
    private let result: ClaudeKeychainReadResult

    init(result: ClaudeKeychainReadResult) {
        self.result = result
    }

    func read(_ mode: KeychainInteractionMode) -> ClaudeKeychainReadResult {
        modes.append(mode)
        return result
    }
}
