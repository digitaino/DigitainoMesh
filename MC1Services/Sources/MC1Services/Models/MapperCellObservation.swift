import Foundation
import SurveyKit
import SwiftData

/// One H3 res-9 cell's signal observations for one UTC day.
///
/// The row is the on-device form of SurveyKit's ``AggregatedCell``: the same running sums
/// and counts, split per UTC day so the wire's day granularity (docs/SIGNAL_MAPPER_V2.md
/// §3.4) is already the storage granularity and nothing has to re-bucket timestamps at
/// upload time. Identity is `(cellRaw, day)` — a capture session folds many packets into
/// one row, and a later session folds into the same row rather than appending.
///
/// This is a *new* entity. It has nothing to do with the dormant Build 40 survey tables
/// (``SurveySession`` / ``SignalSurveyPoint``), which stay untouched and are never read
/// into this pipeline — see docs/SIGNAL_MAPPER_V2.md §6.
@Model
final class MapperCellObservation {
  #Unique<MapperCellObservation>([\.cellRaw, \.day])
  #Index<MapperCellObservation>([\.cellRaw, \.day], [\.day])

  /// The H3 res-9 cell index, stored as its raw 64-bit value. The canonical hex string
  /// form is derived on the way out, so the column stays a cheap integer to index on.
  var cellRaw: UInt64

  /// UTC day bucket, `"YYYY-MM-DD"`. A string rather than a `Date` because it is a
  /// *label*, not an instant: sorting and range queries on it are lexicographic and
  /// timezone-free, which is exactly what the day-granularity privacy rule wants.
  var day: String

  // MARK: - Packet counts

  var packetCount: Int
  var activePacketCount: Int
  var passivePacketCount: Int
  var probesSent: Int

  // MARK: - Direction counters

  /// Observations by direction (docs/SIGNAL_MAPPER_V2.md §2.1). Inline defaults so a row
  /// written before these columns existed reads back as zeroes rather than failing to
  /// migrate; ``MapperCellObservationDTO/init(from:)`` re-attributes such a row to `rx`.
  ///
  /// `rxCount + txHeardCount` is the packet-bearing part of ``packetCount``; `ackCount`
  /// counts deliveries, which carry no radio measurement and never fold as packets.
  var rxCount: Int = 0
  var txHeardCount: Int = 0
  var ackCount: Int = 0

  /// How many of this row's observations were captured while the movement hint said the
  /// phone was not moving.
  ///
  /// The dwell signal ``MapperAnchorPolicy`` reads: a cell whose observations are mostly
  /// stationary, on many separate days, is somewhere the user *stays* rather than passes
  /// through, and the mapper excludes those. It has to be a stored column because it is not
  /// reconstructible after the fact — `(cell, day, counts)` cannot say whether the phone was
  /// standing still while the packets arrived.
  ///
  /// This is deliberately the *only* new dwell column. A within-day presence mask (say a
  /// 15-minute bitmap) would detect anchors faster and is exactly what we refuse to store:
  /// it is a residency calendar, and the safest place for one is nowhere.
  var stationaryObservationCount: Int = 0

  /// Round-trip time of acknowledged sends, in milliseconds.
  var rttMsSum: Double = 0
  var rttSampleCount: Int = 0

  /// Round trips of trace probes, client-measured (M3.5). A separate ledger from the
  /// ACK pair above: an end-to-end delivery and a zero-hop trace differ by an order of
  /// magnitude, and one average over both would describe neither.
  var probeRttMsSum: Double = 0
  var probeRttSampleCount: Int = 0

  // MARK: - Signal aggregates

  var snrSum: Double
  var snrCount: Int
  var minSnr: Double?
  var maxSnr: Double?
  var txSnrSum: Double
  var txSnrCount: Int
  /// Best uplink reading — the coverage-coloring number (M3.5: quality follows the best
  /// usable link, not the pooled average). Additive optional, lightweight-safe.
  var maxTxSnr: Double?
  var rssiSum: Double
  var rssiCount: Int

