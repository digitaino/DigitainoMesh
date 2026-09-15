import CoreLocation
import MapLibre
import MC1Services
import MeshWX
import SwiftUI

/// The camera box around what a map draws, as plain numbers.
struct WeatherMapBounds: Sendable, Equatable {
  var minLatitude: Double
  var maxLatitude: Double
  var minLongitude: Double
  var maxLongitude: Double

  var mapLibre: MLNCoordinateBounds {
    MLNCoordinateBounds(
      sw: CLLocationCoordinate2D(latitude: minLatitude, longitude: minLongitude),
      ne: CLLocationCoordinate2D(latitude: maxLatitude, longitude: maxLongitude))
  }
}

/// What to key a drawing on: the warnings, the place, and whether outlines have loaded. Never the
/// clock: an unchanged set of alerts is not redrawn every 30 seconds.
struct WeatherMapKey: Hashable {
  var warnings: [MeshWXWarning]
  var place: WeatherPlace?
  var isGeometryLoaded: Bool
}

/// Everything a weather map draws, built off the main actor: overlays, pins and the camera box.
///
/// `@unchecked Sendable` because `MapOverlay` carries `UIColor`, which is immutable; the values
/// are built in a detached task and only read afterwards.
struct WeatherMapDrawing: @unchecked Sendable, Equatable {
  var overlays: [MapOverlay] = []
  var points: [MapPoint] = []
  var bounds: WeatherMapBounds?

  /// A storm-based product's own polygon; otherwise the outlines of the areas it names, or,
  /// while outlines are not loaded and for any area the bundle has no outline for, a pin at the
  /// area's centre.
  ///
  /// - Parameters:
  ///   - loadOutlines: parse the outlines if they are not loaded yet. False draws outlines only
  ///     when they already are.
  ///   - framesPlace: include the place in the camera box, not only the alerts.
  static func make(
    warnings: [MeshWXWarning],
    place: WeatherPlace?,
    framesPlace: Bool,
    loadOutlines: Bool,
    tables: MeshWXTables,
    geometry: MeshWXGeometry
  ) -> WeatherMapDrawing {
    struct Shape {
      var tint: MeshWXEventTint
      var rings: [[CLLocationCoordinate2D]]
    }
    var shapes: [Shape] = []
    var points: [MapPoint] = []
    var framed: [CLLocationCoordinate2D] = []
    let useOutlines = loadOutlines || geometry.isLoaded

    for warning in warnings {
      let tint = MeshWXPresentation.tint(forVTEC: tables.vtec(for: warning.event) ?? "")
      if let polygon = warning.polygon, polygon.count >= 3 {
        let ring = polygon.map(coordinate)
        shapes.append(Shape(tint: tint, rings: [ring]))
        framed.append(contentsOf: ring)
        continue
      }
      var rings: [[CLLocationCoordinate2D]] = []
      for area in WeatherFormatting.uniqueAreas(tables.namedAreas(for: warning)) {
        if useOutlines, let outline = geometry.rings(for: area.ugc) {
          rings.append(contentsOf: outline.filter { $0.count >= 3 }.map { $0.map(coordinate) })
        } else if let lat = area.lat, let lon = area.lon {
          let centre = CLLocationCoordinate2D(latitude: lat, longitude: lon)
          points.append(MapPoint(
            id: pointID("area-\(area.ugc)"), coordinate: centre, pinStyle: .droppedPin,
            label: area.name, isClusterable: false, hopIndex: nil, badgeText: nil))
          framed.append(centre)
        }
      }
      if !rings.isEmpty {
        shapes.append(Shape(tint: tint, rings: rings))
        framed.append(contentsOf: rings.flatMap { $0 })
      }
    }

    // The phone's own location is the map's location dot; only a place that is not where the
    // phone is now gets a pin, and no callout over the map's own labels.
    if let place {
      let centre = coordinate(place.coordinate)
      if place.kind != .current {
        points.append(MapPoint(
          id: pointID("place"), coordinate: centre, pinStyle: .droppedPin,
          label: nil, isClusterable: false, hopIndex: nil, badgeText: nil))
      }
      if framesPlace || framed.isEmpty { framed.append(centre) }
    }

    return WeatherMapDrawing(overlays: overlays(shapes.map { ($0.tint, $0.rings) }), points: points, bounds: bounds(framed))
  }

  /// One fill and one outline overlay per colour: the map colours per overlay, not per feature.
  /// Overlays draw in the order given and alerts arrive most urgent first, so they are laid down in
  /// reverse: a tornado warning's polygon sits on top of the heat advisory zones under it.
  private static func overlays(_ shapes: [(MeshWXEventTint, [[CLLocationCoordinate2D]])]) -> [MapOverlay] {
    var order: [MeshWXEventTint] = []
    var byTint: [MeshWXEventTint: [[CLLocationCoordinate2D]]] = [:]
    for (tint, rings) in shapes.reversed() {
      if byTint[tint] == nil { order.append(tint) }
      byTint[tint, default: []].append(contentsOf: rings)
    }
    return order.flatMap { tint -> [MapOverlay] in
      let rings = byTint[tint] ?? []
      let color = WeatherFormatting.uiColor(for: tint)
      let fill = MapOverlay(
        id: "weather-fill-\(tint.rawValue)",
        features: rings.enumerated().map { MapOverlay.Feature(id: "fill-\($0.offset)", geometry: .polygon($0.element), weight: 1) },
        paint: .weightedFill(MapOverlay.WeightedFill(color: color, opacity: 0.3...0.3)))
      // A separate outline above the fill: the fill's own hairline vanishes over imagery.
      let outline = MapOverlay(
        id: "weather-outline-\(tint.rawValue)",
        features: rings.enumerated().map {
          MapOverlay.Feature(id: "outline-\($0.offset)", geometry: .polyline(closed($0.element)), weight: 1)
        },
        paint: .weightedLine(MapOverlay.WeightedLine(color: color, width: 2...2, opacity: 0.9...0.9)))
      return [fill, outline]
    }
  }

