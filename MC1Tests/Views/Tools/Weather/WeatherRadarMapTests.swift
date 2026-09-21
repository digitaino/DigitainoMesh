import CoreLocation
import Foundation
import MC1Services
import MeshWX
import Testing
import UIKit

@testable import MC1

/// How a radar tile reaches the map (docs/MESHWX_UI.md §18).
///
/// The rules being checked are the ones a screenshot would not catch: the cells go **under** the
/// alert shapes and the alert shapes carry no fill, so a warning polygon can never hide the
/// precipitation that issued it; ground the mosaic never covered is drawn in its own grey and
/// never left looking dry; and the three radar colours are the picture's own and not one of the
/// alert tints.
@Suite("Weather radar map")
struct WeatherRadarMapTests {
  typealias F = WeatherFormattingTests

  static let tile = MeshWXRadarTile(south: 29, west: -99, zoom: 0)
  static let austin = WeatherPlace(
    kind: .searched, coordinate: MeshWXCoordinate(latitude: 30.2672, longitude: -97.7431),
    label: "Austin, TX", uncertaintyKilometres: 5)

  /// A whole 32 × 32 tile with the given cells wet, everything else dry.
  static func radar(
    _ wet: [(row: Int, col: Int, level: MeshWXRadarLevel)],
    bounds: MeshWXRadarBounds? = nil,
    coarse: Bool = false
  ) -> MeshWXRadar {
    let size = coarse ? 16 : 32
    var cells = [UInt8](repeating: 0, count: size * size)
    for cell in wet { cells[cell.row * size + cell.col] = cell.level.rawValue }
    return MeshWXRadar(
      takenMinutes: MeshWXPresentation.unixMinutes(for: F.now), south: 29, west: -99, zoom: 0,
      product: 1, isCoarse: coarse, bounds: bounds, cells: cells)
  }

  static func drawing(
    _ radar: MeshWXRadar?,
    warnings: [MeshWXWarning] = [],
    place: WeatherPlace? = WeatherRadarMapTests.austin
  ) -> WeatherMapDrawing {
    WeatherRadarDrawing.make(
      WeatherRadarMapKey(radar: radar, tile: tile, warnings: warnings, place: place),
      tables: .shared, geometry: .shared)
  }

  /// A polygon warning, so the drawing needs no outline bundle to have a shape to lay down.
  static let tornado = MeshWXWarning(
    identity: MeshWXWarningIdentity(event: 2, office: 40, etn: 17),
    expiresMinutes: MeshWXPresentation.unixMinutes(for: F.now) + 60,
    polygon: [
      MeshWXCoordinate(latitude: 30.0, longitude: -98.5),
      MeshWXCoordinate(latitude: 30.5, longitude: -98.5),
      MeshWXCoordinate(latitude: 30.5, longitude: -98.0),
      MeshWXCoordinate(latitude: 30.0, longitude: -98.0)
    ])

  // MARK: - Cells