  // MARK: - Route mix

  var floodCount: Int
  var directCount: Int

  // MARK: - Time span

  /// First and last observation folded into this row. Kept at full fidelity locally;
  /// only the `day` label crosses the wire.
  var earliest: Date?
  var latest: Date?

  // MARK: - JSON-encoded aggregates

  /// Hop count → packet count, JSON `{"0": 3, "2": 1}`. JSON rather than a relationship
  /// because it is read and written whole, never queried into.
  var hopHistogramData: Data

  /// Repeater hex ID → per-repeater stats, JSON keyed by ``NodeHexID/hex``.
  var repeaterStatsData: Data

  init(
    cellRaw: UInt64,
    day: String,
    packetCount: Int = 0,
    activePacketCount: Int = 0,
    passivePacketCount: Int = 0,
    probesSent: Int = 0,
    rxCount: Int = 0,
    txHeardCount: Int = 0,
    ackCount: Int = 0,
    stationaryObservationCount: Int = 0,
    rttMsSum: Double = 0,
    rttSampleCount: Int = 0,
    probeRttMsSum: Double = 0,
    probeRttSampleCount: Int = 0,
    snrSum: Double = 0,
    snrCount: Int = 0,
    minSnr: Double? = nil,
    maxSnr: Double? = nil,
    txSnrSum: Double = 0,
    txSnrCount: Int = 0,
    maxTxSnr: Double? = nil,
    rssiSum: Double = 0,
    rssiCount: Int = 0,
    floodCount: Int = 0,
    directCount: Int = 0,
    earliest: Date? = nil,
    latest: Date? = nil,
    hopHistogramData: Data = Data(),
    repeaterStatsData: Data = Data()
  ) {
    self.cellRaw = cellRaw
    self.day = day
    self.packetCount = packetCount
    self.activePacketCount = activePacketCount
    self.passivePacketCount = passivePacketCount
    self.probesSent = probesSent
    self.rxCount = rxCount
    self.txHeardCount = txHeardCount
    self.ackCount = ackCount
    self.stationaryObservationCount = stationaryObservationCount
    self.rttMsSum = rttMsSum
    self.rttSampleCount = rttSampleCount
    self.probeRttMsSum = probeRttMsSum
    self.probeRttSampleCount = probeRttSampleCount
    self.snrSum = snrSum
    self.snrCount = snrCount
    self.minSnr = minSnr
    self.maxSnr = maxSnr
    self.txSnrSum = txSnrSum
    self.txSnrCount = txSnrCount
    self.maxTxSnr = maxTxSnr
    self.rssiSum = rssiSum
    self.rssiCount = rssiCount
    self.floodCount = floodCount
    self.directCount = directCount
    self.earliest = earliest
    self.latest = latest
    self.hopHistogramData = hopHistogramData
    self.repeaterStatsData = repeaterStatsData
  }

  /// Builds a model instance directly from a DTO.
  convenience init(dto: MapperCellObservationDTO) {
    self.init(cellRaw: dto.cellRaw, day: dto.day)
    apply(dto)
  }

  /// Overwrites every aggregate from `dto`, leaving identity alone. The upsert path
  /// merges in the DTO layer and then writes the merged result through here, so the
  /// model never carries fold logic of its own.
  func apply(_ dto: MapperCellObservationDTO) {
    packetCount = dto.packetCount
    activePacketCount = dto.activePacketCount
    passivePacketCount = dto.passivePacketCount
    probesSent = dto.probesSent
    rxCount = dto.rxCount
    txHeardCount = dto.txHeardCount
    ackCount = dto.ackCount
    stationaryObservationCount = dto.stationaryObservationCount
    rttMsSum = dto.rttMsSum
    rttSampleCount = dto.rttSampleCount
    probeRttMsSum = dto.probeRttMsSum
    probeRttSampleCount = dto.probeRttSampleCount
    snrSum = dto.snrSum
    snrCount = dto.snrCount
    minSnr = dto.minSnr
    maxSnr = dto.maxSnr
    txSnrSum = dto.txSnrSum
    txSnrCount = dto.txSnrCount
    maxTxSnr = dto.maxTxSnr
    rssiSum = dto.rssiSum
    rssiCount = dto.rssiCount
    floodCount = dto.floodCount
    directCount = dto.directCount
    earliest = dto.earliest
    latest = dto.latest
    hopHistogramData = MapperCellObservationDTO.encode(hopHistogram: dto.hopHistogram)
    repeaterStatsData = MapperCellObservationDTO.encode(repeaters: dto.repeaters)
  }
}

