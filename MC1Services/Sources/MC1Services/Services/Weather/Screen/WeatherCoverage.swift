import Foundation
import MeshWX

/// What a coverage test needs from the bundled outlines: the areas a *place* is in.
///
/// `WeatherAreaGeometry` answers the other way round — how far one named area is from a place —
/// which is what the alerts card asks. Reading a bot's own statement asks this way: the statement
/// names zones, and the question is whether the place is in one of them.
public protocol WeatherPlaceAreas: Sendable {
  /// False while the GeoJSON is still parsing. A place has no UGCs then, which is "unknown".
  var isLoaded: Bool { get }
  /// Every county and zone whose outline contains the point or passes within `radius` of it.
  func areaCodes(near point: MeshWXCoordinate, withinKilometres radius: Double) -> [String]
}

extension MeshWXGeometry: WeatherPlaceAreas {}

/// What the evidence says about a place and a bot's area.
public enum WeatherCoverageVerdict: Sendable, Hashable {
  case inside
  /// The only verdict that may be read as "outside": a bot's own complete statement, or — with
  /// nothing stated — its station footprint.
  case outside
  /// Nothing said yet, a list the bot had to cut, or outlines that have not loaded. A cut list
  /// means "not listed", never "not covered" (spec §7A), and unknown is where that lands.
  case unknown
}

/// Whether a place is in a bot's area, and from what evidence.
///
/// First the bot's own statement (Coverage, spec §7A): its circle and the zones it lists. That is
/// the only thing that describes coverage, and the reason the message exists — guessing from the
/// hourly stations and from the offices of whatever warnings were active told a real phone that
/// WX-AUS "may not carry alerts for Travis County", the bot's own home county
/// (docs/MESHWX_UI.md §3.1 I-B18).
///
/// Failing a statement, the footprint the bot has demonstrated: the stations in its scheduled
/// batches (docs/MESHWX_UI.md §6). A batch of one station is the answer to somebody's
/// single-station request — a `>o KJFK` would otherwise put Manhattan "in coverage" — so only
/// multi-station batches count, and only from the last 24 hours on the bot's clock. A station's
/// last scheduled batch is remembered on the reading (`WeatherStoredObservation.lastBatchMinutes`),
/// so a single-station answer that replaces the reading does not also take the station out of the
/// footprint.
///
/// A place is in that footprint when it is inside the convex hull of the bot's stations, or within
/// `stationReachKilometres` of one of them. The bot relays alerts for about 120 km around its home
/// but reports only the nearest reporting stations inside that circle, the farthest about 96 km
/// out for WX-AUS. A fixed reach around every station therefore ran well past the alert area, and a
/// place there could read "No alerts received" under warnings the bot never sends. The hull stays
/// inside the area: a place between its edge and the area's is called out of coverage, which is
/// the side to err on.
///
/// Either way, "outside" needs evidence. A statement whose lists were cut, a place the outlines
/// cannot place, and a bot that has said nothing and reported nothing are all ``unknown``.
public struct WeatherCoverage: Sendable, Hashable {
  public struct Station: Sendable, Hashable {
    public var index: UInt16
    public var station: MeshWXStation
    public var botID: UInt16

    public var coordinate: MeshWXCoordinate {
      MeshWXCoordinate(latitude: station.lat, longitude: station.lon)
    }
  }

  /// One bot's own statement of its area (spec §7A), and when it arrived.
  public struct Stated: Sendable, Hashable {
    public var botID: UInt16
    public var coverage: MeshWXCoverage
    public var receivedAt: Date

    public init(botID: UInt16, coverage: MeshWXCoverage, receivedAt: Date) {
      self.botID = botID
      self.coverage = coverage
      self.receivedAt = receivedAt
    }
  }

  /// One entry per bot and station: a station two bots report is in both footprints.
  public var stations: [Station]
  /// The newest statement from each bot that has made one. A bot in here is answered for from
  /// what it said; its stations then feed the Now card only, never the area test.
  public var stated: [UInt16: Stated]
  /// The tables the wire's state and office indices are read against, and the outlines a place is
  /// resolved to UGCs with. Neither is part of the value — two coverages with the same stations
  /// and the same statements are the same coverage whichever bundle read them — so both sit
  /// outside `==` and `hash(into:)`.
  public var tables: MeshWXTables
  public var areas: any WeatherPlaceAreas

  public static let footprintWindow: TimeInterval = 24 * 60 * 60
  /// A place this close to a footprint station is in that bot's coverage, inside the hull or not:
  /// just past an outer station, or near a bot with one or two stations, which has no hull.
  public static let stationReachKilometres = 20.0

  public init(
    stations: [Station],
    stated: [UInt16: Stated] = [:],
    tables: MeshWXTables = .shared,
    areas: any WeatherPlaceAreas = MeshWXGeometry.shared
  ) {
    self.stations = stations
    self.stated = stated
    self.tables = tables
    self.areas = areas
  }

