import SwiftUI

/// Builds the one-line snippet a search result shows: a window of message text centred on
/// the match, with the matched run emphasised.
///
/// Ported from legacy and re-skinned. Two things changed. The window is now measured in
/// `Character`s taken with `index(_:offsetBy:limitedBy:)` rather than by counting the whole
/// string twice — a long message made the old version walk its text four times per row,
/// once per result, on the main actor. And the match uses the same
/// case- and diacritic-insensitive comparison the store's predicate does, so a row can
/// never come back from the query and then fail to highlight anything.
enum MessageSearchHighlighter {
  /// Characters of context kept on each side of the match.
  static let defaultRadius = 40

  /// The snippet, or `nil` when the query does not appear in `text` — which happens for a
  /// blank query, and for a store match that a locale's collation folded differently.
  /// Callers fall back to the plain, truncated message text.
  static func snippet(text: String, query: String, radius: Int = defaultRadius) -> Snippet? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let match = text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive])
    else { return nil }

    let windowStart = text.index(match.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
    let windowEnd = text.index(match.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex

    return Snippet(
      leading: String(text[windowStart..<match.lowerBound]),
      match: String(text[match]),
      trailing: String(text[match.upperBound..<windowEnd]),
      isTruncatedAtStart: windowStart > text.startIndex,
      isTruncatedAtEnd: windowEnd < text.endIndex
    )
  }

  /// A snippet split around its match, so the caller decides the styling.
  struct Snippet: Equatable {
    let leading: String
    let match: String
    let trailing: String
    let isTruncatedAtStart: Bool
    let isTruncatedAtEnd: Bool

    /// The snippet as plain text, ellipses included — for accessibility labels, where the
    /// emphasis carries no meaning a screen reader can use.
    var plainText: String {
      (isTruncatedAtStart ? "…" : "") + leading + match + trailing + (isTruncatedAtEnd ? "…" : "")
    }
  }

  /// The snippet as styled text: context dimmed, the match in the body colour and bold.
  static func styled(_ snippet: Snippet) -> Text {
    let ellipsisStart = snippet.isTruncatedAtStart ? "…" : ""
    let ellipsisEnd = snippet.isTruncatedAtEnd ? "…" : ""
    return Text(ellipsisStart + snippet.leading).foregroundStyle(.secondary)
      + Text(snippet.match).bold().foregroundStyle(.primary)
      + Text(snippet.trailing + ellipsisEnd).foregroundStyle(.secondary)
  }
}
