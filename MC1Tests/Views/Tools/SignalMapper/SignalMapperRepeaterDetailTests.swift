import Foundation
import MapperRawLog
@testable import MC1
import MC1Services
import Testing

/// The repeater sheet's subtitle date (docs/SIGNAL_MAPPER_V3.md §8).
///
/// "In this hexagon · N heard directly · since D" is a claim about evidence, and D used to
/// be read off the *fetch window* — which under All time is `.distantPast`. Since
/// 2026-09-04 a repeater can be listed on the strength of an echo whose first hop it was,
/// with no row in the hexagon naming it, and the sheet then had no rows to bound D with.
@Suite("Signal mapper repeater detail")
@MainActor
struct SignalMapperRepeaterDetailTests {
  private let cellRaw: UInt64 = 0x0892_8308_280F_FFFF
  private let start = Date(timeIntervalSince1970: 1_753_000_000)

  private func at(_ offset: TimeInterval) -> Date {
    start.addingTimeInterval(offset)
  }

  private func row(_ offset: TimeInterval) -> MapperRawSampleDTO {
    MapperRawSampleDTO(
      runID: nil,
      seq: Int64(offset),
      timestamp: at(offset),
      kindRaw: MapperRawSampleKind.passiveRx.rawValue,
      rxSnr: 6,
      repeaterHexID: "0C13",
      cellRaw: cellRaw,
      gateOutcomeRaw: MapperGateOutcome.accepted.rawValue
    )
  }

  /// The defect: an echo-only repeater under All time. `repeaterRows` is empty and `since`
  /// is `.distantPast`, which the day template prints as "1 Jan" (or "31 Dec" west of UTC)
  /// — a date that reads as this year, on a sheet about evidence from minutes ago.
  @Test
  func `A repeater with no rows of its own dates from its own evidence, not the window`() {
    let evidence = at(500)
    let printed = SignalMapperRepeaterDetailView.evidenceStart(
      in: [],
      window: .distantPast,
      lastEvidenceAt: evidence
    )
    #expect(printed == evidence)
    #expect(printed != .distantPast)
  }

  /// The window still wins when it is the later of the two: a ride scope must not advertise
  /// evidence from before the ride started.
  @Test
  func `The ride window still bounds the date from below`() {
    let rideStart = at(100)
    #expect(SignalMapperRepeaterDetailView.evidenceStart(
      in: [],
      window: rideStart,
      lastEvidenceAt: at(50)
    ) == rideStart)

    #expect(SignalMapperRepeaterDetailView.evidenceStart(
      in: [row(10), row(30)],
      window: rideStart,
      lastEvidenceAt: at(500)
    ) == rideStart)
  }

  /// With rows in hand nothing changed: the oldest one is still the date, and the fallback
  /// never gets a look in.
  @Test
  func `The oldest row we hold is still the date when there is one`() {
    #expect(SignalMapperRepeaterDetailView.evidenceStart(
      in: [row(300), row(120), row(900)],
      window: .distantPast,
      lastEvidenceAt: at(900)
    ) == at(120))
  }
}
