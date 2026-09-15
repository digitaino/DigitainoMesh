import CoreLocation
import MapLibre
import MC1Services
import MeshWX
import SwiftUI

/// One warning in full: the ground it covers, when it ends, what the office tagged it with, and
/// its narrative on request.
///
/// A storm-based product carries its own polygon; a zone-based one names areas and nothing else,
/// and drawing those means the 15 MB of outlines in the bundle (docs/MESHWX.md). Those load
/// lazily and off the main actor, with the centroid pins standing in meanwhile — and staying for
/// any area the bundle has no outline for, which is a normal outcome, not a failure.
struct WeatherWarningDetailView: View {
  @Environment(\.appState) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  let model: WeatherToolModel
  let identity: MeshWXWarningIdentity

  @State private var areaRings: [String: MeshWXGeometry.Rings] = [:]
  @State private var isLoadingRings = false
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
    Group {
      if horizontalSizeClass == .compact {
        VStack(spacing: 0) {
          map
            .containerRelativeFrame(.vertical) { height, _ in height * 0.45 }
          details
        }
      } else {
        HStack(spacing: 0) {
          map
          Divider()
          details
            .frame(maxWidth: 420)
        }
      }
    }
    .navigationTitle(eventName)
    .navigationBarTitleDisplayMode(.inline)
    .task {
      await loadRingsIfNeeded()
    }
    .onChange(of: isStyleLoaded) { _, loaded in
      if loaded { frame() }
    }
  }

  // MARK: - Warning

  private var stored: WeatherStoredWarning? {
    model.activeWarnings.first { $0.identity == identity }
      ?? model.botState?.warnings[identity]
  }

  private var vtec: String {
    model.tables.vtec(for: identity.event) ?? ""
  }

  private var eventName: String {
    model.tables.eventName(for: identity.event)?.long ?? model.tables.eventLabel(for: identity.event)
  }

  private var tint: Color {
    WeatherFormatting.color(for: MeshWXPresentation.tint(forVTEC: vtec))
  }

  private var areas: [MeshWXNamedArea] {
    stored.map { model.tables.namedAreas(for: $0.warning) } ?? []
  }

  // MARK: - Map

  private var mapIsDark: Bool {
    let preference = AppColorSchemePreference(rawValue: mapColorSchemeRaw) ?? .system
    return resolvedMapIsDark(preference: preference, colorScheme: colorScheme)
  }

  private var map: some View {
    MC1MapView(
      points: pins,
      lines: [],
      overlays: overlays,
      mapStyle: mapStyleSelection,
      isDarkMode: mapIsDark,
      isOffline: !appState.offlineMapService.isNetworkAvailable,
      showLabels: showLabels,
      showsUserLocation: true,
      isInteractive: true,
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
    .overlay(alignment: .topLeading) {
      if isLoadingRings {
        Label(L10n.Weather.Weather.WarningDetail.loadingAreas, systemImage: "map")
          .font(.caption)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .liquidGlass(in: .capsule)
          .padding(8)
      }
    }
  }

  /// The rings actually drawn: the product's own polygon when it has one, otherwise every
  /// outline the bundle holds for the areas it names.
  private var drawnRings: [[CLLocationCoordinate2D]] {
    if let polygon = stored?.warning.polygon, polygon.count >= 3 {
      return [polygon.map(Self.coordinate)]
    }
    return areas.flatMap { area in
      (areaRings[area.ugc] ?? []).filter { $0.count >= 3 }.map { $0.map(Self.coordinate) }
    }
  }

  private var overlays: [MapOverlay] {
    let rings = drawnRings
    guard !rings.isEmpty else { return [] }
    let color = WeatherFormatting.uiColor(for: MeshWXPresentation.tint(forVTEC: vtec))
    let fill = MapOverlay(
      id: "weather-warning-fill",
      features: rings.enumerated().map { index, ring in
        MapOverlay.Feature(id: "fill-\(index)", geometry: .polygon(ring), weight: 1)
      },
      paint: .weightedFill(MapOverlay.WeightedFill(color: color, opacity: 0.35...0.35))
    )
    // The emphasis outline is its own overlay above the fill: `weightedFill` only offers
    // MapLibre's hairline, which disappears against satellite imagery (see `MapOverlay`).
    let outline = MapOverlay(
      id: "weather-warning-outline",
      features: rings.enumerated().map { index, ring in
        MapOverlay.Feature(id: "outline-\(index)", geometry: .polyline(closed(ring)), weight: 1)
      },
      paint: .weightedLine(
        MapOverlay.WeightedLine(color: color, width: 2...2, opacity: 0.9...0.9)
      )
    )
    return [fill, outline]
  }

  /// A pin per area with no outline — while the files load, and afterwards for any code the
  /// bundle predates. A warning with no shape still has to show where it is.
  private var pins: [MapPoint] {
    guard stored?.warning.polygon == nil else { return [] }
    return areas.compactMap { area in
      guard areaRings[area.ugc] == nil, let lat = area.lat, let lon = area.lon else { return nil }
      return MapPoint(
        id: Self.pointID(for: area.ugc),
        coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
        pinStyle: .droppedPin,
        label: area.name,
        isClusterable: false,
        hopIndex: nil,
        badgeText: nil
      )
    }
  }

  private func closed(_ ring: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
    guard let first = ring.first, let last = ring.last else { return ring }
    guard first.latitude != last.latitude || first.longitude != last.longitude else { return ring }
    return ring + [first]
  }

  private static func coordinate(_ value: MeshWXCoordinate) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: value.latitude, longitude: value.longitude)
  }

  /// A stable pin id from the UGC, so a ring arriving does not re-key the pins that remain.
  private static func pointID(for ugc: String) -> UUID {
    var bytes = [UInt8](ugc.utf8.prefix(16))
    bytes.append(contentsOf: repeatElement(0, count: 16 - bytes.count))
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3],
      bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11],
      bytes[12], bytes[13], bytes[14], bytes[15]
    ))
  }

  // MARK: - Details

  private var details: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        headline
        if !tagTexts.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(tagTexts, id: \.self) { tag in
              Label(tag, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
            }
          }
        }
        if !areas.isEmpty {
          areaList
        }
        narrativeSection
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var headline: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Image(systemName: MeshWXPresentation.symbolName(forVTEC: vtec))
          .font(.title2)
          .foregroundStyle(tint)
          .accessibilityHidden(true)
        Text(eventName)
          .font(.title3.weight(.semibold))
      }
      if let stored {
        Text(WeatherFormatting.expiry(expiresMinutes: stored.warning.expiresMinutes, now: model.now))
          .font(.subheadline)
        Text(L10n.Weather.Weather.WarningDetail.expiresAt(
          stored.expiresAt.formatted(date: .abbreviated, time: .shortened)
        ))
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
      Text(model.tables.officeLabel(identity.office))
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  private var tagTexts: [String] {
    stored.map { WeatherFormatting.tagTexts(for: $0.warning) } ?? []
  }

  private var areaList: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(L10n.Weather.Weather.WarningDetail.areas)
        .font(.headline)
      ForEach(areas, id: \.ugc) { area in
        HStack {
          Text(WeatherFormatting.areaName(area))
            .font(.subheadline)
          Spacer(minLength: 8)
          Text(area.isCounty
            ? L10n.Weather.Weather.WarningDetail.county
            : L10n.Weather.Weather.WarningDetail.zone)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder
  private var narrativeSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let identityString = model.identityString(identity) {
        Button(L10n.Weather.Weather.WarningDetail.readFullText) {
          Task { await model.send(.warningText(identity: identityString)) }
        }
        .buttonStyle(.bordered)
        .disabled(!model.canSendRequests || model.hasPendingRequest)
      }
      if let narrative {
        Divider()
        Text(narrative.orderedChunks
          .map { $0 ?? L10n.Weather.Weather.Text.missingPart }
          .joined())
          .font(.system(.footnote, design: .monospaced))
          .textSelection(.enabled)
      }
    }
  }

  /// The narrative answering *this* warning's "Read full text", or nil.
  ///
  /// A text reply names its subject and nothing else, so the only way to know which warning a
  /// narrative belongs to is the request that produced it: the latest warning-narrative text
  /// is shown here only while the last narrative the app asked for was this identity. Any
  /// earlier narrative stays reachable under Text products, labelled by subject, not by a
  /// warning it may not describe.
  private var narrative: WeatherTextAssembly? {
    guard let identityString = model.identityString(identity),
          model.lastTextRequests[WeatherTextSubjectCode.warningNarrative]
            == .warningText(identity: identityString)
    else { return nil }
    return model.texts.first { $0.subject == .warningNarrative }
  }

  // MARK: - Loading

  private func loadRingsIfNeeded() async {
    guard let stored, stored.warning.polygon == nil else {
      frame()
      return
    }
    let areas = model.tables.namedAreas(for: stored.warning)
    guard !areas.isEmpty else { return }
    isLoadingRings = true
    // Parsing the GeoJSON is roughly half a second on a cold cache; it has no business on
    // the main actor while a warning map is trying to appear.
    let loaded = await Task.detached(priority: .userInitiated) {
      var result: [String: MeshWXGeometry.Rings] = [:]
      for area in areas {
        guard let rings = MeshWXGeometry.shared.rings(for: area.ugc) else { continue }
        result[area.ugc] = rings
      }
      return result
    }.value
    areaRings = loaded
    isLoadingRings = false
    frame()
  }

  /// Frames whatever is drawn. The map ignores a camera whose version matches the last applied
  /// one, so the target and the version move together.
  private func frame() {
    var coordinates = drawnRings.flatMap { $0 }
    coordinates.append(contentsOf: pins.map(\.coordinate))
    guard let first = coordinates.first else { return }

    var minLatitude = first.latitude
    var maxLatitude = first.latitude
    var minLongitude = first.longitude
    var maxLongitude = first.longitude
    for coordinate in coordinates.dropFirst() {
      minLatitude = min(minLatitude, coordinate.latitude)
      maxLatitude = max(maxLatitude, coordinate.latitude)
      minLongitude = min(minLongitude, coordinate.longitude)
      maxLongitude = max(maxLongitude, coordinate.longitude)
    }
    let latitudePad = max((maxLatitude - minLatitude) * 0.2, 0.02)
    let longitudePad = max((maxLongitude - minLongitude) * 0.2, 0.02)

    cameraBounds = MLNCoordinateBounds(
      sw: CLLocationCoordinate2D(
        latitude: max(-90, minLatitude - latitudePad),
        longitude: max(-180, minLongitude - longitudePad)
      ),
      ne: CLLocationCoordinate2D(
        latitude: min(90, maxLatitude + latitudePad),
        longitude: min(180, maxLongitude + longitudePad)
      )
    )
    cameraVersion += 1
  }
}