  public static func == (lhs: WeatherCoverage, rhs: WeatherCoverage) -> Bool {
    lhs.stations == rhs.stations && lhs.stated == rhs.stated
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(stations)
    hasher.combine(stated)
  }

  public static func make(
    states: [UInt16: WeatherBotState],
    tables: MeshWXTables,
    now: Date,
    areas: any WeatherPlaceAreas = MeshWXGeometry.shared
  ) -> WeatherCoverage {
    var stations: [Station] = []
    var stated: [UInt16: Stated] = [:]
    for (botID, state) in states {
      // A statement does not go stale the way a batch does: it describes the bot, not an hour.
      if let held = state.coverage {
        stated[botID] = Stated(botID: botID, coverage: held.coverage, receivedAt: held.receivedAt)
      }
      for (index, stored) in state.observations
      where stored.lastBatchAt.map({ now.timeIntervalSince($0) <= footprintWindow }) ?? false {
        guard let station = tables.station(at: index) else { continue }
        stations.append(Station(index: index, station: station, botID: botID))
      }
    }
    return WeatherCoverage(
      stations: stations.sorted { ($0.index, $0.botID) < ($1.index, $1.botID) },
      stated: stated,
      tables: tables,
      areas: areas
    )
  }

  /// No evidence of any kind: no bot has stated its coverage or reported a scheduled batch.
  public var isEmpty: Bool { stations.isEmpty && stated.isEmpty }

  public func nearest(to point: MeshWXCoordinate) -> (station: Station, kilometres: Double)? {
    stations
      .map { ($0, WeatherGeo.kilometres(point, $0.coordinate)) }
      .min { $0.1 < $1.1 }
  }

  public func contains(_ point: MeshWXCoordinate) -> Bool {
    !botIDs(covering: point).isEmpty
  }

  /// The bots whose area covers a point: what each one says about itself, else its footprint.
  public func botIDs(covering point: MeshWXCoordinate) -> Set<UInt16> {
    evidenceBotIDs.filter { verdict(of: $0, covering: point, withinKilometres: 0) == .inside }
  }

  /// The bots whose area covers a place, the place's uncertainty included.
  public func botIDs(covering place: WeatherPlace) -> Set<UInt16> {
    evidenceBotIDs.filter { verdict(of: $0, for: place) == .inside }
  }

  /// Every bot with something to say about a place: one that stated its coverage, or one with
  /// stations in its footprint.
  var evidenceBotIDs: Set<UInt16> {
    Set(stated.keys).union(stations.map(\.botID))
  }

  // MARK: - Verdicts

  /// What every bot's evidence together says about a place.
  ///
  /// Inside as soon as one bot's area covers it. Otherwise unknown if any bot cannot say —
  /// nothing stated and nothing reported, a list the bot had to cut, outlines still loading —
  /// because one bot's "outside" says nothing about a place another may carry. Outside only when
  /// at least one bot's evidence puts it outside and no bot leaves it open; with no evidence at
  /// all, unknown.
  public func verdict(for place: WeatherPlace) -> WeatherCoverageVerdict {
    var sawOutside = false
    var sawUnknown = false
    for botID in evidenceBotIDs {
      switch verdict(of: botID, for: place) {
      case .inside: return .inside
      case .outside: sawOutside = true
      case .unknown: sawUnknown = true
      }
    }
    return sawOutside && !sawUnknown ? .outside : .unknown
  }

  public func verdict(of botID: UInt16, for place: WeatherPlace) -> WeatherCoverageVerdict {
    verdict(of: botID, covering: place.coordinate, withinKilometres: place.uncertaintyKilometres)
  }

  /// One bot: its own statement where it has made one, its station footprint where it has not.
  func verdict(
    of botID: UInt16, covering point: MeshWXCoordinate, withinKilometres radius: Double
  ) -> WeatherCoverageVerdict {
    if let statement = stated[botID]?.coverage {
      return verdict(statement, covering: point, withinKilometres: radius)
    }
    let footprint = stations.filter { $0.botID == botID }
    guard !footprint.isEmpty else { return .unknown }
    return Self.footprint(footprint, covers: point) ? .inside : .outside
  }

