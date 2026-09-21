import Foundation
import MeshWX

// MARK: - Picking a tile

/// Which held tile answers for a coordinate (spec revision 11, §7D; docs/MESHWX_UI.md §18).
///
/// Every bot's tiles together, because the lattice is shared: a tile of this square from the bot
/// next door is a picture of the same storm, taken from the same mosaic, and refusing it would
/// have the phone ask for a packet it already holds.
///
/// The order is the order of the three questions a person actually asks. **Newest**, rounded down
/// to the quarter hour the mosaics are made on, so two tiles of one picture that the bot stamped a
/// minute apart do not swap places; then the **lowest zoom**, because a 2° tile of the place is a
/// better picture of the place than a 16° tile it is a dot in; then **fine before coarse**.
public enum WeatherRadarPick {
  /// Past this, a tile is not drawn at all (spec revision 11, §3): two hours of weather is not
  /// this weather, and a radar picture with an old time on it is read as current far more often
  /// than it is read as old.
  public static let maximumAgeMinutes = 120
  /// How coarsely the picture's own time is compared. The mosaics are made about every fifteen
  /// minutes, and the time printed on two tiles of the same sweep can differ by a few: without
  /// this, "newest" would sometimes prefer a wide tile stamped 23:39 over the local one stamped
  /// 23:38 that is the better picture.
  public static let takenBucketMinutes: UInt32 = 15

  /// The best tile held for a coordinate at any width, or nil when nothing reaches it.
  public static func best(
    for coordinate: MeshWXCoordinate,
    tiles: [WeatherStoredRadarTile],
    now: Date
  ) -> WeatherStoredRadarTile? {
    best(for: coordinate, zoom: nil, tiles: tiles, now: now)
  }

  /// The best tile held for a coordinate at one width, for the radar screen's Local / Regional /
  /// Wide control: each width shows the tile held for it, or nothing.
  public static func best(
    for coordinate: MeshWXCoordinate,
    zoom: UInt8?,
    tiles: [WeatherStoredRadarTile],
    now: Date
  ) -> WeatherStoredRadarTile? {
    let nowMinutes = MeshWXPresentation.unixMinutes(for: now)
    let usable = tiles.filter { stored in
      if let zoom, stored.tile.zoom != Int(zoom) { return false }
      guard reaches(stored, coordinate: coordinate) else { return false }
      return age(ofTakenMinutes: stored.takenMinutes, nowMinutes: nowMinutes) <= maximumAgeMinutes
    }
    return usable.max { lhs, rhs in isBetter(rhs, than: lhs) }
  }

  /// The picture held for one **exact** square, whether or not it reaches the place.
  ///
  /// This is the radar screen's width control (spec revision 11, §3): each width shows the tile
  /// held for it, and a partial tile whose bounds stop short of the place is still the tile held
  /// for that width — the screen says "This picture does not reach Austin", which is an answer,
  /// and a very different one from "Not asked for yet". ``best(for:zoom:tiles:now:)`` is for the
  /// other question, "which picture answers for this place", and there a tile that does not reach
  /// it is no answer at all.
  public static func held(
    _ tile: MeshWXRadarTile, tiles: [WeatherStoredRadarTile], now: Date
  ) -> WeatherStoredRadarTile? {
    let nowMinutes = MeshWXPresentation.unixMinutes(for: now)
    return tiles
      .filter {
        $0.tile == tile
          && age(ofTakenMinutes: $0.takenMinutes, nowMinutes: nowMinutes) <= maximumAgeMinutes
      }
      .max { lhs, rhs in isBetter(rhs, than: lhs) }
  }

  /// Whether a tile has anything to say about a coordinate: the square contains it, and — for a
  /// partial tile — the picture reaches the cell it falls in.
  ///
  /// The bounds check is the difference between "dry here" and "this picture does not reach here",
  /// and only one of those two is an answer.
  public static func reaches(
    _ stored: WeatherStoredRadarTile, coordinate: MeshWXCoordinate
  ) -> Bool {
    guard let cell = stored.tile.cell(
      latitude: coordinate.latitude, longitude: coordinate.longitude, size: stored.radar.size)
    else { return false }
    return !stored.radar.isUnknown(row: cell.row, col: cell.col)
  }