  private static func coordinate(_ value: MeshWXCoordinate) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: value.latitude, longitude: value.longitude)
  }

  private static func closed(_ ring: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
    guard let first = ring.first, let last = ring.last else { return ring }
    guard first.latitude != last.latitude || first.longitude != last.longitude else { return ring }
    return ring + [first]
  }

  /// A stable id from a string, so pins keep their identity across updates.
  private static func pointID(_ key: String) -> UUID {
    var bytes = [UInt8](key.utf8.suffix(16))
    bytes.append(contentsOf: repeatElement(0, count: 16 - bytes.count))
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
  }

  private static func bounds(_ coordinates: [CLLocationCoordinate2D]) -> WeatherMapBounds? {
    guard let first = coordinates.first else { return nil }
    var box = WeatherMapBounds(
      minLatitude: first.latitude, maxLatitude: first.latitude,
      minLongitude: first.longitude, maxLongitude: first.longitude)
    for coordinate in coordinates.dropFirst() {
      box.minLatitude = min(box.minLatitude, coordinate.latitude)
      box.maxLatitude = max(box.maxLatitude, coordinate.latitude)
      box.minLongitude = min(box.minLongitude, coordinate.longitude)
      box.maxLongitude = max(box.maxLongitude, coordinate.longitude)
    }
    let latitudePad = max((box.maxLatitude - box.minLatitude) * 0.2, 0.05)
    let longitudePad = max((box.maxLongitude - box.minLongitude) * 0.2, 0.05)
    return WeatherMapBounds(
      minLatitude: max(-90, box.minLatitude - latitudePad), maxLatitude: min(90, box.maxLatitude + latitudePad),
      minLongitude: max(-180, box.minLongitude - longitudePad), maxLongitude: min(180, box.maxLongitude + longitudePad))
  }
}

/// The shared map showing a prepared drawing, framed on it.
struct WeatherAlertMapView: View {
  @Environment(\.appState) private var appState
  @Environment(\.colorScheme) private var colorScheme

  let drawing: WeatherMapDrawing
  let isInteractive: Bool

  @State private var cameraBounds: MLNCoordinateBounds?
  @State private var cameraVersion = 0
  @State private var isStyleLoaded = false

  @AppStorage(AppStorageKey.mapStyleSelection.rawValue)
  private var mapStyleSelection: MapStyleSelection = .standard
  @AppStorage(AppStorageKey.mapShowLabels.rawValue)
  private var showLabels = AppStorageKey.defaultMapShowLabels
  @AppStorage(AppStorageKey.mapNorthLocked.rawValue)
  private var isNorthLocked = AppStorageKey.defaultMapNorthLocked
  @AppStorage(AppStorageKey.mapColorSchemePreference.rawValue)
  private var mapColorSchemeRaw = AppStorageKey.defaultMapColorSchemePreference

  var body: some View {
    MC1MapView(
      points: drawing.points,
      lines: [],
      overlays: drawing.overlays,
      mapStyle: mapStyleSelection,
      isDarkMode: resolvedMapIsDark(
        preference: AppColorSchemePreference(rawValue: mapColorSchemeRaw) ?? .system, colorScheme: colorScheme),
      isOffline: !appState.offlineMapService.isNetworkAvailable,
      showLabels: showLabels,
      // The map asks for permission by itself when this is true while undetermined.
      showsUserLocation: appState.locationService.isAuthorized,
      isInteractive: isInteractive,
      showsScale: false,
      isNorthLocked: isNorthLocked,
      cameraRegion: .constant(nil),
      cameraBounds: cameraBounds,
      cameraRegionVersion: cameraVersion,
      onPointTap: nil,
      onMapTap: nil,
      onCameraRegionChange: nil,
      isStyleLoaded: $isStyleLoaded
    )
    .onChange(of: isStyleLoaded) { _, loaded in
      if loaded { frame() }
    }
    .onChange(of: drawing.bounds) {
      frame()
    }
    .onAppear {
      frame()
    }
  }

  private func frame() {
    guard let bounds = drawing.bounds else { return }
    cameraBounds = bounds.mapLibre
    cameraVersion += 1
  }
}

/// The full, interactive map the list's header opens.
struct WeatherAlertFullMapView: View {
  let drawing: WeatherMapDrawing
  let title: String

  var body: some View {
    WeatherAlertMapView(drawing: drawing, isInteractive: true)
      .ignoresSafeArea(edges: .bottom)
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
  }
}
