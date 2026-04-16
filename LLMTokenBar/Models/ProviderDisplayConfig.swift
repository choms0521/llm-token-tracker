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

    private static let storageKey = "providerDisplayOrder"

    private static let defaultItems: [ProviderDisplayItem] = [
        ProviderDisplayItem(provider: .claude, isEnabled: true),
        ProviderDisplayItem(provider: .openai, isEnabled: true),
        ProviderDisplayItem(provider: .minimax, isEnabled: true),
        ProviderDisplayItem(provider: .kimi, isEnabled: true),
        ProviderDisplayItem(provider: .gemini, isEnabled: false),
    ]

    init() {
        items = Self.load()
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
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } catch {
            logger.error("Provider 설정 저장 실패: \(error.localizedDescription)")
        }
    }

    private static func load() -> [ProviderDisplayItem] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
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
