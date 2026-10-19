import Foundation
import SwiftData

/// What a deletion record is about.
public enum IdentityDeletionKind: UInt8, Sendable {
  /// A contact; the key is its public key.
  case contact = 0
  /// A channel; the key is its secret.
  case channel = 1
}

/// A contact or channel the user deleted from an identity.
///
/// One identity can be on several radios (docs/RADIO_SWAP.md, R1), and a deletion reaches
/// only the radio connected at the time. The record lets a sync with another radio recognise
/// the copy it still holds as stale, remove it from that radio, and not bring it back into
/// the app. Storing the contact or channel again, by the user, an import, or a live add
/// from a radio, clears the record. docs/RADIO_SWAP.md, section 4.4.
@Model
public final class IdentityDeletion {
  public var radioID: UUID = UUID()
  public var kindRawValue: UInt8 = IdentityDeletionKind.contact.rawValue
  public var key: Data = Data()
  public var deletedAt: Date = Date()

  public init(radioID: UUID, kind: IdentityDeletionKind, key: Data, deletedAt: Date) {
    self.radioID = radioID
    kindRawValue = kind.rawValue
    self.key = key
    self.deletedAt = deletedAt
  }

  /// Whether a radio's copy of a deleted contact predates the deletion. A copy the radio wrote
  /// later (it heard the node again and re-added it) is a genuine re-add. Radio clocks are set
  /// from the phone on connect, so the two are comparable; when they are not, the cost is a
  /// node removed once more or kept once more, never a conversation.
  public static func isStaleContactCopy(lastModified: Date, deletedAt: Date?) -> Bool {
    guard let deletedAt else { return false }
    return lastModified <= deletedAt
  }
}
