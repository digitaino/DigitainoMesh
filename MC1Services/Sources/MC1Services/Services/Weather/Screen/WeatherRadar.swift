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

  /// The best tile held for a coordinate at any width the place page shows, or nil when nothing
  /// reaches it.
  ///
  /// **Zoom 0 to 3 only** (spec revision 13, §3): the place page never shows a detail tile. A
  /// detail square is one degree around a spot somebody picked on the radar screen's map, and it
  /// would win "the lowest zoom" from every Local picture of the place the moment one arrived —
  /// a picture of somewhere else, centred a quarter of a degree from where this card is about.
  public static func best(
    for coordinate: MeshWXCoordinate,
    tiles: [WeatherStoredRadarTile],
    now: Date
  ) -> WeatherStoredRadarTile? {
    best(for: coordinate, zoom: nil, tiles: tiles, now: now)
  }

  /// The best tile held for a coordinate at one width, for the radar screen's width control:
  /// each width shows the tile held for it, or nothing. Takes −1, the detail level, like any
  /// zoom; nil is every width the place page shows (0 to 3).
  public static func best(
    for coordinate: MeshWXCoordinate,
    zoom: Int?,
    tiles: [WeatherStoredRadarTile],
    now: Date
  ) -> WeatherStoredRadarTile? {
    let nowMinutes = MeshWXPresentation.unixMinutes(for: now)
    let usable = tiles.filter { stored in
      if let zoom {
        guard stored.tile.zoom == zoom else { return false }
      } else {
        guard stored.tile.zoom >= 0 else { return false }
      }
      guard reaches(stored, coordinate: coordinate) else { return false }
      return age(ofTakenMinutes: stored.takenMinutes, nowMinutes: nowMinutes) <= maximumAgeMinutes
    }
    return usable.max { lhs, rhs in isBetter(rhs, than: lhs) }
  }

  /// The picture held for one **exact** square, whether or not it reaches the place: the newest
  /// of its frames (spec revision 13), any zoom, the detail level included.
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

  /// The width the place page's own ask uses: the narrowest of the place's own squares, which is
  /// the one that is actually about the place. The radar screen offers the others, and Detail for
  /// a spot picked on its map.
  public static let pageZoom = 0

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
      isWiderThanAsked: stored.tile.zoom > pageZoom))
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
    _ zoom: Int,
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
      isWiderThanAsked: stored.tile.zoom > pageZoom))
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
  public static func ask(place: WeatherPlace?, zoom: Int = pageZoom) -> WeatherRequest? {
    guard let place else { return nil }
    return .radar(
      latitude: place.coordinate.latitude, longitude: place.coordinate.longitude, zoom: zoom)
  }

  /// The tile a place's ask at one width would be answered with, for a screen that wants to say
  /// what it already holds for that width before spending a packet.
  public static func tile(for place: WeatherPlace, zoom: Int = pageZoom) -> MeshWXRadarTile {
    MeshWXRadarTile.containing(
      latitude: place.coordinate.latitude, longitude: place.coordinate.longitude, zoom: zoom)
  }

  public var picture: WeatherRadarPicture? {
    guard case let .held(picture) = self else { return nil }
    return picture
  }
}

// MARK: - The loop

/// The last hour of one square, as the radar screen plays it (spec revision 13, §7D.4, §3).
///
/// Built from the frames held of that **exact** tile, from every bot: a frame is a picture of a
/// square at a minute, and two bots' copies of the same minute are one frame — the finer copy, by
/// ``WeatherRadarPick``'s own order. The newest frame anchors the hour; nothing past the two hours
/// a tile is drawn for at all is in it.
public struct WeatherRadarLoop: Sendable, Hashable {
  /// The frames, **oldest first**: the order they play in.
  public var frames: [WeatherStoredRadarTile]
  /// Two consecutive frames are more than ``gapMinutes`` apart: a picture of the hour is missing,
  /// and the screen says so rather than letting a jump in the storm read as its speed.
  public var hasGap: Bool
  /// The frames' `taken` minutes, **newest first** — the order a loop request lists them in
  /// (``WeatherRequest/radarLoop(latitude:longitude:zoom:held:)``).
  public var held: [UInt32]

  public init(frames: [WeatherStoredRadarTile], hasGap: Bool, held: [UInt32]) {
    self.frames = frames
    self.hasGap = hasGap
    self.held = held
  }

  /// No frames: nothing to play and nothing held.
  public static let empty = WeatherRadarLoop(frames: [], hasGap: false, held: [])

  /// The most frames a loop holds: an hour at 15-minute steps, the newest included.
  public static let maxFrames = MeshWXWire.radarLoopMaxFrames
  /// How far back from the newest frame the loop reaches.
  public static let windowMinutes = MeshWXWire.radarLoopWindowMinutes
  /// Past this between two frames, one is missing. Pictures are made every 15 minutes, so 20 is
  /// one picture late and not yet one picture lost.
  public static let gapMinutes = 20

  /// Play and Pause are offered from two frames: one frame is a picture, not a loop.
  public var canPlay: Bool { frames.count >= 2 }
  /// The hour is all here: the ask for it is not offered.
  public var isFull: Bool { frames.count >= Self.maxFrames }
  /// The frame the screen shows when nothing is playing.
  public var newest: WeatherStoredRadarTile? { frames.last }

