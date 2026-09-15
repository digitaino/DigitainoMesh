import Foundation
import MeshWX

// MARK: - Stored records

/// A warning as the app holds it: the last message received for its identity, and when.
public struct WeatherStoredWarning: Sendable, Hashable, Codable {
  public var warning: MeshWXWarning
  /// Phone clock. It orders this warning against a digest (a list built before the warning
  /// arrived cannot speak for it); it is never shown as the warning's age.
  public var receivedAt: Date
  /// How many times a later message replaced this identity (spec §3). Informational.
  public var updateCount: Int

  public init(warning: MeshWXWarning, receivedAt: Date, updateCount: Int = 0) {
    self.warning = warning
    self.receivedAt = receivedAt
    self.updateCount = updateCount
  }

  public var identity: MeshWXWarningIdentity { warning.identity }

  /// The absolute expiry, from the wire's Unix minutes.
  public var expiresAt: Date { Date(unixMinutes: warning.expiresMinutes) }

  /// Spec §3: "treat as expired when passed", judged by the phone's clock.
  public func isExpired(at now: Date) -> Bool { expiresAt <= now }
}

/// A warning ended by a cancel that says it was upgraded (spec §4, flag 2).
///
/// The replacement follows in its own message. Until it arrives, or a later digest settles
/// what is active, the phone knows the area is under *something* worse and must not report
/// it as clear — which is what simply deleting the identity would do if the replacement was
/// lost.
public struct WeatherPendingUpgrade: Sendable, Hashable, Codable {
  public var warning: MeshWXWarning
  public var cancelledAt: Date

  public init(warning: MeshWXWarning, cancelledAt: Date) {
    self.warning = warning
    self.cancelledAt = cancelledAt
  }
}

public struct WeatherStoredDigest: Sendable, Hashable, Codable {
  public var digest: MeshWXDigest
  public var receivedAt: Date

  public init(digest: MeshWXDigest, receivedAt: Date) {
    self.digest = digest
    self.receivedAt = receivedAt
  }

  /// When the bot built the list, on the bot's clock (spec §5 `now`). Ages are measured from
  /// this, never from receipt: a digest drained from the radio's queue eight hours late is
  /// eight hours old.
  public var builtAt: Date { Date(unixMinutes: digest.nowMinutes) }

  /// Spec §5: minutes since the bot last received a product from its home office, in units of
  /// four minutes, capped.
  public var isFeedStale: Bool { MeshWXPresentation.isFeedStale(feedHealth: digest.feedHealth) }
}

/// One station's latest reading, stamped with the batch time it arrived in.
public struct WeatherStoredObservation: Sendable, Hashable, Codable {
  public var observation: MeshWXStationObservation
  /// The batch's `ts`: Unix minutes of the newest observation in the batch (spec §6) — the
  /// report's time, not necessarily this station's.
  public var timestampMinutes: UInt32
  public var receivedAt: Date
  /// Stations in the batch this reading came in. The bot's scheduled broadcast covers its
  /// area; a batch of one is the answer to somebody's single-station request, which says
  /// nothing about where the bot's coverage is.
  public var batchSize: Int

  public init(
    observation: MeshWXStationObservation,
    timestampMinutes: UInt32,
    receivedAt: Date,
    batchSize: Int = 1
  ) {
    self.observation = observation
    self.timestampMinutes = timestampMinutes
    self.receivedAt = receivedAt
    self.batchSize = batchSize
  }

  private enum CodingKeys: String, CodingKey {
    case observation, timestampMinutes, receivedAt, batchSize
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    observation = try container.decode(MeshWXStationObservation.self, forKey: .observation)
    timestampMinutes = try container.decode(UInt32.self, forKey: .timestampMinutes)
    receivedAt = try container.decode(Date.self, forKey: .receivedAt)
    batchSize = try container.decodeIfPresent(Int.self, forKey: .batchSize) ?? 1
  }

  public var observedAt: Date { Date(unixMinutes: timestampMinutes) }

  public func isStale(at now: Date) -> Bool {
    MeshWXPresentation.isObservationStale(
      timestampMinutes: timestampMinutes,
      now: MeshWXPresentation.unixMinutes(for: now)
    )
  }
}

public struct WeatherStoredForecast: Sendable, Hashable, Codable {
  public var forecast: MeshWXForecast
  public var receivedAt: Date
  /// For a forecast the bot resolved from a place string (`point == 0xFFFF`), the request
  /// text is the only label there is (spec §7). Nil for bundled points.
  public var requestLabel: String?
  /// Whether this phone asked for this point. Answers to other phones' requests land here too
  /// (the channel is shared); they are someone else's places and are labelled so.
  public var requestedHere: Bool