  /// One overlay per level, and a **run** per overlay feature rather than a cell: a 32 × 32 tile
  /// is 1,024 shapes and MapLibre redraws every overlay on every pan.
  @Test
  func `each level is one overlay, and a row of equal cells is one shape`() throws {
    let overlays = Self.drawing(Self.radar([
      (0, 0, .light), (0, 1, .light), (0, 2, .light), (0, 4, .heavy), (5, 7, .moderate)
    ])).overlays
    let ids = overlays.map(\.id)
    #expect(ids.contains("radar-\(MeshWXRadarLevel.light.rawValue)"))
    #expect(ids.contains("radar-\(MeshWXRadarLevel.moderate.rawValue)"))
    #expect(ids.contains("radar-\(MeshWXRadarLevel.heavy.rawValue)"))
    let light = try #require(overlays.first { $0.id == "radar-\(MeshWXRadarLevel.light.rawValue)" })
    #expect(light.features.count == 1)
    // A level nothing on the picture carries gets no overlay at all.
    #expect(!Self.drawing(Self.radar([(0, 0, .light)])).overlays
      .contains { $0.id == "radar-\(MeshWXRadarLevel.heavy.rawValue)" })
  }

  /// 55% and **no outline**: the rectangles are runs, not cells, so a hairline would draw the
  /// seams where a run happened to end rather than anything in the weather.
  @Test
  func `cells are filled at about half and carry no outline`() throws {
    let light = try #require(Self.drawing(Self.radar([(0, 0, .light)])).overlays.first)
    guard case let .weightedFill(paint) = light.paint else {
      Issue.record("expected a fill, got \(light.paint)")
      return
    }
    #expect(paint.opacity == WeatherRadarPalette.fillOpacity...WeatherRadarPalette.fillOpacity)
    #expect(paint.outlineColor == nil)
    #expect(paint.color == WeatherRadarPalette.light)
  }

  /// The one part of a radar picture that says nothing: drawn in the dry colour it would claim
  /// clear weather over ground the mosaic never covered.
  @Test
  func `cells outside a partial picture get their own grey and are never drawn as dry`() throws {
    let partial = Self.radar(
      [(4, 4, .heavy)], bounds: MeshWXRadarBounds(row0: 0, row1: 15, col0: 0, col1: 15))
    let overlays = Self.drawing(partial).overlays
    let unknown = try #require(overlays.first { $0.id == "radar-unknown" })
    #expect(!unknown.features.isEmpty)
    guard case let .weightedFill(paint) = unknown.paint else {
      Issue.record("expected a fill, got \(unknown.paint)")
      return
    }
    #expect(paint.color == WeatherRadarPalette.unknown)
    // A whole tile has no unknown overlay at all.
    #expect(!Self.drawing(Self.radar([(4, 4, .heavy)])).overlays.contains { $0.id == "radar-unknown" })
  }

  // MARK: - The alerts over them

  /// Outlines only. A tinted fill the way §17 fills one would cover exactly the cells that made
  /// the warning issue.
  @Test
  func `alerts are drawn as outlines over the cells, never as fills`() {
    let overlays = Self.drawing(Self.radar([(0, 0, .heavy)]), warnings: [Self.tornado]).overlays
    let ids = overlays.map(\.id)
    #expect(ids.contains { $0.hasPrefix("weather-outline-") })
    #expect(!ids.contains { $0.hasPrefix("weather-fill-") })
  }

  @Test
  func `the cells are laid down before the alert shapes`() throws {
    let ids = Self.drawing(Self.radar([(0, 0, .heavy)]), warnings: [Self.tornado]).overlays.map(\.id)
    let cells = try #require(ids.firstIndex { $0.hasPrefix("radar-") })
    let alerts = try #require(ids.firstIndex { $0.hasPrefix("weather-outline-") })
    #expect(cells < alerts)
  }

  /// The alert map is still the alert map: this one only changes how the shapes are painted.
  @Test
  func `the alert map keeps its fills`() {
    let ids = WeatherMapDrawing.make(
      warnings: [Self.tornado], place: Self.austin, framesPlace: true, loadOutlines: false,
      tables: .shared, geometry: .shared).overlays.map(\.id)
    #expect(ids.contains { $0.hasPrefix("weather-fill-") })
    #expect(ids.contains { $0.hasPrefix("weather-outline-") })
  }

  // MARK: - Framing and the place

  /// The square is the answer. The lattice already puts the place a quarter of the span inside
  /// it, and a camera fitted to the alerts instead would frame a warning two states away.
  @Test
  func `the camera is the tile, with none of the alert map's padding`() throws {
    let bounds = try #require(Self.drawing(Self.radar([]), warnings: [Self.tornado]).bounds)
    #expect(bounds.minLatitude == 29)
    #expect(bounds.maxLatitude == 31)
    #expect(bounds.minLongitude == -99)
    #expect(bounds.maxLongitude == -97)
  }

  /// A width nothing is held for is still a map of the square the ask would fill.
  @Test
  func `an empty width still frames its square`() {
    let drawing = Self.drawing(nil)
    #expect(drawing.overlays.isEmpty)
    #expect(drawing.bounds?.minLatitude == 29)
  }

  /// The neutral dot, never the pink dropped pin (§3.1 U-17); and where the place is where the
  /// phone is, the map's own location dot does the job.
  @Test
  func `a searched place gets the neutral dot and a current place leaves it to the map`() {
    #expect(Self.drawing(Self.radar([])).points.map(\.pinStyle) == [.locationFix])
    let current = WeatherPlace(
      kind: .current, coordinate: Self.austin.coordinate, label: "Austin, TX",
      uncertaintyKilometres: 0.5, locatedAt: F.now)
    #expect(Self.drawing(Self.radar([]), place: current).points.isEmpty)
    #expect(Self.drawing(Self.radar([]), place: nil).points.isEmpty)
  }

  // MARK: - Colour

  /// Precipitation and a warning are two different claims. A heavy cell in the Tornado Warning
  /// red would make every squall line read as a warning polygon.
  @Test
  func `the three radar colours are none of the alert tints`() {
    let alerts = Set(MeshWXEventTint.allCases.map { WeatherFormatting.uiColor(for: $0) })
    for level in [MeshWXRadarLevel.light, .moderate, .heavy] {
      #expect(!alerts.contains(WeatherRadarPalette.uiColor(for: level)))
    }
    // And the three are told apart from each other.
    #expect(Set([MeshWXRadarLevel.light, .moderate, .heavy]
      .map { WeatherRadarPalette.uiColor(for: $0) }).count == 3)
  }
}

/// What the radar screens ask for, and what they must never make Update ask for
/// (docs/MESHWX_UI.md §18, spec revision 11, §3).
@Suite("Weather radar requests")
@MainActor
struct WeatherRadarRequestTests {
  typealias F = WeatherFormattingTests

