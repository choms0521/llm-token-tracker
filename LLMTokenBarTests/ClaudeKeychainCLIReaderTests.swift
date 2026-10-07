import Security
import XCTest
@testable import LLM_Token_Bar

final class ClaudeKeychainCLIReaderTests: XCTestCase {
    private let credentialJSON = Data(#"{"claudeAiOauth":{"accessToken":"a"}}"#.utf8)

    func testReadsItemThroughSecurityToolWithoutShell() {
        let harness = ReaderHarness(output: SecurityCommandOutput(exitStatus: 0, stdout: credentialJSON + Data("\n".utf8)))

        let result = harness.reader.read(.background)

        XCTAssertEqual(result, .found(credentialJSON))
        XCTAssertEqual(harness.invocations, [["find-generic-password", "-s", "Claude Code-credentials", "-w"]])
        XCTAssertTrue(harness.fallbackModes.isEmpty)
    }

    func testDecodesHexOutput() {
        let hex = credentialJSON.map { String(format: "%02x", $0) }.joined()
        let harness = ReaderHarness(output: SecurityCommandOutput(exitStatus: 0, stdout: Data("\(hex)\n".utf8)))

        XCTAssertEqual(harness.reader.read(.background), .found(credentialJSON))
    }

    func testMissingItemIsNotFound() {
        let harness = ReaderHarness(output: SecurityCommandOutput(exitStatus: 44, stdout: Data()))

        XCTAssertEqual(harness.reader.read(.background), .notFound)
        XCTAssertTrue(harness.fallbackModes.isEmpty)
    }

    func testEmptyOutputIsUnavailable() {
        let harness = ReaderHarness(output: SecurityCommandOutput(exitStatus: 0, stdout: Data("\n".utf8)))

        XCTAssertEqual(harness.reader.read(.background), .unavailable(errSecDecode))
    }

    func testBackgroundFailureAsksForSyncWithoutInProcessRead() {
        let harness = ReaderHarness(output: SecurityCommandOutput(exitStatus: 51, stdout: Data()))

        XCTAssertEqual(harness.reader.read(.background), .needsUserConsent(errSecAuthFailed))
        XCTAssertTrue(harness.fallbackModes.isEmpty)
    }

    func testBackgroundTimeoutAsksForSyncWithoutInProcessRead() {
        let harness = ReaderHarness(output: nil)

        XCTAssertEqual(harness.reader.read(.background), .needsUserConsent(errSecAuthFailed))
        XCTAssertTrue(harness.fallbackModes.isEmpty)
    }

    func testUserInitiatedFailureFallsBackToInProcessRead() {
        let harness = ReaderHarness(output: SecurityCommandOutput(exitStatus: 51, stdout: Data()))
        harness.fallbackResult = .found(credentialJSON)

        XCTAssertEqual(harness.reader.read(.userInitiated), .found(credentialJSON))
        XCTAssertEqual(harness.fallbackModes, [.userInitiated])
    }

    func testLockedKeychainSkipsSecurityToolInBackground() {
        let harness = ReaderHarness(output: SecurityCommandOutput(exitStatus: 0, stdout: credentialJSON))
        harness.unlocked = false

        XCTAssertEqual(harness.reader.read(.background), .needsUserConsent(errSecInteractionNotAllowed))
        XCTAssertTrue(harness.invocations.isEmpty)
        XCTAssertTrue(harness.fallbackModes.isEmpty)
    }

    func testLockedKeychainUsesInProcessReadOnUserAction() {
        let harness = ReaderHarness(output: SecurityCommandOutput(exitStatus: 0, stdout: credentialJSON))
        harness.unlocked = false
        harness.fallbackResult = .found(credentialJSON)

        XCTAssertEqual(harness.reader.read(.userInitiated), .found(credentialJSON))
        XCTAssertTrue(harness.invocations.isEmpty)
        XCTAssertEqual(harness.fallbackModes, [.userInitiated])
    }

    func testUserActionAllowsLongerTimeout() {
        var timeouts: [TimeInterval] = []
        let reader = ClaudeKeychainCLIReader(
            runSecurity: { _, timeout in
                timeouts.append(timeout)
                return SecurityCommandOutput(exitStatus: 44, stdout: Data())
            },
            isKeychainUnlocked: { true },
            inProcessRead: { _ in .notFound }
        )

        _ = reader.read(.background)
        _ = reader.read(.userInitiated)

        XCTAssertEqual(timeouts.count, 2)
        XCTAssertLessThan(timeouts[0], timeouts[1])
    }

    func testProcessRunnerReturnsExitStatusOfMissingItem() {
        let runner = SecurityCommandRunner()

        let output = runner.run(["find-generic-password", "-s", "llmtokenbar-test-missing-item-7f3a"], timeout: 5)

        XCTAssertEqual(output?.exitStatus, 44)
    }

    func testProcessRunnerStopsChildOnTimeout() {
        let runner = SecurityCommandRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"))
        let start = Date()

        let output = runner.run(["5"], timeout: 0.2)

        XCTAssertNil(output)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}

private final class ReaderHarness {
    private(set) var invocations: [[String]] = []
    private(set) var fallbackModes: [KeychainInteractionMode] = []
    var unlocked = true
    var fallbackResult: ClaudeKeychainReadResult = .notFound
    private let output: SecurityCommandOutput?

    init(output: SecurityCommandOutput?) {
        self.output = output
    }

    var reader: ClaudeKeychainCLIReader {
        ClaudeKeychainCLIReader(
            runSecurity: { [unowned self] arguments, _ in
                invocations.append(arguments)
                return output
            },
            isKeychainUnlocked: { [unowned self] in unlocked },
            inProcessRead: { [unowned self] mode in
                fallbackModes.append(mode)
                return fallbackResult
            }
        )
    }
}
