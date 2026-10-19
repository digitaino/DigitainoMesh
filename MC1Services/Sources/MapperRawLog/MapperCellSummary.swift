import Foundation
import MC1Services
import SwiftData

// MARK: - Model

/// What one hexagon adds up to, all-time within retention: a *derived* row, rebuildable
/// from the samples at any moment (docs/SIGNAL_MAPPER_V3.md §7 step 3).
///
/// **Why a cache at all**, when §2 says no pre-aggregation is the source of anything.
/// It is not a source: every field here is a fold of rows that are still there, and
/// ``MapperRawLogStore/rebuildAllSummaries()`` reproduces the whole table from them. What
/// it buys is the map. A 90-day always-on log is hundreds of thousands of rows at ~400
/// bytes each (``MapperRawLogStore/approximateBytesPerRow``), and painting two layers
/// means "best SNR per cell" over all of them — a full scan per pan, per zoom, per layer
/// switch. The card still reads rows (``MapperCellQueries``); only the map reads this.
///
/// **Why it cannot drift.** One fold function, ``MapperCellSummaryFold/fold(_:)``, is used
/// by both the write path and the rebuild path, so "the cache agrees with the rows" is a
/// property of there being a single implementation rather than of two implementations
/// being kept in step. Deletes rebuild rather than subtract: `rxBestSnr` is a maximum, and
/// a maximum whose row was just purged cannot be undone arithmetically.
///
/// **Privacy.** Cells only — no latitude, no longitude, no repeater identity, no packet
/// hash, no name. A per-cell fold is already a coarse movement summary (§3.1 of
/// ACTIVE_SURVEY_M3_5 is why the aggregate store buckets), so the row keeps the H3 index
/// and nothing that could sharpen it. `MapperRawLogPrivacyInvariantTests` pins that.
@Model
final class MapperCellSummary {
  #Unique<MapperCellSummary>([\.cellRaw])

  /// The H3 index as the **bit pattern** of the 64-bit value, for the reason
  /// ``MapperRawSample/cellRaw`` spells out: SQLite's integer column is signed, and
  /// storing the bit pattern is what makes the round trip lossless. Non-optional here —
  /// a summary of "nowhere" is not a thing, and rows with no cell simply do not fold.
  var cellRaw: Int64

  // MARK: - RX: repeaters we heard, here

  /// Best/sum/count/last over rows that credit a repeater *and* carry our own reading of
  /// it (`rxSnr != nil && repeaterHexID != nil`) — §1's "heard directly": a flood's last
  /// hop, a path-less advert's sender, a probe replier, an echo's last hop. A
  /// direct-routed packet credits nobody (§1), so it lands in ``heardCount`` and never
  /// in these.
  var rxBestSnr: Double?
  var rxSnrSum: Double = 0
  var rxSnrCount: Int = 0
  var rxLastAt: Date?

  // MARK: - TX: repeaters that reported hearing us, here

  /// Best/sum/count/last over probe replies carrying a `txSnr` — §1's (b), the only
  /// evidence that comes with a number.
  var txBestSnr: Double?
  var txSnrSum: Double = 0
  var txSnrCount: Int = 0
  var txLastAt: Date?

  // MARK: - Presence

  /// Echoes of our own packets (`txHeard`): §1's (a). The first hop of the echo heard our
  /// radio, which makes this uplink *fact* without an uplink number — the TX layer's
  /// neutral "heard you" fill.
  var echoCount: Int = 0
  var echoLastAt: Date?

  /// Probe transmissions from this cell (`probeAttempt`). With ``hasHeardYou`` false this
  /// is what separates "we asked and nobody answered" (the "no reach" fill) from "we never
  /// asked here" (no fill at all) — §1's TX layer.
  var probesSent: Int = 0

  /// Our own transmissions from this cell (`sent`): the denominator of reach (§4).
  var sentCount: Int = 0

  /// Passively received packets (`passiveRx`), whoever they credited. The card's
  /// "1,048 heard" (§3).
  var heardCount: Int = 0

  var firstAt: Date?
  var lastAt: Date?

  init(cellRaw: Int64) {
    self.cellRaw = cellRaw
  }
}

// MARK: - Fold

/// One row's worth of the five columns a summary is made of.
///
/// A shape rather than a pair of overloads because the write path folds
/// ``MapperRawSampleEvent``s and the rebuild path folds stored ``MapperRawSample``s, and
/// the whole point of the cache is that those two paths compute the same thing.
struct MapperCellSummaryInput {
  let cellRaw: Int64
  let timestamp: Date
  let kindRaw: Int
  let rxSnr: Double?
  let txSnr: Double?
  /// Whether the row credits a repeater at all — §1's attribution rule, already applied by
  /// the producer, which is why this is a bool and not an identity.
  let creditsRepeater: Bool

