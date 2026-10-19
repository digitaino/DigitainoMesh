import Foundation
import MC1Services

// MARK: - Repeater row

/// The uplink state §3 prints beside a repeater: `hears you N dB`, `heard you`, or `—`.
public enum MapperRepeaterLink: Sendable, Equatable {
  /// The repeater answered a trace or discover and reported the SNR it received us at —
  /// §1's (b), the only evidence that comes with a number.
  case hearsYou(snr: Double, at: Date)
  /// Our own packet came back through it, so its first hop heard our radio — §1's (a).
  /// A fact without a number, which is why the TX layer fills those hexagons neutrally.
  case heardYou(at: Date)
  /// Neither. Not "it cannot hear us" — only "nothing here says it can".
  case none
}

/// One repeater this hexagon has evidence about, as the card lists it (§3).
///
/// Three kinds of evidence can put a repeater here, and any one of them is enough:
///
/// - **We measured it.** §1's "heard directly", applied at capture: a flood's last hop, a
///   path-less advert's sender, a probe replier, an echo's last hop. This is the only
///   evidence that fills the RX figures.
/// - **It reported hearing us** (§1 (b)) — a trace or discover reply carrying a `txSnr`.
/// - **An echo proves it heard us** (§1 (a)) — it was the first hop of a rebroadcast of our
///   own packet.
///
/// The last two used to mint nothing unless we had also measured the repeater ourselves,
/// which silently deleted precisely the interesting asymmetries: a repeater three hops down
/// a flood that cannot hear us but that we hear, and its inverse (Rafael, 2026-09-04). A
/// direct-routed packet still credits nobody, and a *middle* hop of a path still credits
/// nobody — those rules do not move.
public struct MapperRepeaterRow: Sendable, Equatable {
  /// Canonical uppercase hex, exactly as `NodeHexID.hex` spells it. **Not a name**: names
  /// are personal data and this module never sees them (§2.4/§6 F9); the app resolves them
  /// through `NodeIdentityResolver` when it draws the row.
  ///
  /// The *widest* hash this repeater was seen under in the cell — see
  /// ``MapperCellQueries/canonicalHexIDs(in:now:)`` for why a row can be credited under
  /// more than one width and which of them wins.
  public let hexID: String

  /// The narrower hashes folded into ``hexID``: the same repeater as this cell also saw it,
  /// through packets whose path carried fewer bytes. Sorted, and empty for the ordinary
  /// case where every row named the same width.
  ///
  /// Kept on the row rather than thrown away, because anything that goes back to the rows
  /// — the repeater detail's filter, an export — has to look for all of them or it will
  /// show a fraction of the evidence the row was built from (Rafael, 2026-09-05).
  public let aliasHexIDs: [String]

  /// The most recent evidence of any kind — what the row is sorted and aged by. Always
  /// present: a row exists because something happened, and this is when.
  public let lastEvidenceAt: Date

  /// When our radio last measured this repeater. **Nil means never**, which is a real state
  /// now: a repeater known only from a reply or an echo has no downlink reading at all.
  public let lastHeardAt: Date?

  /// The RX SNR of the most recent row that credited this repeater — the "now" of the
  /// card's `↓ now · best · avg`. Nil together with ``lastHeardAt``: there is no honest
  /// number to print for a repeater we have not measured, and printing 0 dB would invent one.
  public let rxLatest: Double?
  public let rxBest: Double?
  public let rxAverage: Double?
  /// Rows that fed the RX figures. Zero for a repeater we never measured.
  public let rxCount: Int
  /// The RSSI beside `rxLatest`, from the same row. Nil when that row carried none.
  public let rssiLatest: Int?

  /// The latest SNR this repeater *reported* for us, from a probe reply in this cell.
  public let hearsYouSnr: Double?
  public let hearsYouAt: Date?

  /// When our own packet last came back through this repeater as the first hop of an echo
  /// — proof it heard our radio, with no number attached.
  public let heardYouAt: Date?

