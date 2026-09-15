import Foundation
import MeshWX

// MARK: - Placement

/// Where an alert sits relative to the place (docs/MESHWX_UI.md §7.1).
public enum WeatherAlertPlacement: Sendable, Hashable {
  /// Its polygon or one of its areas contains the place or passes within the place's
  /// uncertainty.
  case here
  /// Within 50 km; the direction is from the place towards the alert.
  case near(kilometres: Double, direction: MeshWXCompass)
  /// It names areas and the outlines are still loading.
  case checking
  /// Nothing to measure against: no polygon and no outline for an area that could be close.
  /// Never read as "not here".
  case unplaced
  case elsewhere

  public static let nearKilometres = 50.0
  /// An area the bundle has no outline for counts as possibly-here when its centroid is this
  /// close, or when it has no centroid either.
  static let unoutlinedReachKilometres = 150.0

  /// Whether the alert is a row on the card rather than a count in the footer.
  public var isCardRow: Bool {
    switch self {
    case .here, .near, .checking, .unplaced: true
    case .elsewhere: false
    }
  }

  /// The order among alerts of the same priority below *here*: an alert that may be here
  /// before one known to be near, before one known to be elsewhere.
  var sortOrder: Int {
    switch self {
    case .here: 0
    case .checking, .unplaced: 1
    case .near: 2
    case .elsewhere: 3
    }
  }

  public static func place(
    _ warning: MeshWXWarning,
    at place: WeatherPlace,
    geometry: any WeatherAreaGeometry,
    tables: MeshWXTables
  ) -> WeatherAlertPlacement {
    let point = place.coordinate
    let radius = place.uncertaintyKilometres

    if let polygon = warning.polygon, polygon.count >= 3 {
      // Storm-based products: the polygon is the warning; the county list is only what lies
      // under it.
      let distance = MeshWXGeometry.distanceKilometres(from: point, to: polygon)
      return classify(distance: distance, radius: radius, from: point, towards: WeatherGeo.centre(of: polygon))
    }

    let areas = tables.namedAreas(for: warning)
    guard !areas.isEmpty else { return .unplaced }
    guard geometry.isLoaded else { return .checking }

    var nearest: (distance: Double, ugc: String)?
    var unoutlinedWithinReach = false
    for area in areas {
      if let distance = geometry.distanceKilometres(from: point, toArea: area.ugc) {
        if nearest.map({ distance < $0.distance }) ?? true { nearest = (distance, area.ugc) }
      } else if let lat = area.lat, let lon = area.lon {
        let centroid = MeshWXCoordinate(latitude: lat, longitude: lon)
        if WeatherGeo.kilometres(point, centroid) <= unoutlinedReachKilometres { unoutlinedWithinReach = true }
      } else {
        unoutlinedWithinReach = true
      }
    }
    if let nearest, nearest.distance <= radius { return .here }
    if unoutlinedWithinReach { return .unplaced }
    guard let nearest else { return .unplaced }
    return classify(distance: nearest.distance, radius: radius, from: point, towards: geometry.centre(ofArea: nearest.ugc))
  }

  static func classify(
    distance: Double,
    radius: Double,
    from point: MeshWXCoordinate,
    towards target: MeshWXCoordinate?
  ) -> WeatherAlertPlacement {
    if distance <= radius { return .here }
    if distance <= nearKilometres {
      return .near(kilometres: distance, direction: target.map { WeatherGeo.direction(from: point, to: $0) } ?? .north)
    }
    return .elsewhere
  }
}

// MARK: - Priority

/// The fixed order alerts are listed in (docs/MESHWX_UI.md §7.2). Severity from the
/// significance letter alone would put a tornado warning behind a flood advisory that expires
/// sooner.
public enum WeatherAlertPriority {
  /// Lower is more urgent.
  public static func rank(_ warning: MeshWXWarning, tables: MeshWXTables) -> Int {
    let vtec = tables.vtec(for: warning.event) ?? ""
    switch vtec {
    case "TO.W": return 0
    case "EW.W": return 1
    case "FF.W" where warning.floodDamage == .catastrophic: return 2
    case "SV.W" where warning.tornado != .none: return 3
    case "FF.W": return 4
    case "SV.W": return 5
    default:
      switch MeshWXSeverity(vtec: vtec) {
      case .warning: return 6
      case .watch: return 7
      case .advisory: return 8
      case .statement: return 9
      case nil: return 10
      }
    }
  }

