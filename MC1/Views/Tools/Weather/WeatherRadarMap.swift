import CoreLocation
import MC1Services
import MeshWX
import SwiftUI
import UIKit

/// The three colours a radar picture is drawn in, and the grey for ground the picture never
/// covered (docs/MESHWX_UI.md §18).
///
/// **Their own constants, never the alert tints.** Precipitation and a warning are two different
/// claims, and a screen that draws both has to say which is which without a legend being read: a
/// heavy cell in the Tornado Warning red would make every squall line look like a warning polygon.
/// Literal sRGB rather than system colours for the same reason the NWS greens are
/// (``WeatherFormatting/color(for:)``), and because the bot, the web client and this app have to
/// agree on one picture — a colour that shifted with the theme would make three clients three
/// pictures.
enum WeatherRadarPalette {
  /// 20 dBZ and up: drizzle to light rain.
  static let light = UIColor(red: 0.20, green: 0.70, blue: 0.36, alpha: 1)
  /// 35 dBZ and up.
  static let moderate = UIColor(red: 0.96, green: 0.70, blue: 0.11, alpha: 1)
  /// 50 dBZ and up: the cores.
  static let heavy = UIColor(red: 0.85, green: 0.17, blue: 0.20, alpha: 1)
  /// Inside the tile, outside the radar picture. Deliberately colourless and deliberately
  /// **not** absent: a cell the mosaic never covered drawn as dry claims clear weather over
  /// ground nobody looked at (spec revision 11, §7D).
  static let unknown = UIColor(white: 0.55, alpha: 1)

  /// How solid a cell reads. 0.55 leaves the state and county lines under it legible, which is
  /// what tells a reader where the picture is of.
  static let fillOpacity = 0.55
  /// The unknown grey sits under the caution line that names it, so it is quieter than the cells.
  static let unknownOpacity = 0.35

  static func uiColor(for level: MeshWXRadarLevel) -> UIColor {
    switch level {
    case .none: unknown
    case .light: light
    case .moderate: moderate
    case .heavy: heavy
    }
  }

  /// The same colour for a legend swatch.
  static func color(for level: MeshWXRadarLevel) -> Color {
    Color(uiColor: uiColor(for: level))
  }
}

/// What a loop's frames are drawn from: everything a single picture's key holds but the picture,
/// and the frames' pictures oldest first (spec revision 13, §7D.4).
struct WeatherRadarLoopKey: Hashable {
  var base: WeatherRadarMapKey
  var radars: [MeshWXRadar]
}

/// What to redraw a radar map on. Never the clock: an unchanged picture is not re-shaded every 30
/// seconds, and a tile is a thousand cells.
struct WeatherRadarMapKey: Hashable {
  /// The picture itself, or nil for a width nothing is held for — which is still a map, framed on
  /// the square the ask would name.
  var radar: MeshWXRadar?
  /// The square the camera frames. Usually the picture's own; on the Detail width with the Local
  /// fallback drawn it is still the one-degree square that was picked (spec revision 13, §3).
  var tile: MeshWXRadarTile
  /// Empty on the place page's card, which draws the picture and nothing over it.
  var warnings: [MeshWXWarning] = []
  var place: WeatherPlace?
  var isGeometryLoaded = false
  /// The detail square around a spot picked on the radar screen's map, outlined (spec revision
  /// 13, §3). Nil everywhere else, which draws exactly what it drew before.
  var outline: MeshWXRadarTile?
}

/// A radar tile as a map draws it (docs/MESHWX_UI.md §18).
///
/// Cells at the bottom, the alert shapes over them as **outlines only**, the place on top. The
/// order is the whole argument: the screen exists to show where the precipitation is, and an
/// alert polygon filled the way §17 fills it would cover exactly the cells that made it issue.
///
/// Built from ``WeatherRadarCells``, which has already turned 1,024 cells into a few hundred runs:
/// MapLibre redraws every overlay on every pan, and a thousand of them is the difference between
/// a map that moves and one that does not.
enum WeatherRadarDrawing {
  static func make(
    _ key: WeatherRadarMapKey, tables: MeshWXTables, geometry: MeshWXGeometry
  ) -> WeatherMapDrawing {
    drawing(cells: key.radar, over: furniture(key, tables: tables, geometry: geometry))
  }

  /// Every frame of a loop, each drawn **once** (spec revision 13, §3): the player steps through
  /// these and never builds a drawing on a step. The alerts, the place and the picked square are
  /// the same on every frame, so they are gathered once and laid over each frame's own cells.
  static func loop(
    _ key: WeatherRadarLoopKey, tables: MeshWXTables, geometry: MeshWXGeometry
  ) -> [WeatherMapDrawing] {
    let base = furniture(key.base, tables: tables, geometry: geometry)
    return key.radars.map { drawing(cells: $0, over: base) }
  }

  /// The cells at the bottom, everything else as it was gathered.
  private static func drawing(cells radar: MeshWXRadar?, over base: WeatherMapDrawing) -> WeatherMapDrawing {
    var drawing = base
    // Unknown first, so a wet run that reaches the edge of the picture is never drawn under the
    // grey that says the picture stops there.
    drawing.overlays = (radar.map { cellOverlays(radar: $0) } ?? []) + base.overlays
    return drawing
  }