  public init(
    hexID: String,
    aliasHexIDs: [String] = [],
    lastEvidenceAt: Date,
    lastHeardAt: Date? = nil,
    rxLatest: Double? = nil,
    rxBest: Double? = nil,
    rxAverage: Double? = nil,
    rxCount: Int = 0,
    rssiLatest: Int? = nil,
    hearsYouSnr: Double? = nil,
    hearsYouAt: Date? = nil,
    heardYouAt: Date? = nil
  ) {
    self.hexID = hexID
    self.aliasHexIDs = aliasHexIDs
    self.lastEvidenceAt = lastEvidenceAt
    self.lastHeardAt = lastHeardAt
    self.rxLatest = rxLatest
    self.rxBest = rxBest
    self.rxAverage = rxAverage
    self.rxCount = rxCount
    self.rssiLatest = rssiLatest
    self.hearsYouSnr = hearsYouSnr
    self.hearsYouAt = hearsYouAt
    self.heardYouAt = heardYouAt
  }

  /// The uplink state to print.
  ///
  /// Precedence is evidence *quality*, not recency: a reported number outranks an echo even
  /// when the echo is newer, because §1 says only a reply gives a number and printing
  /// `heard you` over `hears you 13 dB` would say less than we know.
  ///
  /// `now` bounds the evidence rather than ageing it out. §1 is explicit that nothing is
  /// hidden by age — the age is printed beside it — so an old reading still shows; what
  /// `now` excludes is evidence stamped after it, so a card drawn against a past instant
  /// (a ride replay, a test) cannot show a link that had not happened yet.
  public func link(at now: Date) -> MapperRepeaterLink {
    if let hearsYouSnr, let hearsYouAt, hearsYouAt <= now {
      return .hearsYou(snr: hearsYouSnr, at: hearsYouAt)
    }
    if let heardYouAt, heardYouAt <= now {
      return .heardYou(at: heardYouAt)
    }
    return .none
  }

  /// Whether the newest evidence about this repeater is outside §1's "now".
  ///
  /// Measured against ``lastEvidenceAt`` rather than ``lastHeardAt``, because a row can
  /// exist with nothing ever heard: a reply from two seconds ago is not stale merely
  /// because our radio has never measured the repeater that sent it.
  ///
  /// A presentation hint and nothing more: a stale row is still listed, with its age. The
  /// card never hides a repeater for being quiet — that would turn "we have not heard it
  /// lately" into "it is not there".
  public func isStale(at now: Date) -> Bool {
    now.timeIntervalSince(lastEvidenceAt) > MapperCellQueries.freshnessWindow
  }
}

// MARK: - Headline

/// The card's first line and the two layers' evidence for one hexagon (§3).
public struct MapperCellHeadline: Sendable, Equatable {
  /// Best SNR at which we heard any repeater directly here — the RX layer's colour (§1).
  public let rxBest: Double?
  /// When the most recent such reading landed.
  public let rxLatestAt: Date?
  /// Packets passively received here, whoever they credited — the card's "1,048 heard".
  public let heardCount: Int

  /// Best SNR any repeater reported for us here — the TX layer's colour.
  public let txBest: Double?
  /// How many reported readings that best is drawn from.
  public let txReadings: Int

  /// Some repeater heard our radio here, by reply or by echo. Without ``txBest`` this is
  /// the neutral "heard you" fill.
  public let hasHeardYou: Bool
  /// We probed here and nothing ever heard us — the "no reach" fill, and *not* the same
  /// as a hexagon we never probed.
  public let isUnreachedProbed: Bool

  public let probesSent: Int
  /// Replies received here. See ``MapperCellQueries/cellHeadline(in:now:)`` for why this
  /// is a count of replies rather than of attempts that were answered.
  public let probesAnswered: Int

