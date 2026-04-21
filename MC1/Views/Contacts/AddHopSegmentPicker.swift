import SwiftUI

/// Four-segment filter for `AddHopPickerView`. Lives in its own file so it can
/// read `@Environment(\.isSearching)` from its descendant-of-`.searchable`
/// position — reading `isSearching` on the view that declares `.searchable`
/// isn't reliable. While searching, the picker is muted and disabled (searches
/// behave as if `All` were selected, matching `DiscoverSegmentPicker`).
struct AddHopSegmentPicker: View {
    @Binding var selection: AddHopFilter
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        Picker(L10n.Contacts.Contacts.PathEdit.filterPickerLabel, selection: $selection) {
            ForEach(AddHopFilter.allCases) { filter in
                Text(filter.localizedLabel).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, PathEditMetrics.rowInset)
        .padding(.vertical, PathEditMetrics.segmentPickerVerticalInset)
        .opacity(isSearching ? PathEditMetrics.disabledOpacity : 1.0)
        .disabled(isSearching)
    }
}
