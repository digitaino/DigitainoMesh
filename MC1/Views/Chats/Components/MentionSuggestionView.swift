import MC1Services
import SwiftUI

/// Floating popup displaying mention suggestions
struct MentionSuggestionView: View {
  let contacts: [ContactDTO]
  let onSelect: (ContactDTO) -> Void

  /// The name's line box, which is what makes a row taller than its avatar once Dynamic Type
  /// outgrows 32pt. Scaled, because the popup sizes itself from these numbers: the flat 48pt
  /// row this replaces under-measured every accessibility size and clipped the bottom row —
  /// the one the reversal below puts nearest the thumb.
  @ScaledMetric(relativeTo: .body) private var nameLineHeight: CGFloat = 22
  private let avatarHeight: CGFloat = 32
  private let rowVerticalPadding: CGFloat = 8
  private let dividerHeight: CGFloat = 1
  /// Rows visible before the popup scrolls. Fractional so the next row is cut off rather than
  /// flush, which is what makes the list read as scrollable.
  private let maxVisibleRows: CGFloat = 4.25
  private let maxSuggestions = 20

  /// Mirrors `MentionSuggestionRow`'s own layout: the taller of avatar and name, plus padding.
  private var rowHeight: CGFloat {
    max(avatarHeight, nameLineHeight) + rowVerticalPadding * 2
  }

  private var maxHeight: CGFloat {
    rowHeight * maxVisibleRows
  }

  /// `contacts` arrives recency-first (see `MentionUtilities.filterContacts`), and the popup
  /// is anchored above the composer, so rendering it in order puts the most likely pick at the
  /// top — the farthest point from the thumb. Reversing lands it on the bottom row, directly
  /// above the input, which is where the thumb already is.
  var suggestions: [ContactDTO] {
    Array(contacts.prefix(maxSuggestions).reversed())
  }

  private var contentHeight: CGFloat {
    let count = suggestions.count
    let totalHeight = CGFloat(count) * rowHeight + CGFloat(max(0, count - 1)) * dividerHeight
    return min(totalHeight, maxHeight)
  }

  var body: some View {
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
        }
      }
    }
    // The list can overflow `maxHeight`, and a scroll view opens at its top — which after the
    // reversal is the *least* likely pick. Parked declaratively rather than with a
    // `ScrollViewProxy`: the `onAppear` park this replaces ran before the lazy rows existed, so
    // it silently no-opped in precisely the overflowing case it was written for. The
    // `sizeChanges` role covers the rest — filtering rewrites the list under an open popup, and
    // the bottom row has to stay the one on screen.
    .defaultScrollAnchor(.bottom)
    .defaultScrollAnchor(.bottom, for: .sizeChanges)
    .frame(height: contentHeight)
    .background(.regularMaterial)
    .clipShape(.rect(cornerRadius: 12))
    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    .animation(.spring(response: 0.25, dampingFraction: 0.9), value: contacts.count)
    .accessibilityLabel(L10n.Chats.Chats.Suggestions.accessibilityLabel)
  }
}