  public init(
    rxBest: Double? = nil,
    rxLatestAt: Date? = nil,
    heardCount: Int = 0,
    txBest: Double? = nil,
    txReadings: Int = 0,
    hasHeardYou: Bool = false,
    isUnreachedProbed: Bool = false,
    probesSent: Int = 0,
    probesAnswered: Int = 0
  ) {
    self.rxBest = rxBest
    self.rxLatestAt = rxLatestAt
    self.heardCount = heardCount
    self.txBest = txBest
    self.txReadings = txReadings
    self.hasHeardYou = hasHeardYou
    self.isUnreachedProbed = isUnreachedProbed
    self.probesSent = probesSent
    self.probesAnswered = probesAnswered
  }
}

// MARK: - Reach

/// The card's reach line for one hexagon (§4), counted from stored sightings.
///
/// No distance: the farthest observer needs observer *positions*, which live in the app
/// beside CoreScope's node list. This module knows how many heard us, not where they were,
/// and inventing a coordinate column here to answer it would put third-party positions in
/// the one store that already keeps our own.
public struct MapperCellReach: Sendable, Equatable {
  /// Distinct observers, compared case-insensitively — the same node reported as `A1B2`
  /// and `a1b2` is one observer, not two.
  public let observerCount: Int
  /// Sighting rows in total: one observer hearing three of our packets counts three.
  public let sightingCount: Int
  /// How many of our transmissions from this hexagon anybody heard.
  public let packetCount: Int
  /// How many we sent from here — the honest denominator, including the ones nobody heard.
  public let sentCount: Int

  public init(observerCount: Int = 0, sightingCount: Int = 0, packetCount: Int = 0, sentCount: Int = 0) {
    self.observerCount = observerCount
    self.sightingCount = sightingCount
    self.packetCount = packetCount
    self.sentCount = sentCount
  }
}

// MARK: - Queries

/// Everything the card shows about one hexagon, computed from that hexagon's rows.
///
/// Pure functions over a fetched array rather than store methods, for three reasons: they
/// are the part of §3 that is worth testing exhaustively against fixed fixtures; the caller
/// already has to choose the window (the ride filter *is* the `since:` it fetched with,
/// §3); and one fetch feeds the headline, the repeater rows and the reach line instead of
/// three round trips through the actor.
///
/// Order-independent throughout. `fetchSamples(cellRaw:since:until:limit:)` returns newest
/// first, but a probe reply settles after the packets heard while waiting for it and an
/// echo can back-fill minutes late, so nothing here may assume the array is sorted.
public enum MapperCellQueries {
  /// §1's "now": ten minutes. Rafael, 2026-09-03.
  ///
  /// A freshness *hint*, never a filter — see ``MapperRepeaterRow/isStale(at:)``.
  public static let freshnessWindow: TimeInterval = 600

