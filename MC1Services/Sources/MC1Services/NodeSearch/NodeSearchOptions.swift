import Foundation

/// Knobs a caller turns when the defaults do not fit its surface.
public struct NodeSearchOptions: Sendable, Hashable {
  /// The default: recency ordering within each relevance tier, interior key matches from
  /// two bytes up.
  public static let `default` = NodeSearchOptions()

  /// Interior key matching disabled — only key *prefixes* count. What a surface wants
  /// when its users read a key prefix off a node row and type it back in.
  public static let prefixOnly = NodeSearchOptions(interiorKeyMatching: .disabled)

  /// How much of the public key an interior match has to cover.
  public enum InteriorKeyMatching: Sendable, Hashable {
    /// Only a query at least this many nibbles wide may match a key's interior.
    ///
    /// Legacy applied no floor, which made the tier close to useless in practice: a
    /// one-digit query is present somewhere in roughly 98% of 32-byte keys, so typing
    /// `"a"` returned nearly every node with the handful of genuine prefix matches buried
    /// underneath. Two bytes is the point where the tier starts discriminating.
    case fromNibbleWidth(Int)
    /// Never match a key's interior.
    case disabled

    func admits(_ prefix: NodeKeyPrefix) -> Bool {
      switch self {
      case let .fromNibbleWidth(minimum): prefix.nibbleWidth >= minimum
      case .disabled: false
      }
    }
  }

  /// Ordering within a relevance tier.
  public var tieBreak: NodeSearchTieBreak

  /// Whether, and how narrowly, a query may match the inside of a public key.
  public var interiorKeyMatching: InteriorKeyMatching

  public init(
    tieBreak: NodeSearchTieBreak = .recency,
    interiorKeyMatching: InteriorKeyMatching = .fromNibbleWidth(4)
  ) {
    self.tieBreak = tieBreak
    self.interiorKeyMatching = interiorKeyMatching
  }

  /// A copy with `tieBreak` replaced — for callers that keep their own sort control.
  public func ordering(_ tieBreak: NodeSearchTieBreak) -> NodeSearchOptions {
    var copy = self
    copy.tieBreak = tieBreak
    return copy
  }
}