  /// The frames of `tile` whose `taken` is within ``windowMinutes`` before the newest held for it
  /// and at most ``WeatherRadarPick/maximumAgeMinutes`` old, at most ``maxFrames``, the newest
  /// kept when there are more.
  public static func make(
    tile: MeshWXRadarTile, tiles: [WeatherStoredRadarTile], now: Date
  ) -> WeatherRadarLoop {
    let nowMinutes = MeshWXPresentation.unixMinutes(for: now)
    var byTaken: [UInt32: WeatherStoredRadarTile] = [:]
    for stored in tiles where stored.tile == tile {
      guard WeatherRadarPick.age(ofTakenMinutes: stored.takenMinutes, nowMinutes: nowMinutes)
        <= WeatherRadarPick.maximumAgeMinutes
      else { continue }
      if let other = byTaken[stored.takenMinutes], !WeatherRadarPick.isBetter(stored, than: other) {
        continue
      }
      byTaken[stored.takenMinutes] = stored
    }
    guard let newest = byTaken.keys.max() else { return .empty }
    let floor = newest >= UInt32(windowMinutes) ? newest - UInt32(windowMinutes) : 0
    let frames = Array(
      byTaken.values.filter { $0.takenMinutes >= floor }
        .sorted { $0.takenMinutes < $1.takenMinutes }
        .suffix(maxFrames))
    let hasGap = zip(frames, frames.dropFirst()).contains { earlier, later in
      later.takenMinutes - earlier.takenMinutes > UInt32(gapMinutes)
    }
    return WeatherRadarLoop(
      frames: frames, hasGap: hasGap, held: frames.map(\.takenMinutes).reversed())
  }

  /// The ask for the rest of the hour at one width, listing what this loop already holds so the
  /// bot leaves those pictures out (spec revision 13, §7D.4). The coordinate is the place's for
  /// Local, Regional and Wide, and the picked spot's for Detail.
  public func ask(latitude: Double, longitude: Double, zoom: Int) -> WeatherRequest {
    .radarLoop(latitude: latitude, longitude: longitude, zoom: zoom, held: held)
  }
}

// MARK: - Detail

/// The radar screen's Detail width: one degree around a spot picked on its map (spec revision 13,
/// §7E, §3).
///
/// Three states, the middle one the bot's own fallback: where no picture is fine enough for
/// detail the bot sends the Local tile for the spot instead, and the screen draws that and says
/// so rather than calling it a detailed picture.
public enum WeatherRadarDetail: Sendable, Hashable {
  /// A detail picture of the spot's square, at most two hours old.
  case held(picture: WeatherRadarPicture)
  /// No detail picture, but the zoom 0 tile containing the spot: "No detailed picture of this
  /// spot. Showing Local."
  case local(picture: WeatherRadarPicture)
  /// Neither: "Not asked for yet."
  case missing

  /// The detail square a spot is in: the one-degree tile whose centre is the nearest half-degree
  /// lattice point.
  public static func tile(for spot: MeshWXCoordinate) -> MeshWXRadarTile {
    MeshWXRadarTile.containing(
      latitude: spot.latitude, longitude: spot.longitude, zoom: MeshWXWire.radarDetailZoom)
  }

  /// The Local tile the bot falls back to for a spot: the zoom 0 tile containing it.
  public static func localTile(for spot: MeshWXCoordinate) -> MeshWXRadarTile {
    MeshWXRadarTile.containing(latitude: spot.latitude, longitude: spot.longitude, zoom: 0)
  }

  /// What the Detail width shows for a spot. Through ``WeatherRadarPick/held(_:tiles:now:)``, the
  /// exact square, like every width: a partial tile that stops short of the spot is still the
  /// picture held for it. The pictures' summaries are about the spot; the screen speaks about
  /// the place only when the place is inside (``summary(of:place:)``).
  public static func card(
    spot: MeshWXCoordinate, tiles: [WeatherStoredRadarTile], now: Date
  ) -> WeatherRadarDetail {
    if let stored = WeatherRadarPick.held(tile(for: spot), tiles: tiles, now: now) {
      return .held(picture: picture(stored, spot: spot, now: now))
    }
    if let stored = WeatherRadarPick.held(localTile(for: spot), tiles: tiles, now: now) {
      return .local(picture: picture(stored, spot: spot, now: now))
    }
    return .missing
  }

  /// The single ask for a spot: `>radar <lat>,<lon> z-1`.
  public static func ask(spot: MeshWXCoordinate) -> WeatherRequest {
    .radar(latitude: spot.latitude, longitude: spot.longitude, zoom: MeshWXWire.radarDetailZoom)
  }

  /// The summary sentences about the **place**, when the place is inside the tile drawn: a
  /// detail square is about a spot, and a sentence naming Austin under a square of Round Rock
  /// would be about a place the picture is not of. Nil when the place is outside it.
  public static func summary(
    of picture: WeatherRadarPicture, place: MeshWXCoordinate?
  ) -> WeatherRadarSummary? {
    guard let place,
      picture.stored.tile.contains(latitude: place.latitude, longitude: place.longitude)
    else { return nil }
    return WeatherRadarSummary.make(tile: picture.stored, coordinate: place)
  }

  public var picture: WeatherRadarPicture? {
    switch self {
    case let .held(picture), let .local(picture): picture
    case .missing: nil
    }
  }

  /// The Local tile is on screen in place of a detail picture.
  public var isFallback: Bool {
    if case .local = self { return true }
    return false
  }

  private static func picture(
    _ stored: WeatherStoredRadarTile, spot: MeshWXCoordinate, now: Date
  ) -> WeatherRadarPicture {
    WeatherRadarPicture(
      stored: stored,
      age: WeatherRadarAge.make(takenMinutes: stored.takenMinutes, now: now),
      summary: WeatherRadarSummary.make(tile: stored, coordinate: spot),
      isWiderThanAsked: stored.tile.zoom > MeshWXWire.radarDetailZoom)
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
