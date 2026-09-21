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
  /// The `seq` of the message this copy came in, so a late resend can be told apart from an older
  /// message. Nil in state saved before copies carried one.
  public var seq: UInt8?
  /// When NWS issued the product (spec §3, revision 5), resolved once from the message that
  /// carried it. Nil for a warning from a bot older than revision 5, and in state saved before
  /// the app could read it.
  ///
  /// Stored rather than computed from ``MeshWXWarning/issuedMinutes`` because the wire states the
  /// issue time *relative to the expiry*, and a digest may later extend that expiry
  /// (`WeatherStateReducer.applyDigest`): recomputing would then walk the issue time forward with
  /// it. The instant a warning was issued never moves.
  public var issuedAt: Date?
  /// Where the bot got this warning (spec §2.2, revision 7), from the header of the message that
  /// carried it. ``MeshWXDataSource/unstated`` for a bot older than revision 7 and for state
  /// saved before the app could read it — which is not a source, and says nothing on screen.
  public var source: MeshWXDataSource

  public init(
    warning: MeshWXWarning,
    receivedAt: Date,
    updateCount: Int = 0,
    seq: UInt8? = nil,
    issuedAt: Date? = nil,
    source: MeshWXDataSource = .unstated
  ) {
    self.warning = warning
    self.receivedAt = receivedAt
    self.updateCount = updateCount
    self.seq = seq
    self.issuedAt = issuedAt
    self.source = source
  }

  private enum CodingKeys: String, CodingKey {
    case warning, receivedAt, updateCount, seq, issuedAt, source
  }

  /// `source` arrived with revision 7, so a state file written before it decodes as unstated
  /// rather than failing: the warning is still the last one the bot sent.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    warning = try container.decode(MeshWXWarning.self, forKey: .warning)
    receivedAt = try container.decode(Date.self, forKey: .receivedAt)
    updateCount = try container.decode(Int.self, forKey: .updateCount)
    seq = try container.decodeIfPresent(UInt8.self, forKey: .seq)
    issuedAt = try container.decodeIfPresent(Date.self, forKey: .issuedAt)
    source = try container.decodeIfPresent(MeshWXDataSource.self, forKey: .source) ?? .unstated
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
  /// four minutes, capped. Quiet or never received; either withholds calm.
  public var isFeedStale: Bool { MeshWXPresentation.isFeedStale(feedHealth: digest.feedHealth) }

  /// What `feed_health` says, split so a quiet office is not worded as a broken feed.
  public var feed: MeshWXFeedHealth { MeshWXFeedHealth(feedHealth: digest.feedHealth) }
}

/// The bot's own statement of what it carries (spec §7A), and when it arrived.
///
/// The message carries no time of its own: it says what the bot covers at the moment it is sent,
/// so its age is receipt. It does not go stale either — it is broadcast every three hours, and a
/// statement from yesterday is still what the bot said about itself, which is the only evidence
/// there is for "is this place in its area".
public struct WeatherStoredCoverage: Sendable, Hashable, Codable {
  public var coverage: MeshWXCoverage
  public var receivedAt: Date

  public init(coverage: MeshWXCoverage, receivedAt: Date) {
    self.coverage = coverage
    self.receivedAt = receivedAt
  }
}

/// One station's latest reading, stamped with the time that station measured it.
public struct WeatherStoredObservation: Sendable, Hashable, Codable {
  public var observation: MeshWXStationObservation
  /// This station's own report time in Unix minutes: the batch's `ts` less the station's age
  /// (spec §6.1). For a batch from a bot older than revision 5, which states no ages, it is the
  /// batch `ts` — all such a batch says about any of its stations.
  ///
  /// Everything time-like about a reading reads this — ``observedAt``, ``isStale(at:)``, and the
  /// newest-wins merge in the reducer — so all three are per station the moment the bot sends the
  /// ages. The batch time itself lives on in ``lastBatchMinutes``.
  public var timestampMinutes: UInt32
  public var receivedAt: Date
  /// Stations in the batch this reading came in. The bot's scheduled broadcast covers its
  /// area; a batch of one is the answer to somebody's single-station request, which says
  /// nothing about where the bot's coverage is.
  public var batchSize: Int
  /// The `ts` of the newest multi-station batch that named this station — the batch's own time,
  /// not this station's report time — whether or not that batch carried the reading held now.
  ///
  /// It is the evidence that the station is in the bot's area (docs/MESHWX_UI.md §6): a
  /// single-station answer to somebody's `>o KATT` carries a newer reading and replaces it, but
  /// must not take Camp Mabry out of the bot's area, shrink the coverage outline or change what
  /// its button asks for. Nil for a station only ever seen in a batch of one. Since revision 5 it
  /// is also the only place the batch time survives, ``timestampMinutes`` being the station's own.
  public var lastBatchMinutes: UInt32?
  /// Where the bot got this reading (spec §2.2, revision 7), from the header of the batch that
  /// carried it. Unstated for a bot older than revision 7 and for state saved before the app
  /// could read it.
  public var source: MeshWXDataSource