// MARK: - Repeater stats

/// Per-repeater involvement in one cell-day, mirroring ``AggregatedCell/RepeaterStats`` in
/// a storage-facing form.
///
/// **Deliberately not `Codable`.** It carries `firstHeard`/`lastHeard` at second precision,
/// which is a timestamp trail — exactly what docs/SIGNAL_MAPPER_V2.md §3.4 says must never
/// reach the wire, where the granularity is the UTC day. Conformance would make
/// `JSONEncoder().encode(rows)` compile, and a plausible-looking one-liner that ships a
/// residency timeline is not a mistake anyone should be able to make by accident. The
/// storage columns get an explicit codec instead (``MapperCellObservationDTO``'s private
/// column types); a wire representation, when M2 needs one, gets a wire type written on
/// purpose.
public struct MapperRepeaterStats: Sendable, Equatable {
  /// Hex identity, always the canonical uppercase form produced by ``NodeHexID/hex``.
  public var id: String
  public var rxPacketCount: Int
  public var txPacketCount: Int
  public var rxSnrSum: Double
  public var rxSnrCount: Int
  public var txSnrSum: Double
  public var txSnrCount: Int
  public var rssiSum: Double
  public var rssiCount: Int
  public var firstHeard: Date
  public var lastHeard: Date

  public init(
    id: String,
    rxPacketCount: Int = 0,
    txPacketCount: Int = 0,
    rxSnrSum: Double = 0,
    rxSnrCount: Int = 0,
    txSnrSum: Double = 0,
    txSnrCount: Int = 0,
    rssiSum: Double = 0,
    rssiCount: Int = 0,
    firstHeard: Date,
    lastHeard: Date
  ) {
    self.id = id
    self.rxPacketCount = rxPacketCount
    self.txPacketCount = txPacketCount
    self.rxSnrSum = rxSnrSum
    self.rxSnrCount = rxSnrCount
    self.txSnrSum = txSnrSum
    self.txSnrCount = txSnrCount
    self.rssiSum = rssiSum
    self.rssiCount = rssiCount
    self.firstHeard = firstHeard
    self.lastHeard = lastHeard
  }

  init(_ stats: AggregatedCell.RepeaterStats) {
    self.init(
      id: stats.id,
      rxPacketCount: stats.rxPacketCount,
      txPacketCount: stats.txPacketCount,
      rxSnrSum: stats.rxSnrSum,
      rxSnrCount: stats.rxSnrCount,
      txSnrSum: stats.txSnrSum,
      txSnrCount: stats.txSnrCount,
      rssiSum: stats.rssiSum,
      rssiCount: stats.rssiCount,
      firstHeard: stats.firstHeard,
      lastHeard: stats.lastHeard
    )
  }

  // MARK: - Computed

  /// Packets this repeater was involved in, either direction. Mirrors
  /// ``AggregatedCell/RepeaterStats/packetCount``.
  public var packetCount: Int {
    rxPacketCount + txPacketCount
  }

  /// Mean SNR of packets we heard *from* this repeater directly. Nil when it was only ever
  /// an upstream hop, whose signal somebody else measured.
  public var avgRxSnr: Double? {
    rxSnrCount > 0 ? rxSnrSum / Double(rxSnrCount) : nil
  }

