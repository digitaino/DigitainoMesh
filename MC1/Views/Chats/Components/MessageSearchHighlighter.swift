import SwiftUI

/// Utility for creating highlighted text snippets from search results.
enum MessageSearchHighlighter {

    /// Creates a `Text` view with the matching portion bolded and the surrounding
    /// text dimmed, trimmed to a snippet window around the first match.
    /// - Parameters:
    ///   - text: Full message text
    ///   - searchText: The search query
    ///   - snippetRadius: Number of characters to show around the match
    /// - Returns: Styled `Text` view, or nil if no match found
    static func highlight(text: String, searchText: String, snippetRadius: Int = 40) -> Text? {
        guard !searchText.isEmpty,
              let range = text.range(of: searchText, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }

        let matchStart = text.distance(from: text.startIndex, to: range.lowerBound)
        let matchEnd = text.distance(from: text.startIndex, to: range.upperBound)
        let matchText = String(text[range])

        // Calculate snippet window
        let snippetStart = max(0, matchStart - snippetRadius)
        let snippetEnd = min(text.count, matchEnd + snippetRadius)

        let startIndex = text.index(text.startIndex, offsetBy: snippetStart)
        let endIndex = text.index(text.startIndex, offsetBy: snippetEnd)

        let prefix = snippetStart > 0 ? "…" : ""
        let suffix = snippetEnd < text.count ? "…" : ""

        let beforeMatch = String(text[startIndex..<range.lowerBound])
        let afterMatch = String(text[range.upperBound..<endIndex])

        return Text(prefix + beforeMatch)
            .foregroundColor(.secondary)
            + Text(matchText)
            .bold()
            .foregroundColor(.primary)
            + Text(afterMatch + suffix)
            .foregroundColor(.secondary)
    }
}
