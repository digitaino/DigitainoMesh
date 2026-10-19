import Foundation

/// A parsed node-search query: what the user typed, plus whether it can be read as a
/// public-key fragment.
///
/// The one decision this type makes is *strict-hex detection*. A query made entirely of
/// hex digits is eligible to match public keys as well as names; anything else matches
/// names only. That gate is what keeps `"Cafe"` — a perfectly ordinary node name that
/// happens to be all hex digits — from being the *only* kind of false positive, instead
/// of every query fuzzily matching every key. It is also what fixed the legacy bug where
/// searching `"0c"` matched a key containing `"CC"`: locale-aware string containment has
/// no business anywhere near key comparison.
///
/// Names are matched with `localizedStandardContains`, which is case- and
/// diacritic-insensitive and is what the rest of the app uses for user-visible text.
public struct NodeSearchQuery: Sendable, Hashable {
  /// The query with surrounding whitespace removed. Empty for a blank search.
  public let text: String

  /// The query read as a public-key fragment, or `nil` when it is not strictly hex.
  public let keyPrefix: NodeKeyPrefix?

  /// Parses raw search-field input.
  public init(_ raw: String) {
    text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    keyPrefix = text.isEmpty ? nil : NodeKeyPrefix(hex: text)
  }

  /// Whether the query selects nothing in particular — every candidate matches.
  public var isEmpty: Bool {
    text.isEmpty
  }

  /// Whether the query is eligible to match public keys.
  public var isStrictHex: Bool {
    keyPrefix != nil
  }

  /// Whether `name` contains the query, by the app's usual user-text rules.
  public func matchesName(_ name: String) -> Bool {
    guard !text.isEmpty else { return true }
    return name.localizedStandardContains(text)
  }
}