  init?(event: MapperRawSampleEvent) {
    guard let cellRaw = event.cellRaw else { return nil }
    self.cellRaw = Int64(bitPattern: cellRaw)
    timestamp = event.timestamp
    kindRaw = event.kind.rawValue
    rxSnr = event.rxSnr
    txSnr = event.txSnr
    creditsRepeater = event.repeaterHexID != nil
  }

  init?(model: MapperRawSample) {
    guard let cellRaw = model.cellRaw else { return nil }
    self.cellRaw = cellRaw
    timestamp = model.timestamp
    kindRaw = model.kindRaw
    rxSnr = model.rxSnr
    txSnr = model.txSnr
    creditsRepeater = model.repeaterHexID != nil
  }
}

/// The accumulator both paths run through: load, fold, store.
///
/// Kept as a value type so a rebuild can hold a few thousand of these in a dictionary
/// while it walks the table, without any of them being a live SwiftData object.
struct MapperCellSummaryFold {
  var rxBestSnr: Double?
  var rxSnrSum: Double = 0
  var rxSnrCount: Int = 0
  var rxLastAt: Date?

  var txBestSnr: Double?
  var txSnrSum: Double = 0
  var txSnrCount: Int = 0
  var txLastAt: Date?

  var echoCount: Int = 0
  var echoLastAt: Date?
  var probesSent: Int = 0
  var sentCount: Int = 0
  var heardCount: Int = 0

  var firstAt: Date?
  var lastAt: Date?

  /// True for a fold that has seen nothing — the signal for "delete this summary" after a
  /// purge took a cell's last row.
  var isEmpty: Bool {
    lastAt == nil
  }

  init() {}

  /// Continues from what is already stored, so an insert is a fold of the *new* rows only
  /// rather than a re-read of the cell's history.
  init(model: MapperCellSummary) {
    rxBestSnr = model.rxBestSnr
    rxSnrSum = model.rxSnrSum
    rxSnrCount = model.rxSnrCount
    rxLastAt = model.rxLastAt
    txBestSnr = model.txBestSnr
    txSnrSum = model.txSnrSum
    txSnrCount = model.txSnrCount
    txLastAt = model.txLastAt
    echoCount = model.echoCount
    echoLastAt = model.echoLastAt
    probesSent = model.probesSent
    sentCount = model.sentCount
    heardCount = model.heardCount
    firstAt = model.firstAt
    lastAt = model.lastAt
  }

  /// Adds one row. Order-independent by construction — every field is a max, a min, a sum
  /// or a count — because rows do not arrive in timestamp order: a probe reply settles
  /// after the packets heard while waiting for it, and an echo can back-fill minutes late.
  mutating func fold(_ input: MapperCellSummaryInput) {
    firstAt = Self.earlier(firstAt, input.timestamp)
    lastAt = Self.later(lastAt, input.timestamp)

    // §1 "heard directly": our reading of a repeater we can name. The kind is not
    // consulted — a flood, an advert, an echo's last hop and a probe reply are all our
    // radio measuring somebody else's — but the credit is, and a direct-routed packet
    // carries none.
    if let rxSnr = input.rxSnr, input.creditsRepeater {
      rxBestSnr = Self.larger(rxBestSnr, rxSnr)
      rxSnrSum += rxSnr
      rxSnrCount += 1
      rxLastAt = Self.later(rxLastAt, input.timestamp)
    }

    switch MapperRawSampleKind(rawValue: input.kindRaw) {
    case .probeTraceReply, .probeDiscoverResponse:
      // §1 (b): the only evidence that comes with a number, and it comes only from a
      // reply. An echo's SNR is *our* reading of the rebroadcast, not the repeater's
      // reading of us, and folding it here would invent an uplink measurement.
      if let txSnr = input.txSnr {
        txBestSnr = Self.larger(txBestSnr, txSnr)
        txSnrSum += txSnr
        txSnrCount += 1
        txLastAt = Self.later(txLastAt, input.timestamp)
      }
    case .txHeard:
      echoCount += 1
      echoLastAt = Self.later(echoLastAt, input.timestamp)
    case .probeAttempt:
      probesSent += 1
    case .sent:
      sentCount += 1
    case .passiveRx:
      heardCount += 1
    default:
      // Every other kind still moves `firstAt`/`lastAt` above: a cell where the radio link
      // dropped and nothing else happened is a cell we were in.
      break
    }
  }

  /// Writes the fold onto its row. The only place a summary column is assigned.
  func apply(to model: MapperCellSummary) {
    model.rxBestSnr = rxBestSnr
    model.rxSnrSum = rxSnrSum
    model.rxSnrCount = rxSnrCount
    model.rxLastAt = rxLastAt
    model.txBestSnr = txBestSnr
    model.txSnrSum = txSnrSum
    model.txSnrCount = txSnrCount
    model.txLastAt = txLastAt
    model.echoCount = echoCount
    model.echoLastAt = echoLastAt
    model.probesSent = probesSent
    model.sentCount = sentCount
    model.heardCount = heardCount
    model.firstAt = firstAt
    model.lastAt = lastAt
  }