  public static func isTornadoWarning(_ warning: MeshWXWarning, tables: MeshWXTables) -> Bool {
    tables.vtec(for: warning.event) == "TO.W"
  }
}

// MARK: - Items

/// One alert as the screen lists it: the union across bots, placed and ranked.
public struct WeatherAlertItem: Sendable, Hashable, Identifiable {
  public enum Kind: Sendable, Hashable {
    case active
    /// Cancelled as upgraded; the replacement has not been received.
    case upgradedAwaitingReplacement(cancelledAt: Date)
    /// Covered the place and passed its expiry in the last 15 minutes with no update: kept,
    /// because a phone clock ahead of the bot's would otherwise end it early.
    case expiredRecently
  }

  public var identity: MeshWXWarningIdentity
  public var warning: MeshWXWarning
  public var kind: Kind
  public var placement: WeatherAlertPlacement
  public var rank: Int
  public var botIDs: [UInt16]
  public var receivedAt: Date

  public var id: MeshWXWarningIdentity { identity }
  public var expiresAt: Date { Date(unixMinutes: warning.expiresMinutes) }
}

public enum WeatherAlertItems {
  public static let expiredHold: TimeInterval = 15 * 60

  /// Every alert held by any bot, one item per identity, placed against the place and sorted.
  ///
  /// Two bots can hold different copies of one warning (spec §12). The copy shown is the one
  /// still active over one that has expired — a bot that heard the extension beats one that
  /// did not — then the one with the later expiry. An upgrade marker stands in only when no bot
  /// holds a copy of the warning at all.
  ///
  /// Order: anything *here* first, then by priority whatever the placement — a Tornado Warning
  /// 20 km away above a Heat Advisory whose outlines are still loading — then checking/unplaced
  /// before near before elsewhere, then the soonest expiry. A covering alert that just expired
  /// comes last: it is a note about what ended, not something to act on.
  ///
  /// With no place, placement is `.elsewhere` for everything — the card lists them without
  /// claiming any is here.
  public static func make(
    states: [UInt16: WeatherBotState],
    place: WeatherPlace?,
    geometry: any WeatherAreaGeometry,
    tables: MeshWXTables,
    now: Date
  ) -> [WeatherAlertItem] {
    struct Candidate {
      var stored: WeatherStoredWarning
      var kind: WeatherAlertItem.Kind
      var botIDs: Set<UInt16>
    }
    var candidates: [MeshWXWarningIdentity: Candidate] = [:]
    // Bot order fixed, so which copy wins a full tie does not depend on dictionary order.
    let botIDs = states.keys.sorted()

    for botID in botIDs {
      guard let state = states[botID] else { continue }
      for stored in state.warnings.values {
        let kind: WeatherAlertItem.Kind
        if !stored.isExpired(at: now) {
          kind = .active
        } else if now.timeIntervalSince(stored.expiresAt) <= expiredHold {
          kind = .expiredRecently
        } else {
          continue
        }
        guard var held = candidates[stored.identity] else {
          candidates[stored.identity] = Candidate(stored: stored, kind: kind, botIDs: [botID])
          continue
        }
        held.botIDs.insert(botID)
        if prefers(stored, kind, over: held.stored, held.kind) {
          held.stored = stored
          held.kind = kind
        }
        candidates[stored.identity] = held
      }
    }

    var markers: [MeshWXWarningIdentity: Candidate] = [:]
    for botID in botIDs {
      guard let state = states[botID] else { continue }
      for (identity, pending) in state.pendingUpgrades where candidates[identity] == nil {
        let stored = WeatherStoredWarning(warning: pending.warning, receivedAt: pending.cancelledAt)
        let kind = WeatherAlertItem.Kind.upgradedAwaitingReplacement(cancelledAt: pending.cancelledAt)
        guard var held = markers[identity] else {
          markers[identity] = Candidate(stored: stored, kind: kind, botIDs: [botID])
          continue
        }
        held.botIDs.insert(botID)
        if pending.cancelledAt > held.stored.receivedAt {
          held.stored = stored
          held.kind = kind
        }
        markers[identity] = held
      }
    }
    candidates.merge(markers) { warning, _ in warning }

    let items: [WeatherAlertItem] = candidates.values.compactMap { candidate in
      let placement = place.map {
        WeatherAlertPlacement.place(candidate.stored.warning, at: $0, geometry: geometry, tables: tables)
      } ?? .elsewhere
      // An expired alert is only worth a row where it mattered.
      if candidate.kind == .expiredRecently, placement != .here { return nil }
      return WeatherAlertItem(
        identity: candidate.stored.identity,
        warning: candidate.stored.warning,
        kind: candidate.kind,
        placement: placement,
        rank: WeatherAlertPriority.rank(candidate.stored.warning, tables: tables),
        botIDs: candidate.botIDs.sorted(),
        receivedAt: candidate.stored.receivedAt
      )
    }
    return items.sorted { lhs, rhs in
      let lhsExpired = lhs.kind == .expiredRecently
      let rhsExpired = rhs.kind == .expiredRecently
      if lhsExpired != rhsExpired { return rhsExpired }
      let lhsHere = lhs.placement == .here
      let rhsHere = rhs.placement == .here
      if lhsHere != rhsHere { return lhsHere }
      if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
      if lhs.placement.sortOrder != rhs.placement.sortOrder { return lhs.placement.sortOrder < rhs.placement.sortOrder }
      if lhs.expiresAt != rhs.expiresAt { return lhs.expiresAt < rhs.expiresAt }
      if lhs.identity.etn != rhs.identity.etn { return lhs.identity.etn < rhs.identity.etn }
      return WeatherStateReducer.identityOrder(lhs.identity, rhs.identity)
    }
  }

