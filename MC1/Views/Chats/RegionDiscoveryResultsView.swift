import SwiftUI

/// Pushed view showing discovered regions with toggleable selection
struct RegionDiscoveryResultsView: View {
    let sortedRegions: [String]
    let onAdd: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedRegions: Set<String>

    init(discoveredRegions: [String], onAdd: @escaping ([String]) -> Void) {
        let sorted = discoveredRegions.sorted()
        self.sortedRegions = sorted
        self.onAdd = onAdd
        self._selectedRegions = State(initialValue: Set(discoveredRegions))
    }

    var body: some View {
        Form {
            Section {
                ForEach(sortedRegions, id: \.self) { region in
                    Button {
                        toggleSelection(region)
                    } label: {
                        HStack {
                            Text(region)
                            if region.isPrivateRegion {
                                Text(L10n.Chats.Chats.ChannelInfo.Region.`private`)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if selectedRegions.contains(region) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .tint(.primary)
                }
            }

            Section {
                Button(L10n.Chats.Chats.ChannelInfo.Region.addSelected) {
                    onAdd(Array(selectedRegions))
                    dismiss()
                }
                .disabled(selectedRegions.isEmpty)
            }
        }
        .navigationTitle(L10n.Chats.Chats.ChannelInfo.Region.discover)
    }

    private func toggleSelection(_ region: String) {
        if selectedRegions.contains(region) {
            selectedRegions.remove(region)
        } else {
            selectedRegions.insert(region)
        }
    }
}