  public init(
    forecast: MeshWXForecast,
    receivedAt: Date,
    requestLabel: String? = nil,
    requestedHere: Bool = false
  ) {
    self.forecast = forecast
    self.receivedAt = receivedAt
    self.requestLabel = requestLabel
    self.requestedHere = requestedHere
  }

  private enum CodingKeys: String, CodingKey {
    case forecast, receivedAt, requestLabel, requestedHere
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    forecast = try container.decode(MeshWXForecast.self, forKey: .forecast)
    receivedAt = try container.decode(Date.self, forKey: .receivedAt)
    requestLabel = try container.decodeIfPresent(String.self, forKey: .requestLabel)
    requestedHere = try container.decodeIfPresent(Bool.self, forKey: .requestedHere) ?? false
  }

  public var issuedAt: Date { Date(unixMinutes: forecast.issuedMinutes) }

  public func isStale(at now: Date) -> Bool {
    MeshWXPresentation.isForecastStale(
      issuedMinutes: forecast.issuedMinutes,
      now: MeshWXPresentation.unixMinutes(for: now)
    )
  }
}

/// A text reply being reassembled by `(bot, group)` in `idx` order (spec §8.1).
///
/// A re-sent reply (the bot's five-minute cache, or the app asking again after 20 s) carries
/// the *original* group byte, so it merges into the same assembly and fills whatever was
/// missing — which is exactly the recovery the spec describes.
public struct WeatherTextAssembly: Sendable, Hashable, Codable {
  public var subject: MeshWXTextSubject
  public var group: UInt8
  public var total: UInt8
  /// Chunk text by index. Absent indexes never arrived.
  public var chunks: [UInt8: String]
  public var firstReceivedAt: Date
  public var lastReceivedAt: Date
  /// The request of this phone's that this reply answered. A text chunk names only its
  /// subject: without this, somebody else's `>storm OK` is indistinguishable from the storm
  /// reports this phone asked for Texas.
  public var request: WeatherRequest?

  public init(
    subject: MeshWXTextSubject,
    group: UInt8,
    total: UInt8,
    chunks: [UInt8: String] = [:],
    firstReceivedAt: Date,
    lastReceivedAt: Date,
    request: WeatherRequest? = nil
  ) {
    self.subject = subject
    self.group = group
    self.total = total
    self.chunks = chunks
    self.firstReceivedAt = firstReceivedAt
    self.lastReceivedAt = lastReceivedAt
    self.request = request
  }

  private enum CodingKeys: String, CodingKey {
    case subject, group, total, chunks, firstReceivedAt, lastReceivedAt, request
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    subject = try container.decode(MeshWXTextSubject.self, forKey: .subject)
    group = try container.decode(UInt8.self, forKey: .group)
    total = try container.decode(UInt8.self, forKey: .total)
    chunks = try container.decode([UInt8: String].self, forKey: .chunks)
    firstReceivedAt = try container.decode(Date.self, forKey: .firstReceivedAt)
    lastReceivedAt = try container.decode(Date.self, forKey: .lastReceivedAt)
    request = try container.decodeIfPresent(WeatherRequest.self, forKey: .request)
  }

  public var missingIndexes: [UInt8] {
    (0..<total).filter { chunks[$0] == nil }
  }

  public var isComplete: Bool { total > 0 && missingIndexes.isEmpty }

  /// The chunks in order, nil where one never arrived, so the view can place its own
  /// "missing part" marker.
  public var orderedChunks: [String?] {
    (0..<total).map { chunks[$0] }
  }
}

// MARK: - Per-bot state