  /// Mean SNR this repeater reported for hearing *us*, from a trace or discover response.
  public var avgTxSnr: Double? {
    txSnrCount > 0 ? txSnrSum / Double(txSnrCount) : nil
  }

  public var avgRssi: Double? {
    rssiCount > 0 ? rssiSum / Double(rssiCount) : nil
  }

  /// Adds another sighting run for the same repeater. Counts and sums add; the heard
  /// window widens to cover both.
  public func merged(with other: MapperRepeaterStats) -> MapperRepeaterStats {
    MapperRepeaterStats(
      id: id,
      rxPacketCount: rxPacketCount + other.rxPacketCount,
      txPacketCount: txPacketCount + other.txPacketCount,
      rxSnrSum: rxSnrSum + other.rxSnrSum,
      rxSnrCount: rxSnrCount + other.rxSnrCount,
      txSnrSum: txSnrSum + other.txSnrSum,
      txSnrCount: txSnrCount + other.txSnrCount,
      rssiSum: rssiSum + other.rssiSum,
      rssiCount: rssiCount + other.rssiCount,
      firstHeard: Swift.min(firstHeard, other.firstHeard),
      lastHeard: Swift.max(lastHeard, other.lastHeard)
    )
  }
}

// MARK: - DTO

/// Sendable DTO for cross-actor transfer of a ``MapperCellObservation`` row.
///
/// Folding lives here rather than on the model so the capture engine, the store's upsert
/// and the tests all merge cell-days through one implementation.
///
/// **Deliberately not `Codable`** — see ``MapperRepeaterStats`` for the argument. This is a
/// *storage* DTO: it holds `earliest`/`latest` instants and a repeater map with per-repeater
/// first/last-heard, all at full local fidelity, and only the `day` label is ever allowed
/// across the wire (docs/SIGNAL_MAPPER_V2.md §3.4). Without the conformance, uploading this
/// type does not compile, and M2 has to write a wire DTO that says out loud which fields it
/// carries. The two JSON columns the SwiftData row stores are encoded through the private
/// column types at the bottom of this file, which is the only serialization that exists.
public struct MapperCellObservationDTO: Sendable, Equatable {
  public let cellRaw: UInt64
  public let day: String

  public var packetCount: Int
  public var activePacketCount: Int
  public var passivePacketCount: Int
  public var probesSent: Int

  /// Packets received here (docs/SIGNAL_MAPPER_V2.md §2.1, direction `rx`).
  public var rxCount: Int
  /// Our own packets heard being rebroadcast by a repeater — evidence the *uplink* from
  /// this cell works, which no amount of listening can establish (direction `txHeard`).
  public var txHeardCount: Int
  /// Sends from here that were acknowledged end to end (direction `ack`). Not a packet
  /// count: an ACK carries no radio measurement of its own and never folds as one.
  public var ackCount: Int

  /// How many of ``observationCount`` were captured while the phone was not moving — the
  /// dwell signal ``MapperAnchorPolicy`` reads. See the model's column for why it is stored
  /// rather than derived.
  public var stationaryObservationCount: Int

  /// Round-trip time of acknowledged sends, in milliseconds.
  public var rttMsSum: Double
  public var rttSampleCount: Int
  /// Trace-probe round trips (M3.5) — never mixed into the ACK pair above.
  public var probeRttMsSum: Double
  public var probeRttSampleCount: Int

  public var snrSum: Double
  public var snrCount: Int
  public var minSnr: Double?
  public var maxSnr: Double?
  public var txSnrSum: Double
  public var txSnrCount: Int
  public var maxTxSnr: Double?
  public var rssiSum: Double
  public var rssiCount: Int

  public var floodCount: Int
  public var directCount: Int

  public var earliest: Date?
  public var latest: Date?

  /// Hop count → packet count.
  public var hopHistogram: [Int: Int]
  /// Repeater hex ID → stats.
  public var repeaters: [String: MapperRepeaterStats]

