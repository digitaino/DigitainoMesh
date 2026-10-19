import Foundation
@testable import MC1
@testable import MC1Services
import Testing

/// `MentionUtilities.filterContacts` hands back the most recent sender first, and the popup is
/// anchored above the composer — so rendering that order verbatim puts the likeliest pick at the
/// top of the list, farthest from the thumb. The view reverses it. The scroll-park that keeps the
/// bottom row on screen when the list overflows is device-only; this guards the ordering.
@Suite("Mention Suggestion Ordering")
@MainActor
struct MentionSuggestionOrderTests {
  private func makeContact(name: String) -> ContactDTO {
    ContactDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data(repeating: 0, count: ProtocolLimits.publicKeySize),
      name: name,
      typeRawValue: ContactType.chat.rawValue,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: false,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: nil,
      unreadCount: 0
    )
  }

  @Test
  func `Most recent sender renders on the bottom row, nearest the composer`() {
    let recent = makeContact(name: "Recent")
    let middle = makeContact(name: "Middle")
    let oldest = makeContact(name: "Oldest")
    let view = MentionSuggestionView(contacts: [recent, middle, oldest], onSelect: { _ in })

    #expect(view.suggestions.map(\.id) == [oldest.id, middle.id, recent.id])
  }

  @Test
  func `Suggestions cap keeps the twenty most recent, not the twenty oldest`() {
    // The cap is applied before the reversal, so it must trim the tail of the
    // recency-ordered input rather than the head of the displayed one.
    let contacts = (0..<25).map { makeContact(name: "Node\($0)") }
    let view = MentionSuggestionView(contacts: contacts, onSelect: { _ in })

    #expect(view.suggestions.count == 20)
    #expect(view.suggestions.last?.id == contacts.first?.id)
    #expect(view.suggestions.first?.id == contacts[19].id)
  }

  @Test
  func `An empty contact list yields no rows`() {
    let view = MentionSuggestionView(contacts: [], onSelect: { _ in })
    #expect(view.suggestions.isEmpty)
  }
}