  /// Newest quarter hour, then the narrowest tile, then the finer grid.
  static func isBetter(_ lhs: WeatherStoredRadarTile, than rhs: WeatherStoredRadarTile) -> Bool {
    let lhsBucket = lhs.takenMinutes / takenBucketMinutes
    let rhsBucket = rhs.takenMinutes / takenBucketMinutes
    if lhsBucket != rhsBucket { return lhsBucket > rhsBucket }
    if lhs.tile.zoom != rhs.tile.zoom { return lhs.tile.zoom < rhs.tile.zoom }
    if lhs.radar.isCoarse != rhs.radar.isCoarse { return !lhs.radar.isCoarse }
    // Nothing left to choose by that is about the picture, so the exact stamp and then arrival
    // break the tie: the order has to be the same on two runs over the same state.
    if lhs.takenMinutes != rhs.takenMinutes { return lhs.takenMinutes > rhs.takenMinutes }
    return lhs.receivedAt > rhs.receivedAt
  }

  static func age(ofTakenMinutes taken: UInt32, nowMinutes: UInt32) -> Int {
    Int(nowMinutes) - Int(taken)
  }
}

// MARK: - How old the picture is

/// How old a radar picture is, and whether that is old enough to say so
/// (docs/MESHWX_UI.md §18).
public struct WeatherRadarAge: Sendable, Hashable {
  /// Minutes from the time printed on the picture to now, on the phone's clock. Negative is
  /// clamped to 0: a bot a minute ahead must not produce "−1 min old".
  public var minutes: Int
  /// The picture is old enough that what it shows has moved. The line takes the caution tone and
  /// adds a sentence saying so; the picture is still drawn, because a picture of where the storm
  /// was half an hour ago is worth more than no picture at all.
  public var isOld: Bool

  /// From here the picture is stale (spec revision 11, §3). Two mosaics have been made since, so
  /// either the bot missed them or the phone did.
  public static let oldFromMinutes = 30

  public init(minutes: Int, isOld: Bool) {
    self.minutes = minutes
    self.isOld = isOld
  }

  public static func make(takenMinutes: UInt32, now: Date) -> WeatherRadarAge {
    let minutes = max(
      0, WeatherRadarPick.age(
        ofTakenMinutes: takenMinutes, nowMinutes: MeshWXPresentation.unixMinutes(for: now)))
    return WeatherRadarAge(minutes: minutes, isOld: minutes >= oldFromMinutes)
  }

  /// Past ``WeatherRadarPick/maximumAgeMinutes`` nothing is drawn at all.
  public var isTooOldToDraw: Bool { minutes > WeatherRadarPick.maximumAgeMinutes }
}

// MARK: - What the picture says

/// What a radar tile says about one place, in the three sentences the card is built from
/// (spec revision 11, §3).
public struct WeatherRadarSummary: Sendable, Hashable {
  /// Precipitation somewhere other than the place, and where it is.
  public struct Reach: Sendable, Hashable {
    public var level: MeshWXRadarLevel
    /// Great circle from the place to the centre of the cell.
    public var kilometres: Double
    /// Eight points, not sixteen: the cell is seven kilometres across at zoom 0 and fifty at zoom
    /// 3, so "north-north-west" would be a precision the picture does not have.
    public var bearing: MeshWXCompass

    public init(level: MeshWXRadarLevel, kilometres: Double, bearing: MeshWXCompass) {
      self.level = level
      self.kilometres = kilometres
      self.bearing = bearing
    }
  }

  /// What is falling on the place itself, or **nil** when the coordinate is outside the picture —
  /// inside the tile but outside a partial tile's bounds. Nil is "this picture does not reach
  /// here", which is a different sentence from "dry here" and must never be shown as one.
  public var here: MeshWXRadarLevel?
  /// The nearest wet cell other than the place's own.
  public var nearest: Reach?
  /// The nearest heavy cell. Omitted when it is the cell ``nearest`` already named, and when the
  /// place itself is under heavy precipitation: the card would otherwise say the same thing twice,
  /// or point at a storm the reader is standing in.
  public var nearestHeavy: Reach?

  public init(here: MeshWXRadarLevel?, nearest: Reach?, nearestHeavy: Reach?) {
    self.here = here
    self.nearest = nearest
    self.nearestHeavy = nearestHeavy
  }

  /// Nothing at all on this picture: dry at the place and no wet cell anywhere in the tile.
  public var isAllDry: Bool { here == MeshWXRadarLevel.none && nearest == nil }