  public init(
    cellRaw: UInt64,
    day: String,
    packetCount: Int = 0,
    activePacketCount: Int = 0,
    passivePacketCount: Int = 0,
    probesSent: Int = 0,
    rxCount: Int = 0,
    txHeardCount: Int = 0,
    ackCount: Int = 0,
    stationaryObservationCount: Int = 0,
    rttMsSum: Double = 0,
    rttSampleCount: Int = 0,
    probeRttMsSum: Double = 0,
    probeRttSampleCount: Int = 0,
    snrSum: Double = 0,
    snrCount: Int = 0,
    minSnr: Double? = nil,
    maxSnr: Double? = nil,
    txSnrSum: Double = 0,
    txSnrCount: Int = 0,
    maxTxSnr: Double? = nil,
    rssiSum: Double = 0,
    rssiCount: Int = 0,
    floodCount: Int = 0,
    directCount: Int = 0,
    earliest: Date? = nil,
    latest: Date? = nil,
    hopHistogram: [Int: Int] = [:],
    repeaters: [String: MapperRepeaterStats] = [:]
  ) {
    self.cellRaw = cellRaw
    self.day = day
    self.packetCount = packetCount
    self.activePacketCount = activePacketCount
    self.passivePacketCount = passivePacketCount
    self.probesSent = probesSent
    self.rxCount = rxCount
    self.txHeardCount = txHeardCount
    self.ackCount = ackCount
    self.stationaryObservationCount = stationaryObservationCount
    self.rttMsSum = rttMsSum
    self.rttSampleCount = rttSampleCount
    self.probeRttMsSum = probeRttMsSum
    self.probeRttSampleCount = probeRttSampleCount
    self.snrSum = snrSum
    self.snrCount = snrCount
    self.minSnr = minSnr
    self.maxSnr = maxSnr
    self.txSnrSum = txSnrSum
    self.txSnrCount = txSnrCount
    self.maxTxSnr = maxTxSnr
    self.rssiSum = rssiSum
    self.rssiCount = rssiCount
    self.floodCount = floodCount
    self.directCount = directCount
    self.earliest = earliest
    self.latest = latest
    self.hopHistogram = hopHistogram
    self.repeaters = repeaters
  }

  /// Wraps a SurveyKit aggregate for one UTC day.
  ///
  /// `AggregatedCell.dailyCounts` is dropped: a row *is* one day, so the map would only
  /// ever hold this row's own count. It is rebuilt in ``aggregate`` for callers who want
  /// the SurveyKit shape back.
  ///
  /// Direction is not something a SurveyKit aggregate knows — it folds packets, not
  /// intents — so it is passed alongside. `rxCount` defaults to the whole packet count,
  /// which is what a plain aggregate of received packets is.
  public init(
    day: String,
    aggregate: AggregatedCell,
    rxCount: Int? = nil,
    txHeardCount: Int = 0,
    ackCount: Int = 0,
    stationaryObservationCount: Int = 0,
    rttMsSum: Double = 0,
    rttSampleCount: Int = 0,
    probeRttMsSum: Double = 0,
    probeRttSampleCount: Int = 0
  ) {
    self.init(
      cellRaw: aggregate.cell.rawValue,
      day: day,
      packetCount: aggregate.packetCount,
      activePacketCount: aggregate.activePacketCount,
      passivePacketCount: aggregate.passivePacketCount,
      probesSent: aggregate.probesSent,
      rxCount: rxCount ?? aggregate.packetCount,
      txHeardCount: txHeardCount,
      ackCount: ackCount,
      stationaryObservationCount: stationaryObservationCount,
      rttMsSum: rttMsSum,
      rttSampleCount: rttSampleCount,
      probeRttMsSum: probeRttMsSum,
      probeRttSampleCount: probeRttSampleCount,
      snrSum: aggregate.snrSum,
      snrCount: aggregate.snrCount,
      minSnr: aggregate.minSnr,
      maxSnr: aggregate.maxSnr,
      txSnrSum: aggregate.txSnrSum,
      txSnrCount: aggregate.txSnrCount,
      maxTxSnr: aggregate.maxTxSnr,
      rssiSum: aggregate.rssiSum,
      rssiCount: aggregate.rssiCount,
      floodCount: aggregate.floodCount,
      directCount: aggregate.directCount,
      earliest: aggregate.earliest,
      latest: aggregate.latest,
      hopHistogram: aggregate.hopHistogram,
      repeaters: aggregate.repeaters.mapValues(MapperRepeaterStats.init)
    )
  }

