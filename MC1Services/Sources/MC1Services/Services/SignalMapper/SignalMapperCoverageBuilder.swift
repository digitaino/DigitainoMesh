import Foundation
import SurveyKit

/// Turns stored `(cell, day)` rows into the cells a coverage map draws.
///
/// A pure function of its arguments — rows in, value types out, caller supplies the clock —
/// so the whole of the coverage logic is testable without a store, a radio, or a map, the
/// way ``TrafficHeatmapAggregator`` is. Nothing here knows how any of it is drawn.
///
/// The rules:
///
/// - **A cell is the merge of its days.** Storage is day-bucketed for the wire's sake
///   (docs/SIGNAL_MAPPER_V2.md §3.4); the map is not. Days fold through
///   ``MapperCellObservationDTO/merged(with:)`` — the same fold the store uses — so the
///   map and the upload can never disagree about what a cell holds.
/// - **Quality is SurveyKit's, not ours.** ``SignalQuality`` from mean SNR, one scale for
///   the app, the server and the web map.
/// - **Weight is observations, not packets.** A cell where ten sends were acknowledged is
///   as well covered as one where ten packets arrived; only counting packets would fade
///   out the cells that prove the *uplink*, which is the half of coverage nothing else
///   measures.
/// - **Repeater names come from the resolver.** A hash is resolved through
///   ``NodeIdentityResolving`` or it stays a hash. Nothing here compares hex strings.
public struct SignalMapperCoverageBuilder: Sendable {
  private let resolver: any NodeIdentityResolving

  public init(resolver: any NodeIdentityResolving = NodeIdentityResolver()) {
    self.resolver = resolver
  }

  // MARK: - Building

  /// Merges rows into cells.
  ///
  /// - Parameters:
  ///   - rows: every stored cell-day to include. Days of one cell may arrive in any order.
  ///   - candidates: the pool repeater hashes resolve names against, contacts and
  ///     discovered nodes alike. Empty leaves every repeater showing as its hash.
  ///   - now: the clock the resolver ranks advert recency against.
  public func build(
    rows: [MapperCellObservationDTO],
    candidates: [AnyResolvableNode] = [],
    now: Date,
    overrides: NodeIdentityOverrides = [:]
  ) -> SignalMapperCoverageSnapshot {
    assembled(rows: rows, candidates: candidates, now: now, overrides: overrides)
  }

  /// The whole of ``build(rows:candidates:now:overrides:)``'s arithmetic, shared verbatim
  /// with ``buildSession(rows:baseline:candidates:now:overrides:)``.
  ///
  /// The ride's map is the same map drawn over fewer, smaller rows — so it merges, weights,
  /// colours and sorts through this one path, and the two can never disagree about what a
  /// hexagon is.
  func assembled(
    rows: [MapperCellObservationDTO],
    candidates: [AnyResolvableNode],
    now: Date,
    overrides: NodeIdentityOverrides
  ) -> SignalMapperCoverageSnapshot {
    var merged: [UInt64: MapperCellObservationDTO] = [:]
    var days: [UInt64: Set<String>] = [:]
    var allDays: Set<String> = []
    var unreadableRowCount = 0

    for row in rows {
      guard row.cell != nil else {
        unreadableRowCount += 1
        continue
      }
      // Merging is by (cell, day), so a row from another day is folded under the first
      // day's identity before it can be refused for having a different label.
      if let existing = merged[row.cellRaw] {
        merged[row.cellRaw] = existing.merged(with: row.relabelled(day: existing.day))
      } else {
        merged[row.cellRaw] = row
      }
      days[row.cellRaw, default: []].insert(row.day)
      allDays.insert(row.day)
    }

    // Weights are relative to the busiest cell in this snapshot, so the ramp always spans
    // its full range however little or much has been captured.
    let heaviest = merged.values.map(\.observationCount).max() ?? 1
    // One identity match per distinct hash for the whole pass; the pool and the clock are
    // fixed here, and a hash names the same node in every cell it appears in.
    var names: [String: ResolvedName] = [:]

    let cells = merged.values.compactMap { row -> SignalMapperCoverageCell? in
      cell(
        from: row,
        days: days[row.cellRaw] ?? [row.day],
        heaviest: heaviest,
        candidates: candidates,
        now: now,
        overrides: overrides,
        names: &names
      )
    }

    // Heaviest first, ties broken on the cell index so rebuilding unchanged data is
    // identical run to run.
    let sorted = cells.sorted { lhs, rhs in
      if lhs.observationCount != rhs.observationCount {
        return lhs.observationCount > rhs.observationCount
      }
      return lhs.cell.rawValue < rhs.cell.rawValue
    }

    return SignalMapperCoverageSnapshot(
      cells: sorted,
      totalObservations: sorted.reduce(0) { $0 + $1.observationCount },
      totalPackets: sorted.reduce(0) { $0 + $1.packetCount },
      dayCount: allDays.count,
      firstDay: allDays.min(),
      lastDay: allDays.max(),
      unreadableRowCount: unreadableRowCount
    )
  }

