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

  /// Every alert held by any bot, deduplicated by identity (the freshest message wins),
  /// placed against the place and sorted: here, then checking/unplaced, then near, then
  /// elsewhere; within each, by priority and then soonest expiry. With no place, placement is
  /// `.elsewhere` for everything — the card lists them without claiming any is here.
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

    func offer(_ stored: WeatherStoredWarning, kind: WeatherAlertItem.Kind, botID: UInt16) {
      if var held = candidates[stored.identity] {
        held.botIDs.insert(botID)
        if stored.receivedAt > held.stored.receivedAt {
          held.stored = stored
          held.kind = kind
        }
        candidates[stored.identity] = held
      } else {
        candidates[stored.identity] = Candidate(stored: stored, kind: kind, botIDs: [botID])
      }
    }

    for (botID, state) in states {
      for stored in state.warnings.values {
        if !stored.isExpired(at: now) {
          offer(stored, kind: .active, botID: botID)
        } else if now.timeIntervalSince(stored.expiresAt) <= expiredHold {
          offer(stored, kind: .expiredRecently, botID: botID)
        }
      }
      for (identity, pending) in state.pendingUpgrades where candidates[identity] == nil {
        let stored = WeatherStoredWarning(warning: pending.warning, receivedAt: pending.cancelledAt)
        offer(stored, kind: .upgradedAwaitingReplacement(cancelledAt: pending.cancelledAt), botID: botID)
      }
    }

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
      if lhs.placement.sortOrder != rhs.placement.sortOrder { return lhs.placement.sortOrder < rhs.placement.sortOrder }
      if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
      if lhs.expiresAt != rhs.expiresAt { return lhs.expiresAt < rhs.expiresAt }
      return lhs.identity.etn < rhs.identity.etn
    }
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
