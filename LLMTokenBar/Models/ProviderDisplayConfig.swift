import Foundation
import OSLog

private let logger = Logger(subsystem: "com.llmtokenbar", category: "ProviderDisplay")

struct ProviderDisplayItem: Identifiable, Codable, Equatable {
    let provider: Provider
    var isEnabled: Bool

    var id: String { provider.rawValue }
}

@MainActor
final class ProviderDisplayConfig: ObservableObject {
    @Published var items: [ProviderDisplayItem] = []

    static let storageKey = "providerDisplayOrder"
    /// Antigravity 한도 카드가 추가되면서 Gemini 항목을 한 번만 자동으로 켜기 위한 표식.
    static let antigravityMigrationKey = "antigravityQuotaDisplayMigrated"

    private static let defaultItems: [ProviderDisplayItem] = [
        ProviderDisplayItem(provider: .claude, isEnabled: true),
        ProviderDisplayItem(provider: .openai, isEnabled: true),
        ProviderDisplayItem(provider: .minimax, isEnabled: true),
        ProviderDisplayItem(provider: .kimi, isEnabled: true),
        ProviderDisplayItem(provider: .gemini, isEnabled: false),
    ]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = Self.load(from: defaults)
        migrateAntigravityDisplayIfNeeded()
    }

    func isEnabled(_ provider: Provider) -> Bool {
        items.first(where: { $0.provider == provider })?.isEnabled ?? false
    }

    func enabledProviders() -> [Provider] {
        items.filter(\.isEnabled).map(\.provider)
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func toggle(_ provider: Provider) {
        guard let index = items.firstIndex(where: { $0.provider == provider }) else { return }
        items[index] = ProviderDisplayItem(
            provider: items[index].provider,
            isEnabled: !items[index].isEnabled
        )
        save()
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(items)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            logger.error("Provider 설정 저장 실패: \(error.localizedDescription)")
        }
    }

    /// 기존 사용자도 Gemini 카드를 보도록 한 번만 켠다. 이후에 끄면 그대로 둔다.
    private func migrateAntigravityDisplayIfNeeded() {
        guard !defaults.bool(forKey: Self.antigravityMigrationKey) else { return }
        defaults.set(true, forKey: Self.antigravityMigrationKey)

        guard let index = items.firstIndex(where: { $0.provider == .gemini }),
              !items[index].isEnabled else { return }
        items[index] = ProviderDisplayItem(provider: .gemini, isEnabled: true)
        save()
    }

    private static func load(from defaults: UserDefaults) -> [ProviderDisplayItem] {
        guard let data = defaults.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([ProviderDisplayItem].self, from: data) else {
            return defaultItems
        }

        // 삭제된 Provider 필터링 + 새로 추가된 Provider 끝에 추가
        let validProviders = Set(Provider.allCases)
        var result = saved.filter { validProviders.contains($0.provider) }
        for defaultItem in defaultItems where !result.contains(where: { $0.provider == defaultItem.provider }) {
            result.append(defaultItem)
        }
        return result
    }
}