  /// Which hex id each hex id in these rows is credited under — every id present maps to
  /// something, itself when nothing folds it.
  ///
  /// MeshCore path hashes are 1, 2 or 3 bytes wide depending on the packet, so one repeater
  /// reaches this cell as `ABBA` on some rows and as its 1-byte prefix `AB` on others.
  /// Accumulating on the raw string mints a row for each, both of which the app then
  /// resolves to the same node — which is what the card printed on the 2026-09-05 ride as
  /// "Digitaino Central ABBA" and "Digitaino Central AB", read as two repeaters, and (via
  /// the card's colliding-names rule) had its hash suffixed to both to tell them apart.
  ///
  /// The fold is hex-only and guesses nothing. An id that is a proper prefix of **exactly
  /// one** longer id here is that same repeater seen at a narrower width, and folds into
  /// it; an id that prefixes several is genuinely ambiguous — the byte we have cannot say
  /// which — and stays its own row. CoreScope answers the same question by excluding 1-byte
  /// prefixes from attribution altogether; we keep them and show them, because a row we
  /// cannot merge is still evidence, and dropping it would be a bigger lie than listing it.
  ///
  /// A fold target can never itself fold — if `X` folded into `Y` and `Y` into `Z`, then
  /// `Z` would extend `X` too and `X` would have had two extensions — so the map needs no
  /// chain resolution: one lookup lands on the widest hash in the cell.
  ///
  /// Comparison is literal, not case-insensitive: both sides come from `NodeHexID.hex`,
  /// which is canonical uppercase, on the `repeaterHexID` column and inside `pathHashes`
  /// alike. (Unlike ``reach(in:sightings:)``, where the spelling comes off a server.)
  public static func canonicalHexIDs(in rows: [MapperRawSampleDTO], now: Date) -> [String: String] {
    var ids: Set<String> = []
    for row in rows where row.timestamp <= now {
      if let hexID = row.repeaterHexID { ids.insert(hexID) }
      // Every row's first hop, not only an echo's. Pass 3 keys on echo first hops, so they
      // have to be here — and the rest earn their place by making the fold *stricter*: a
      // 1-byte id that matches two wide ids this cell has seen stays ambiguous instead of
      // merging into whichever one happened to be credited with a reading.
      if let firstHop = row.pathHashes?.first { ids.insert(firstHop) }
    }

    var canonical: [String: String] = [:]
    canonical.reserveCapacity(ids.count)
    for id in ids {
      // Only a *longer* id can be this one seen wider; an equal-length id that differs is
      // a different repeater, and one that does not differ is this one.
      let wider = ids.filter { $0.count > id.count && $0.hasPrefix(id) }
      canonical[id] = wider.count == 1 ? (wider.first ?? id) : id
    }
    return canonical
  }

  /// One row per repeater this cell has evidence about, newest evidence first.
  ///
  /// Rows stamped after `now` are ignored, so the same fetch can be asked what the cell
  /// looked like at an earlier instant; with `now` in the present that is every row.
  ///
  /// **Each of the three passes can mint a row.** A reply that reported an SNR for us, and
  /// an echo whose first hop proves somebody heard us, are evidence in their own right; they
  /// used to be folded only into repeaters pass 1 had already found, which meant the one
  /// case the card exists to show — a repeater we can hear but that cannot hear us, and its
  /// inverse — was silently dropped whenever only one leg had been measured (Rafael,
  /// 2026-09-04). What still mints nothing: a direct-routed packet (it credits nobody at
  /// capture, so no row here names it) and a *middle* hop of a path, which is somebody
  /// else's measurement.
  ///
  /// **All three fold through ``canonicalHexIDs(in:now:)``**, so a repeater that reached
  /// this cell under two hash widths is one accumulator and one row, with the narrower
  /// hashes recorded in ``MapperRepeaterRow/aliasHexIDs``. Folding in only one pass would
  /// be worse than not folding at all: the row would carry the downlink of the wide hash
  /// and the uplink of the narrow one and look like a complete link that nothing measured.
  public static func repeaterRows(in rows: [MapperRawSampleDTO], now: Date) -> [MapperRepeaterRow] {
    let canonical = canonicalHexIDs(in: rows, now: now)
    var accumulators: [String: Accumulator] = [:]

    // Pass 1 — the rows that credit a repeater with our own measurement of it.
    for row in rows where row.timestamp <= now {
      guard let hexID = row.repeaterHexID, let rxSnr = row.rxSnr else { continue }
      accumulators[canonical[hexID] ?? hexID, default: Accumulator()]
        .foldRx(at: row.timestamp, rxSnr: rxSnr, rssi: row.rssi)
    }

    // Pass 2 — what repeaters reported about us. Only a trace or discover reply carries a
    // number (§1 (b)); an echo's SNR is our reading of the rebroadcast, and folding it here
    // would invent an uplink measurement.
    for row in rows where row.timestamp <= now {
      guard let kind = row.kind, kind == .probeTraceReply || kind == .probeDiscoverResponse else { continue }
      guard let hexID = row.repeaterHexID, let txSnr = row.txSnr else { continue }
      accumulators[canonical[hexID] ?? hexID, default: Accumulator()]
        .foldHearsYou(at: row.timestamp, snr: txSnr)
    }

    // Pass 3 — echoes. The *first* hop of an echo is the node that heard our radio (§1's
    // three-hops case); the last hop is the one we heard, and it is already in pass 1 via
    // the row's own credit.
    for row in rows where row.timestamp <= now {
      guard row.kind == .txHeard, let firstHop = row.pathHashes?.first else { continue }
      accumulators[canonical[firstHop] ?? firstHop, default: Accumulator()]
        .foldHeardYou(at: row.timestamp)
    }

    var aliases: [String: [String]] = [:]
    for (id, target) in canonical where id != target {
      aliases[target, default: []].append(id)
    }

    return accumulators
      .compactMap { hexID, accumulator in
        accumulator.row(hexID: hexID, aliasHexIDs: aliases[hexID]?.sorted() ?? [])
      }
      .sorted { lhs, rhs in
        if lhs.lastEvidenceAt != rhs.lastEvidenceAt { return lhs.lastEvidenceAt > rhs.lastEvidenceAt }
        return lhs.hexID < rhs.hexID
      }
  }

