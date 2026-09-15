import Foundation
import MeshWX

/// What applying one message did to a bot's state. The UI re-reads state on any change; the
/// cases exist so tests can pin every rule in spec §2.3 and §3–§8 individually.
public enum WeatherStateChange: Sendable, Hashable {
  /// Same `(bot, seq)` as the last accepted message: the bot's second transmission of the
  /// same bytes, delivered after all. Nothing else in the message is looked at.
  case duplicate(seq: UInt8)
  /// `seq` skipped ahead: at least one message was missed.
  case sequenceGap(expected: UInt8, received: UInt8)
  case warningStored(MeshWXWarningIdentity, replacedExisting: Bool)
  /// A held warning ended. `reason` is the cancel's, or nil when a digest omitted it.
  case warningRemoved(MeshWXWarningIdentity, reason: MeshWXCancelReason?)
  /// A cancel for an identity the app never held; nothing to remove.
  case cancelForUnknown(MeshWXWarningIdentity)
  case digestApplied(missing: [MeshWXWarningIdentity], removed: [MeshWXWarningIdentity])
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
  /// Applies `message` (already known to be from `state.botID`) and reports what changed.
  public static func apply(
    _ message: MeshWXMessage,
    to state: inout WeatherBotState,
    receivedAt: Date
  ) -> [WeatherStateChange] {
    var changes: [WeatherStateChange] = []
    let seq = message.header.seq

    if let lastSeq = state.lastSeq {
      // Spec §2.3: nodes dedupe by packet hash so the copy normally never reaches the phone;
      // when it does, its seq equals the last one and the bytes are identical.
      if lastSeq == seq { return [.duplicate(seq: seq)] }
      let expected = lastSeq &+ 1
      if seq != expected {
        changes.append(.sequenceGap(expected: expected, received: seq))
        state.needsDigest = true
      }
    }
    state.lastSeq = seq
    state.lastHeardAt = receivedAt

    switch message.payload {
    case let .warning(warning):
      changes.append(store(warning, in: &state, receivedAt: receivedAt))
    case let .cancel(cancel):
      changes.append(remove(cancel, from: &state))
    case let .digest(digest):
      changes.append(applyDigest(digest, to: &state, receivedAt: receivedAt))
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
    return .warningStored(warning.identity, replacedExisting: existing != nil)
  }

  private static func remove(
    _ cancel: MeshWXCancel,
    from state: inout WeatherBotState
  ) -> WeatherStateChange {
    state.missingFromDigest.removeAll { $0 == cancel.identity }
    guard state.warnings.removeValue(forKey: cancel.identity) != nil else {
      return .cancelForUnknown(cancel.identity)
    }
    return .warningRemoved(cancel.identity, reason: cancel.reason)
  }

  // MARK: - Digest

  private static func applyDigest(
    _ digest: MeshWXDigest,
    to state: inout WeatherBotState,
    receivedAt: Date
  ) -> WeatherStateChange {
    let listed = Set(digest.entries.map(\.identity))
    // Spec §5: "an identity the app holds that is absent from the digest has ended".
    let removed = state.warnings.keys
      .filter { !listed.contains($0) }
      .sorted(by: identityOrder)
    for identity in removed {
      state.warnings.removeValue(forKey: identity)
    }

    var missing: [MeshWXWarningIdentity] = []
    for entry in digest.entries {
      if var held = state.warnings[entry.identity] {
        // The digest's expiry is absolute (`now + rel`) and at least as fresh as the
        // warning message, so a countdown drawn from it stays honest even when the
        // warning's own 30-minute update threshold has not been crossed.
        if held.warning.expiresMinutes != entry.expiresMinutes {
          held.warning.expiresMinutes = entry.expiresMinutes
          state.warnings[entry.identity] = held
        }
      } else {
        missing.append(entry.identity)
      }
    }

    state.digest = WeatherStoredDigest(digest: digest, receivedAt: receivedAt)
    state.missingFromDigest = missing
    state.needsDigest = false
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
        receivedAt: receivedAt
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
    if let held = state.forecasts[forecast.pointIndex],
       held.forecast.issuedMinutes > forecast.issuedMinutes {
      return .forecastIgnoredOlder(point: forecast.pointIndex)
    }
    // A fresh forecast for the unbundled slot is for whatever place was asked for last; the
    // service re-labels it when it settles the request that produced it.
    state.forecasts[forecast.pointIndex] = WeatherStoredForecast(
      forecast: forecast,
      receivedAt: receivedAt,
      requestLabel: nil
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
