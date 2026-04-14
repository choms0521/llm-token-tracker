import SwiftUI

struct ProviderDisplaySettingsView: View {
    @ObservedObject var config: ProviderDisplayConfig

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Display Settings")
                    .font(.title2.bold())

                Text("Toggle visibility and drag to reorder providers in the popover")
                    .foregroundStyle(.secondary)

                providerList
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Provider Order")
                .font(.pretendard(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            List {
                ForEach(config.items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                            .font(.pretendard(size: 12))

                        Image(systemName: item.provider.iconName)
                            .foregroundStyle(Color(item.provider.accentColorName))
                            .frame(width: 20)

                        Text(item.provider.displayName)
                            .font(.pretendard(size: 13, weight: .medium))

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { item.isEnabled },
                            set: { _ in config.toggle(item.provider) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                    .padding(.vertical, 4)
                }
                .onMove { source, destination in
                    config.move(from: source, to: destination)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: CGFloat(config.items.count) * 44 + 8)

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.pretendard(size: 10))
                Text("Drag rows to change display order in the popover")
                    .font(.pretendard(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
    }
}
