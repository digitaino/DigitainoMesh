import Foundation
import SwiftData

public extension PersistenceStore {
  // MARK: - Identity Deletions

  func recordIdentityDeletion(radioID: UUID, kind: IdentityDeletionKind, key: Data) throws {
    for existing in try identityDeletionModels(radioID: radioID, kind: kind, keys: [key]) {
      modelContext.delete(existing)
    }
    modelContext.insert(IdentityDeletion(radioID: radioID, kind: kind, key: key, deletedAt: Date()))
    try modelContext.save()
  }

  func fetchIdentityDeletions(radioID: UUID, kind: IdentityDeletionKind) throws -> [Data: Date] {
    let targetRadioID = radioID
    let kindRaw = kind.rawValue
    let predicate = #Predicate<IdentityDeletion> { deletion in
      deletion.radioID == targetRadioID && deletion.kindRawValue == kindRaw
    }
    let rows = try modelContext.fetch(FetchDescriptor(predicate: predicate))
    return Dictionary(rows.map { ($0.key, $0.deletedAt) }, uniquingKeysWith: { lhs, rhs in max(lhs, rhs) })
  }

  /// Drops the records for keys that are being stored again. Staged on the context without
  /// saving, so it commits with the save that stores them.
  internal func stageClearingIdentityDeletions(radioID: UUID, kind: IdentityDeletionKind, keys: [Data]) throws {
    guard !keys.isEmpty else { return }
    for existing in try identityDeletionModels(radioID: radioID, kind: kind, keys: keys) {
      modelContext.delete(existing)
    }
  }

  private func identityDeletionModels(radioID: UUID, kind: IdentityDeletionKind, keys: [Data]) throws -> [IdentityDeletion] {
    let targetRadioID = radioID
    let kindRaw = kind.rawValue
    let predicate = #Predicate<IdentityDeletion> { deletion in
      deletion.radioID == targetRadioID && deletion.kindRawValue == kindRaw
    }
    let wanted = Set(keys)
    return try modelContext.fetch(FetchDescriptor(predicate: predicate)).filter { wanted.contains($0.key) }
  }
}
