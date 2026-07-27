import MC1Services
import SwiftUI

/// One message-search result: which conversation it came from, the matching text, and when.
///
/// The conversation name leads the row because global search crosses conversations — a
/// snippet alone leaves the reader with no idea whose message they are about to open.
struct MessageSearchSnippetRow: View {
  let result: MessageSearchResult
  /// Display name of the conversation the message belongs to.
  let conversationName: String
  let query: String
  let referenceDate: Date

  private var snippet: MessageSearchHighlighter.Snippet? {
    MessageSearchHighlighter.snippet(text: result.text, query: query)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(conversationName)
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)

        Spacer(minLength: 0)

        Text(result.createdAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }

      if let sender {
        Text(sender)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      snippetText
        .font(.subheadline)
        .lineLimit(2)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }

  /// Sender line, shown only when it adds something: an incoming channel message could be
  /// from anyone, whereas a DM's sender is the conversation name already on the row.
  private var sender: String? {
    guard result.channelIndex != nil, !result.isOutgoing else { return nil }
    return result.senderNodeName
  }

  @ViewBuilder
  private var snippetText: some View {
    if let snippet {
      MessageSearchHighlighter.styled(snippet)
    } else {
      Text(result.text).foregroundStyle(.secondary)
    }
  }

  private var accessibilityLabel: String {
    let body = snippet?.plainText ?? result.text
    guard let sender else { return "\(conversationName). \(body)" }
    return "\(conversationName). \(sender). \(body)"
  }
}