  public init(
    observation: MeshWXStationObservation,
    timestampMinutes: UInt32,
    receivedAt: Date,
    batchSize: Int = 1,
    lastBatchMinutes: UInt32? = nil,
    source: MeshWXDataSource = .unstated
  ) {
    self.observation = observation
    self.timestampMinutes = timestampMinutes
    self.receivedAt = receivedAt
    self.batchSize = batchSize
    self.lastBatchMinutes = lastBatchMinutes
    self.source = source
  }

  private enum CodingKeys: String, CodingKey {
    case observation, timestampMinutes, receivedAt, batchSize, lastBatchMinutes, source
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    observation = try container.decode(MeshWXStationObservation.self, forKey: .observation)
    timestampMinutes = try container.decode(UInt32.self, forKey: .timestampMinutes)
    receivedAt = try container.decode(Date.self, forKey: .receivedAt)
    batchSize = try container.decodeIfPresent(Int.self, forKey: .batchSize) ?? 1
    // A file written before the batch was remembered separately: a reading that came in a batch
    // is its own evidence, which is exactly what the app read from `batchSize` then.
    lastBatchMinutes = try container.decodeIfPresent(UInt32.self, forKey: .lastBatchMinutes)
      ?? (batchSize > 1 ? timestampMinutes : nil)
    source = try container.decodeIfPresent(MeshWXDataSource.self, forKey: .source) ?? .unstated
  }

  /// When this station measured what it reported — the *as of* time (spec §10.5), never when the
  /// packet arrived.
  public var observedAt: Date { Date(unixMinutes: timestampMinutes) }

  /// When this station was last in one of the bot's scheduled batches, on the bot's clock.
  public var lastBatchAt: Date? { lastBatchMinutes.map { Date(unixMinutes: $0) } }

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
  /// Where the bot got this forecast (spec §2.2, revision 7), from the header of the message that
  /// carried it. Unstated for a bot older than revision 7 and for state saved before the app
  /// could read it.
  public var source: MeshWXDataSource

  public init(
    forecast: MeshWXForecast,
    receivedAt: Date,
    requestLabel: String? = nil,
    requestedHere: Bool = false,
    source: MeshWXDataSource = .unstated
  ) {
    self.forecast = forecast
    self.receivedAt = receivedAt
    self.requestLabel = requestLabel
    self.requestedHere = requestedHere
    self.source = source
  }

  private enum CodingKeys: String, CodingKey {
    case forecast, receivedAt, requestLabel, requestedHere, source
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    forecast = try container.decode(MeshWXForecast.self, forKey: .forecast)
    receivedAt = try container.decode(Date.self, forKey: .receivedAt)
    requestLabel = try container.decodeIfPresent(String.self, forKey: .requestLabel)
    requestedHere = try container.decodeIfPresent(Bool.self, forKey: .requestedHere) ?? false
    source = try container.decodeIfPresent(MeshWXDataSource.self, forKey: .source) ?? .unstated
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
/// A chunk the bot transmits a second time — the same bytes, when no repeater echoed the first —
/// carries the *original* group byte, so it merges into the same assembly and fills the hole.
/// Asking again gets a reply built afresh (the bot keeps no cache), under a new group byte.
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
  /// Where the bot got the product this reply is of (spec §2.2, revision 7), taken from the
  /// chunks. They agree — one reply is built from one product — so this is the newest stated
  /// value, and a chunk that states nothing never erases one that did.
  public var source: MeshWXDataSource
  /// Any chunk said the product was longer than 8 packets and the bot dropped the tail (spec
  /// §8.1, revision 7).
  ///
  /// Not the same claim as a hole in ``orderedChunks``: a hole is a chunk the air ate, and asking
  /// again may fill it. This is the whole reply the bot will ever send for that request, cut at a
  /// sentence boundary, so the screen says so rather than leaving the reader to wonder whether
  /// their radio missed something.
  public var wasCut: Bool

