import Foundation
import MeshWX

/// What applying one message did to a bot's state. The UI re-reads state on any change; the
/// cases exist so tests can pin every rule in spec §2.3 and §3–§8 individually.
public enum WeatherStateChange: Sendable, Hashable {
  /// A `seq` already accepted: the bot's second transmission of the same bytes, or a copy
  /// delivered late. Nothing else in the message is looked at.
  case duplicate(seq: UInt8)
  /// `seq` skipped ahead: at least one message was missed.
  case sequenceGap(expected: UInt8, received: UInt8)
  /// A `seq` behind the newest accepted one and not a known copy. Its warning, cancel or
  /// digest is not applied — newer messages may already have superseded it — and the gap it
  /// reveals asks for a digest.
  case outOfOrder(seq: UInt8)
  case warningStored(MeshWXWarningIdentity, replacedExisting: Bool)
  /// A held warning ended. `reason` is the cancel's, or nil when a digest omitted it.
  case warningRemoved(MeshWXWarningIdentity, reason: MeshWXCancelReason?)
  /// A cancel for an identity the app never held; nothing to remove.
  case cancelForUnknown(MeshWXWarningIdentity)
  case digestApplied(missing: [MeshWXWarningIdentity], removed: [MeshWXWarningIdentity])
  /// The digest was built before the one already held — a late drain from the radio's queue —
  /// so it changed nothing.
  case digestIgnoredOlder(builtMinutes: UInt32)
  case observationsStored(stations: [UInt16])
  case forecastStored(point: UInt16)
  /// The held forecast for that point was issued later than this one; kept the held one.
  case forecastIgnoredOlder(point: UInt16)
  case textChunkStored(group: UInt8, index: UInt8, isComplete: Bool)
  case notAvailable(MeshWXNotAvailable)
  case unknownType(rawType: UInt8)
}

/// Pure state transitions for one bot. No clock, no I/O, no tables: every input is in the
/// arguments, which is what makes each spec rule a one-line test.
public enum WeatherStateReducer {
  /// How many accepted `seq` values count as "already seen".
  static let duplicateWindow = 16
  /// After this long without hearing the bot, a repeated `seq` is a new message that wrapped
  /// around, not a copy.
  static let duplicateWindowReset: TimeInterval = 6 * 60 * 60
  /// A digest speaks only for warnings that arrived before it was built. Arrival is on the
  /// phone's clock and building on the bot's, so a margin absorbs clock difference and the
  /// bot's five-minute answer cache (spec §8.2): an empty list re-sent at 23:04 was built at
  /// 23:00 and cannot remove the tornado warning received at 23:02.
  static let digestMargin: TimeInterval = 10 * 60

  /// Applies `message` (already known to be from `state.botID`) and reports what changed.
  public static func apply(
    _ message: MeshWXMessage,
    to state: inout WeatherBotState,
    receivedAt: Date
  ) -> [WeatherStateChange] {
    let seq = message.header.seq
    let isLongSilence = state.lastHeardAt.map { receivedAt.timeIntervalSince($0) > duplicateWindowReset } ?? false
    if isLongSilence { state.recentSeqs = [] }
    if state.recentSeqs.contains(seq) { return [.duplicate(seq: seq)] }

    var changes: [WeatherStateChange] = []
    var isOutOfOrder = false
    if let lastSeq = state.lastSeq {
      let forward = seq &- lastSeq
      if isLongSilence || (forward >= 1 && forward <= 128) {
        if forward != 1 {
          changes.append(.sequenceGap(expected: lastSeq &+ 1, received: seq))
          markGap(&state, at: receivedAt)
        }
        state.lastSeq = seq
      } else {
        isOutOfOrder = true
        changes.append(.outOfOrder(seq: seq))
        markGap(&state, at: receivedAt)
      }
    } else {
      state.lastSeq = seq
    }
    state.recentSeqs.append(seq)
    if state.recentSeqs.count > duplicateWindow {
      state.recentSeqs.removeFirst(state.recentSeqs.count - duplicateWindow)
    }
    state.lastHeardAt = max(state.lastHeardAt ?? receivedAt, receivedAt)

    switch message.payload {
    case let .warning(warning):
      if !isOutOfOrder { changes.append(store(warning, in: &state, receivedAt: receivedAt)) }
    case let .cancel(cancel):
      if !isOutOfOrder { changes.append(remove(cancel, from: &state, receivedAt: receivedAt)) }
    case let .digest(digest):
      if !isOutOfOrder { changes.append(applyDigest(digest, to: &state, receivedAt: receivedAt)) }
    case let .observations(batch):
      changes.append(store(batch, in: &state, receivedAt: receivedAt))
    case let .forecast(forecast):
      changes.append(store(forecast, in: &state, receivedAt: receivedAt))
    case let .text(chunk):
      changes.append(store(chunk, in: &state, receivedAt: receivedAt))
    case let .notAvailable(notAvailable):
      changes.append(.notAvailable(notAvailable))
    case .unknown:
      changes.append(.unknownType(rawType: message.header.rawType))
    }
    return changes
  }

