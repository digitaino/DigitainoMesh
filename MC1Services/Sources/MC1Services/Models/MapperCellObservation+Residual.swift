import Foundation

// MARK: - Residuals

/// What one survey run added to a stored row: the row now, minus the row as it stood when
/// the run started.
///
/// This is the whole of the "this ride vs all time" arithmetic, and it is deliberately the
/// exact inverse of ``MapperCellObservationDTO/merged(with:)`` — every field that adds when
/// two rows fold subtracts here, in the same order, so the two can never drift apart. A
/// residual is a value nobody stores and nobody uploads: it is computed for display against
/// an in-memory ``SignalMapperSessionBaseline`` and thrown away with the run.
///
/// Three rules are not obvious and are load-bearing:
///
/// - **Maxima do not subtract.** A row's `maxSnr` is the best reading it has ever held, and
///   "best ever minus best before" is not "best during": if the ride's own strongest packet
///   was weaker than one from last week, the difference is the *older* number, attributed to
///   the ride. There is no way to recover a ride's own maximum from an aggregate that only
///   kept the overall one, so every maximum and minimum in a residual is `nil` and the
///   ride's card shows no best/worst at all rather than somebody else's. Means survive
///   because their sums and counts both subtract honestly.
/// - **Counts clamp at zero; the sums they divide do not.** A stored row can *shrink*: the
///   anchor purge deletes the rows of a cell that has become detectable as somebody's home
///   (docs/SIGNAL_MAPPER_V2.md §2.6), which the baseline still remembers at its old size.
///   Subtracting then goes negative, and negative coverage is meaningless — so counts clamp,
///   the row ends with no evidence, `nil` comes back, and the cell silently leaves the
///   session exactly as the purge intended. A *sum* must not clamp, because half of them are
///   sums of negative readings: `rssiSum` is always negative and an SNR sum often is, so
///   clamping would report a ride mean of 0 dBm — a perfect signal — for every hexagon. Each
///   sum instead subtracts outright and is zeroed only when its own sample count came out at
///   zero, where it has no divisor and no meaning.
/// - **Timestamps are filtered, not subtracted.** "Last heard" is not additive; a residual
///   keeps such an instant only when it falls inside the run, and drops it otherwise.
public extension MapperRepeaterStats {
  /// This repeater's contribution to the run, or nil when the difference holds no evidence.
  ///
  /// - Parameters:
  ///   - baseline: the same repeater's stats at run start, or nil when it was not in the
  ///     baseline row at all — in which case everything it holds is the ride's, since the
  ///     row it lives in was itself created during the run.
  ///   - startedAt: the run's start instant. Nothing before it belongs to the ride, which
  ///     is what filters the freshness pairs below.
  func residual(since baseline: MapperRepeaterStats?, startedAt: Date) -> MapperRepeaterStats? {
    let rxPackets = Self.clamped(rxPacketCount, baseline?.rxPacketCount)
    let txPackets = Self.clamped(txPacketCount, baseline?.txPacketCount)
    let rxSnrs = Self.clamped(rxSnrCount, baseline?.rxSnrCount)
    let txSnrs = Self.clamped(txSnrCount, baseline?.txSnrCount)
    let rssis = Self.clamped(rssiCount, baseline?.rssiCount)
    let relays = Self.clamped(relayCount, baseline?.relayCount)
    let echoes = Self.clamped(echoCount, baseline?.echoCount)

    // No count moved: this repeater was seen before the run and not during it.
    guard rxPackets + txPackets + rxSnrs + txSnrs + rssis + relays + echoes > 0 else {
      return nil
    }

    // The pair moves together or not at all — a fresh instant beside a reading taken
    // before the run started would be a fabricated measurement.
    let directIsMine = (lastDirectHeard ?? .distantPast) >= startedAt

    return MapperRepeaterStats(
      id: id,
      rxPacketCount: rxPackets,
      txPacketCount: txPackets,
      rxSnrSum: Self.delta(rxSnrSum, baseline?.rxSnrSum, over: rxSnrs),
      rxSnrCount: rxSnrs,
      txSnrSum: Self.delta(txSnrSum, baseline?.txSnrSum, over: txSnrs),
      txSnrCount: txSnrs,
      rssiSum: Self.delta(rssiSum, baseline?.rssiSum, over: rssis),
      rssiCount: rssis,
      minRxSnr: nil,
      maxRxSnr: nil,
      minTxSnr: nil,
      maxTxSnr: nil,
      relayCount: relays,
      echoCount: echoes,
      lastDirectHeard: directIsMine ? lastDirectHeard : nil,
      lastRxSnr: directIsMine ? lastRxSnr : nil,
      lastUplinkAt: (lastUplinkAt ?? .distantPast) >= startedAt ? lastUplinkAt : nil,
      // The ride cannot have met this repeater here before it began, and — with a
      // baseline — no earlier than the last sighting the baseline already accounted for.
      firstHeard: Swift.max(startedAt, baseline?.lastHeard ?? startedAt),
      lastHeard: lastHeard
    )
  }

  private static func clamped(_ current: Int, _ baseline: Int?) -> Int {
    Swift.max(0, current - (baseline ?? 0))
  }

