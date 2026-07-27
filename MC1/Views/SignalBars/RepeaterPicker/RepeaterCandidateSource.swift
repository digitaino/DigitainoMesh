import Foundation
import MC1Services

/// Builds the candidate list every repeater picker shows.
///
/// Two sources, one list: the radio's saved repeater contacts, and whatever the signal-bars
/// table is currently hearing. Contacts alone would omit a repeater that is plainly in range
/// but has never been added; the table alone would omit one that is saved but quiet. Rows
/// present in both are merged on ``NodeHexID/identifiesSameNode(as:)`` rather than on string
/// equality, because the same node appears at 1-, 2- or 3-byte hash width depending on the
/// path a packet took.
///
/// A table row with no public key is dropped: it cannot be probed, so offering it as a
/// benchmark target or a watch target would only produce failures.
///
/// TODO(Phase5): retarget onto NodeSearch. §2.2's contacts-facing query replaces the manual
/// fetch-and-filter here, and its ranking rules replace ``ordered(_:)``.
@MainActor
enum RepeaterCandidateSource {
  /// Loads and orders the candidate list.
  ///
  /// - Parameters:
  ///   - dataStore: Where saved contacts come from; `nil` yields table rows only.
  ///   - radioID: Scopes the contact fetch to the connected radio.
  ///   - signals: The live signal-bars façade, for heard state and quality.
  ///   - pathHashMode: The radio's hash width, so candidate IDs match the table's.
  static func load(
    dataStore: PersistenceStore?,
    radioID: UUID?,
    signals: RepeaterSignalModel,
    pathHashMode: UInt8
  ) async -> [RepeaterCandidate] {
    let width = hashWidth(pathHashMode: pathHashMode)
    let heard = signals.snapshot.repeaters

    var candidates: [RepeaterCandidate] = []
    var claimed: [NodeHexID] = []

    if let dataStore, let radioID {
      let contacts = await (try? dataStore.fetchContacts(radioID: radioID)) ?? []
      for contact in contacts where contact.type == .repeater {
        guard let hexID = NodeHexID(data: contact.publicKey.prefix(width)) else { continue }
        let row = heard.first { $0.id.identifiesSameNode(as: hexID) }
        claimed.append(hexID)
        candidates.append(RepeaterCandidate(
          publicKey: contact.publicKey,
          name: contact.resolvableName,
          hexID: hexID,
          isFavorite: contact.isFavorite,
          lastSeen: row?.lastHeard ?? Date(timeIntervalSince1970: TimeInterval(contact.lastModified)),
          isHeard: row != nil,
          rxQuality: row?.rxQuality ?? .unknown
        ))
      }
    }

    // Heard but unsaved: worth offering, since the whole point of a range test is measuring
    // repeaters you have not committed to yet.
    for row in heard {
      guard let publicKey = row.publicKey, !publicKey.isEmpty else { continue }
      guard !claimed.contains(where: { $0.identifiesSameNode(as: row.id) }) else { continue }
      claimed.append(row.id)
      candidates.append(RepeaterCandidate(
        publicKey: publicKey,
        name: row.name,
        hexID: row.id,
        isFavorite: false,
        lastSeen: row.lastHeard,
        isHeard: true,
        rxQuality: row.rxQuality
      ))
    }

    return ordered(candidates)
  }

  /// Heard first, then favourites, then most recently seen. What is audible right now is
  /// what a range test is about, so it outranks a starred repeater that has gone quiet.
  static func ordered(_ candidates: [RepeaterCandidate]) -> [RepeaterCandidate] {
    candidates.sorted { lhs, rhs in
      if lhs.isHeard != rhs.isHeard { return lhs.isHeard }
      if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
      return (lhs.lastSeen ?? .distantPast) > (rhs.lastSeen ?? .distantPast)
    }
  }

  /// Routing hash width for the radio's path hash mode: 0/1/2 → 1/2/3 bytes.
  private static func hashWidth(pathHashMode: UInt8) -> Int {
    min(NodeHexID.maxByteWidth, max(1, Int(pathHashMode) + 1))
  }
}