  /// Whether one bot's copy of a warning should be shown over another's: active over expired,
  /// then the later expiry, then the later message.
  private static func prefers(
    _ stored: WeatherStoredWarning, _ kind: WeatherAlertItem.Kind,
    over held: WeatherStoredWarning, _ heldKind: WeatherAlertItem.Kind
  ) -> Bool {
    let isActive = kind == .active
    let heldIsActive = heldKind == .active
    if isActive != heldIsActive { return isActive }
    if stored.warning.expiresMinutes != held.warning.expiresMinutes {
      return stored.warning.expiresMinutes > held.warning.expiresMinutes
    }
    return stored.receivedAt > held.receivedAt
  }
}

// MARK: - Folding

/// The alerts card's rows (docs/MESHWX_UI.md §7.3): at most `limit`, plus "N more".
///
/// The dangerous ones are never folded, wherever they are: the six storm warnings at the top of
/// the priority order (`WeatherAlertPriority.rank` 0–5), and an upgrade whose replacement has
/// not arrived — the replacement is worse than what it replaced, and this row is all the phone
/// has of it. Only other items past the limit fold. Order is kept.
public enum WeatherAlertFolding {
  /// Tornado, Extreme Wind, catastrophic Flash Flood, tornado-tagged Severe Thunderstorm, Flash
  /// Flood and Severe Thunderstorm Warnings.
  public static let neverFoldedRank = 5

  public static func fold(
    _ items: [WeatherAlertItem],
    limit: Int = 2,
    tables: MeshWXTables
  ) -> (rows: [WeatherAlertItem], folded: Int) {
    let rows = items.enumerated().compactMap { offset, item -> WeatherAlertItem? in
      offset < limit || isNeverFolded(item, tables: tables) ? item : nil
    }
    return (rows, items.count - rows.count)
  }

  public static func isNeverFolded(_ item: WeatherAlertItem, tables: MeshWXTables) -> Bool {
    if case .upgradedAwaitingReplacement = item.kind { return true }
    return WeatherAlertPriority.rank(item.warning, tables: tables) <= neverFoldedRank
  }
}