  public init(
    subject: MeshWXTextSubject,
    group: UInt8,
    total: UInt8,
    chunks: [UInt8: String] = [:],
    firstReceivedAt: Date,
    lastReceivedAt: Date,
    request: WeatherRequest? = nil,
    source: MeshWXDataSource = .unstated,
    wasCut: Bool = false
  ) {
    self.subject = subject
    self.group = group
    self.total = total
    self.chunks = chunks
    self.firstReceivedAt = firstReceivedAt
    self.lastReceivedAt = lastReceivedAt
    self.request = request
    self.source = source
    self.wasCut = wasCut
  }

  private enum CodingKeys: String, CodingKey {
    case subject, group, total, chunks, firstReceivedAt, lastReceivedAt, request, source, wasCut
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
    // Both arrived with revision 7. A reply saved before them is still the reply that was
    // received; it just says nothing about where it came from or whether it was cut.
    source = try container.decodeIfPresent(MeshWXDataSource.self, forKey: .source) ?? .unstated
    wasCut = try container.decodeIfPresent(Bool.self, forKey: .wasCut) ?? false
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

/// An area sweep being reassembled by `(bot, group)` in `idx` order (spec §7C).
///
/// One sweep is one picture, built at one minute, of the states it covers. Packets of *this*
/// sweep merge into it; a newer sweep is a second picture and gets an assembly of its own
/// (`WeatherBotState.areaSweeps`), because merging two would draw this hour's Texas beside last
/// hour's Montana — the one output a map must never produce.
///
/// Held whether or not it is complete. Eight packets on a shared channel is the most expensive
/// answer in the protocol, and a sweep missing its last packet is still forty states' worth of
/// map — so a partial one is kept, drawn, and labelled as partial. Since revision 10 the missing
/// packets can also be asked for by name (``WeatherPartsOffer``).
public struct WeatherAreaSweepAssembly: Sendable, Hashable, Codable {
  /// When the bot built the sweep, in Unix minutes (spec §7C). The age on screen is from this,
  /// never from receipt.
  public var builtMinutes: UInt32
  /// Shared by every packet of this sweep: the `seq` of its first.
  public var group: UInt8
  public var total: UInt8
  /// Entries by packet index. Absent indexes never arrived.
  public var packets: [UInt8: [MeshWXAreaSweep.Entry]]
  public var firstReceivedAt: Date
  public var lastReceivedAt: Date
  /// Any packet said entries were dropped to fit. An area absent from a cut sweep is not an area
  /// with no alert, and no screen may read it as one.
  public var wasCut: Bool
  /// The sweep carries advisories as well as warnings and watches. Clear means the narrower scope
  /// was asked for, not that no advisory is active.
  public var includesAdvisories: Bool
  /// The sweep covers only the states ``scope`` names, not the country (spec revision 10, §7C).
  ///
  /// Read off `total` bit 7, which every packet of a scoped sweep carries — so this is known from
  /// whichever packet arrived first, packet 0 or not.
  public var isScoped: Bool
  /// Which states the sweep covers, in three states of knowledge:
  ///
  /// - `[]` — the whole country. ``isScoped`` is false and every unshaded area is genuinely
  ///   clear, as far as the sweep goes.
  /// - the state indices — scoped, and the packet carrying the scope entries (packet 0) arrived.
  ///   An unshaded area inside these states is clear; one outside them was never asked about.
  /// - `nil` — scoped, and packet 0 has not arrived. The sweep's entries are real and are drawn,
  ///   but nothing is known about which states it was asked for, so it speaks for none of them.
  ///   This is the case the whole `total` bit 7 design exists for: without the flag on every
  ///   packet, a phone in this position would read a scoped sweep as the country.
  public var scope: [UInt8]?
  /// Where the bot got the products behind the sweep (spec §2.2, revision 7). Unstated for a bot
  /// older than revision 7; a packet that states nothing never erases one that did.
  public var source: MeshWXDataSource
  /// The request of this phone's that this sweep answered, if any. A sweep is broadcast to
  /// everyone on `#meshwx`, so most of them answer somebody else's tap.
  public var request: WeatherRequest?