  public static func make(
    tile stored: WeatherStoredRadarTile, coordinate: MeshWXCoordinate
  ) -> WeatherRadarSummary {
    let radar = stored.radar
    let square = stored.tile
    let size = radar.size
    let own = square.cell(
      latitude: coordinate.latitude, longitude: coordinate.longitude, size: size)
    let here: MeshWXRadarLevel? = own.flatMap { cell in
      radar.isUnknown(row: cell.row, col: cell.col) ? nil : radar.level(row: cell.row, col: cell.col)
    }

    var nearest: Reach?
    var heavy: Reach?
    var heavyCell: (row: Int, col: Int)?
    var nearestCell: (row: Int, col: Int)?
    for row in 0..<size {
      for col in 0..<size {
        // Outside the bounds a level 0 is unknown, not dry, and every cell out there is 0 — so
        // there is nothing to measure and nothing to report.
        guard !radar.isUnknown(row: row, col: col) else { continue }
        let level = radar.level(row: row, col: col)
        guard level.isWet else { continue }
        // The place's own cell is what `here` answers for; counting it as "nearest" would put
        // "nearest precipitation 2 km" under "light precipitation at Austin".
        if let own, own.row == row, own.col == col { continue }
        let box = square.cellBox(row: row, col: col, size: size)
        let centre = MeshWXCoordinate(
          latitude: (box.south + box.north) / 2, longitude: (box.west + box.east) / 2)
        let distance = WeatherGeo.kilometres(coordinate, centre)
        if nearest == nil || distance < nearest!.kilometres {
          nearest = Reach(
            level: level, kilometres: distance,
            bearing: eightPointBearing(from: coordinate, to: centre))
          nearestCell = (row, col)
        }
        if level == .heavy, heavy == nil || distance < heavy!.kilometres {
          heavy = Reach(
            level: .heavy, kilometres: distance,
            bearing: eightPointBearing(from: coordinate, to: centre))
          heavyCell = (row, col)
        }
      }
    }

    if here == .heavy { heavy = nil }
    if let heavyCell, let nearestCell, heavyCell == nearestCell { heavy = nil }
    return WeatherRadarSummary(here: here, nearest: nearest, nearestHeavy: heavy)
  }

  /// The compass rounded to eight points. ``MeshWXCompass`` carries sixteen because a wind nibble
  /// does; a radar cell does not.
  ///
  /// Rounded from the bearing itself, 45° sectors centred on the points, and not by folding the
  /// sixteen-point sector: folding shifts every sector by 11.25°, so a core 15° east of north read
  /// "NE" here while the bot's `radar` reply and the web client, which round the bearing, both said
  /// "N" about the same picture.
  static func eightPointBearing(
    from origin: MeshWXCoordinate, to target: MeshWXCoordinate
  ) -> MeshWXCompass {
    let degrees = WeatherGeo.bearingDegrees(from: origin, to: target)
    let eighth = Int(((degrees + 22.5) / 45).rounded(.down)) % 8
    return MeshWXCompass(nibble: UInt8(eighth * 2))
  }
}

// MARK: - The card

/// One held radar picture, ready to draw (docs/MESHWX_UI.md §18).
public struct WeatherRadarPicture: Sendable, Hashable {
  public var stored: WeatherStoredRadarTile
  public var age: WeatherRadarAge
  public var summary: WeatherRadarSummary
  /// The tile is wider than the ask the card offers: the place page asks at zoom 0, so anything
  /// above it is a picture somebody asked for at another width and the card says so quietly.
  public var isWiderThanAsked: Bool

  public init(
    stored: WeatherStoredRadarTile,
    age: WeatherRadarAge,
    summary: WeatherRadarSummary,
    isWiderThanAsked: Bool
  ) {
    self.stored = stored
    self.age = age
    self.summary = summary
    self.isWiderThanAsked = isWiderThanAsked
  }

  /// The grid this picture was sent at: 16 when the bot had to halve the detail to fit a packet.
  public var isCoarse: Bool { stored.radar.isCoarse }
  /// Part of the tile is outside the radar picture, so some cells are unknown rather than dry.
  public var isPartial: Bool { stored.radar.bounds != nil }
}

