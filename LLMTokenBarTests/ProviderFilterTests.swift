import XCTest
@testable import LLM_Token_Bar

final class ProviderFilterTests: XCTestCase {
    /// Display 설정 화면과 동일한 순서 (Gemini만 꺼둔 상태).
    private let userConfiguredItems: [ProviderDisplayItem] = [
        ProviderDisplayItem(provider: .claude, isEnabled: true),
        ProviderDisplayItem(provider: .kimi, isEnabled: true),
        ProviderDisplayItem(provider: .openai, isEnabled: true),
        ProviderDisplayItem(provider: .minimax, isEnabled: true),
        ProviderDisplayItem(provider: .gemini, isEnabled: false),
    ]

    func testHiddenProvidersAreOmittedByDefault() {
        let filters = ProviderFilter.makeFilters(
            items: userConfiguredItems,
            showsHiddenProviders: false
        )

        XCTAssertEqual(filters.map(\.id), ["all", "claude", "kimi", "openai", "minimax"])
        XCTAssertFalse(filters.contains { $0.isHidden })
    }

    func testRevealingHiddenProvidersAppendsThemInConfiguredPosition() {
        let filters = ProviderFilter.makeFilters(
            items: userConfiguredItems,
            showsHiddenProviders: true
        )

        XCTAssertEqual(filters.map(\.id), ["all", "claude", "kimi", "openai", "minimax", "gemini"])
        XCTAssertEqual(filters.filter(\.isHidden).map(\.id), ["gemini"])
    }

    /// 시크릿 해제는 순서를 재배치하지 않고 원래 자리에 끼워 넣는다.
    func testRevealedProviderKeepsItsMiddlePosition() {
        let items: [ProviderDisplayItem] = [
            ProviderDisplayItem(provider: .claude, isEnabled: true),
            ProviderDisplayItem(provider: .gemini, isEnabled: false),
            ProviderDisplayItem(provider: .kimi, isEnabled: true),
        ]

        XCTAssertEqual(
            ProviderFilter.makeFilters(items: items, showsHiddenProviders: false).map(\.id),
            ["all", "claude", "kimi"]
        )
        XCTAssertEqual(
            ProviderFilter.makeFilters(items: items, showsHiddenProviders: true).map(\.id),
            ["all", "claude", "gemini", "kimi"]
        )
    }

    func testAllFilterIsAlwaysPresentAndNeverHidden() {
        for showsHidden in [true, false] {
            let filters = ProviderFilter.makeFilters(items: [], showsHiddenProviders: showsHidden)
            XCTAssertEqual(filters.map(\.id), ["all"])
            XCTAssertNil(filters[0].provider)
            XCTAssertFalse(filters[0].isHidden)
        }
    }

    func testEveryConfiguredProviderIsReachableWhenAllEnabled() {
        let items = Provider.allCases.map { ProviderDisplayItem(provider: $0, isEnabled: true) }
        let filters = ProviderFilter.makeFilters(items: items, showsHiddenProviders: false)

        XCTAssertEqual(filters.count, Provider.allCases.count + 1)
        for provider in Provider.allCases {
            XCTAssertTrue(filters.contains { $0.provider == provider })
        }
    }
}