  /// Initialize from the SwiftData model, decoding the JSON columns. A column that fails
  /// to decode yields an empty map rather than dropping the whole row — the counts are
  /// still good data.
  ///
  /// A row carrying packets but no direction at all predates the direction counters (M0
  /// only ever captured RX), so its packets are attributed to `rx` on the way out rather
  /// than being reported as coming from nowhere.
  init(from model: MapperCellObservation) {
    let hasDirection = model.rxCount > 0 || model.txHeardCount > 0 || model.ackCount > 0
    self.init(
      cellRaw: model.cellRaw,
      day: model.day,
      packetCount: model.packetCount,
      activePacketCount: model.activePacketCount,
      passivePacketCount: model.passivePacketCount,
      probesSent: model.probesSent,
      rxCount: hasDirection ? model.rxCount : model.packetCount,
      txHeardCount: model.txHeardCount,
      ackCount: model.ackCount,
      stationaryObservationCount: model.stationaryObservationCount,
      rttMsSum: model.rttMsSum,
      rttSampleCount: model.rttSampleCount,
      probeRttMsSum: model.probeRttMsSum,
      probeRttSampleCount: model.probeRttSampleCount,
      snrSum: model.snrSum,
      snrCount: model.snrCount,
      minSnr: model.minSnr,
      maxSnr: model.maxSnr,
      txSnrSum: model.txSnrSum,
      txSnrCount: model.txSnrCount,
      maxTxSnr: model.maxTxSnr,
      rssiSum: model.rssiSum,
      rssiCount: model.rssiCount,
      floodCount: model.floodCount,
      directCount: model.directCount,
      earliest: model.earliest,
      latest: model.latest,
      hopHistogram: Self.decodeHopHistogram(model.hopHistogramData),
      repeaters: Self.decodeRepeaters(model.repeaterStatsData)
    )
  }

  // MARK: - Computed

  /// The H3 cell, or nil if the stored raw value is not a valid index (a corrupt row).
  public var cell: H3Cell? {
    H3Cell(rawValue: cellRaw)
  }

  public var avgSnr: Double? {
    snrCount > 0 ? snrSum / Double(snrCount) : nil
  }

  public var avgTxSnr: Double? {
    txSnrCount > 0 ? txSnrSum / Double(txSnrCount) : nil
  }

  public var avgRssi: Double? {
    rssiCount > 0 ? rssiSum / Double(rssiCount) : nil
  }

  /// Mean round-trip time of acknowledged sends, in milliseconds.
  public var avgRttMs: Double? {
    rttSampleCount > 0 ? rttMsSum / Double(rttSampleCount) : nil
  }

  /// Mean trace-probe round trip, ms.
  public var avgProbeRttMs: Double? {
    probeRttSampleCount > 0 ? probeRttMsSum / Double(probeRttSampleCount) : nil
  }

  /// Every observation folded into this row, whatever direction it came from. Larger than
  /// ``packetCount`` wherever ACKs landed, since those are not packets.
  public var observationCount: Int {
    rxCount + txHeardCount + ackCount
  }

  public var quality: SignalQuality {
    SignalQuality(snr: avgSnr)
  }