  // MARK: - One cell

  private func cell(
    from row: MapperCellObservationDTO,
    days: Set<String>,
    heaviest: Int,
    candidates: [AnyResolvableNode],
    now: Date,
    overrides: NodeIdentityOverrides,
    names: inout [String: ResolvedName]
  ) -> SignalMapperCoverageCell? {
    guard let cell = row.cell else { return nil }

    let repeaters = collapsed(
      row.repeaters.values,
      candidates: candidates,
      now: now,
      overrides: overrides,
      names: &names
    )
    .map { group -> SignalMapperCoverageRepeater in
      let stats = group.stats
      // Rows written before the freshness columns existed still carry the two facts they
      // imply: a repeater with direct readings was last heard directly no later than
      // `lastHeard`, and one that reported an uplink reading proved the uplink by then
      // too. The best reading stands in for the last one — it is the only reading such a
      // row kept — and both fall away as soon as a fresh sighting writes the real pair.
      let legacyDirect = stats.rxSnrCount > 0 ? stats.lastHeard : nil
      let lastDirectHeard = stats.lastDirectHeard ?? legacyDirect
      let lastRxSnr = stats.lastRxSnr ?? (stats.lastDirectHeard == nil && legacyDirect != nil
        ? stats.maxRxSnr
        : nil)
      let lastUplinkAt = stats.lastUplinkAt ?? (stats.txSnrCount > 0 ? stats.lastHeard : nil)

      return SignalMapperCoverageRepeater(
        hexID: stats.id,
        name: group.resolved.name,
        isAmbiguous: group.resolved.isAmbiguous,
        packetCount: stats.packetCount,
        averageSnr: stats.avgRxSnr,
        averageTxSnr: stats.avgTxSnr,
        bestSnr: stats.maxRxSnr,
        worstSnr: stats.minRxSnr,
        bestTxSnr: stats.maxTxSnr,
        worstTxSnr: stats.minTxSnr,
        averageRssi: stats.avgRssi,
        rxPacketCount: stats.rxPacketCount,
        txPacketCount: stats.txPacketCount,
        relayCount: stats.relayCount,
        echoCount: stats.echoCount,
        directReadingCount: stats.rxSnrCount,
        lastDirectHeard: lastDirectHeard,
        lastRxSnr: lastRxSnr,
        lastUplinkAt: lastUplinkAt,
        firstHeard: stats.firstHeard,
        lastHeard: stats.lastHeard
      )
    }
    .sorted { lhs, rhs in
      if lhs.packetCount != rhs.packetCount { return lhs.packetCount > rhs.packetCount }
      return lhs.hexID < rhs.hexID
    }

    return SignalMapperCoverageCell(
      cell: cell,
      boundary: SurveyGrid.boundary(of: cell),
      center: SurveyGrid.center(of: cell),
      // Best-link coloring: a cell you can reach the mesh from at +12 dB is excellent
      // coverage no matter how many distant repeaters were faintly overheard there.
      // The DTO's own `quality` stays average-based for any future wire use.
      quality: SignalQuality(snr: row.maxSnr ?? row.avgSnr),
      packetCount: row.packetCount,
      observationCount: row.observationCount,
      rxCount: row.rxCount,
      txHeardCount: row.txHeardCount,
      ackCount: row.ackCount,
      averageSnr: row.avgSnr,
      bestSnr: row.maxSnr,
      worstSnr: row.minSnr,
      averageRssi: row.avgRssi,
      averageRttMs: row.avgRttMs,
      averageProbeRttMs: row.avgProbeRttMs,
      activePacketCount: row.activePacketCount,
      passivePacketCount: row.passivePacketCount,
      probesSent: row.probesSent,
      probesAnswered: row.probesAnswered,
      averageTxSnr: row.avgTxSnr,
      bestTxSnr: row.maxTxSnr,
      txSnrCount: row.txSnrCount,
      lastSeen: row.latest,
      floodCount: row.floodCount,
      directCount: row.directCount,
      dayCount: days.count,
      firstDay: days.min() ?? row.day,
      lastDay: days.max() ?? row.day,
      repeaters: repeaters,
      normalizedWeight: heaviest > 0 ? Double(row.observationCount) / Double(heaviest) : 0
    )
  }

  // MARK: - One chip per physical node