  private static func larger(_ current: Double?, _ candidate: Double) -> Double {
    guard let current else { return candidate }
    return Swift.max(current, candidate)
  }

  private static func later(_ current: Date?, _ candidate: Date) -> Date {
    guard let current else { return candidate }
    return Swift.max(current, candidate)
  }

  private static func earlier(_ current: Date?, _ candidate: Date) -> Date {
    guard let current else { return candidate }
    return Swift.min(current, candidate)
  }
}

// MARK: - DTO

/// Sendable snapshot of one cell's summary: what the map reads.
///
/// **Deliberately not `Codable`**, for the reason ``MapperRawSampleDTO`` is not. This one
/// carries no coordinate, but a table of it is still "every hexagon this phone has been in,
/// when, and how often" — the shape §2.8 says may only leave the module through the app
/// target's explicit, scrubbing export encoder.
public struct MapperCellSummaryDTO: Sendable, Equatable {
  /// The H3 index, converted back from the row's stored bit pattern.
  public let cellRaw: UInt64

  public let rxBestSnr: Double?
  public let rxSnrSum: Double
  public let rxSnrCount: Int
  public let rxLastAt: Date?

  public let txBestSnr: Double?
  public let txSnrSum: Double
  public let txSnrCount: Int
  public let txLastAt: Date?

  public let echoCount: Int
  public let echoLastAt: Date?
  public let probesSent: Int
  public let sentCount: Int
  public let heardCount: Int

  public let firstAt: Date?
  public let lastAt: Date?

  public init(
    cellRaw: UInt64,
    rxBestSnr: Double? = nil,
    rxSnrSum: Double = 0,
    rxSnrCount: Int = 0,
    rxLastAt: Date? = nil,
    txBestSnr: Double? = nil,
    txSnrSum: Double = 0,
    txSnrCount: Int = 0,
    txLastAt: Date? = nil,
    echoCount: Int = 0,
    echoLastAt: Date? = nil,
    probesSent: Int = 0,
    sentCount: Int = 0,
    heardCount: Int = 0,
    firstAt: Date? = nil,
    lastAt: Date? = nil
  ) {
    self.cellRaw = cellRaw
    self.rxBestSnr = rxBestSnr
    self.rxSnrSum = rxSnrSum
    self.rxSnrCount = rxSnrCount
    self.rxLastAt = rxLastAt
    self.txBestSnr = txBestSnr
    self.txSnrSum = txSnrSum
    self.txSnrCount = txSnrCount
    self.txLastAt = txLastAt
    self.echoCount = echoCount
    self.echoLastAt = echoLastAt
    self.probesSent = probesSent
    self.sentCount = sentCount
    self.heardCount = heardCount
    self.firstAt = firstAt
    self.lastAt = lastAt
  }

  init(from model: MapperCellSummary) {
    self.init(
      cellRaw: UInt64(bitPattern: model.cellRaw),
      rxBestSnr: model.rxBestSnr,
      rxSnrSum: model.rxSnrSum,
      rxSnrCount: model.rxSnrCount,
      rxLastAt: model.rxLastAt,
      txBestSnr: model.txBestSnr,
      txSnrSum: model.txSnrSum,
      txSnrCount: model.txSnrCount,
      txLastAt: model.txLastAt,
      echoCount: model.echoCount,
      echoLastAt: model.echoLastAt,
      probesSent: model.probesSent,
      sentCount: model.sentCount,
      heardCount: model.heardCount,
      firstAt: model.firstAt,
      lastAt: model.lastAt
    )
  }

  // MARK: - Derived

  /// Computed rather than stored, so the sum and the count are the only things that have
  /// to survive a rebuild and an average can never disagree with them.
  public var rxAverage: Double? {
    rxSnrCount > 0 ? rxSnrSum / Double(rxSnrCount) : nil
  }

  public var txAverage: Double? {
    txSnrCount > 0 ? txSnrSum / Double(txSnrCount) : nil
  }

  /// §1: a repeater heard our radio if our packet came back (an echo's first hop) or if it
  /// replied with the SNR it received us at. Either is enough for the TX layer's fill; only
  /// the second gives it a colour.
  public var hasHeardYou: Bool {
    echoCount > 0 || txSnrCount > 0
  }

  /// We asked here and nobody answered — §1's "no reach" fill. Distinct from a cell with no
  /// TX evidence at all, which is simply a place we never probed.
  public var isUnreachedProbed: Bool {
    probesSent > 0 && !hasHeardYou
  }
}
