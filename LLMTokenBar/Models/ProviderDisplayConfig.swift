import Foundation

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
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private static func load() -> [ProviderDisplayItem] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([ProviderDisplayItem].self, from: data) else {
            return defaultItems
        }

        // 새로 추가된 Provider가 있으면 끝에 추가
        var result = saved
        for defaultItem in defaultItems where !saved.contains(where: { $0.provider == defaultItem.provider }) {
            result.append(defaultItem)
        }
        return result
    }
}