  public init(
    builtMinutes: UInt32,
    group: UInt8,
    total: UInt8,
    packets: [UInt8: [MeshWXAreaSweep.Entry]] = [:],
    firstReceivedAt: Date,
    lastReceivedAt: Date,
    wasCut: Bool = false,
    includesAdvisories: Bool = false,
    isScoped: Bool = false,
    scope: [UInt8]? = [],
    source: MeshWXDataSource = .unstated,
    request: WeatherRequest? = nil
  ) {
    self.builtMinutes = builtMinutes
    self.group = group
    self.total = total
    self.packets = packets
    self.firstReceivedAt = firstReceivedAt
    self.lastReceivedAt = lastReceivedAt
    self.wasCut = wasCut
    self.includesAdvisories = includesAdvisories
    self.isScoped = isScoped
    self.scope = scope
    self.source = source
    self.request = request
  }

  private enum CodingKeys: String, CodingKey {
    case builtMinutes, group, total, packets, firstReceivedAt, lastReceivedAt, wasCut,
      includesAdvisories, isScoped, scope, source, request
  }

  /// Both scope fields arrived with revision 10. A sweep saved before them was a national one —
  /// there was no other kind — so absent decodes as `isScoped: false, scope: []` rather than as
  /// an unknown scope, which would make a held map stop speaking for the country on upgrade.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    builtMinutes = try container.decode(UInt32.self, forKey: .builtMinutes)
    group = try container.decode(UInt8.self, forKey: .group)
    total = try container.decode(UInt8.self, forKey: .total)
    packets = try container.decode([UInt8: [MeshWXAreaSweep.Entry]].self, forKey: .packets)
    firstReceivedAt = try container.decode(Date.self, forKey: .firstReceivedAt)
    lastReceivedAt = try container.decode(Date.self, forKey: .lastReceivedAt)
    wasCut = try container.decodeIfPresent(Bool.self, forKey: .wasCut) ?? false
    includesAdvisories = try container.decodeIfPresent(Bool.self, forKey: .includesAdvisories) ?? false
    isScoped = try container.decodeIfPresent(Bool.self, forKey: .isScoped) ?? false
    scope = isScoped ? try container.decodeIfPresent([UInt8].self, forKey: .scope) : []
    source = try container.decodeIfPresent(MeshWXDataSource.self, forKey: .source) ?? .unstated
    request = try container.decodeIfPresent(WeatherRequest.self, forKey: .request)
  }

  /// When the bot built it, on the bot's clock.
  public var builtAt: Date { Date(unixMinutes: builtMinutes) }

  /// The sweep covers the country: not scoped, so every state is in it.
  public var isNational: Bool { !isScoped }

  /// Whether this sweep is the newest word on `stateIndex` — that it was asked about at all.
  /// A scoped sweep whose scope has not arrived (``scope`` nil) speaks for no state: its entries
  /// are drawn, but "nothing shaded here" is a claim it cannot make.
  public func covers(stateIndex: UInt8) -> Bool {
    guard isScoped else { return true }
    return scope?.contains(stateIndex) ?? false
  }

  public var missingIndexes: [UInt8] {
    (0..<total).filter { packets[$0] == nil }
  }

  public var isComplete: Bool { total > 0 && missingIndexes.isEmpty }

  public var receivedPacketCount: Int { packets.count }

  /// Every entry received, in packet order then in the order the bot sent them — most severe
  /// first (spec §7C), which is also the order the map lays its tints down in.
  public var entries: [MeshWXAreaSweep.Entry] {
    packets.keys.sorted().flatMap { packets[$0] ?? [] }
  }
}

/// One radar tile the phone is holding (spec revision 11, §7D).
///
/// One picture per tile and no history: a radar answer is a snapshot of a square of earth at a
/// minute, and the only thing anyone wants of an older one is to know it has been replaced. Keyed
/// by ``tile`` rather than by the coordinate anybody asked about, because the lattice is shared —
/// two people three kilometres apart ask about the same square, and the second one costs the
/// channel nothing.
public struct WeatherStoredRadarTile: Sendable, Hashable, Codable {
  /// The square of earth, which is this entry's identity.
  public var tile: MeshWXRadarTile
  public var radar: MeshWXRadar
  /// Phone clock: when the packet arrived. The age on screen is measured from
  /// ``MeshWXRadar/takenMinutes`` and never from this — a tile drained from the radio's queue an
  /// hour late is an hour older than it looks.
  public var receivedAt: Date
  /// Where the bot got the picture (spec §2.2, revision 7). A tile off the dish is
  /// ``MeshWXDataSource/goesSatellite``, which is the whole point of revision 11: no internet at
  /// either end.
  public var source: MeshWXDataSource

