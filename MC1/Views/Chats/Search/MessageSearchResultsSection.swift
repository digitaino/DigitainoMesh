import MC1Services
import SwiftUI

/// The "Messages" half of the chats-list search results, mounted under the matching
/// conversations while a search is active.
///
/// It lives inside the same scroll view as the conversation rows rather than behind a
/// segmented control, because the two answer different halves of one question — "where was
/// that conversation" and "where was that message" — and the user rarely knows which they
/// are asking until they see the answer.
struct MessageSearchResultsSection: View {
  let search: MessageSearchViewModel
  let query: String
  let referenceDate: Date
  let onOpen: (MessageSearchResult) -> Void

  /// Leading inset matching the conversation rows' divider.
  private static let separatorLeadingInset: CGFloat = 16

  var body: some View {
    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        header
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var header: some View {
    HStack {
      Text(L10n.Chats.Chats.Search.Messages.section)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)

      if search.isLoading {
        ProgressView().controlSize(.mini)
      }

      Spacer(minLength: 0)

      if search.hasMoreThanLoaded {
        Text(L10n.Chats.Chats.Search.Messages.showingFirst(search.loadedCount))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
    .padding(.horizontal, Self.separatorLeadingInset)
    .padding(.top, 16)
    .padding(.bottom, 6)
  }

  @ViewBuilder
  private var content: some View {
    if search.groups.isEmpty {
      if !search.isLoading, search.resolvedQuery == query.trimmingCharacters(in: .whitespacesAndNewlines) {
        Text(L10n.Chats.Chats.Search.Messages.empty)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.horizontal, Self.separatorLeadingInset)
          .padding(.vertical, 8)
      }
    } else {
      ForEach(search.groups) { group in
        groupRows(group)
      }
    }
  }

  @ViewBuilder
  private func groupRows(_ group: MessageSearchViewModel.Group) -> some View {
    let visible = search.visibleResults(in: group)

    ForEach(Array(visible.shown), id: \.id) { result in
      Divider().padding(.leading, Self.separatorLeadingInset)
      Button {
        onOpen(result)
      } label: {
        MessageSearchSnippetRow(
          result: result,
          conversationName: group.name,
          query: search.resolvedQuery,
          referenceDate: referenceDate
        )
        .padding(.horizontal, Self.separatorLeadingInset)
        .padding(.vertical, 8)
      }
      .buttonStyle(.plain)
    }

    if visible.hidden > 0 {
      Divider().padding(.leading, Self.separatorLeadingInset)
      Button {
        search.expand(group.id)
      } label: {
        Text(L10n.Chats.Chats.Search.Messages.showMore(visible.hidden))
          .font(.subheadline)
          .padding(.horizontal, Self.separatorLeadingInset)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
    }
  }
}