/// Everything the app holds for one bot (spec §12: "keep separate state per bot").
public struct WeatherBotState: Sendable, Hashable, Codable {
  public var botID: UInt16
  /// The newest `seq` accepted, for gap detection (spec §2.3).
  public var lastSeq: UInt8?
  /// The last few accepted `seq` values, newest last. A copy of any of them is a duplicate
  /// however late it arrives; comparing against `lastSeq` alone let a late copy through as a
  /// gap and could bring a cancelled warning back.
  public var recentSeqs: [UInt8]
  public var lastHeardAt: Date?
  /// Set on a `seq` gap or an out-of-order message; cleared only by a digest built after the
  /// gap was seen — the cue that `>d` would help and that "no alerts" cannot be claimed.
  public var needsDigest: Bool
  /// Phone time the outstanding gap was detected, so a digest built before it (a cached
  /// re-send) does not clear it.
  public var gapDetectedAt: Date?
  public var warnings: [MeshWXWarningIdentity: WeatherStoredWarning]
  /// Upgraded warnings whose replacement has not been received.
  public var pendingUpgrades: [MeshWXWarningIdentity: WeatherPendingUpgrade]
  public var digest: WeatherStoredDigest?
  /// Identities the last digest listed that the app does not hold: each is one
  /// `>w <identity>` away (spec §5).
  public var missingFromDigest: [MeshWXWarningIdentity]
  /// By wire station index.
  public var observations: [UInt16: WeatherStoredObservation]
  /// By point index; `0xFFFF` holds the last place-resolved forecast.
  public var forecasts: [UInt16: WeatherStoredForecast]
  /// By group.
  public var texts: [UInt8: WeatherTextAssembly]

  public init(botID: UInt16) {
    self.botID = botID
    lastSeq = nil
    recentSeqs = []
    lastHeardAt = nil
    needsDigest = false
    gapDetectedAt = nil
    warnings = [:]
    pendingUpgrades = [:]
    digest = nil
    missingFromDigest = []
    observations = [:]
    forecasts = [:]
    texts = [:]
  }

  private enum CodingKeys: String, CodingKey {
    case botID, lastSeq, recentSeqs, lastHeardAt, needsDigest, gapDetectedAt, warnings,
      pendingUpgrades, digest, missingFromDigest, observations, forecasts, texts
  }

  /// Fields added after the first release decode as absent rather than failing the whole file:
  /// a state file from before them is still the last picture the bot sent.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    botID = try container.decode(UInt16.self, forKey: .botID)
    lastSeq = try container.decodeIfPresent(UInt8.self, forKey: .lastSeq)
    recentSeqs = try container.decodeIfPresent([UInt8].self, forKey: .recentSeqs) ?? []
    lastHeardAt = try container.decodeIfPresent(Date.self, forKey: .lastHeardAt)
    needsDigest = try container.decode(Bool.self, forKey: .needsDigest)
    gapDetectedAt = try container.decodeIfPresent(Date.self, forKey: .gapDetectedAt)
    warnings = try container.decode([MeshWXWarningIdentity: WeatherStoredWarning].self, forKey: .warnings)
    pendingUpgrades = try container.decodeIfPresent(
      [MeshWXWarningIdentity: WeatherPendingUpgrade].self, forKey: .pendingUpgrades) ?? [:]
    digest = try container.decodeIfPresent(WeatherStoredDigest.self, forKey: .digest)
    missingFromDigest = try container.decode([MeshWXWarningIdentity].self, forKey: .missingFromDigest)
    observations = try container.decode([UInt16: WeatherStoredObservation].self, forKey: .observations)
    forecasts = try container.decode([UInt16: WeatherStoredForecast].self, forKey: .forecasts)
    texts = try container.decode([UInt8: WeatherTextAssembly].self, forKey: .texts)
  }

  /// Warnings not yet expired at `now`, in the spec's display order (§10.2): the most severe
  /// first (`MeshWXSeverity.rank`, warnings above watches above advisories), then the soonest
  /// expiry. An event the tables cannot rank sorts last.
  public func activeWarnings(at now: Date, severity: (UInt8) -> MeshWXSeverity?) -> [WeatherStoredWarning] {
    warnings.values
      .filter { !$0.isExpired(at: now) }
      .sorted { lhs, rhs in
        let lhsRank = severity(lhs.warning.event)?.rank ?? -1
        let rhsRank = severity(rhs.warning.event)?.rank ?? -1
        if lhsRank != rhsRank { return lhsRank > rhsRank }
        if lhs.expiresAt != rhs.expiresAt { return lhs.expiresAt < rhs.expiresAt }
        return lhs.identity.etn < rhs.identity.etn
      }
  }

  /// The newest observation batch time across stations, if any.
  public var latestObservationMinutes: UInt32? {
    observations.values.map(\.timestampMinutes).max()
  }
}

// MARK: - Unix minutes

extension Date {
  /// The wire's clock: Unix minutes (`seconds / 60`) as u32 (spec §2.4).
  public init(unixMinutes: UInt32) {
    self.init(timeIntervalSince1970: TimeInterval(unixMinutes) * 60)
  }
}
