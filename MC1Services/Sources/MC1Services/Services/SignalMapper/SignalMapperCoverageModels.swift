import Foundation
import SurveyKit

/// One repeater's involvement in a cell, ready to list.
///
/// Identity is the canonical hex the capture engine stored (`NodeHexID.hex`). The display
/// name, when there is one, came out of the identity resolver — never out of a string
/// comparison (MIGRATION_PLAN §2.1).
public struct SignalMapperCoverageRepeater: Sendable, Hashable, Identifiable {
  /// Canonical uppercase hash, e.g. `"0C13"`.
  public let hexID: String
  /// The resolved node's name, or nil when no known node answers to this hash.
  public let name: String?
  /// Whether more than one known node answers to this hash, so `name` is a best guess.
  public let isAmbiguous: Bool
  /// Packets this repeater carried into (or out of) the cell.
  public let packetCount: Int
  /// Mean SNR of the packets we heard *from* this repeater directly. Nil when it was only
  /// ever an upstream hop, whose signal somebody else measured.
  public let averageSnr: Double?
  /// Mean SNR this repeater reported for *our* transmissions — the uplink leg, populated
  /// only by trace/discover replies. Nil when it never told us.
  public let averageTxSnr: Double?
  /// The packet count split by which side transmitted.
  public let rxPacketCount: Int
  public let txPacketCount: Int
  public let firstHeard: Date
  public let lastHeard: Date

  public var id: String {
    hexID
  }

  public init(
    hexID: String,
    name: String? = nil,
    isAmbiguous: Bool = false,
    packetCount: Int,
    averageSnr: Double?,
    averageTxSnr: Double? = nil,
    rxPacketCount: Int = 0,
    txPacketCount: Int = 0,
    firstHeard: Date,
    lastHeard: Date
  ) {
    self.hexID = hexID
    self.name = name
    self.isAmbiguous = isAmbiguous
    self.packetCount = packetCount
    self.averageSnr = averageSnr
    self.averageTxSnr = averageTxSnr
    self.rxPacketCount = rxPacketCount
    self.txPacketCount = txPacketCount
    self.firstHeard = firstHeard
    self.lastHeard = lastHeard
  }
}

/// One H3 res-9 cell of our own coverage, merged across every day it was observed on.
///
/// A value type with no map framework anywhere in it: the boundary is a list of
/// coordinates, and whichever renderer is in fashion turns it into a polygon.
public struct SignalMapperCoverageCell: Sendable, Hashable, Identifiable {
  public let cell: H3Cell
  /// The cell's boundary vertices in ring order, from ``SurveyGrid/boundary(of:)``.
  public let boundary: [GeoCoordinate]
  public let center: GeoCoordinate

  /// SurveyKit's one quality scale, from the cell's mean SNR.
  public let quality: SignalQuality

  /// Packets folded here. ACKs are not packets, so this can be smaller than
  /// ``observationCount``.
  public let packetCount: Int
  /// Every observation of any direction.
  public let observationCount: Int
  public let rxCount: Int
  public let txHeardCount: Int
  public let ackCount: Int

  public let averageSnr: Double?
  public let bestSnr: Double?
  public let worstSnr: Double?
  public let averageRssi: Double?
  /// Mean round-trip time of acknowledged sends from here, in milliseconds.
  public let averageRttMs: Double?
  /// Mean round-trip time of trace probes from here, in milliseconds (M3.5).
  public let averageProbeRttMs: Double?

  /// Packets that answered our probes vs. everything passively heard (M3.5).
  public let activePacketCount: Int
  public let passivePacketCount: Int
  /// Probe transmissions attributed to this cell — the denominator "no reach" divides by.
  public let probesSent: Int
  /// Mean uplink SNR (repeaters' readings of us) and how many readings back it.
  public let averageTxSnr: Double?
  public let txSnrCount: Int

  public let floodCount: Int
  public let directCount: Int

  /// How many distinct UTC days this cell was observed on.
  public let dayCount: Int
  public let firstDay: String
  public let lastDay: String

  /// Busiest first, then by hash so the order is total.
  public let repeaters: [SignalMapperCoverageRepeater]

