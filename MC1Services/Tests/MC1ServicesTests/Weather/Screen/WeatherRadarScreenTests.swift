import Foundation
@testable import MC1Services
import MeshWX
import Testing

/// The radar screen rules (spec revision 11, §3; docs/MESHWX_UI.md §18): which held tile answers
/// for a place, how old it is, what it says in words, and how its cells reach a map.
@Suite("WeatherRadar screen rules")
struct WeatherRadarScreenTests {
  /// 2026-09-20 23:38 UTC, the minute printed on the vector's Dallas picture.
  static let takenMinutes: UInt32 = 29_832_458
  static let taken = Date(unixMinutes: takenMinutes)
  /// Austin, which the zoom 0 tile 29N/99W contains.
  static let austin = MeshWXCoordinate(latitude: 30.27, longitude: -97.74)
  /// The cell of that tile Austin falls in, at the fine grid. Worked out from the lattice rather
  /// than written down, so the fixtures move with the tile if the lattice ever does.
  static let austinCell: (row: Int, col: Int) = MeshWXRadarTile(south: 29, west: -99, zoom: 0)
    .cell(latitude: austin.latitude, longitude: austin.longitude, size: MeshWXWire.radarGrid)
    ?? (row: 0, col: 0)

  static func place(
    _ coordinate: MeshWXCoordinate = austin, label: String = "Austin, TX"
  ) -> WeatherPlace {
    WeatherPlace(
      kind: .current, coordinate: coordinate, label: label, uncertaintyKilometres: 0.5,
      locatedAt: taken)
  }

  /// A held tile, built from the cells it should carry rather than from a wire round trip: these
  /// rules are about the grid, and the codec has its own suite.
  static func tile(
    south: Int8 = 29,
    west: Int16 = -99,
    zoom: UInt8 = 0,
    takenMinutes: UInt32 = takenMinutes,
    isCoarse: Bool = false,
    bounds: MeshWXRadarBounds? = nil,
    wet: [(Int, Int, UInt8)] = [],
    receivedAt: Date = taken,
    source: MeshWXDataSource = .goesSatellite
  ) -> WeatherStoredRadarTile {
    let size = isCoarse ? MeshWXWire.radarCoarseGrid : MeshWXWire.radarGrid
    var cells = [UInt8](repeating: 0, count: size * size)
    for (row, col, level) in wet {
      cells[row * size + col] = level
    }
    let radar = MeshWXRadar(
      takenMinutes: takenMinutes, south: south, west: west, zoom: zoom, product: 1,
      isCoarse: isCoarse, bounds: bounds, cells: cells)
    return WeatherStoredRadarTile(
      tile: radar.tile, radar: radar, receivedAt: receivedAt, source: source)
  }

  // MARK: - Picking

