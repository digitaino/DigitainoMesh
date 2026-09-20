import Foundation
import MapperRawLog
import MC1Services
import SurveyKit

/// Which window the card is reading (§3, mockup screen 3).
enum SignalMapperCardScope: String, Hashable, CaseIterable, Identifiable {
  /// Rows stamped since the open ride started. The default while riding: the question on
  /// a ride is what is happening *now*, not what a hexagon has ever been worth.
  case ride
  /// Everything inside retention.
  case allTime

  var id: String {
    rawValue
  }
}

// MARK: - Empty states

/// Why a hexagon's card has no rows.
///
/// Three different facts wore one sentence until 2026-09-04, and the sentence blamed the
/// hexagon for all three: a rider whose GPS was being refused, and a rider whose ride had
/// captured nothing at all, both read "Nothing heard here this ride" — which is a claim
/// about the *place*, and in both cases false.
enum SignalMapperCardEmptyReason: Hashable, Sendable {
  /// The ride (or the log) has evidence elsewhere; this hexagon simply has none.
  case nothingHere
  /// Nothing has been captured anywhere yet — the ride is young, or the radio is silent.
  case nothingYet
  /// Fixes exist and are being refused for quality, so nothing the radio hears can be
  /// placed anywhere.
  case fixesRejected
  /// There is no fix at all yet — the warm-up, garage and tunnel case.
  ///
  /// Split from ``fixesRejected`` because that sentence makes a claim about *accuracy*, and
  /// a run of pure `droppedNoFixCount` has no accuracy to be poor: the strip has drawn the
  /// same distinction since M3.5 (`isRejectingFixes && isQualityRejection`) and the card
  /// was the one surface still printing one sentence for both.
  case noFixYet

  /// Which kind of nothing an empty card is looking at, in the order the answers matter:
  /// a refused fix explains every empty hexagon at once, a ride that has captured nothing
  /// anywhere explains this one, and only then is the hexagon itself the answer.
  ///
  /// The first two are claims about the rider's *here and now*, so both are gated on the
  /// card actually showing the rider's own hexagon over the ride window. A tapped hexagon
  /// three kilometres back, or the All time window, is neither — answering "GPS too poor to
  /// place anything here" about a place the phone has not been this ride is a statement
  /// about the wrong hexagon and the wrong window at once.
  ///
  /// `scope == .ride` already implies a ride is open (the view forces `.allTime` outside
  /// one), so it subsumes the old `isSurveying` test rather than sitting beside it.
  ///
  /// A pure function of five plain values so the order of blame is pinned by a test rather
  /// than by reading the view.
  static func resolve(
    isTappedHexagon: Bool,
    scope: SignalMapperCardScope,
    isRejectingFixes: Bool,
    isQualityRejection: Bool,
    rideEvidenceCount: Int
  ) -> SignalMapperCardEmptyReason {
    guard !isTappedHexagon, scope == .ride else { return .nothingHere }
    if isRejectingFixes {
      return isQualityRejection ? .fixesRejected : .noFixYet
    }
    if rideEvidenceCount == 0 {
      return .nothingYet
    }
    return .nothingHere
  }
}

// MARK: - Uplink

/// What one repeater has reported about *us* in one hexagon.
///
/// `MapperRepeaterRow` carries the latest reported reading and nothing more, because §3's
/// Hear layer only ever prints "hears you N dB". The Reach layer leads with the uplink
/// (mockup screen 2) and wants the same `now · best · avg` shape the downlink gets, so this
/// folds it from the same rows — the identical rule the query uses: **only a trace or
/// discover reply carries a number** (§1 (b)); an echo's SNR is our reading of the
/// rebroadcast and would invent an uplink measurement.
struct SignalMapperUplinkStats: Hashable, Sendable {
  let latest: Double
  let best: Double
  let average: Double
  let count: Int
  let latestAt: Date
}

// MARK: - Rows

/// One repeater as the card lists it: the query's row, plus the name the app resolved for
/// it and the uplink fold the Reach layer needs.
struct SignalMapperRepeaterListRow: Identifiable, Equatable, Sendable {
  let row: MapperRepeaterRow
  /// The resolved node's name, or nil when no known node answers to this hash.
  let name: String?
  /// Whether more than one known node answers to this hash, so `name` is a best guess.
  let isAmbiguous: Bool
  let uplink: SignalMapperUplinkStats?

  var id: String {
    row.hexID
  }

  var hexID: String {
    row.hexID
  }
}

/// Everything the card and the repeater detail read for one hexagon.
struct SignalMapperCardData: Equatable, Sendable {
  let cell: H3Cell
  let scope: SignalMapperCardScope
  /// The window the rows were fetched over — the repeater detail's "since".
  let since: Date
  let headline: MapperCellHeadline
  let repeaters: [SignalMapperRepeaterListRow]
  /// The cell's raw rows, newest first: what the repeater detail charts and lists. Held
  /// rather than re-fetched, so opening a repeater is free.
  let rows: [MapperRawSampleDTO]
}