  /// This cell's observation count as a fraction of the busiest cell's in the same
  /// snapshot (0...1). Drives the fill's opacity ramp.
  public let normalizedWeight: Double

  public var id: UInt64 {
    cell.rawValue
  }

  /// The uplink ("Reach") layer's colour, when this cell has uplink evidence.
  public var reachQuality: SignalQuality? {
    txSnrCount > 0 ? SignalQuality(snr: averageTxSnr) : nil
  }

  /// We shouted from this cell and nobody ever reported hearing us. Deliberately not
  /// `AggregatedCell.isDeadZone` (whose `packetCount == 0` test is defeated by any
  /// passively heard packet — M3.5 review M5): the reach question is about the uplink
  /// leg specifically.
  public var isUnreachedProbed: Bool {
    probesSent > 0 && txSnrCount == 0
  }

  public init(
    cell: H3Cell,
    boundary: [GeoCoordinate],
    center: GeoCoordinate,
    quality: SignalQuality,
    packetCount: Int,
    observationCount: Int,
    rxCount: Int,
    txHeardCount: Int,
    ackCount: Int,
    averageSnr: Double?,
    bestSnr: Double?,
    worstSnr: Double?,
    averageRssi: Double?,
    averageRttMs: Double?,
    averageProbeRttMs: Double? = nil,
    activePacketCount: Int = 0,
    passivePacketCount: Int = 0,
    probesSent: Int = 0,
    averageTxSnr: Double? = nil,
    txSnrCount: Int = 0,
    floodCount: Int,
    directCount: Int,
    dayCount: Int,
    firstDay: String,
    lastDay: String,
    repeaters: [SignalMapperCoverageRepeater],
    normalizedWeight: Double
  ) {
    self.cell = cell
    self.boundary = boundary
    self.center = center
    self.quality = quality
    self.packetCount = packetCount
    self.observationCount = observationCount
    self.rxCount = rxCount
    self.txHeardCount = txHeardCount
    self.ackCount = ackCount
    self.averageSnr = averageSnr
    self.bestSnr = bestSnr
    self.worstSnr = worstSnr
    self.averageRssi = averageRssi
    self.averageRttMs = averageRttMs
    self.averageProbeRttMs = averageProbeRttMs
    self.activePacketCount = activePacketCount
    self.passivePacketCount = passivePacketCount
    self.probesSent = probesSent
    self.averageTxSnr = averageTxSnr
    self.txSnrCount = txSnrCount
    self.floodCount = floodCount
    self.directCount = directCount
    self.dayCount = dayCount
    self.firstDay = firstDay
    self.lastDay = lastDay
    self.repeaters = repeaters
    self.normalizedWeight = normalizedWeight
  }
}

/// What one pass of ``SignalMapperCoverageBuilder`` found.
public struct SignalMapperCoverageSnapshot: Sendable, Hashable {
  /// Busiest first, then by cell index so the order is total.
  public let cells: [SignalMapperCoverageCell]
  public let totalObservations: Int
  public let totalPackets: Int
  /// Distinct UTC days anything was captured on, across every cell.
  public let dayCount: Int
  public let firstDay: String?
  public let lastDay: String?
  /// Rows whose stored cell index no longer parses as an H3 cell. Non-zero means a
  /// corrupt row, not an empty map.
  public let unreadableRowCount: Int

  public static let empty = SignalMapperCoverageSnapshot(
    cells: [],
    totalObservations: 0,
    totalPackets: 0,
    dayCount: 0,
    firstDay: nil,
    lastDay: nil,
    unreadableRowCount: 0
  )

  public var isEmpty: Bool {
    cells.isEmpty
  }

  public init(
    cells: [SignalMapperCoverageCell],
    totalObservations: Int,
    totalPackets: Int,
    dayCount: Int,
    firstDay: String?,
    lastDay: String?,
    unreadableRowCount: Int
  ) {
    self.cells = cells
    self.totalObservations = totalObservations
    self.totalPackets = totalPackets
    self.dayCount = dayCount
    self.firstDay = firstDay
    self.lastDay = lastDay
    self.unreadableRowCount = unreadableRowCount
  }
}