  @Test
  func `the newest quarter hour wins, then the narrowest tile, then the finer grid`() {
    let now = Self.taken.addingTimeInterval(120)
    let local = Self.tile()
    let wide = Self.tile(south: 24, west: -104, zoom: 3)
    let older = Self.tile(south: 28, west: -100, zoom: 2, takenMinutes: Self.takenMinutes - 30)
    // Every one of the three contains Austin, so only the order decides.
    #expect(WeatherRadarPick.best(for: Self.austin, tiles: [wide, local, older], now: now)?.tile
      == local.tile)
    // Take the narrow one away and the wide one is still a picture of the place.
    #expect(WeatherRadarPick.best(for: Self.austin, tiles: [wide, older], now: now)?.tile
      == wide.tile)

    // Same square, same minute, two grids: the fine one.
    let coarse = Self.tile(isCoarse: true, receivedAt: Self.taken.addingTimeInterval(30))
    #expect(WeatherRadarPick.best(for: Self.austin, tiles: [coarse, local], now: now)?.radar.size
      == MeshWXWire.radarGrid)

    // Stamps a minute apart inside one quarter hour do not reorder the widths: the mosaics are
    // made about every fifteen minutes, and a wide tile stamped a minute later is not newer news.
    let widerButLater = Self.tile(
      south: 24, west: -104, zoom: 3, takenMinutes: Self.takenMinutes + 1)
    #expect(WeatherRadarPick.best(for: Self.austin, tiles: [widerButLater, local], now: now)?.tile
      == local.tile)
  }

  @Test
  func `a tile that does not reach the place is not the place's picture`() {
    let now = Self.taken.addingTimeInterval(60)
    // Dallas's tile: Austin is not in it.
    #expect(WeatherRadarPick.best(
      for: Self.austin, tiles: [Self.tile(south: 32, west: -98)], now: now) == nil)
    // Inside the square but outside a partial picture's bounds, which is not an answer either.
    let partial = Self.tile(bounds: MeshWXRadarBounds(row0: 0, row1: 5, col0: 0, col1: 31))
    #expect(WeatherRadarPick.best(for: Self.austin, tiles: [partial], now: now) == nil)
    #expect(!WeatherRadarPick.reaches(partial, coordinate: Self.austin))
  }

  /// Two hours of weather is not this weather (spec revision 11, §3), so past that nothing is
  /// drawn at all.
  @Test
  func `a picture over two hours old is not offered`() {
    let tile = Self.tile()
    #expect(WeatherRadarPick.best(
      for: Self.austin, tiles: [tile], now: Self.taken.addingTimeInterval(119 * 60)) != nil)
    #expect(WeatherRadarPick.best(
      for: Self.austin, tiles: [tile], now: Self.taken.addingTimeInterval(121 * 60)) == nil)
  }

  /// The radar screen's width control asks per zoom: each width shows what is held for it, or
  /// says it has not been asked for.
  @Test
  func `picking at one width ignores every other`() {
    let now = Self.taken.addingTimeInterval(60)
    let local = Self.tile()
    let regional = Self.tile(south: 28, west: -100, zoom: 1)
    let tiles = [local, regional]
    #expect(WeatherRadarPick.best(for: Self.austin, zoom: 0, tiles: tiles, now: now)?.tile.zoom == 0)
    #expect(WeatherRadarPick.best(for: Self.austin, zoom: 1, tiles: tiles, now: now)?.tile.zoom == 1)
    #expect(WeatherRadarPick.best(for: Self.austin, zoom: 2, tiles: tiles, now: now) == nil)
  }

  // MARK: - Age

  @Test
  func `the age is measured from the time printed on the picture`() {
    let fresh = WeatherRadarAge.make(
      takenMinutes: Self.takenMinutes, now: Self.taken.addingTimeInterval(12 * 60))
    #expect(fresh.minutes == 12)
    #expect(!fresh.isOld)
    #expect(!fresh.isTooOldToDraw)

    let old = WeatherRadarAge.make(
      takenMinutes: Self.takenMinutes, now: Self.taken.addingTimeInterval(30 * 60))
    #expect(old.minutes == 30)
    #expect(old.isOld, "two mosaics have been made since")

    let ancient = WeatherRadarAge.make(
      takenMinutes: Self.takenMinutes, now: Self.taken.addingTimeInterval(121 * 60))
    #expect(ancient.isTooOldToDraw)

    // A bot a minute ahead must not produce a negative age.
    #expect(WeatherRadarAge.make(
      takenMinutes: Self.takenMinutes, now: Self.taken.addingTimeInterval(-90)).minutes == 0)
  }

  // MARK: - The summary

  @Test
  func `the summary says what is falling on the place`() {
    let own = Self.austinCell
    let summary = WeatherRadarSummary.make(
      tile: Self.tile(wet: [(own.row, own.col, 2)]), coordinate: Self.austin)
    #expect(summary.here == .moderate)
    #expect(summary.nearest == nil, "the place's own cell is what `here` answers for")
    #expect(summary.nearestHeavy == nil)
    #expect(!summary.isAllDry)
  }

  @Test
  func `a dry place gets the nearest precipitation and its bearing`() {
    let own = Self.austinCell
    // Four cells due west of the place: a cell is 1/16°, so about 24 km at this latitude.
    let summary = WeatherRadarSummary.make(
      tile: Self.tile(wet: [(own.row, own.col - 4, 1)]), coordinate: Self.austin)
    #expect(summary.here == MeshWXRadarLevel.none)
    let nearest = try! #require(summary.nearest)
    #expect(nearest.level == .light)
    #expect(nearest.bearing == .west)
    #expect(nearest.kilometres > 15 && nearest.kilometres < 35)
    #expect(summary.nearestHeavy == nil)
  }

  /// Eight points and not sixteen: a cell is seven kilometres across at zoom 0, so
  /// "north-north-west" would be a precision the picture does not have.
  @Test
  func `bearings are the eight points`() {
    let own = Self.austinCell
    let bearings: [(Int, Int, MeshWXCompass)] = [
      (-6, 0, .north), (6, 0, .south), (0, 6, .east), (0, -6, .west),
      (-6, 6, .northEast), (6, 6, .southEast), (-6, -6, .northWest), (6, -6, .southWest),
      // A cell that would read NNW on sixteen points folds up to N.
      (-8, -3, .north),
      // And NNE folds to N too, not on to NE: 12° east of north is north on the bot's `radar`
      // reply and on the web, which round the bearing itself, so it is north here.
      (-8, 2, .north)
    ]
    for (rowOffset, colOffset, expected) in bearings {
      let summary = WeatherRadarSummary.make(
        tile: Self.tile(wet: [(own.row + rowOffset, own.col + colOffset, 1)]),
        coordinate: Self.austin)
      #expect(summary.nearest?.bearing == expected, "\(rowOffset),\(colOffset)")
    }
    #expect(MeshWXCompass.allCases.filter { $0.rawValue % 2 == 0 }.count == 8)
  }

  /// A separate heavy core is worth its own sentence; the same cell twice is not.
  @Test
  func `the heavy core is named only when it is somewhere else`() {
    let own = Self.austinCell
    let apart = WeatherRadarSummary.make(
      tile: Self.tile(wet: [
        (own.row, own.col - 2, 1),
        (own.row + 10, own.col, 3)
      ]),
      coordinate: Self.austin)
    #expect(apart.nearest?.level == .light)
    #expect(apart.nearestHeavy?.level == .heavy)
    #expect(apart.nearestHeavy!.kilometres > apart.nearest!.kilometres)

    // The nearest cell is itself the heavy one: one sentence, not two.
    let same = WeatherRadarSummary.make(
      tile: Self.tile(wet: [(own.row + 4, own.col, 3)]), coordinate: Self.austin)
    #expect(same.nearest?.level == .heavy)
    #expect(same.nearestHeavy == nil)

    // Heavy precipitation over the place itself: nothing to point at.
    let overhead = WeatherRadarSummary.make(
      tile: Self.tile(wet: [(own.row, own.col, 3), (own.row + 8, own.col, 3)]),
      coordinate: Self.austin)
    #expect(overhead.here == .heavy)
    #expect(overhead.nearestHeavy == nil)
  }

  /// Outside a partial picture's bounds, `here` is nil — "this picture does not reach here",
  /// which is a different sentence from "dry here" and must never be shown as one. The cells out
  /// there are level 0 on the wire and are not counted as dry ground either.
  @Test
  func `a place outside the picture has no reading at all`() {
    let own = Self.austinCell
    let summary = WeatherRadarSummary.make(
      tile: Self.tile(
        bounds: MeshWXRadarBounds(row0: 0, row1: UInt8(own.row - 1), col0: 0, col1: 31),
        wet: [(own.row - 3, own.col, 2)]),
      coordinate: Self.austin)
    #expect(summary.here == nil)
    #expect(summary.nearest?.level == .moderate, "what the picture does reach is still reported")
    #expect(!summary.isAllDry)
  }

  @Test
  func `a picture with nothing on it says so`() {
    let summary = WeatherRadarSummary.make(tile: Self.tile(), coordinate: Self.austin)
    #expect(summary.here == MeshWXRadarLevel.none)
    #expect(summary.nearest == nil)
    #expect(summary.isAllDry)
  }

  // MARK: - The card

  @Test
  func `the card has three states and no fourth`() {
    let now = Self.taken.addingTimeInterval(600)
    #expect(WeatherRadarCard.make(place: nil, tiles: [Self.tile()], now: now) == .noCoordinate)
    #expect(WeatherRadarCard.make(place: Self.place(), tiles: [], now: now) == .missing)
    // Held only for somewhere else, which is the same nothing.
    #expect(WeatherRadarCard.make(
      place: Self.place(), tiles: [Self.tile(south: 32, west: -98)], now: now) == .missing)

    let card = WeatherRadarCard.make(place: Self.place(), tiles: [Self.tile(wet: [(0, 0, 1)])], now: now)
    let picture = try! #require(card.picture)
    #expect(picture.age.minutes == 10)
    #expect(!picture.isWiderThanAsked)
    #expect(!picture.isCoarse)
    #expect(!picture.isPartial)
    #expect(picture.summary.here == MeshWXRadarLevel.none)
  }

  /// The place page asks at the narrowest width, so anything wider is a picture somebody asked
  /// for at another width and the card says so quietly.
  @Test
  func `a wider tile than the page would ask for is marked`() {
    let now = Self.taken.addingTimeInterval(60)
    let card = WeatherRadarCard.make(
      place: Self.place(), tiles: [Self.tile(south: 28, west: -100, zoom: 2)], now: now)
    #expect(card.picture?.isWiderThanAsked == true)
  }

  /// The radar screen's width control asks a different question from the card: not "which picture
  /// is this place's" but "what is held for this width". A partial tile whose bounds stop short of
  /// the place is held for its width, and the summary's nil `here` is what lets the screen say the
  /// picture does not reach the place rather than showing nothing.
  @Test
  func `a width holds a tile the card would not call the place's picture`() {
    let now = Self.taken.addingTimeInterval(60)
    let short = Self.tile(bounds: MeshWXRadarBounds(row0: 0, row1: 5, col0: 0, col1: 31))
    #expect(WeatherRadarCard.make(place: Self.place(), tiles: [short], now: now) == .missing)

    let width = WeatherRadarCard.width(0, place: Self.place(), tiles: [short], now: now)
    let picture = try! #require(width.picture)
    #expect(picture.isPartial)
    #expect(picture.summary.here == nil, "this picture does not reach the place")

    // Nothing held for that width is "Not asked for yet"; no coordinate is no section at all.
    #expect(WeatherRadarCard.width(2, place: Self.place(), tiles: [short], now: now) == .missing)
    #expect(WeatherRadarCard.width(0, place: nil, tiles: [short], now: now) == .noCoordinate)
    // And it is the width's own square, never a neighbouring one: the zoom 1 tile of the same
    // place is a different square and does not answer for zoom 0.
    let regional = Self.tile(south: 28, west: -100, zoom: 1)
    #expect(WeatherRadarCard.width(0, place: Self.place(), tiles: [regional], now: now) == .missing)
    #expect(WeatherRadarCard.width(1, place: Self.place(), tiles: [regional], now: now).picture != nil)
    // Past two hours a width holds nothing either.
    #expect(WeatherRadarCard.width(
      1, place: Self.place(), tiles: [regional],
      now: Self.taken.addingTimeInterval(121 * 60)) == .missing)
  }

  /// The ask is the coordinate and never the place's name: the lattice turns the coordinate into
  /// a tile this phone can name before the answer arrives (spec revision 11, §7D).
  @Test
  func `the ask names the coordinate and the width`() {
    #expect(WeatherRadarCard.ask(place: nil) == nil)
    #expect(WeatherRadarCard.ask(place: Self.place())
      == .radar(latitude: 30.27, longitude: -97.74, zoom: 0))
    #expect(WeatherRadarCard.ask(place: Self.place(), zoom: 2)
      == .radar(latitude: 30.27, longitude: -97.74, zoom: 2))
    #expect(WeatherRadarCard.ask(place: Self.place())?.wireText == ">radar 30.270,-97.740")
    // What a width's ask would come back as, so a screen can say what it already holds for it.
    #expect(WeatherRadarCard.tile(for: Self.place()) == MeshWXRadarTile(south: 29, west: -99, zoom: 0))
    #expect(WeatherRadarCard.tile(for: Self.place(), zoom: 2)
      == MeshWXRadarTile(south: 28, west: -100, zoom: 2))
  }

  /// Every bot's tiles in one list: the lattice is shared, so a tile of this square from the bot
  /// next door is a picture of the same storm.
  @Test
  func `the card reads every bot's tiles`() {
    var first = WeatherBotState(botID: 1)
    first.radarTiles = [Self.tile(south: 32, west: -98)]
    var second = WeatherBotState(botID: 2)
    second.radarTiles = [Self.tile(wet: [(0, 0, 1)])]
    let tiles = WeatherRadarCard.tiles(in: [1: first, 2: second])
    #expect(tiles.count == 2)
    #expect(WeatherRadarCard.make(
      place: Self.place(), tiles: tiles, now: Self.taken.addingTimeInterval(60)).picture != nil)
  }

  // MARK: - The cells as rectangles

  /// One rectangle per horizontal run of one level, so a map draws hundreds of shapes and not a
  /// thousand.
  @Test
  func `a row of one level is one rectangle`() {
    let radar = Self.tile(wet: (0..<5).map { (3, $0 + 2, UInt8(1)) }).radar
    let rectangles = WeatherRadarCells.rectangles(radar: radar)
    #expect(rectangles.count == 1)
    let box = try! #require(rectangles.first)
    #expect(box.level == .light)
    let cell = 2.0 / 32
    #expect(abs(box.west - (-99 + 2 * cell)) < 1e-9)
    #expect(abs(box.east - (-99 + 7 * cell)) < 1e-9)
    #expect(abs(box.north - (31 - 3 * cell)) < 1e-9)
    #expect(abs(box.south - (31 - 4 * cell)) < 1e-9)
  }

  @Test
  func `runs break on a change of level, on a dry cell and at the row's end`() {
    let radar = Self.tile(wet: [
      (0, 0, 1), (0, 1, 1), (0, 2, 2),   // two runs: light then moderate
      (0, 4, 1),                          // a dry cell between them starts a third
      (1, 30, 3), (1, 31, 3),             // a run that ends at the row's edge
      (2, 0, 1)                           // a row of its own, never merged upwards
    ]).radar
    let rectangles = WeatherRadarCells.rectangles(radar: radar)
    #expect(rectangles.count == 5)
    #expect(rectangles.map(\.level) == [.light, .moderate, .light, .heavy, .light])
    // Nothing is merged vertically: the two single cells in rows 0 and 2 stay apart.
    #expect(Set(rectangles.map(\.north)).count == 3)
  }

  @Test
  func `dry cells draw nothing`() {
    #expect(WeatherRadarCells.rectangles(radar: Self.tile().radar).isEmpty)
    #expect(WeatherRadarCells.unknownRectangles(radar: Self.tile().radar).isEmpty)
  }

  /// The cells outside a partial tile's bounds come back separately and are never merged into the
  /// wet ones: drawn in the dry colour they would claim clear weather over ground the mosaic
  /// never covered.
  @Test
  func `unknown cells are returned on their own`() {
    let radar = Self.tile(
      bounds: MeshWXRadarBounds(row0: 0, row1: 9, col0: 0, col1: 31),
      wet: [(2, 3, 1)]).radar
    let wet = WeatherRadarCells.rectangles(radar: radar)
    #expect(wet.count == 1)
    #expect(wet.first?.level == .light)

    let unknown = WeatherRadarCells.unknownRectangles(radar: radar)
    #expect(unknown.count == 22, "rows 10 to 31, each one full-width run")
    #expect(unknown.allSatisfy { $0.level == MeshWXRadarLevel.none })
    #expect(unknown.allSatisfy { abs($0.west - (-99)) < 1e-9 && abs($0.east - (-97)) < 1e-9 })
    // The southern edge of the tile is the southern edge of the last unknown row.
    #expect(abs(unknown.map(\.south).min()! - 29) < 1e-9)
  }

  @Test
  func `a coarse tile's rectangles are twice the size`() {
    let radar = Self.tile(isCoarse: true, wet: [(0, 0, 2)]).radar
    let box = try! #require(WeatherRadarCells.rectangles(radar: radar).first)
    #expect(abs((box.east - box.west) - 2.0 / 16) < 1e-9)
    #expect(abs((box.north - box.south) - 2.0 / 16) < 1e-9)
  }

  // MARK: - The refusals

  @Test
  func `the wire's reasons split into the four the screen says different things for`() {
    #expect(WeatherRadarRefusal(reason: .noData) == .noPicture)
    #expect(WeatherRadarRefusal(reason: .unknownLocation) == .unknownPlace)
    #expect(WeatherRadarRefusal(reason: .unsupported) == .unsupported)
    #expect(WeatherRadarRefusal(reason: .rateLimited) == .sentRecently)
    #expect(WeatherRadarRefusal(reason: .botError) == .other(.botError))
    #expect(WeatherRadarRefusal(reason: .other(9)) == .other(.other(9)))
  }

  // MARK: - The page snapshot

  /// The card rides in the snapshot exactly as the forecast card does, so a view draws it and
  /// asks the model nothing.
  @Test
  func `the page snapshot carries the radar card`() {
    var state = WeatherPhoneFixture.state()
    state.radarTiles = [Self.tile(
      takenMinutes: WeatherPhoneFixture.nowMinutes - 8,
      wet: [(0, 0, 1)],
      receivedAt: WeatherPhoneFixture.now)]
    let snapshot = WeatherScreenSnapshot.make(
      WeatherScreenSnapshot.Inputs(
        states: [WeatherPhoneFixture.botID: state],
        bots: [],
        preferredBotID: nil,
        place: Self.place(),
        isRadioConnected: true,
        firmwareSupportsWeather: true,
        firmwareVersion: "1.15.0",
        hasWeatherChannel: true,
        session: WeatherSessionInfo(),
        now: WeatherPhoneFixture.now,
        calendar: WeatherPhoneFixture.calendar),
      geometry: UnloadedGeometry(),
      tables: .shared)
    #expect(snapshot.radar.picture?.age.minutes == 8)

    // No coordinate, no section.
    let noPlace = WeatherScreenSnapshot.make(
      WeatherScreenSnapshot.Inputs(
        states: [WeatherPhoneFixture.botID: state],
        bots: [],
        preferredBotID: nil,
        place: nil,
        isRadioConnected: true,
        firmwareSupportsWeather: true,
        firmwareVersion: "1.15.0",
        hasWeatherChannel: true,
        session: WeatherSessionInfo(),
        now: WeatherPhoneFixture.now,
        calendar: WeatherPhoneFixture.calendar),
      geometry: UnloadedGeometry(),
      tables: .shared)
    #expect(noPlace.radar == .noCoordinate)
  }
}