  /// Everything over the cells: the alert outlines, the picked square, the place, and the camera.
  private static func furniture(
    _ key: WeatherRadarMapKey, tables: MeshWXTables, geometry: MeshWXGeometry
  ) -> WeatherMapDrawing {
    var overlays: [MapOverlay] = []
    // The alerts this device holds, as outlines. Areas the bundle has no outline for are simply
    // not drawn here: the alert map is where an alert is accounted for, and a dropped pin over a
    // radar picture would be a marker for something this screen is not about.
    let shapes = WeatherMapDrawing.shapes(
      warnings: key.warnings, loadOutlines: false, tables: tables, geometry: geometry)
    overlays.append(contentsOf: WeatherMapDrawing.overlays(shapes.shapes, fills: false))
    // The picked square on top of everything but the place, in the selection ring the signal
    // mapper uses: the label colour, never a radar or an alert tint, so it reads as "here" and
    // not as weather.
    if let outline = key.outline {
      overlays.append(squareOutline(outline))
    }

    var points: [MapPoint] = []
    if let place = key.place, place.kind != .current {
      // The neutral dot, the same one §3.1 U-17 chose for the alert maps: on a map of coloured
      // weather a hot-pink dropped pin for *you* reads as one more piece of weather. A place that
      // is where the phone is gets the map's own location dot instead.
      points.append(MapPoint(
        id: WeatherMapDrawing.pointID("radar-place"),
        coordinate: WeatherMapDrawing.coordinate(place.coordinate),
        pinStyle: .locationFix, label: nil, isClusterable: false, hopIndex: 0, badgeText: nil))
    }

    // Framed on the **tile**, exactly, with none of the alert map's padding: the square is the
    // answer, the place sits at least a quarter of the span inside it by the lattice rule, and a
    // camera that fitted the alerts instead would frame a warning two states away.
    let tile = key.tile
    return WeatherMapDrawing(
      overlays: overlays,
      points: points,
      bounds: WeatherMapBounds(
        minLatitude: tile.south, maxLatitude: tile.north,
        minLongitude: tile.west, maxLongitude: tile.east))
  }

  /// A tile's edge as a closed ring.
  private static func squareOutline(_ tile: MeshWXRadarTile) -> MapOverlay {
    let box = WeatherRadarRectangle(
      level: .none, south: tile.south, west: tile.west, north: tile.north, east: tile.east)
    var corners = ring(box)
    corners.append(corners[0])
    return MapOverlay(
      id: "radar-detail-square",
      features: [MapOverlay.Feature(id: "square", geometry: .polyline(corners), weight: 1)],
      paint: .weightedLine(MapOverlay.WeightedLine(
        color: .label, width: 2.5...2.5, opacity: 0.9...0.9,
        casing: MapOverlay.Casing(extraWidth: 2))))
  }

  /// One overlay per level, plus one for the cells outside a partial picture. Colour is per
  /// overlay in this map's vocabulary (``MapOverlay``), which is why the runs are grouped by level
  /// rather than drawn one shape at a time.
  ///
  /// No outline on the fills: the rectangles are *runs*, not cells, so a hairline would draw the
  /// seams where a run happened to end rather than anything in the weather.
  private static func cellOverlays(radar: MeshWXRadar) -> [MapOverlay] {
    var overlays: [MapOverlay] = []
    let unknown = WeatherRadarCells.unknownRectangles(radar: radar)
    if !unknown.isEmpty {
      overlays.append(overlay(
        id: "radar-unknown", rectangles: unknown, color: WeatherRadarPalette.unknown,
        opacity: WeatherRadarPalette.unknownOpacity))
    }
    let byLevel = Dictionary(grouping: WeatherRadarCells.rectangles(radar: radar), by: \.level)
    for level in [MeshWXRadarLevel.light, .moderate, .heavy] {
      guard let rectangles = byLevel[level], !rectangles.isEmpty else { continue }
      overlays.append(overlay(
        id: "radar-\(level.rawValue)", rectangles: rectangles,
        color: WeatherRadarPalette.uiColor(for: level), opacity: WeatherRadarPalette.fillOpacity))
    }
    return overlays
  }

  private static func overlay(
    id: String, rectangles: [WeatherRadarRectangle], color: UIColor, opacity: Double
  ) -> MapOverlay {
    MapOverlay(
      id: id,
      features: rectangles.enumerated().map { index, box in
        MapOverlay.Feature(id: "\(id)-\(index)", geometry: .polygon(ring(box)), weight: 1)
      },
      // Every cell of one level is the same cell of that level: the weight ramp carries nothing
      // here, so both ends of it are the one opacity.
      paint: .weightedFill(MapOverlay.WeightedFill(color: color, opacity: opacity...opacity)))
  }

  /// A box as a ring, anticlockwise from its south-west corner. The map closes it.
  private static func ring(_ box: WeatherRadarRectangle) -> [CLLocationCoordinate2D] {
    [
      CLLocationCoordinate2D(latitude: box.south, longitude: box.west),
      CLLocationCoordinate2D(latitude: box.south, longitude: box.east),
      CLLocationCoordinate2D(latitude: box.north, longitude: box.east),
      CLLocationCoordinate2D(latitude: box.north, longitude: box.west)
    ]
  }
}