  /// Back to the SurveyKit shape, for code that renders or uploads aggregates.
  /// Returns nil for a row whose stored cell index is invalid.
  public var aggregate: AggregatedCell? {
    guard let cell else { return nil }
    var result = AggregatedCell(cell: cell)
    result.packetCount = packetCount
    result.activePacketCount = activePacketCount
    result.passivePacketCount = passivePacketCount
    result.probesSent = probesSent
    result.snrSum = snrSum
    result.snrCount = snrCount
    result.minSnr = minSnr
    result.maxSnr = maxSnr
    result.txSnrSum = txSnrSum
    result.txSnrCount = txSnrCount
    result.rssiSum = rssiSum
    result.rssiCount = rssiCount
    result.floodCount = floodCount
    result.directCount = directCount
    result.earliest = earliest
    result.latest = latest
    result.dailyCounts = [day: packetCount]
    result.hopHistogram = hopHistogram
    result.repeaters = repeaters.mapValues { stats in
      AggregatedCell.RepeaterStats(
        id: stats.id,
        rxPacketCount: stats.rxPacketCount,
        txPacketCount: stats.txPacketCount,
        rxSnrSum: stats.rxSnrSum,
        rxSnrCount: stats.rxSnrCount,
        txSnrSum: stats.txSnrSum,
        txSnrCount: stats.txSnrCount,
        rssiSum: stats.rssiSum,
        rssiCount: stats.rssiCount,
        firstHeard: stats.firstHeard,
        lastHeard: stats.lastHeard
      )
    }
    return result
  }

  // MARK: - Folding

  /// Folds another observation of the same cell-day into this one.
  ///
  /// Counts and sums add, min/max widen, the time span widens, histograms and repeater
  /// maps merge key-wise. Identity is taken from `self`; folding a different `(cell, day)`
  /// is a programmer error and is returned unchanged rather than corrupting either row.
  public func merged(with other: MapperCellObservationDTO) -> MapperCellObservationDTO {
    guard other.cellRaw == cellRaw, other.day == day else { return self }
    var merged = self
    merged.packetCount += other.packetCount
    merged.activePacketCount += other.activePacketCount
    merged.passivePacketCount += other.passivePacketCount
    merged.probesSent += other.probesSent
    merged.rxCount += other.rxCount
    merged.txHeardCount += other.txHeardCount
    merged.ackCount += other.ackCount
    merged.stationaryObservationCount += other.stationaryObservationCount
    merged.rttMsSum += other.rttMsSum
    merged.rttSampleCount += other.rttSampleCount
    merged.probeRttMsSum += other.probeRttMsSum
    merged.probeRttSampleCount += other.probeRttSampleCount
    merged.snrSum += other.snrSum
    merged.snrCount += other.snrCount
    merged.minSnr = Self.lower(minSnr, other.minSnr)
    merged.maxSnr = Self.upper(maxSnr, other.maxSnr)
    merged.txSnrSum += other.txSnrSum
    merged.txSnrCount += other.txSnrCount
    merged.maxTxSnr = [merged.maxTxSnr, other.maxTxSnr].compactMap(\.self).max()
    merged.rssiSum += other.rssiSum
    merged.rssiCount += other.rssiCount
    merged.floodCount += other.floodCount
    merged.directCount += other.directCount
    merged.earliest = Self.lower(earliest, other.earliest)
    merged.latest = Self.upper(latest, other.latest)
    merged.hopHistogram = hopHistogram.merging(other.hopHistogram, uniquingKeysWith: +)
    merged.repeaters = repeaters.merging(other.repeaters) { lhs, rhs in lhs.merged(with: rhs) }
    return merged
  }

  private static func lower<T: Comparable>(_ lhs: T?, _ rhs: T?) -> T? {
    guard let lhs else { return rhs }
    guard let rhs else { return lhs }
    return Swift.min(lhs, rhs)
  }

  private static func upper<T: Comparable>(_ lhs: T?, _ rhs: T?) -> T? {
    guard let lhs else { return rhs }
    guard let rhs else { return lhs }
    return Swift.max(lhs, rhs)
  }

  // MARK: - JSON columns