  private static func markGap(_ state: inout WeatherBotState, at date: Date) {
    state.needsDigest = true
    state.gapDetectedAt = max(state.gapDetectedAt ?? date, date)
  }

  /// Drops warnings that expired before `cutoff`, returning what went. Expiry is judged at
  /// read time everywhere else; this exists so persisted state does not grow without bound.
  @discardableResult
  public static func pruneExpired(
    _ state: inout WeatherBotState,
    expiredBefore cutoff: Date
  ) -> [MeshWXWarningIdentity] {
    let expired = state.warnings.values
      .filter { $0.isExpired(at: cutoff) }
      .map(\.identity)
      .sorted(by: identityOrder)
    for identity in expired {
      state.warnings.removeValue(forKey: identity)
    }
    return expired
  }

  /// Forgets upgrade markers older than `cutoff`: long enough that the replacement, if it was
  /// ever sent, has been listed by a digest or has itself expired.
  public static func prunePendingUpgrades(_ state: inout WeatherBotState, olderThan cutoff: Date) {
    state.pendingUpgrades = state.pendingUpgrades.filter { $0.value.cancelledAt >= cutoff }
  }

  // MARK: - Warnings

  private static func store(
    _ warning: MeshWXWarning,
    in state: inout WeatherBotState,
    receivedAt: Date
  ) -> WeatherStateChange {
    // Spec §2.3: keyed by identity, not by seq — a known identity is replaced either way,
    // whether or not the bot set the update flag.
    let existing = state.warnings[warning.identity]
    state.warnings[warning.identity] = WeatherStoredWarning(
      warning: warning,
      receivedAt: receivedAt,
      updateCount: existing.map { $0.updateCount + 1 } ?? 0
    )
    state.missingFromDigest.removeAll { $0 == warning.identity }
    // The replacement for an upgraded warning comes from the same office over the same
    // ground. Anything else from that office leaves the marker in place.
    state.pendingUpgrades = state.pendingUpgrades.filter { _, pending in
      !(pending.warning.office == warning.office && areasOverlap(pending.warning, warning))
    }
    return .warningStored(warning.identity, replacedExisting: existing != nil)
  }

  private static func remove(
    _ cancel: MeshWXCancel,
    from state: inout WeatherBotState,
    receivedAt: Date
  ) -> WeatherStateChange {
    state.missingFromDigest.removeAll { $0 == cancel.identity }
    guard let removed = state.warnings.removeValue(forKey: cancel.identity) else {
      return .cancelForUnknown(cancel.identity)
    }
    if cancel.reason == .upgraded {
      state.pendingUpgrades[cancel.identity] = WeatherPendingUpgrade(
        warning: removed.warning, cancelledAt: receivedAt)
    }
    return .warningRemoved(cancel.identity, reason: cancel.reason)
  }

  /// Whether two warnings cover shared ground: a common county or zone, or overlapping polygon
  /// boxes. Deliberately generous — a false "yes" only clears an upgrade marker a little early
  /// when the office issues something nearby, a false "no" keeps it until the next digest.
  static func areasOverlap(_ lhs: MeshWXWarning, _ rhs: MeshWXWarning) -> Bool {
    if !areaKeys(lhs).isDisjoint(with: areaKeys(rhs)) { return true }
    guard let lhsPolygon = lhs.polygon, let rhsPolygon = rhs.polygon,
          let lhsBox = MeshWXGeometry.Box([lhsPolygon]),
          let rhsBox = MeshWXGeometry.Box([rhsPolygon])
    else { return false }
    return lhsBox.minLatitude <= rhsBox.maxLatitude && rhsBox.minLatitude <= lhsBox.maxLatitude
      && lhsBox.minLongitude <= rhsBox.maxLongitude && rhsBox.minLongitude <= lhsBox.maxLongitude
  }

  private struct AreaKey: Hashable {
    let state: UInt8
    let isCounty: Bool
    let number: UInt16
  }

  private static func areaKeys(_ warning: MeshWXWarning) -> Set<AreaKey> {
    Set((warning.areas ?? []).flatMap { run in
      run.numbers.map { AreaKey(state: run.stateIndex, isCounty: run.isCounty, number: $0) }
    })
  }

  // MARK: - Digest

