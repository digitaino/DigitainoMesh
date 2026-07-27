import MC1Services
import SwiftUI

/// Floating popup displaying mention suggestions
struct MentionSuggestionView: View {
  let contacts: [ContactDTO]
  let onSelect: (ContactDTO) -> Void

  private let maxHeight: CGFloat = 200
  private let rowHeight: CGFloat = 48 // Avatar 32 + vertical padding 16
  private let maxSuggestions = 20

  /// `contacts` arrives recency-first (see `MentionUtilities.filterContacts`), and the popup
  /// is anchored above the composer, so rendering it in order puts the most likely pick at the
  /// top — the farthest point from the thumb. Reversing lands it on the bottom row, directly
  /// above the input, which is where the thumb already is.
  var suggestions: [ContactDTO] {
    Array(contacts.prefix(maxSuggestions).reversed())
  }

  private var contentHeight: CGFloat {
    let count = suggestions.count
    let dividerHeight: CGFloat = 1
    let totalHeight = CGFloat(count) * rowHeight + CGFloat(max(0, count - 1)) * dividerHeight
    return min(totalHeight, maxHeight)
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(suggestions) { contact in
            VStack(spacing: 0) {
              Button {
                onSelect(contact)
              } label: {
                MentionSuggestionRow(contact: contact)
              }
              .buttonStyle(.plain)

              if contact.id != suggestions.last?.id {
                Divider()
                  .padding(.leading, 44)
              }
            }
            .id(contact.id)
          }
        }
      }
      // The list can overflow `maxHeight`, and a scroll view opens at its top —
      // which after the reversal is the *least* likely pick. Park it at the bottom
      // so the most recent sender is the row on screen, and re-park whenever the
      // ordering changes underneath an open popup.
      .onAppear { scrollToMostRecent(proxy) }
      .onChange(of: suggestions.last?.id) { _, _ in scrollToMostRecent(proxy) }
    }
    .frame(height: contentHeight)
    .background(.regularMaterial)
    .clipShape(.rect(cornerRadius: 12))
    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    .animation(.spring(response: 0.25, dampingFraction: 0.9), value: contacts.count)
    .accessibilityLabel(L10n.Chats.Chats.Suggestions.accessibilityLabel)
  }

  private func scrollToMostRecent(_ proxy: ScrollViewProxy) {
    guard let last = suggestions.last else { return }
    proxy.scrollTo(last.id, anchor: .bottom)
  }
}