  /// The cell's headline and both layers' evidence.
  ///
  /// **`probesAnswered` counts reply rows, not answered attempts.** A `probeAttempt` row
  /// carries the target and the placement but no probe tag — the tag is the engine's
  /// in-memory correlation key and §2's column list deliberately does not persist it — so
  /// two attempts to the same repeater inside one reply window are indistinguishable from
  /// the rows alone. Counting replies is the honest reading of what the rows say: a reply
  /// is placed in the cell the probe was *sent* from (the engine folds it against the
  /// send-time placement), so "answers that came back to a probe sent from here" is exactly
  /// this count. One consequence to know: a broadcast discover is one attempt that several
  /// repeaters may answer, so `probesAnswered` can legitimately exceed `probesSent`.
  public static func cellHeadline(in rows: [MapperRawSampleDTO], now: Date) -> MapperCellHeadline {
    var rxBest: Double?
    var rxLatestAt: Date?
    var heardCount = 0
    var txBest: Double?
    var txReadings = 0
    var echoCount = 0
    var probesSent = 0
    var probesAnswered = 0

    for row in rows where row.timestamp <= now {
      if let rxSnr = row.rxSnr, row.repeaterHexID != nil {
        rxBest = rxBest.map { Swift.max($0, rxSnr) } ?? rxSnr
        rxLatestAt = rxLatestAt.map { Swift.max($0, row.timestamp) } ?? row.timestamp
      }
      switch row.kind {
      case .probeTraceReply, .probeDiscoverResponse:
        probesAnswered += 1
        if let txSnr = row.txSnr {
          txBest = txBest.map { Swift.max($0, txSnr) } ?? txSnr
          txReadings += 1
        }
      case .txHeard:
        echoCount += 1
      case .probeAttempt:
        probesSent += 1
      case .passiveRx:
        heardCount += 1
      default:
        break
      }
    }

    let hasHeardYou = echoCount > 0 || txReadings > 0
    return MapperCellHeadline(
      rxBest: rxBest,
      rxLatestAt: rxLatestAt,
      heardCount: heardCount,
      txBest: txBest,
      txReadings: txReadings,
      hasHeardYou: hasHeardYou,
      isUnreachedProbed: probesSent > 0 && !hasHeardYou,
      probesSent: probesSent,
      probesAnswered: probesAnswered
    )
  }