// MARK: - Builder

/// Rows in, card out. A pure function of its arguments — no store, no radio, no map — so
/// the card's arithmetic is testable the way ``MapperCellQueries`` is.
///
/// Names come from ``NodeIdentityResolving`` or the hash stands. Nothing here compares hex
/// strings, which is the same rule `SignalMapperCoverageBuilder` follows and the reason a
/// name is never invented from a prefix that merely looks familiar (MIGRATION_PLAN §2.1).
struct SignalMapperCardBuilder: Sendable {
  private let resolver: any NodeIdentityResolving

  init(resolver: any NodeIdentityResolving = NodeIdentityResolver()) {
    self.resolver = resolver
  }

  func build(
    cell: H3Cell,
    scope: SignalMapperCardScope,
    since: Date,
    rows: [MapperRawSampleDTO],
    candidates: [AnyResolvableNode] = [],
    now: Date,
    overrides: NodeIdentityOverrides = [:]
  ) -> SignalMapperCardData {
    let uplinks = Self.uplinkStats(in: rows, now: now)
    var names: [String: ResolvedName] = [:]
    let repeaters = MapperCellQueries.repeaterRows(in: rows, now: now).map { row in
      let resolved = resolvedName(
        for: row.hexID,
        candidates: candidates,
        now: now,
        overrides: overrides,
        cache: &names
      )
      return SignalMapperRepeaterListRow(
        row: row,
        name: resolved.name,
        isAmbiguous: resolved.isAmbiguous,
        uplink: uplinks[row.hexID]
      )
    }
    return SignalMapperCardData(
      cell: cell,
      scope: scope,
      since: since,
      headline: MapperCellQueries.cellHeadline(in: rows, now: now),
      repeaters: repeaters,
      rows: rows
    )
  }

  /// Folds every reply that reported an SNR for us, per repeater.
  ///
  /// Order-independent for the same reason the queries are: a reply settles after the
  /// packets heard while waiting for it, so "latest" is decided by timestamp and never by
  /// position in the array.
  ///
  /// Keyed on the *canonical* hash, exactly as `MapperCellQueries.repeaterRows` is: the two
  /// are joined by that key in `build(…)`, so a repeater whose replies arrived under a
  /// 1-byte path hash and whose receptions arrived under the 2-byte one would otherwise
  /// have its uplink dropped on the floor by the very merge that made the row (2026-09-05).
  static func uplinkStats(in rows: [MapperRawSampleDTO], now: Date) -> [String: SignalMapperUplinkStats] {
    let canonical = MapperCellQueries.canonicalHexIDs(in: rows, now: now)
    var folds: [String: Fold] = [:]
    for row in rows where row.timestamp <= now {
      guard let kind = row.kind, kind == .probeTraceReply || kind == .probeDiscoverResponse,
            let hexID = row.repeaterHexID, let txSnr = row.txSnr else { continue }
      folds[canonical[hexID] ?? hexID, default: Fold()].fold(at: row.timestamp, snr: txSnr)
    }
    return folds.compactMapValues(\.stats)
  }

  // MARK: - Internals

  private struct Fold {
    var latest: Double = 0
    var latestAt: Date?
    var best: Double?
    var sum: Double = 0
    var count = 0

    mutating func fold(at timestamp: Date, snr: Double) {
      sum += snr
      count += 1
      best = best.map { Swift.max($0, snr) } ?? snr
      guard latestAt.map({ timestamp > $0 }) ?? true else { return }
      latestAt = timestamp
      latest = snr
    }

    var stats: SignalMapperUplinkStats? {
      guard let latestAt, let best, count > 0 else { return nil }
      return SignalMapperUplinkStats(
        latest: latest,
        best: best,
        average: sum / Double(count),
        count: count,
        latestAt: latestAt
      )
    }
  }

  private struct ResolvedName {
    var name: String?
    var isAmbiguous: Bool
  }

  private func resolvedName(
    for hexID: String,
    candidates: [AnyResolvableNode],
    now: Date,
    overrides: NodeIdentityOverrides,
    cache: inout [String: ResolvedName]
  ) -> ResolvedName {
    if let hit = cache[hexID] { return hit }
    let resolved = if let id = NodeHexID(hexID),
                      let resolution = resolver.resolve(id, among: candidates, now: now, overrides: overrides) {
      ResolvedName(name: resolution.best.resolvableName, isAmbiguous: resolution.isAmbiguous)
    } else {
      ResolvedName(name: nil, isAmbiguous: false)
    }
    cache[hexID] = resolved
    return resolved
  }
}
