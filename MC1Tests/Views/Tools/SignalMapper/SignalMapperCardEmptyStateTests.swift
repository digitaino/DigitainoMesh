import Foundation
@testable import MC1
import Testing

/// What an empty cell card says, and about what.
///
/// Every sentence here is a *claim* — about the hexagon, about the ride, or about the GPS —
/// and the review of 2026-09-04 found three of them being made about the wrong thing: a
/// ride-wide answer printed over a hexagon three kilometres back, a passive-packet count
/// standing in for "the ride has captured nothing", and "nothing heard here" printed beside
/// a header counting packets. These pin the two pure functions those answers now come from.
@Suite("Signal mapper card empty state")
@MainActor
struct SignalMapperCardEmptyStateTests {
  // MARK: - Which kind of nothing

  /// The rider's own hexagon, over the ride window, is the only card the ride-wide answers
  /// may appear on.
  @Test
  func `The ride-wide answers are only offered for the live hexagon in the ride window`() {
    // The live cell during a ride: the state both sentences were written for.
    #expect(SignalMapperCardEmptyReason.resolve(
      isTappedHexagon: false,
      scope: .ride,
      isRejectingFixes: true,
      isQualityRejection: true,
      rideEvidenceCount: 0
    ) == .fixesRejected)

    // A hexagon the rider tapped is a question about *that* place. Answering "GPS too poor
    // to place anything here" about somewhere the phone has not been this ride blames the
    // wrong thing twice over.
    #expect(SignalMapperCardEmptyReason.resolve(
      isTappedHexagon: true,
      scope: .ride,
      isRejectingFixes: true,
      isQualityRejection: true,
      rideEvidenceCount: 0
    ) == .nothingHere)

    // So is the All time window, which is what the switch forces outside a ride.
    #expect(SignalMapperCardEmptyReason.resolve(
      isTappedHexagon: false,
      scope: .allTime,
      isRejectingFixes: true,
      isQualityRejection: true,
      rideEvidenceCount: 0
    ) == .nothingHere)
  }

  /// "No fix at all" and "the fix is too vague" are two problems with two answers, and only
  /// the second one is about accuracy. The strip has drawn this line since M3.5.
  @Test
  func `A run of refusals with no fix behind it does not blame GPS accuracy`() {
    #expect(SignalMapperCardEmptyReason.resolve(
      isTappedHexagon: false,
      scope: .ride,
      isRejectingFixes: true,
      isQualityRejection: false,
      rideEvidenceCount: 0
    ) == .noFixYet)
  }

  /// Finding 7's ride: probes out, trace and discover replies back, no other RF. Not one
  /// `passiveRx` row for the whole ride — so the legend's observation count is 0 while the
  /// hexagon behind the rider lists repeaters, and the empty-state test must not read that
  /// as "the ride has captured nothing".
  @Test
  func `A probe-reply-only ride has captured something`() {
    #expect(SignalMapperCardEmptyReason.resolve(
      isTappedHexagon: false,
      scope: .ride,
      isRejectingFixes: false,
      isQualityRejection: false,
      rideEvidenceCount: 6
    ) == .nothingHere)

    #expect(SignalMapperCardEmptyReason.resolve(
      isTappedHexagon: false,
      scope: .ride,
      isRejectingFixes: false,
      isQualityRejection: false,
      rideEvidenceCount: 0
    ) == .nothingYet, "a ride that really has heard nothing anywhere still says so")
  }

  // MARK: - The sentence itself

  /// The card may not deny a count its own pinned header is printing.
  ///
  /// A hexagon whose rows are all direct-routed, or 0-hop and not adverts, credits no
  /// repeater under §1: the list is empty and "12 heard" sits above it. "Nothing heard here
  /// this ride" is then simply false.
  @Test
  func `An empty list beside a non-zero heard count says what is missing, not that nothing was heard`() {
    let text = SignalMapperCellCard.emptyText(reason: .nothingHere, scope: .ride, heardCount: 12)
    #expect(text == L10n.Tools.Tools.SignalMapper.Card.noneAttributable(12))
    #expect(text != L10n.Tools.Tools.SignalMapper.Card.nothingThisRide)

    // The same claim is just as false on the all-time window, so this is keyed on the count
    // and not on the scope or the layer.
    #expect(
      SignalMapperCellCard.emptyText(reason: .nothingHere, scope: .allTime, heardCount: 12)
        == L10n.Tools.Tools.SignalMapper.Card.noneAttributable(12)
    )
  }

  @Test
  func `A hexagon that really heard nothing still blames the hexagon`() {
    #expect(
      SignalMapperCellCard.emptyText(reason: .nothingHere, scope: .ride, heardCount: 0)
        == L10n.Tools.Tools.SignalMapper.Card.nothingThisRide
    )
    #expect(
      SignalMapperCellCard.emptyText(reason: .nothingHere, scope: .allTime, heardCount: 0)
        == L10n.Tools.Tools.SignalMapper.Detail.noPacketsHeard
    )
  }

  /// The ride-wide answers outrank the hexagon's own, count or no count: if nothing anywhere
  /// is being placed, the hexagon is not what is empty.
  @Test
  func `The ride-wide answers are not overridden by a heard count`() {
    #expect(
      SignalMapperCellCard.emptyText(reason: .fixesRejected, scope: .ride, heardCount: 12)
        == L10n.Tools.Tools.SignalMapper.Card.fixesRejected
    )
    #expect(
      SignalMapperCellCard.emptyText(reason: .noFixYet, scope: .ride, heardCount: 12)
        == L10n.Tools.Tools.SignalMapper.Card.noFixYet
    )
    #expect(
      SignalMapperCellCard.emptyText(reason: .nothingYet, scope: .ride, heardCount: 0)
        == L10n.Tools.Tools.SignalMapper.Card.nothingYet
    )
  }
}