  public init(
    tile: MeshWXRadarTile,
    radar: MeshWXRadar,
    receivedAt: Date,
    source: MeshWXDataSource = .unstated
  ) {
    self.tile = tile
    self.radar = radar
    self.receivedAt = receivedAt
    self.source = source
  }

  /// When the picture was taken, on the bot's clock.
  public var takenAt: Date { Date(unixMinutes: radar.takenMinutes) }

  /// The picture's own time, which is what every rule about a tile is written in terms of.
  public var takenMinutes: UInt32 { radar.takenMinutes }
}

// MARK: - Per-bot state

/// One accepted message in the duplicate window: its `seq`, and a fingerprint of its content so
/// a new message that reuses a `seq` after the bot restarts is not taken for a copy.
public struct WeatherSeenMessage: Sendable, Hashable, Codable {
  public var seq: UInt8
  /// `WeatherStateReducer.fingerprint(of:)`. Nil for an entry from a state file written before
  /// fingerprints, or for a message the codec cannot re-encode.
  public var fingerprint: UInt64?

  public init(seq: UInt8, fingerprint: UInt64?) {
    self.seq = seq
    self.fingerprint = fingerprint
  }

  /// A copy has the same `seq` and, where both fingerprints are known, the same content. With
  /// either unknown the `seq` alone decides, as it did before fingerprints.
  func isCopy(seq: UInt8, fingerprint: UInt64?) -> Bool {
    guard seq == self.seq else { return false }
    guard let fingerprint, let known = self.fingerprint else { return true }
    return fingerprint == known
  }
}

/// Everything the app holds for one bot (spec §12: "keep separate state per bot").
public struct WeatherBotState: Sendable, Hashable, Codable {
  public var botID: UInt16
  /// The newest `seq` accepted, for gap detection (spec §2.3).
  public var lastSeq: UInt8?
  /// The last few accepted messages, newest last. A copy of any of them is a duplicate however
  /// late it arrives; comparing against `lastSeq` alone let a late copy through as a gap and
  /// could bring a cancelled warning back.
  public var recentMessages: [WeatherSeenMessage]
  public var lastHeardAt: Date?
  /// The last message heard live from this bot — not drained from the radio's queue at
  /// connect. What "the bot is in range" rests on: a backlog is stamped with the drain time, so
  /// a bot that went silent hours ago would otherwise look current. Nil for a state file from
  /// before the distinction.
  public var lastLiveHeardAt: Date?
  /// Set on a `seq` gap or an out-of-order message; cleared only by a digest built after the
  /// gap was seen — the cue that `>d` would help and that "no alerts" cannot be claimed.
  public var needsDigest: Bool
  /// Phone time the outstanding gap was detected, so a digest built before it — delivered late,
  /// or drained from the radio's queue — does not clear it.
  public var gapDetectedAt: Date?
  public var warnings: [MeshWXWarningIdentity: WeatherStoredWarning]
  /// Upgraded warnings whose replacement has not been received.
  public var pendingUpgrades: [MeshWXWarningIdentity: WeatherPendingUpgrade]
  /// Identities cancelled in the last hour, and when. A warning for one of them arriving out of
  /// order was sent before its cancel, and is not stored again.
  public var recentCancels: [MeshWXWarningIdentity: Date]
  public var digest: WeatherStoredDigest?
  /// Identities the last digest listed that the app does not hold: each is one
  /// `>w <identity>` away (spec §5).
  public var missingFromDigest: [MeshWXWarningIdentity]
  /// By wire station index.
  public var observations: [UInt16: WeatherStoredObservation]
  /// By point index; `0xFFFF` holds the last place-resolved forecast.
  public var forecasts: [UInt16: WeatherStoredForecast]
  /// Forecasts the bot resolved for itself, by **the coordinate that was asked for**, written
  /// exactly as the wire wrote it: `"35.687,-105.938"` (spec revision 10, §1.3).
  ///
  /// A `>f <lat>,<lon>` answer comes back under point `0xFFFF` when the point the bot chose is
  /// not in this bundle, and `0xFFFF` is one slot for the whole protocol: two coordinates asked
  /// about a minute apart would overwrite each other, and neither would have a name. The key is
  /// the question, which is the only label such a forecast has.
  ///
  /// ``WeatherBotState/unbundledAskKey`` is the one slot for an answer nobody here asked for: a
  /// `0xFFFF` forecast heard on the channel is somebody else's question, is kept for the Cached
  /// screen, and is never shown as a place's forecast.
  ///
  /// At most ``unbundledForecastLimit``, oldest received dropped.
  public var unbundledForecasts: [String: WeatherStoredForecast]
  /// By group.
  public var texts: [UInt8: WeatherTextAssembly]
  /// What the bot says it carries (spec §7A). Nil until it has said: the station footprint is
  /// the fallback then, and nothing the bot has not stated may put a place outside its area.
  public var coverage: WeatherStoredCoverage?
  /// The area sweeps this bot sent (spec §7C), complete or partial, **newest first**. Empty until
  /// one has been heard — and it never is until somebody on the channel taps for it.
  ///
  /// More than one since revision 10, because a scoped sweep of Texas and a national sweep from
  /// an hour ago are two different answers and the map wants both: Texas from the newer one, the
  /// rest of the country from the older. `WeatherStateReducer.retained(_:)` is what keeps the
  /// list from growing — a national sweep drops everything older than it, a scoped one drops
  /// older scoped sweeps it fully contains, and ``areaSweepLimit`` is the ceiling.
  public var areaSweeps: [WeatherAreaSweepAssembly]
  /// The radar tiles this bot sent (spec revision 11, §7D), **newest `taken` first**. Empty until
  /// somebody on the channel asks for one: revision 11 is request-only, and nothing is ever
  /// broadcast on a schedule.
  ///
  /// One entry per square of earth, whatever the zoom: a zoom 1 tile of the same centre is a
  /// different square and gets a row of its own, which is what lets the radar screen's width
  /// control show what is held for each width.
  public var radarTiles: [WeatherStoredRadarTile]