/// The Radar section of a place page (spec revision 11, §3).
///
/// Three states and no fourth. A place with no coordinate has no section at all — the tile is
/// decided by a coordinate and nothing else — which is why ``noCoordinate`` is a case rather than
/// an empty card.
public enum WeatherRadarCard: Sendable, Hashable {
  /// The place has no coordinate yet: no section.
  case noCoordinate
  /// Nothing held for the place: "No radar picture yet" and the ask.
  case missing
  /// A picture to draw.
  case held(picture: WeatherRadarPicture)

  /// The width the place page's own ask uses: the narrowest, which is the one that is actually
  /// about the place. The radar screen offers the others.
  public static let pageZoom: UInt8 = 0

  public static func make(
    place: WeatherPlace?,
    tiles: [WeatherStoredRadarTile],
    now: Date
  ) -> WeatherRadarCard {
    guard let place else { return .noCoordinate }
    guard let stored = WeatherRadarPick.best(for: place.coordinate, tiles: tiles, now: now) else {
      return .missing
    }
    return .held(picture: WeatherRadarPicture(
      stored: stored,
      age: WeatherRadarAge.make(takenMinutes: stored.takenMinutes, now: now),
      summary: WeatherRadarSummary.make(tile: stored, coordinate: place.coordinate),
      isWiderThanAsked: stored.tile.zoom > Int(pageZoom)))
  }

  /// One width of the radar screen's control (spec revision 11, §3): the tile held for the square
  /// this place's ask at that width would name, or ``missing`` — "Not asked for yet".
  ///
  /// Not ``make(place:tiles:now:)`` with a zoom, because the two answer different questions. The
  /// card asks *which picture is this place's*, and a partial tile whose bounds stop short of the
  /// place is not one. A width asks *what is held for this width*, and that same tile is held for
  /// it: the summary's ``WeatherRadarSummary/here`` comes back nil and the screen says the picture
  /// does not reach the place, which is an answer and not an absence.
  public static func width(
    _ zoom: UInt8,
    place: WeatherPlace?,
    tiles: [WeatherStoredRadarTile],
    now: Date
  ) -> WeatherRadarCard {
    guard let place else { return .noCoordinate }
    guard let stored = WeatherRadarPick.held(
      tile(for: place, zoom: zoom), tiles: tiles, now: now)
    else { return .missing }
    return .held(picture: WeatherRadarPicture(
      stored: stored,
      age: WeatherRadarAge.make(takenMinutes: stored.takenMinutes, now: now),
      summary: WeatherRadarSummary.make(tile: stored, coordinate: place.coordinate),
      isWiderThanAsked: stored.tile.zoom > Int(pageZoom)))
  }

  /// Every bot's tiles in one list, which is what ``make(place:tiles:now:)`` wants: a tile is a
  /// square of earth and not a bot's property, and the picker orders them by what the picture is
  /// rather than by who sent it.
  public static func tiles(in states: [UInt16: WeatherBotState]) -> [WeatherStoredRadarTile] {
    states.keys.sorted().flatMap { states[$0]?.radarTiles ?? [] }
  }

  /// The ask for a place at one width, or nil when the place has no coordinate to ask about.
  ///
  /// The coordinate, never the place's name: the lattice turns the coordinate into a tile this
  /// phone can name before the answer arrives, and a place the bot resolves for itself would come
  /// back as a square nobody here chose (spec revision 11, §7D).
  public static func ask(place: WeatherPlace?, zoom: UInt8 = pageZoom) -> WeatherRequest? {
    guard let place else { return nil }
    return .radar(
      latitude: place.coordinate.latitude, longitude: place.coordinate.longitude, zoom: zoom)
  }

  /// The tile a place's ask at one width would be answered with, for a screen that wants to say
  /// what it already holds for that width before spending a packet.
  public static func tile(for place: WeatherPlace, zoom: UInt8 = pageZoom) -> MeshWXRadarTile {
    MeshWXRadarTile.containing(
      latitude: place.coordinate.latitude, longitude: place.coordinate.longitude, zoom: Int(zoom))
  }

  public var picture: WeatherRadarPicture? {
    guard case let .held(picture) = self else { return nil }
    return picture
  }
}

