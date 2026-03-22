import SwiftUI
import MC1Services

/// A single row in the global search results, showing a message snippet
/// with the matching text highlighted.
struct MessageSearchSnippetRow: View {
    let result: MessageSearchResult
    let searchText: String
    let isChannel: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isChannel, let senderName = result.senderNodeName, !result.isOutgoing {
                Text(senderName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let highlighted = MessageSearchHighlighter.highlight(
                text: result.text,
                searchText: searchText
            ) {
                highlighted
                    .font(.subheadline)
                    .lineLimit(2)
            } else {
                Text(result.text)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Text(result.createdAt, style: .relative)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}
