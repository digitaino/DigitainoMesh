import Foundation

/// Sync deletions held back on a radio that has just taken on an identity's history.
///
/// A radio swap moves a key onto hardware whose contact table and channel slots are
/// usually empty or different. A full sync treats the radio as authoritative, so the
/// first one after a swap would delete every cached contact and every channel row the
/// new radio lacks. The guard is armed when the swap is detected and each part holds
/// its own deletions back until a sync of that part finds nothing it would delete.
/// See docs/RADIO_SWAP.md, rule R2.
public struct SwapGuard: OptionSet, Sendable, Hashable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  /// The full-sync contact prune is held back.
  public static let contacts = SwapGuard(rawValue: 1 << 0)

  /// Channel rows at slots the radio reports empty, or beyond its capacity, are kept.
  public static let channels = SwapGuard(rawValue: 1 << 1)

  public static let all: SwapGuard = [.contacts, .channels]
}
