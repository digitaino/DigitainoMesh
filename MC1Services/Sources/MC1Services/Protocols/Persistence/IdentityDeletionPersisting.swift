import Foundation

/// Store operations for ``IdentityDeletion`` records.
public protocol IdentityDeletionPersisting: Actor {
  /// Records that the user deleted `key` (a contact's public key or a channel's secret) from
  /// the identity, replacing any earlier record of it.
  func recordIdentityDeletion(radioID: UUID, kind: IdentityDeletionKind, key: Data) async throws

  /// The identity's deletions of `kind`, by key, with when each happened.
  func fetchIdentityDeletions(radioID: UUID, kind: IdentityDeletionKind) async throws -> [Data: Date]
}
