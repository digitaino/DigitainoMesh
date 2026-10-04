import CryptoKit
import Foundation

/// Single source of truth for content-based deduplication key generation.
/// Used by SyncCoordinator (live sync), PersistenceStore+Migration (on-device backfill),
/// and PersistenceStore+Backup (export/import).
enum DeduplicationKey {
  static let channelPrefix = "ch-"
  static let directMessagePrefix = "dm-"
  static let outgoingIdentityPrefix = "out-"
  static let unknownContactPlaceholder = "unknown"

  /// The same channel key filed under another slot. Keys embed the slot, so messages moved
  /// between slots carry rewritten keys or a later copy at the new slot would not dedup.
  static func movingChannel(_ key: String, from oldIndex: UInt8, to newIndex: UInt8) -> String {
    let oldPrefix = "\(channelPrefix)\(oldIndex)-"
    guard key.hasPrefix(oldPrefix) else { return key }
    return "\(channelPrefix)\(newIndex)-" + key.dropFirst(oldPrefix.count)
  }

  static func contentBased(
    contactID: UUID?,
    channelIndex: UInt8?,
    senderNodeName: String?,
    timestamp: UInt32,
    content: String
  ) -> String {
    let contentHash = SHA256.hash(data: Data(content.utf8))
    let hashPrefix = contentHash.prefix(4).map { String(format: "%02X", $0) }.joined()
    if let channelIndex {
      return "\(channelPrefix)\(channelIndex)-\(timestamp)-\(senderNodeName ?? "")-\(hashPrefix)"
    }
    let contactSegment = contactID?.uuidString ?? unknownContactPlaceholder
    return "\(directMessagePrefix)\(contactSegment)-\(timestamp)-\(hashPrefix)"
  }
}