  /// The private, deliberate codec for the two JSON columns the SwiftData row stores.
  ///
  /// This is the *whole* serialization surface of a mapper observation, and it is
  /// `private`: neither this DTO nor ``MapperRepeaterStats`` is `Codable`, so nothing
  /// outside this file can turn a stored row into bytes, and a wire encoder has to be
  /// written on purpose with its fields chosen on purpose. That is the point — the type
  /// carries second-precision `firstHeard`/`lastHeard` instants, and a `Codable`
  /// conformance is one `JSONEncoder().encode(rows)` away from shipping a timestamp trail
  /// (docs/SIGNAL_MAPPER_V2.md §3.4).
  ///
  /// The column shape is unchanged from the synthesized conformance it replaces — same key
  /// names, same `Date` representation — so rows written by earlier builds decode as they
  /// always did.
  private struct RepeaterStatsColumn: Codable {
    var id: String
    var rxPacketCount: Int
    var txPacketCount: Int
    var rxSnrSum: Double
    var rxSnrCount: Int
    var txSnrSum: Double
    var txSnrCount: Int
    var rssiSum: Double
    var rssiCount: Int
    var firstHeard: Date
    var lastHeard: Date

    init(_ stats: MapperRepeaterStats) {
      id = stats.id
      rxPacketCount = stats.rxPacketCount
      txPacketCount = stats.txPacketCount
      rxSnrSum = stats.rxSnrSum
      rxSnrCount = stats.rxSnrCount
      txSnrSum = stats.txSnrSum
      txSnrCount = stats.txSnrCount
      rssiSum = stats.rssiSum
      rssiCount = stats.rssiCount
      firstHeard = stats.firstHeard
      lastHeard = stats.lastHeard
    }

    var stats: MapperRepeaterStats {
      MapperRepeaterStats(
        id: id,
        rxPacketCount: rxPacketCount,
        txPacketCount: txPacketCount,
        rxSnrSum: rxSnrSum,
        rxSnrCount: rxSnrCount,
        txSnrSum: txSnrSum,
        txSnrCount: txSnrCount,
        rssiSum: rssiSum,
        rssiCount: rssiCount,
        firstHeard: firstHeard,
        lastHeard: lastHeard
      )
    }
  }

  /// Sorted keys so an unchanged aggregate encodes to identical bytes run to run, which
  /// keeps diffing a store dump meaningful.
  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  static func encode(hopHistogram: [Int: Int]) -> Data {
    let keyed = Dictionary(uniqueKeysWithValues: hopHistogram.map { (String($0.key), $0.value) })
    return (try? encoder.encode(keyed)) ?? Data()
  }

  static func encode(repeaters: [String: MapperRepeaterStats]) -> Data {
    (try? encoder.encode(repeaters.mapValues(RepeaterStatsColumn.init))) ?? Data()
  }

  static func decodeHopHistogram(_ data: Data) -> [Int: Int] {
    guard !data.isEmpty,
          let keyed = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
    return Dictionary(uniqueKeysWithValues: keyed.compactMap { key, value in
      Int(key).map { ($0, value) }
    })
  }

  static func decodeRepeaters(_ data: Data) -> [String: MapperRepeaterStats] {
    guard !data.isEmpty,
          let columns = try? JSONDecoder().decode([String: RepeaterStatsColumn].self, from: data)
    else { return [:] }
    return columns.mapValues(\.stats)
  }
}

// MARK: - Day keys

/// The UTC day label every mapper row and aggregate is bucketed by.
///
/// One implementation, shared by the capture engine and the store, so a row written by
/// one and read back by the other can never disagree about which day a packet belongs to.
/// Matches `CellAggregator`'s own `dailyCounts` key format.
public enum MapperDayKey {
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
  }()

  /// `"YYYY-MM-DD"` in UTC.
  public static func key(for date: Date) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "%04d-%02d-%02d",
      components.year ?? 0,
      components.month ?? 0,
      components.day ?? 0
    )
  }
}
