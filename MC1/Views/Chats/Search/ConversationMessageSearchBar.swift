import SwiftUI

/// Find-in-conversation bar: a field, a match counter, and previous/next.
///
/// It sits as a top safe-area inset rather than a `.searchable` field because `.searchable`
/// owns the navigation bar and would replace the conversation title — and because the
/// counter and the step buttons have to stay visible while the keyboard is up.
struct ConversationMessageSearchBar: View {
  @Bindable var state: ConversationMessageSearchState

  @Environment(\.appTheme) private var theme
  @FocusState private var isFieldFocused: Bool

  var body: some View {
    HStack(spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .font(.footnote)

        TextField(L10n.Chats.Chats.Search.InConversation.placeholder, text: $state.query)
          .textFieldStyle(.plain)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .submitLabel(.search)
          .focused($isFieldFocused)

        counter
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(.quaternary, in: .rect(cornerRadius: 10))

      stepButtons

      Button(L10n.Chats.Chats.Search.InConversation.done) {
        state.dismiss()
      }
      .font(.body)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.bar)
    .onAppear { isFieldFocused = true }
  }

  @ViewBuilder
  private var counter: some View {
    if state.isLoading {
      ProgressView().controlSize(.mini)
    } else if state.hasSettledWithNoMatches {
      Text(L10n.Chats.Chats.Search.InConversation.noResults)
        .font(.caption)
        .foregroundStyle(.secondary)
    } else if state.matchCount > 0 {
      Text(L10n.Chats.Chats.Search.InConversation.matchPosition(state.currentPosition, state.matchCount))
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }

  private var stepButtons: some View {
    HStack(spacing: 2) {
      Button {
        state.step(-1)
      } label: {
        Image(systemName: "chevron.up")
      }
      .accessibilityLabel(L10n.Chats.Chats.Search.InConversation.previous)

      Button {
        state.step(1)
      } label: {
        Image(systemName: "chevron.down")
      }
      .accessibilityLabel(L10n.Chats.Chats.Search.InConversation.next)
    }
    .buttonStyle(.plain)
    .font(.body.weight(.semibold))
    .foregroundStyle(state.canStep ? Color.accentColor : Color.secondary)
    .disabled(!state.canStep)
  }
}
