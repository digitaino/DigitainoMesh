import MC1Services
import SwiftUI

/// Picks one repeater, or several, from the candidates this radio can reach.
///
/// One view for both jobs because the difference is a checkmark and whether it dismisses:
/// the benchmark needs a test repeater (single) and a target set (multi), and the watch
/// screen needs a single target. Splitting them would mean two copies of the same search,
/// ordering and empty state.
///
/// Matching is ``NodeSearchEngine``'s, shared with the contacts and discovery lists. What
/// stays local is the *base* order — heard first, then favourites (see
/// ``RepeaterCandidateSource/ordered(_:)``) — because a range test is about what the radio
/// can hear right now. Search re-ranks that order by relevance rather than replacing it, so
/// a key-prefix match still surfaces while an audible repeater keeps its precedence over a
/// quiet one that matched equally well.
struct RepeaterPickerView: View {
  /// Single or multiple selection.
  enum Mode {
    /// Choosing one repeater; picking a row dismisses.
    case single
    /// Building a set; rows toggle and the user leaves when done.
    case multiple
  }

  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss

  let mode: Mode
  let candidates: [RepeaterCandidate]
  /// Keys currently chosen. Drives the checkmarks in both modes.
  let selection: Set<Data>
  let onToggle: (RepeaterCandidate) -> Void

  @State private var query = ""

  private var filtered: [RepeaterCandidate] {
    Self.nodeSearch.matches(
      searchText: query,
      among: candidates,
      options: .default.ordering(.inputOrder)
    )
  }

  private static let nodeSearch = NodeSearchEngine()

  var body: some View {
    List {
      if filtered.isEmpty {
        ContentUnavailableView {
          Label(
            L10n.Tools.Tools.Benchmark.Picker.empty,
            systemImage: "antenna.radiowaves.left.and.right.slash"
          )
        } description: {
          Text(L10n.Tools.Tools.Benchmark.Picker.emptyDescription)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
      } else {
        ForEach(filtered) { candidate in
          Button {
            onToggle(candidate)
            if mode == .single { dismiss() }
          } label: {
            RepeaterPickerRow(
              candidate: candidate,
              isSelected: selection.contains(candidate.publicKey)
            )
          }
          .tint(.primary)
          .themedRowBackground(theme)
        }
      }
    }
    .listStyle(.plain)
    .themedCanvas(theme)
    .searchable(text: $query, prompt: L10n.Tools.Tools.Benchmark.Picker.searchPrompt)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if mode == .multiple {
        ToolbarItem(placement: .topBarTrailing) {
          Button(L10n.Tools.Tools.Benchmark.Picker.done) { dismiss() }
        }
      }
    }
  }
}