  /// How far our packets from this hexagon got, counted from the sightings already fetched.
  ///
  /// `rows` is the cell's own fetch — only its `sent` rows are read — and `sightings` is
  /// what `fetchObserverSightings(contentHashes:)` returned for those rows' hashes. Hashes
  /// are matched case-insensitively for the same reason observer ids are: both come back
  /// from a server whose spelling we do not control, and hex is hex.
  ///
  /// A `sent` row with no hash yet (the echo has not revealed it — §2) counts toward
  /// ``MapperCellReach/sentCount`` and never toward ``MapperCellReach/packetCount``: we
  /// cannot ask about a packet we cannot name, and calling that "nobody heard it" would be
  /// a lie about the mesh rather than about our own bookkeeping.
  public static func reach(in rows: [MapperRawSampleDTO], sightings: [MapperRawSampleDTO]) -> MapperCellReach {
    var observers: Set<String> = []
    var heardHashes: Set<String> = []
    var sightingCount = 0

    for sighting in sightings where sighting.kind == .observerSighting {
      sightingCount += 1
      if let observer = sighting.repeaterHexID {
        observers.insert(observer.lowercased())
      }
      if let hash = sighting.contentHash {
        heardHashes.insert(hash.lowercased())
      }
    }

    var sentCount = 0
    var packetCount = 0
    for row in rows where row.kind == .sent {
      sentCount += 1
      if let hash = row.contentHash, heardHashes.contains(hash.lowercased()) {
        packetCount += 1
      }
    }

    return MapperCellReach(
      observerCount: observers.count,
      sightingCount: sightingCount,
      packetCount: packetCount,
      sentCount: sentCount
    )
  }

  // MARK: - Internals

  /// One repeater's tally while the passes run. A value type: the three passes each hand
  /// back a whole accumulator rather than mutating a shared object, so a row can only
  /// affect the repeater it names.
  private struct Accumulator {
    var lastHeardAt: Date?
    var rxLatest: Double = 0
    var rssiLatest: Int?
    var rxBest: Double?
    var rxSum: Double = 0
    var rxCount = 0
    var hearsYouSnr: Double?
    var hearsYouAt: Date?
    var heardYouAt: Date?

    mutating func foldRx(at timestamp: Date, rxSnr: Double, rssi: Int?) {
      rxSum += rxSnr
      rxCount += 1
      rxBest = rxBest.map { Swift.max($0, rxSnr) } ?? rxSnr
      // "Latest" is decided by timestamp, not by arrival: rows are not fetched in the order
      // they happened, and `>` here is what makes the pass order-independent. Ties keep the
      // first reading seen, which is the only choice that does not depend on the fetch.
      guard lastHeardAt.map({ timestamp > $0 }) ?? true else { return }
      lastHeardAt = timestamp
      rxLatest = rxSnr
      rssiLatest = rssi
    }

    mutating func foldHearsYou(at timestamp: Date, snr: Double) {
      guard hearsYouAt.map({ timestamp > $0 }) ?? true else { return }
      hearsYouAt = timestamp
      hearsYouSnr = snr
    }

    mutating func foldHeardYou(at timestamp: Date) {
      heardYouAt = heardYouAt.map { Swift.max($0, timestamp) } ?? timestamp
    }

    /// A row whenever any one of the three kinds of evidence landed, and nil when none did
    /// — an accumulator that only ever received a `nil`-`txSnr` reply, say.
    func row(hexID: String, aliasHexIDs: [String]) -> MapperRepeaterRow? {
      let evidence = [lastHeardAt, hearsYouAt, heardYouAt].compactMap { $0 }
      guard let lastEvidenceAt = evidence.max() else { return nil }
      let hasRx = lastHeardAt != nil && rxCount > 0
      return MapperRepeaterRow(
        hexID: hexID,
        aliasHexIDs: aliasHexIDs,
        lastEvidenceAt: lastEvidenceAt,
        lastHeardAt: lastHeardAt,
        rxLatest: hasRx ? rxLatest : nil,
        rxBest: hasRx ? rxBest : nil,
        rxAverage: hasRx ? rxSum / Double(rxCount) : nil,
        rxCount: rxCount,
        rssiLatest: rssiLatest,
        hearsYouSnr: hearsYouSnr,
        hearsYouAt: hearsYouAt,
        heardYouAt: heardYouAt
      )
    }
  }
}
