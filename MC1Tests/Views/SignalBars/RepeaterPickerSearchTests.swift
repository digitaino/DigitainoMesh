import Foundation
@testable import MC1
import MC1Services
import Testing

/// Pins the picker's search behaviour, which was untested while it carried its own
/// `matches(query:)`. The retarget onto ``NodeSearchEngine`` (Phase 5 · §2.2) has to keep
/// every rule the old matcher had, and must not disturb `RepeaterCandidateSource.ordered`.
@Suite("Repeater picker search")
@MainActor
struct RepeaterPickerSearchTests {
  private let engine = NodeSearchEngine()

  private func candidate(
    _ name: String?,
    key prefix: [UInt8],
    fill: UInt8 = 0x77,
    isFavorite: Bool = false,
    isHeard: Bool = false,
    lastSeen: Date? = nil
  ) -> RepeaterCandidate {
    let publicKey = Data(prefix) + Data(repeating: fill, count: 32 - prefix.count)
    return RepeaterCandidate(
      publicKey: publicKey,
      name: name,
      hexID: NodeHexID(data: publicKey.prefix(1))!,
      isFavorite: isFavorite,
      lastSeen: lastSeen,
      isHeard: isHeard,
      rxQuality: .unknown
    )
  }

  /// What `RepeaterPickerView.filtered` does: search over the source's ordering, letting
  /// relevance re-rank stably on top of it.
  private func filtered(_ query: String, _ candidates: [RepeaterCandidate]) -> [String] {
    engine.matches(
      searchText: query,
      among: candidates,
      options: .default.ordering(.inputOrder)
    ).map(\.displayName)
  }

  // MARK: - Rules carried over from the old matcher

  @Test
  func `an empty or whitespace query matches every candidate`() {
    let pool = [candidate("Tower", key: [0x0A]), candidate("Ridge", key: [0x0C])]
    #expect(filtered("", pool) == ["Tower", "Ridge"])
    #expect(filtered("   ", pool) == ["Tower", "Ridge"])
  }

  @Test
  func `a name substring matches regardless of case`() {
    let pool = [candidate("Tower", key: [0x0A]), candidate("Ridge", key: [0x0C])]
    #expect(filtered("tow", pool) == ["Tower"])
  }

  @Test
  func `surrounding whitespace is trimmed off the query`() {
    let pool = [candidate("Tower", key: [0x0A])]
    #expect(filtered("  Tower  ", pool) == ["Tower"])
  }

  @Test
  func `a non hex query is never compared against key bytes`() {
    // "Zone" contains no hex-only run, so the 0x20-keyed candidate must not match it.
    let pool = [candidate("Tower", key: [0x20, 0x0E]), candidate("Zone", key: [0xFF])]
    #expect(filtered("Zone", pool) == ["Zone"])
  }

  @Test
  func `a hex query matches on the public key prefix`() {
    let pool = [candidate("Tower", key: [0x0A, 0xBC]), candidate("Ridge", key: [0x0C])]
    #expect(filtered("0ABC", pool) == ["Tower"])
  }

  @Test
  func `an unnamed candidate is findable by the hash it is labelled with`() {
    let pool = [candidate(nil, key: [0x0A, 0xBC])]
    #expect(filtered("0A", pool) == ["0A"])
  }

  // MARK: - Rules the retarget adds

  @Test
  func `a key prefix match outranks a name match`() {
    let pool = [
      candidate("0ABC Depot", key: [0xFF, 0xFF], fill: 0xFF),
      candidate("Tower", key: [0x0A, 0xBC])
    ]
    #expect(filtered("0ABC", pool) == ["Tower", "0ABC Depot"])
  }

  @Test
  func `the sources heard first ordering survives inside a relevance tier`() {
    // `ordered(_:)` puts the heard repeater first; both match on their key prefix, so the
    // search must not reshuffle them.
    let quiet = candidate("Ridge", key: [0x0A, 0x01], lastSeen: .distantPast)
    let heard = candidate("Tower", key: [0x0A, 0x02], isHeard: true, lastSeen: Date())
    let ordered = RepeaterCandidateSource.ordered([quiet, heard])

    #expect(ordered.map(\.displayName) == ["Tower", "Ridge"])
    #expect(filtered("0A", ordered) == ["Tower", "Ridge"])
  }

  @Test
  func `ordering is untouched when nothing is typed`() {
    let quiet = candidate("Ridge", key: [0x0A], lastSeen: .distantPast)
    let favorite = candidate("Barn", key: [0x0B], isFavorite: true, lastSeen: .distantPast)
    let heard = candidate("Tower", key: [0x0C], isHeard: true, lastSeen: Date())
    let ordered = RepeaterCandidateSource.ordered([quiet, favorite, heard])

    #expect(filtered("", ordered) == ordered.map(\.displayName))
  }
}
