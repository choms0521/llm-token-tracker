import XCTest
@testable import LLM_Token_Bar

final class ProviderDisplayConfigMigrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ProviderDisplayConfigMigrationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @MainActor
    func testFirstLaunchEnablesGeminiOnceAndRecordsFlag() {
        let saved: [ProviderDisplayItem] = [
            ProviderDisplayItem(provider: .claude, isEnabled: true),
            ProviderDisplayItem(provider: .gemini, isEnabled: false),
        ]
        defaults.set(try? JSONEncoder().encode(saved), forKey: ProviderDisplayConfig.storageKey)

        let config = ProviderDisplayConfig(defaults: defaults)

        XCTAssertTrue(config.isEnabled(.gemini))
        XCTAssertTrue(defaults.bool(forKey: ProviderDisplayConfig.antigravityMigrationKey))
        XCTAssertEqual(config.items.map(\.provider), [.claude, .gemini, .openai, .minimax, .kimi])
    }

    @MainActor
    func testMigrationRunsOnlyOnceSoUserCanDisableGeminiAgain() {
        let first = ProviderDisplayConfig(defaults: defaults)
        XCTAssertTrue(first.isEnabled(.gemini))

        first.toggle(.gemini)
        XCTAssertFalse(first.isEnabled(.gemini))

        let second = ProviderDisplayConfig(defaults: defaults)
        XCTAssertFalse(second.isEnabled(.gemini))
    }

    @MainActor
    func testFreshInstallEnablesGeminiByDefaultEvenWhenMigrationAlreadyRan() {
        defaults.set(true, forKey: ProviderDisplayConfig.antigravityMigrationKey)

        let config = ProviderDisplayConfig(defaults: defaults)

        XCTAssertTrue(config.isEnabled(.gemini))
    }
}