  /// What one statement says about a point (spec §7A).
  ///
  /// Inside on the stated circle, on a stated run, or on a statement with no area filter at all
  /// (`n` = 0 and `k` = 0: the bot carries everything its feed does). Outside only when both
  /// lists are whole, the bot listed zones to test against, and the place resolved to UGCs that
  /// none of the runs covers. Everything else is unknown: a cut list says "not listed", and a
  /// place the outlines cannot place is not a place outside the area.
  func verdict(
    _ statement: MeshWXCoverage, covering point: MeshWXCoordinate, withinKilometres radius: Double
  ) -> WeatherCoverageVerdict {
    if statement.hasNoAreaFilter { return .inside }
    if statement.circleContains(point) { return .inside }
    let codes = areaCodes(near: point, withinKilometres: radius)
    if codes.contains(where: { statement.covers(ugc: $0, states: tables.states) }) { return .inside }
    guard statement.isComplete else { return .unknown }
    // The runs are the only list that speaks about a place. The office list can deny an office
    // (``uncarriedOffice``) but never place a point, so a statement without runs settles nothing.
    guard !statement.areas.isEmpty, !codes.isEmpty else { return .unknown }
    return .outside
  }

  /// The counties and zones a place could be in: the ones it lies in, plus any within its
  /// uncertainty. Empty while the outlines load, which is why empty never reads as "outside".
  func areaCodes(near point: MeshWXCoordinate, withinKilometres radius: Double) -> [String] {
    guard areas.isLoaded else { return [] }
    return areas.areaCodes(near: point, withinKilometres: max(0, radius))
  }

  // MARK: - Offices

  /// The place's forecast office when no bot answering for it says it carries that office
  /// (spec §7A, docs/MESHWX_UI.md §3.1 I-B18 and §7.4).
  ///
  /// The bot's own word and nothing weaker: every bot that could answer for the place must have
  /// stated its offices with the office-cut flag clear, and none of them may list the place's
  /// office. A bot that has stated nothing, a cut list, an office any of them carries, or a place
  /// with no office to name all mean the app has nothing to say — which is exactly what the
  /// offices of whatever warnings were active used to be mistaken for.
  public func uncarriedOffice(for place: WeatherPlace) -> String? {
    let answering = evidenceBotIDs.filter { verdict(of: $0, for: place) != .outside }
    guard !answering.isEmpty else { return nil }
    let offices = placeOffices(for: place)
    guard !offices.isEmpty else { return nil }
    for botID in answering {
      guard let statement = stated[botID]?.coverage,
        !statement.officesCut,
        !statement.officeIndices.isEmpty
      else { return nil }
      let carried = Set(statement.officeIndices.compactMap { tables.officeCode($0) })
      guard offices.isDisjoint(with: carried) else { return nil }
    }
    return offices.sorted().first
  }

  /// The NWS forecast offices of the zones a place is in (`zones.json` `wfo`). Counties carry no
  /// office of their own and drop out.
  func placeOffices(for place: WeatherPlace) -> Set<String> {
    Set(
      areaCodes(near: place.coordinate, withinKilometres: place.uncertaintyKilometres)
        .compactMap { tables.zone($0)?.office })
  }

  /// One bot's stations: within reach of one, or inside their hull.
  static func footprint(_ stations: [Station], covers point: MeshWXCoordinate) -> Bool {
    if stations.contains(where: { WeatherGeo.kilometres(point, $0.coordinate) <= stationReachKilometres }) {
      return true
    }
    // Kilometres east and north of the point on a flat projection: over a footprint a couple of
    // hundred kilometres across the error is far below the reach.
    let cosLatitude = cos(point.latitude * .pi / 180)
    let planar = stations.map { station -> Planar in
      var longitude = station.station.lon - point.longitude
      if longitude > 180 { longitude -= 360 } else if longitude < -180 { longitude += 360 }
      return Planar(x: longitude * 111.32 * cosLatitude, y: (station.station.lat - point.latitude) * 110.574)
    }
    let hull = convexHull(planar)
    guard hull.count >= 3 else { return false }
    // Counter-clockwise: the point (the origin) is inside, or on the edge, when it is to the right
    // of no edge.
    let origin = Planar(x: 0, y: 0)
    for (index, start) in hull.enumerated() where cross(start, hull[(index + 1) % hull.count], origin) < 0 {
      return false
    }
    return true
  }

  struct Planar {
    var x: Double
    var y: Double
  }

  /// Andrew's monotone chain: the hull counter-clockwise, points on an edge dropped.
  private static func convexHull(_ points: [Planar]) -> [Planar] {
    let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
    guard sorted.count >= 3 else { return sorted }
    func chain(_ ordered: some Sequence<Planar>) -> [Planar] {
      var chain: [Planar] = []
      for point in ordered {
        while chain.count >= 2, cross(chain[chain.count - 2], chain[chain.count - 1], point) <= 0 {
          chain.removeLast()
        }
        chain.append(point)
      }
      return chain
    }
    return Array(chain(sorted).dropLast() + chain(sorted.reversed()).dropLast())
  }

  /// Positive when `point` is to the left of the line from `start` to `end`.
  private static func cross(_ start: Planar, _ end: Planar, _ point: Planar) -> Double {
    (end.x - start.x) * (point.y - start.y) - (end.y - start.y) * (point.x - start.x)
  }
}