// MARK: - Status line

/// The one line that says what the alerts card can and cannot claim (docs/MESHWX_UI.md §7.4).
/// Evaluated top to bottom; the first condition that holds wins.
public enum WeatherAlertStatus: Sendable, Hashable {
  case noPlace
  case outOfCoverage
  /// No alert list from any bot covering the place.
  case notChecked
  case feedStale(minutesSinceProduct: Int)
  case radioOffline(listAsOf: Date)
  case missedMessages
  case listOld(asOf: Date)
  case locationOld(since: Date)
  /// No bot has sent a multi-station observation batch in the last day, so where any bot
  /// reports is unknown: the list that arrived may be for somewhere else entirely, and "no
  /// alerts" cannot be claimed from it.
  case coverageUnknown
  case officeMayNotBeCovered(office: String)
  /// Alerts here, near, still being placed, or unplaceable: the rows say it.
  case rowsSpeak
  case noneHere(elsewhere: Int, asOf: Date)
  /// The green check: no alert received, and this phone would have received one.
  case clear(asOf: Date)

  /// Three hours between scheduled lists, plus a quarter of an hour for a late broadcast.
  public static let listFreshFor: TimeInterval = 3 * 60 * 60 + 15 * 60

  public static func evaluate(
    place: WeatherPlace?,
    coverage: WeatherCoverage,
    states: [UInt16: WeatherBotState],
    items: [WeatherAlertItem],
    isRadioConnected: Bool,
    sessionStartedAt: Date?,
    tables: MeshWXTables,
    now: Date
  ) -> WeatherAlertStatus {
    guard let place else { return .noPlace }
    if !coverage.isEmpty, !coverage.contains(place.coordinate) { return .outOfCoverage }

    // With no footprint yet every bot's list is considered, which is enough to say what is
    // wrong with the list — but never enough for calm (`coverageUnknown` below).
    let covering = coverage.botIDs(covering: place.coordinate)
    let relevant = states.filter { covering.isEmpty || covering.contains($0.key) }.map(\.value)
    let withDigest = relevant.compactMap { state in state.digest.map { (state, $0) } }
    guard let (_, digest) = withDigest.max(by: { $0.1.builtAt < $1.1.builtAt }) else { return .notChecked }

    if digest.isFeedStale {
      return .feedStale(minutesSinceProduct: MeshWXPresentation.feedHealthMinutes(digest.digest.feedHealth))
    }
    if !isRadioConnected { return .radioOffline(listAsOf: digest.builtAt) }
    if relevant.contains(where: { $0.needsDigest || !$0.missingFromDigest.isEmpty || !$0.pendingUpgrades.isEmpty }) {
      return .missedMessages
    }
    let listedBeforeSession = sessionStartedAt.map { digest.receivedAt < $0 } ?? true
    if now.timeIntervalSince(digest.builtAt) > listFreshFor || listedBeforeSession {
      return .listOld(asOf: digest.builtAt)
    }
    if place.kind == .lastKnown, let locatedAt = place.locatedAt { return .locationOld(since: locatedAt) }
    if coverage.isEmpty { return .coverageUnknown }

    let officesShown = Set(relevant.flatMap { state in
      state.warnings.values.map(\.warning.office) + (state.digest?.digest.entries.map(\.identity.office) ?? [])
    }.compactMap { tables.officeCode($0) })
    if !officesShown.isEmpty,
       let placeOffice = tables.nearestPoint(toLat: place.coordinate.latitude, lon: place.coordinate.longitude)?.office,
       !officesShown.contains(placeOffice) {
      return .officeMayNotBeCovered(office: placeOffice)
    }

    if items.contains(where: { $0.placement.isCardRow }) { return .rowsSpeak }
    let elsewhere = items.filter { $0.placement == .elsewhere }.count
    if elsewhere > 0 { return .noneHere(elsewhere: elsewhere, asOf: digest.builtAt) }
    return .clear(asOf: digest.builtAt)
  }
}