  /// The most sweeps kept per bot. Eight because the picker offers fifteen states at a time and
  /// a handful of selections plus the last national sweep is what a map is built out of; past
  /// that the oldest is not on screen anywhere.
  public static let areaSweepLimit = 8
  /// The most radar tiles kept per bot (spec revision 11, design §2 "State"). Twelve is three
  /// widths of four places, which is more than a pager of saved places ever has open at once; past
  /// that the oldest picture is on no screen anywhere.
  public static let radarTileLimit = 12
  /// How far behind the bot's own clock a held tile may be. Three hours is well past the two the
  /// screens will draw one for (``WeatherRadarPick``): this is the rule that keeps the file from
  /// growing, not the rule that decides what is shown.
  public static let radarTileRetentionMinutes: UInt32 = 3 * 60
  /// The most coordinate-keyed forecasts kept per bot.
  public static let unbundledForecastLimit = 12
  /// The ``unbundledForecasts`` key for an answer this phone did not ask for. Not a coordinate,
  /// and deliberately not one: nothing may take it for a place's forecast.
  public static let unbundledAskKey = "?"

  public init(botID: UInt16) {
    self.botID = botID
    lastSeq = nil
    recentMessages = []
    lastHeardAt = nil
    lastLiveHeardAt = nil
    needsDigest = false
    gapDetectedAt = nil
    warnings = [:]
    pendingUpgrades = [:]
    recentCancels = [:]
    digest = nil
    missingFromDigest = []
    observations = [:]
    forecasts = [:]
    unbundledForecasts = [:]
    texts = [:]
    coverage = nil
    areaSweeps = []
    radarTiles = []
  }

  private enum CodingKeys: String, CodingKey {
    case botID, lastSeq, recentMessages, lastHeardAt, lastLiveHeardAt, needsDigest, gapDetectedAt, warnings,
      pendingUpgrades, recentCancels, digest, missingFromDigest, observations, forecasts,
      unbundledForecasts, texts, coverage, areaSweeps, radarTiles
  }