/// Why the bot would not send a radar tile (spec revision 11, §3).
///
/// The reasons are the wire's, split into the four the screen says different things for. Radar is
/// the one request where the refusal carries most of the information: "no recent picture for this
/// area" and "this bot has no dish at all" ask the reader to do entirely different things, and a
/// single "not available" would leave them tapping again for ever.
public enum WeatherRadarRefusal: Sendable, Hashable {
  /// Reason 0: nothing newer than an hour covers the tile, or it lies outside every mosaic, or the
  /// region is not calibrated.
  case noPicture
  /// Reason 1: the place did not resolve, or the coordinate is not one. The app sends a
  /// coordinate, so this one means the bot could not place it at all.
  case unknownPlace
  /// Reason 2: this bot has no radar source. Nothing to retry, at this bot or any time.
  case unsupported
  /// Reason 4: this tile, cut from this same picture, went out in the last five minutes. There is
  /// nothing newer yet; waiting is the answer.
  case sentRecently
  /// Anything else a bot sends back under `x`.
  case other(MeshWXNotAvailableReason)

  public init(reason: MeshWXNotAvailableReason) {
    switch reason {
    case .noData: self = .noPicture
    case .unknownLocation: self = .unknownPlace
    case .unsupported: self = .unsupported
    case .rateLimited: self = .sentRecently
    default: self = .other(reason)
    }
  }
}

// MARK: - Drawing the cells

/// One block of the radar picture as a map draws it: a level and the box it covers.
public struct WeatherRadarRectangle: Sendable, Hashable {
  public var level: MeshWXRadarLevel
  public var south: Double
  public var west: Double
  public var north: Double
  public var east: Double

  public init(level: MeshWXRadarLevel, south: Double, west: Double, north: Double, east: Double) {
    self.level = level
    self.south = south
    self.west = west
    self.north = north
    self.east = east
  }
}

/// A tile's cells as rectangles a map can draw (docs/MESHWX_UI.md §18).
///
/// One rectangle per **horizontal run of one level in one row**, because a 32 × 32 tile is 1,024
/// shapes and a squall line is a few hundred runs: MapKit redraws every overlay on every pan, and
/// a thousand of them on a card that is not even interactive is the difference between a map that
/// scrolls and one that does not. Runs are not merged vertically — a rectangle joining two rows
/// would have to be split again the moment either row's level changed, and the saving past the
/// horizontal pass is small.
public enum WeatherRadarCells {
  /// The wet cells, as rectangles. Dry cells and cells outside a partial tile's bounds are not in
  /// here: the first have nothing to draw and the second are ``unknownRectangles``.
  public static func rectangles(radar: MeshWXRadar) -> [WeatherRadarRectangle] {
    runs(of: radar) { row, col in
      let level = radar.level(row: row, col: col)
      guard !radar.isUnknown(row: row, col: col), level.isWet else { return nil }
      return level
    }
  }

  /// The cells outside a partial tile's bounds, as rectangles, so the map can hatch or grey them
  /// (spec revision 11, §3).
  ///
  /// Separate from ``rectangles(radar:)`` and never merged into it, because they are the one part
  /// of a radar picture that says nothing: drawn in the dry colour they would claim clear weather
  /// over ground the mosaic never covered. Empty for a whole tile.
  public static func unknownRectangles(radar: MeshWXRadar) -> [WeatherRadarRectangle] {
    guard radar.bounds != nil else { return [] }
    return runs(of: radar) { row, col in
      radar.isUnknown(row: row, col: col) ? MeshWXRadarLevel.none : nil
    }
  }

  /// Row by row, left to right, gathering neighbouring cells that `value` answers the same thing
  /// for. Cells it answers nil for break the run.
  private static func runs(
    of radar: MeshWXRadar, value: (Int, Int) -> MeshWXRadarLevel?
  ) -> [WeatherRadarRectangle] {
    let size = radar.size
    let tile = radar.tile
    var out: [WeatherRadarRectangle] = []
    for row in 0..<size {
      var start: Int?
      var level: MeshWXRadarLevel = .none

      func close(at end: Int) {
        guard let from = start else { return }
        let left = tile.cellBox(row: row, col: from, size: size)
        let right = tile.cellBox(row: row, col: end - 1, size: size)
        out.append(WeatherRadarRectangle(
          level: level, south: left.south, west: left.west, north: left.north, east: right.east))
        start = nil
      }

      for col in 0..<size {
        guard let cell = value(row, col) else {
          close(at: col)
          continue
        }
        if start != nil, cell != level { close(at: col) }
        if start == nil {
          start = col
          level = cell
        }
      }
      close(at: size)
    }
    return out
  }
}