  /// A sum's plain difference, kept signed — zeroed only when the samples it averages over
  /// are gone, where it has no divisor and nothing to say.
  private static func delta(_ current: Double, _ baseline: Double?, over samples: Int) -> Double {
    samples > 0 ? current - (baseline ?? 0) : 0
  }
}

public extension MapperCellObservationDTO {
  /// This cell-day's contribution to the run, or nil when the difference holds no
  /// observation at all.
  ///
  /// Field for field the inverse of ``merged(with:)``. Identity comes from `self`; a
  /// baseline for a different `(cell, day)` is a programmer error and is treated as no
  /// baseline rather than subtracting one row's totals from another's — the same
  /// do-no-harm convention `merged(with:)` uses when it is handed a foreign row.
  ///
  /// - Parameters:
  ///   - baseline: this row at run start, or nil when the row did not exist then (every
  ///     figure it holds is the ride's).
  ///   - startedAt: the run's start instant.
  func residual(since baseline: MapperCellObservationDTO?, startedAt: Date) -> MapperCellObservationDTO? {
    let reference: MapperCellObservationDTO? = if let baseline,
                                                  baseline.cellRaw == cellRaw, baseline.day == day {
      baseline
    } else {
      nil
    }

    var residual = MapperCellObservationDTO(cellRaw: cellRaw, day: day)
    residual.packetCount = Self.clamped(packetCount, reference?.packetCount)
    residual.activePacketCount = Self.clamped(activePacketCount, reference?.activePacketCount)
    residual.passivePacketCount = Self.clamped(passivePacketCount, reference?.passivePacketCount)
    residual.probesSent = Self.clamped(probesSent, reference?.probesSent)
    residual.probesAnswered = Self.clamped(probesAnswered, reference?.probesAnswered)
    residual.rxCount = Self.clamped(rxCount, reference?.rxCount)
    residual.txHeardCount = Self.clamped(txHeardCount, reference?.txHeardCount)
    residual.ackCount = Self.clamped(ackCount, reference?.ackCount)
    residual.stationaryObservationCount = Self.clamped(
      stationaryObservationCount,
      reference?.stationaryObservationCount
    )
    residual.rttSampleCount = Self.clamped(rttSampleCount, reference?.rttSampleCount)
    residual.rttMsSum = Self.delta(rttMsSum, reference?.rttMsSum, over: residual.rttSampleCount)
    residual.probeRttSampleCount = Self.clamped(probeRttSampleCount, reference?.probeRttSampleCount)
    residual.probeRttMsSum = Self.delta(
      probeRttMsSum,
      reference?.probeRttMsSum,
      over: residual.probeRttSampleCount
    )
    residual.snrCount = Self.clamped(snrCount, reference?.snrCount)
    residual.snrSum = Self.delta(snrSum, reference?.snrSum, over: residual.snrCount)
    // See the type's doc comment: a ride's own best link is not recoverable from an
    // all-time maximum, so the ride reports none.
    residual.minSnr = nil
    residual.maxSnr = nil
    residual.txSnrCount = Self.clamped(txSnrCount, reference?.txSnrCount)
    residual.txSnrSum = Self.delta(txSnrSum, reference?.txSnrSum, over: residual.txSnrCount)
    residual.maxTxSnr = nil
    residual.rssiCount = Self.clamped(rssiCount, reference?.rssiCount)
    residual.rssiSum = Self.delta(rssiSum, reference?.rssiSum, over: residual.rssiCount)
    residual.floodCount = Self.clamped(floodCount, reference?.floodCount)
    residual.directCount = Self.clamped(directCount, reference?.directCount)
    // The ride's window opens where the baseline's closed, never before the run itself.
    residual.earliest = Swift.max(reference?.latest ?? startedAt, startedAt)
    residual.latest = latest
    residual.hopHistogram = hopHistogram.reduce(into: [Int: Int]()) { histogram, entry in
      let delta = Self.clamped(entry.value, reference?.hopHistogram[entry.key])
      if delta > 0 { histogram[entry.key] = delta }
    }
    // Keyed by the map's own key, not by `stats.id`: the builder's hash-width collapse
    // rewrites ids, and a residual must line up with the baseline entry for the same key.
    residual.repeaters = repeaters.reduce(into: [String: MapperRepeaterStats]()) { result, entry in
      if let delta = entry.value.residual(
        since: reference?.repeaters[entry.key],
        startedAt: startedAt
      ) {
        result[entry.key] = delta
      }
    }

    // Weight is observations, so no observations is no cell: the ride never covered here,
    // or the anchor purge has since shrunk the row below what the baseline remembers.
    guard residual.observationCount > 0 else { return nil }
    return residual
  }

  private static func clamped(_ current: Int, _ baseline: Int?) -> Int {
    Swift.max(0, current - (baseline ?? 0))
  }

  /// A sum's plain difference, kept signed — see the type's doc comment for why clamping a
  /// sum of negative readings would invent a perfect signal.
  private static func delta(_ current: Double, _ baseline: Double?, over samples: Int) -> Double {
    samples > 0 ? current - (baseline ?? 0) : 0
  }
}