  static let botID: UInt16 = 0x041D
  static let bot = WeatherBot(
    publicKey: Data([0x1D, 0x04]) + Data(repeating: 0x55, count: 30), name: "WX-AUS",
    latitude: 30.2672, longitude: -97.7431, lastAdvert: F.now)
  static let austin = WeatherPlace(
    kind: .searched, coordinate: MeshWXCoordinate(latitude: 30.2672, longitude: -97.7431),
    label: "Austin, TX", uncertaintyKilometres: 5)

  static func state(withTile: Bool) -> WeatherBotState {
    var state = WeatherBotState(botID: botID)
    guard withTile else { return state }
    var cells = [UInt8](repeating: 0, count: 1024)
    // Austin's own cell in the zoom 0 tile: row 11, column 20.
    cells[11 * 32 + 20] = MeshWXRadarLevel.moderate.rawValue
    state.radarTiles = [WeatherStoredRadarTile(
      tile: MeshWXRadarTile(south: 29, west: -99, zoom: 0),
      radar: MeshWXRadar(
        takenMinutes: MeshWXPresentation.unixMinutes(for: F.now) - 12, south: 29, west: -99,
        zoom: 0, product: 1, isCoarse: false, cells: cells),
      receivedAt: F.now, source: .goesSatellite)]
    return state
  }

  static func snapshot(withTile: Bool) -> WeatherScreenSnapshot {
    WeatherScreenSnapshot.make(
      WeatherScreenSnapshot.Inputs(
        states: [botID: state(withTile: withTile)], bots: [bot], preferredBotID: nil,
        place: austin, isRadioConnected: true, firmwareSupportsWeather: true,
        firmwareVersion: "v1.15.0", hasWeatherChannel: true,
        session: WeatherSessionInfo(startedAt: F.now), now: F.now, calendar: F.calendar),
      geometry: MeshWXGeometry.shared, tables: .shared)
  }

  /// **Radar is not part of Update** (spec revision 11, §4: request-only). Update is the one tap
  /// that spends several packets without naming each of them, and a picture that arrives because
  /// somebody pulled to refresh is a packet nobody asked for.
  @Test
  func `Update never plans a radar tile, held or not`() {
    for withTile in [false, true] {
      let plan = WeatherUpdatePlan.make(
        snapshot: Self.snapshot(withTile: withTile), sourceState: Self.state(withTile: withTile),
        tables: .shared, now: F.now)
      #expect(!plan.requests.contains { if case .radar = $0 { return true } else { return false } })
    }
  }

  /// The card is built with the rest of the snapshot, from every radio's tiles: the lattice is
  /// shared, so a tile of this square from the radio next door is a picture of the same storm.
  @Test
  func `the place page's card is held when a tile reaches the place, and missing otherwise`() throws {
    #expect(Self.snapshot(withTile: false).radar == .missing)
    let picture = try #require(Self.snapshot(withTile: true).radar.picture)
    #expect(picture.summary.here == .moderate)
    #expect(picture.age.minutes == 12)
    #expect(!picture.isWiderThanAsked)
  }

  /// A place with no coordinate has no section at all, which is a state and not an empty card.
  @Test
  func `a place with no coordinate has no radar section`() {
    let empty = WeatherScreenSnapshot.make(
      WeatherScreenSnapshot.Inputs(
        states: [:], bots: [Self.bot], preferredBotID: nil, place: nil, isRadioConnected: true,
        firmwareSupportsWeather: true, firmwareVersion: "v1.15.0", hasWeatherChannel: true,
        session: WeatherSessionInfo(startedAt: F.now), now: F.now, calendar: F.calendar),
      geometry: MeshWXGeometry.shared, tables: .shared)
    #expect(empty.radar == .noCoordinate)
  }

  /// The ask carries the coordinate and the width, and the width is the only thing that changes:
  /// the lattice turns the coordinate into a square this phone can name before the answer comes.
  @Test
  func `each width asks for its own square at the same one packet`() throws {
    let local = try #require(WeatherRadarCard.ask(place: Self.austin, zoom: 0))
    let wide = try #require(WeatherRadarCard.ask(place: Self.austin, zoom: 2))
    #expect(local == .radar(latitude: 30.2672, longitude: -97.7431, zoom: 0))
    #expect(local.wireText == ">radar 30.267,-97.743")
    #expect(wide.wireText == ">radar 30.267,-97.743 z2")
    #expect(WeatherRadarCard.ask(place: nil) == nil)
    // Refused under `x`, not `r`: `r` is `>rain`, and a refusal has to say which it refuses.
    #expect(local.requestLetter == "x")
  }

  /// The radar screen offers three of the four widths the wire has.
  @Test
  func `the width control offers zoom 0, 1 and 2 and stops there`() {
    #expect(WeatherRadarView.offeredZooms == [0, 1, 2])
    #expect(WeatherRadarView.widestOffered == 2)
    #expect(Int(WeatherRadarView.widestOffered) < Int(MeshWXWire.maxRadarZoom))
  }
}