  private enum LegacyCodingKeys: String, CodingKey {
    /// The duplicate window before fingerprints: bare `seq` values.
    case recentSeqs
    /// The one sweep a phone held before revision 10 could hold several.
    case areaSweep
  }

  /// Fields added after the first release decode as absent rather than failing the whole file:
  /// a state file from before them is still the last picture the bot sent.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    botID = try container.decode(UInt16.self, forKey: .botID)
    lastSeq = try container.decodeIfPresent(UInt8.self, forKey: .lastSeq)
    if let seen = try container.decodeIfPresent([WeatherSeenMessage].self, forKey: .recentMessages) {
      recentMessages = seen
    } else {
      let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
      recentMessages = (try legacy.decodeIfPresent([UInt8].self, forKey: .recentSeqs) ?? [])
        .map { WeatherSeenMessage(seq: $0, fingerprint: nil) }
    }
    lastHeardAt = try container.decodeIfPresent(Date.self, forKey: .lastHeardAt)
    lastLiveHeardAt = try container.decodeIfPresent(Date.self, forKey: .lastLiveHeardAt)
    needsDigest = try container.decode(Bool.self, forKey: .needsDigest)
    gapDetectedAt = try container.decodeIfPresent(Date.self, forKey: .gapDetectedAt)
    warnings = try container.decode([MeshWXWarningIdentity: WeatherStoredWarning].self, forKey: .warnings)
    pendingUpgrades = try container.decodeIfPresent(
      [MeshWXWarningIdentity: WeatherPendingUpgrade].self, forKey: .pendingUpgrades) ?? [:]
    recentCancels = try container.decodeIfPresent([MeshWXWarningIdentity: Date].self, forKey: .recentCancels) ?? [:]
    digest = try container.decodeIfPresent(WeatherStoredDigest.self, forKey: .digest)
    missingFromDigest = try container.decode([MeshWXWarningIdentity].self, forKey: .missingFromDigest)
    observations = try container.decode([UInt16: WeatherStoredObservation].self, forKey: .observations)
    forecasts = try container.decode([UInt16: WeatherStoredForecast].self, forKey: .forecasts)
    // Revision 10, §1.3. A file written before it holds whatever `0xFFFF` was holding, which
    // stays where it is: this dictionary is the coordinate-keyed cache, and nothing was ever
    // asked for by coordinate before it existed.
    unbundledForecasts = try container.decodeIfPresent(
      [String: WeatherStoredForecast].self, forKey: .unbundledForecasts) ?? [:]
    texts = try container.decode([UInt8: WeatherTextAssembly].self, forKey: .texts)
    // A file written before the bot stated anything, or before the app could read it: absent is
    // "has not said", which falls back to the station footprint rather than failing the file.
    coverage = try container.decodeIfPresent(WeatherStoredCoverage.self, forKey: .coverage)
    // Revision 8, §7C, then revision 10's list of them. A file written before the app could read
    // a sweep decodes as having none, which is exactly right: nobody had asked for one. One
    // written between the two holds a single sweep under `areaSweep`, which was national — there
    // was no other kind — and is lifted into the list rather than thrown away, so the map a
    // phone had before the upgrade is the map it has after it.
    if let list = try container.decodeIfPresent([WeatherAreaSweepAssembly].self, forKey: .areaSweeps) {
      areaSweeps = list
    } else {
      let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
      areaSweeps = (try legacy.decodeIfPresent(WeatherAreaSweepAssembly.self, forKey: .areaSweep))
        .map { [$0] } ?? []
    }
    // Revision 11, §7D. Absent is empty, which is exactly right for a file written before radar:
    // nobody had asked for a tile, so there is nothing to lift.
    radarTiles = try container.decodeIfPresent([WeatherStoredRadarTile].self, forKey: .radarTiles) ?? []
  }

  /// The newest sweep held, whatever its scope. What a caller wants when it needs one sweep and
  /// not a map: the age line on a row, the packet-count estimate, the "has anybody asked?" check.
  /// The map itself reads all of them (``WeatherAlertMapPicture``).
  public var newestAreaSweep: WeatherAreaSweepAssembly? { areaSweeps.first }

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

  /// The newest reading held, by the time its station measured it (spec §6.1), if any.
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
