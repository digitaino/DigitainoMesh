import Foundation
import MeshWX

// MARK: - Stored records

/// A warning as the app holds it: the last message received for its identity, and when.
public struct WeatherStoredWarning: Sendable, Hashable, Codable {
  public var warning: MeshWXWarning
  public var receivedAt: Date
  /// How many times a later message replaced this identity (spec §3: sent again when
  /// something material changes). Informational.
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

public struct WeatherStoredDigest: Sendable, Hashable, Codable {
  public var digest: MeshWXDigest
  public var receivedAt: Date

  public init(digest: MeshWXDigest, receivedAt: Date) {
    self.digest = digest
    self.receivedAt = receivedAt
  }

  /// Spec §5: minutes since the bot last received a product from its home office, in
  /// units of four minutes, capped.
  public var isFeedStale: Bool { MeshWXPresentation.isFeedStale(feedHealth: digest.feedHealth) }
}

/// One station's latest reading, stamped with the batch time it arrived in.
public struct WeatherStoredObservation: Sendable, Hashable, Codable {
  public var observation: MeshWXStationObservation
  /// The batch's `ts`: Unix minutes of the newest observation in the batch (spec §6).
  public var timestampMinutes: UInt32
  public var receivedAt: Date

  public init(observation: MeshWXStationObservation, timestampMinutes: UInt32, receivedAt: Date) {
    self.observation = observation
    self.timestampMinutes = timestampMinutes
    self.receivedAt = receivedAt
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

  public init(forecast: MeshWXForecast, receivedAt: Date, requestLabel: String? = nil) {
    self.forecast = forecast
    self.receivedAt = receivedAt
    self.requestLabel = requestLabel
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

  public init(
    subject: MeshWXTextSubject,
    group: UInt8,
    total: UInt8,
    chunks: [UInt8: String] = [:],
    firstReceivedAt: Date,
    lastReceivedAt: Date
  ) {
    self.subject = subject
    self.group = group
    self.total = total
    self.chunks = chunks
    self.firstReceivedAt = firstReceivedAt
    self.lastReceivedAt = lastReceivedAt
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
  /// The last `seq` accepted, for duplicate and gap detection (spec §2.3).
  public var lastSeq: UInt8?
  public var lastHeardAt: Date?
  /// Set on a `seq` gap and cleared by the next digest — the cue that `>d` would help.
  public var needsDigest: Bool
  public var warnings: [MeshWXWarningIdentity: WeatherStoredWarning]
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
    lastHeardAt = nil
    needsDigest = false
    warnings = [:]
    digest = nil
    missingFromDigest = []
    observations = [:]
    forecasts = [:]
    texts = [:]
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