  private static func applyDigest(
    _ digest: MeshWXDigest,
    to state: inout WeatherBotState,
    receivedAt: Date
  ) -> WeatherStateChange {
    if let held = state.digest, digest.nowMinutes < held.digest.nowMinutes {
      return .digestIgnoredOlder(builtMinutes: digest.nowMinutes)
    }
    let speaksBefore = Date(unixMinutes: digest.nowMinutes).addingTimeInterval(-digestMargin)
    let listed = Set(digest.entries.map(\.identity))

    // Spec §5: "an identity the app holds that is absent from the digest has ended" — for
    // identities the list could have known about.
    let removed = state.warnings.values
      .filter { !listed.contains($0.identity) && $0.receivedAt < speaksBefore }
      .map(\.identity)
      .sorted(by: identityOrder)
    for identity in removed {
      state.warnings.removeValue(forKey: identity)
    }

    var missing: [MeshWXWarningIdentity] = []
    for entry in digest.entries {
      guard var held = state.warnings[entry.identity] else {
        missing.append(entry.identity)
        continue
      }
      // The digest's expiry is absolute (`now + rel`). It replaces the held one when the list
      // is newer than the warning message; otherwise it may only extend it.
      let replaces = held.receivedAt < speaksBefore
      if held.warning.expiresMinutes != entry.expiresMinutes,
         replaces || entry.expiresMinutes > held.warning.expiresMinutes {
        held.warning.expiresMinutes = entry.expiresMinutes
        state.warnings[entry.identity] = held
      }
    }

    state.pendingUpgrades = state.pendingUpgrades.filter { $0.value.cancelledAt >= speaksBefore }
    if let gap = state.gapDetectedAt {
      if gap < speaksBefore {
        state.needsDigest = false
        state.gapDetectedAt = nil
      }
    } else {
      state.needsDigest = false
    }
    state.digest = WeatherStoredDigest(digest: digest, receivedAt: receivedAt)
    state.missingFromDigest = missing
    return .digestApplied(missing: missing, removed: removed)
  }

  // MARK: - Observations and forecasts

  private static func store(
    _ batch: MeshWXObservations,
    in state: inout WeatherBotState,
    receivedAt: Date
  ) -> WeatherStateChange {
    var stored: [UInt16] = []
    for observation in batch.stations {
      // A cached re-send of an older batch must not roll a station back.
      if let held = state.observations[observation.stationIndex],
         held.timestampMinutes > batch.timestampMinutes {
        continue
      }
      state.observations[observation.stationIndex] = WeatherStoredObservation(
        observation: observation,
        timestampMinutes: batch.timestampMinutes,
        receivedAt: receivedAt,
        batchSize: batch.stations.count
      )
      stored.append(observation.stationIndex)
    }
    return .observationsStored(stations: stored)
  }

  private static func store(
    _ forecast: MeshWXForecast,
    in state: inout WeatherBotState,
    receivedAt: Date
  ) -> WeatherStateChange {
    let held = state.forecasts[forecast.pointIndex]
    if let held, held.forecast.issuedMinutes > forecast.issuedMinutes {
      return .forecastIgnoredOlder(point: forecast.pointIndex)
    }
    // A fresh forecast for the unbundled slot is for whatever place was asked for last; the
    // service re-labels it when it settles the request that produced it. Whether this phone
    // asked about a bundled point survives the bot's next scheduled issue of it.
    state.forecasts[forecast.pointIndex] = WeatherStoredForecast(
      forecast: forecast,
      receivedAt: receivedAt,
      requestLabel: nil,
      requestedHere: forecast.isUnbundledPoint ? false : (held?.requestedHere ?? false)
    )
    return .forecastStored(point: forecast.pointIndex)
  }

  // MARK: - Text

  private static func store(
    _ chunk: MeshWXText,
    in state: inout WeatherBotState,
    receivedAt: Date
  ) -> WeatherStateChange {
    var assembly: WeatherTextAssembly
    if let held = state.texts[chunk.group],
       held.subject == chunk.subject,
       held.total == chunk.total {
      assembly = held
    } else {
      // A different subject or chunk count under the same group byte is a new reply that
      // happens to reuse the byte (it wraps with `seq`); start over.
      assembly = WeatherTextAssembly(
        subject: chunk.subject,
        group: chunk.group,
        total: chunk.total,
        firstReceivedAt: receivedAt,
        lastReceivedAt: receivedAt
      )
    }
    assembly.chunks[chunk.index] = chunk.text
    assembly.lastReceivedAt = receivedAt
    state.texts[chunk.group] = assembly
    return .textChunkStored(group: chunk.group, index: chunk.index, isComplete: assembly.isComplete)
  }

  // MARK: - Ordering

  /// Deterministic order for identity lists in change records and pruning.
  static func identityOrder(_ lhs: MeshWXWarningIdentity, _ rhs: MeshWXWarningIdentity) -> Bool {
    if lhs.event != rhs.event { return lhs.event < rhs.event }
    if lhs.office != rhs.office { return lhs.office < rhs.office }
    return lhs.etn < rhs.etn
  }
}