  /// One group per *node*, not per hash width.
  ///
  /// Firmware advertises the same repeater at 1, 2 or 3 bytes depending on the path a
  /// packet took, so one node routinely arrives as two or three hashes in the same cell and
  /// used to be listed two or three times — as if the hexagon had that many repeaters. The
  /// grouping key is therefore the resolved node's public key whenever the resolution is
  /// unambiguous, and the raw hash otherwise.
  ///
  /// **An ambiguous hash is never folded into anyone.** A 1-byte `"AB"` that two known
  /// nodes answer to is exactly the case where merging would invent a fact; it stays its own
  /// row, carrying the ambiguity flag that says so.
  private func collapsed(
    _ stats: some Collection<MapperRepeaterStats>,
    candidates: [AnyResolvableNode],
    now: Date,
    overrides: NodeIdentityOverrides,
    names: inout [String: ResolvedName]
  ) -> [RepeaterGroup] {
    var groups: [RepeaterIdentity: RepeaterGroup] = [:]
    for stat in stats {
      let resolved = resolvedName(
        for: stat.id,
        candidates: candidates,
        now: now,
        overrides: overrides,
        cache: &names
      )
      let identity: RepeaterIdentity = if let key = resolved.publicKey, !resolved.isAmbiguous {
        .node(key)
      } else {
        .hash(stat.id)
      }
      guard let existing = groups[identity] else {
        groups[identity] = RepeaterGroup(stats: stat, resolved: resolved)
        continue
      }
      // The widest hash in the group is the one shown: it is the most the mesh ever said
      // about this node, and narrowing it would throw away identity the card can use.
      var merged = existing.stats.merged(with: stat)
      merged.id = Self.widest(existing.stats.id, stat.id)
      groups[identity] = RepeaterGroup(stats: merged, resolved: existing.resolved)
    }
    return Array(groups.values)
  }

  /// The wider of two hashes, ties broken lexicographically so a rebuild of unchanged rows
  /// is identical however the dictionary happens to iterate.
  private static func widest(_ lhs: String, _ rhs: String) -> String {
    if lhs.count != rhs.count { return lhs.count > rhs.count ? lhs : rhs }
    return Swift.min(lhs, rhs)
  }

  /// What one chip's worth of sightings is keyed by: a node when we know which one, and a
  /// bare hash when we do not (or when more than one node answers to it).
  private enum RepeaterIdentity: Hashable {
    case node(Data)
    case hash(String)
  }

  private struct RepeaterGroup {
    var stats: MapperRepeaterStats
    var resolved: ResolvedName
  }

  // MARK: - Names

  private struct ResolvedName {
    var name: String?
    var isAmbiguous: Bool
    /// The winning candidate's key, which is what makes two hash widths one node. Nil when
    /// nothing answered to the hash.
    var publicKey: Data?
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
      ResolvedName(
        name: resolution.best.resolvableName,
        isAmbiguous: resolution.isAmbiguous,
        publicKey: resolution.best.publicKey
      )
    } else {
      ResolvedName(name: nil, isAmbiguous: false, publicKey: nil)
    }
    cache[hexID] = resolved
    return resolved
  }
}

// MARK: - Day relabelling

private extension MapperCellObservationDTO {
  /// The same aggregates under a different day label.
  ///
  /// Only the coverage builder needs this, and only because merging across days is exactly
  /// what ``merged(with:)`` refuses to do — for good reason, since the store must never
  /// blur two days into one row. Here the day *is* being deliberately collapsed, and the
  /// first day seen stands for the merged cell; ``SignalMapperCoverageCell/dayCount``
  /// carries how many days went into it.
  func relabelled(day: String) -> MapperCellObservationDTO {
    guard day != self.day else { return self }
    var copy = MapperCellObservationDTO(cellRaw: cellRaw, day: day)
    copy.packetCount = packetCount
    copy.activePacketCount = activePacketCount
    copy.passivePacketCount = passivePacketCount
    copy.probesSent = probesSent
    copy.probesAnswered = probesAnswered
    copy.rxCount = rxCount
    copy.txHeardCount = txHeardCount
    copy.ackCount = ackCount
    copy.stationaryObservationCount = stationaryObservationCount
    copy.rttMsSum = rttMsSum
    copy.rttSampleCount = rttSampleCount
    copy.probeRttMsSum = probeRttMsSum
    copy.probeRttSampleCount = probeRttSampleCount
    copy.snrSum = snrSum
    copy.snrCount = snrCount
    copy.minSnr = minSnr
    copy.maxSnr = maxSnr
    copy.txSnrSum = txSnrSum
    copy.txSnrCount = txSnrCount
    copy.maxTxSnr = maxTxSnr
    copy.rssiSum = rssiSum
    copy.rssiCount = rssiCount
    copy.floodCount = floodCount
    copy.directCount = directCount
    copy.earliest = earliest
    copy.latest = latest
    copy.hopHistogram = hopHistogram
    copy.repeaters = repeaters
    return copy
  }
}
