import MapKit
import MapLibre
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.mc1", category: "MapPins")

/// How a map places the name pills above its pins.
enum MapLabelPlacement {
  /// Every pill draws, whatever it covers — the behaviour every screen has
  /// always had.
  case overlap
  /// Pills enter MapLibre's collision index; of two that would overlap, the
  /// one with the lower `MapPoint.labelPriority` draws. Pins themselves never
  /// disappear.
  case collide
}

struct MC1MapView: UIViewRepresentable {
  // Data
  let points: [MapPoint]
  let lines: [MapLine]
  /// Weighted data layers contributed by a tool, drawn beneath `lines` and `points`.
  /// See ``MapOverlay``.
  var overlays: [MapOverlay] = []
  let mapStyle: MapStyleSelection
  let isDarkMode: Bool
  var isOffline: Bool = false

  /// Configuration
  let showLabels: Bool
  /// Whether name pills force-draw or collide. Defaults to today's behaviour.
  var labelPlacement: MapLabelPlacement = .overlap
  let showsUserLocation: Bool
  let isInteractive: Bool
  let showsScale: Bool
  var isNorthLocked: Bool = false

  /// Camera
  @Binding var cameraRegion: MKCoordinateRegion?
  /// MapLibre-native camera target, honored ahead of `cameraRegion` when set and driven by the
  /// same version counter. It exists so a screen built on the MapLibre stack can frame the map
  /// without taking on MapKit's geometry types (§2.3); callers that already hold an
  /// `MKCoordinateRegion` keep using `cameraRegion` and leave this nil.
  var cameraBounds: MLNCoordinateBounds?
  let cameraRegionVersion: Int
  var cameraEdgePadding: UIEdgeInsets = .zero
  var cameraBottomSheetFraction: CGFloat?

  // Programmatic selection: the id of the point to select, plus a version
  // counter bumped to (re)fire it, mirroring the camera region + version idiom.
  // The coordinator projects the point and routes it through `onPointTap`, so a
  // programmatic selection is the same code path as a user tap.
  var selectionRequestID: UUID?
  var selectionRequestVersion: Int = 0

  // Output callbacks
  let onPointTap: ((MapPoint, CGPoint) -> Void)?
  let onMapTap: ((CLLocationCoordinate2D) -> Void)?
  var onMapLongPress: ((CLLocationCoordinate2D) -> Void)?
  let onCameraRegionChange: ((MKCoordinateRegion) -> Void)?
  /// A tap on a `.badge` point's pill. Nil keeps today's behaviour, where a
  /// badge tap counts as a map tap.
  var onBadgeTap: ((MapPoint) -> Void)?
  /// The user took the camera somewhere by gesture. `isCenteredOnUser` cannot
  /// stand in for this: a gesture sets it to *false*, which is not a signal a
  /// host can act on.
  var onUserCameraMove: (() -> Void)?

  /// Optional features
  var isStyleLoaded: Binding<Bool> = .constant(true)

  /// Reports whether the camera is currently centered on the user's location.
  var isCenteredOnUser: Binding<Bool> = .constant(false)

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> MLNMapView {
    let mapView = context.coordinator.mapView
    mapView.delegate = context.coordinator

    mapView.showsUserLocation = showsUserLocation
    mapView.compassViewPosition = .topRight
    mapView.compassViewMargins = CGPoint(x: 8, y: 8)
    mapView.attributionButtonPosition = .bottomLeft
    mapView.attributionButtonMargins = CGPoint(x: 4, y: 30)

    if showsScale {
      mapView.showsScale = true
    }

    if !isInteractive {
      mapView.isScrollEnabled = false
      mapView.isZoomEnabled = false
      mapView.isRotateEnabled = false
      mapView.isPitchEnabled = false
      mapView.compassView.isHidden = true
    }

    // Disable quick-zoom (tap-then-hold-drag) gesture
    mapView.gestureRecognizers?
      .compactMap { $0 as? UILongPressGestureRecognizer }
      .filter { $0.numberOfTapsRequired == 1 && $0.minimumPressDuration == 0 }
      .forEach { $0.isEnabled = false }

    // Tap gesture for feature queries
    let tap = UITapGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handleTap(_:))
    )
    tap.delegate = context.coordinator
    mapView.addGestureRecognizer(tap)

    // Long-press gesture for dropping a pin at the pressed coordinate
    let longPress = UILongPressGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handleLongPress(_:))
    )
    longPress.delegate = context.coordinator
    mapView.addGestureRecognizer(longPress)

    return mapView
  }

  static func dismantleUIView(_ mapView: MLNMapView, coordinator: Coordinator) {
    coordinator.pendingRegionTask?.cancel()
    mapView.delegate = nil
  }

  func updateUIView(_ mapView: MLNMapView, context: Context) {
    let coordinator = context.coordinator
    coordinator.isUpdatingFromSwiftUI = true
    defer { coordinator.isUpdatingFromSwiftUI = false }

    // Refresh callbacks
    coordinator.onPointTap = onPointTap
    coordinator.onMapTap = onMapTap
    coordinator.onMapLongPress = onMapLongPress
    coordinator.onCameraRegionChange = onCameraRegionChange
    coordinator.onBadgeTap = onBadgeTap
    coordinator.onUserCameraMove = onUserCameraMove
    coordinator.setIsStyleLoaded = { isStyleLoaded.wrappedValue = $0 }
    coordinator.setIsCenteredOnUser = { isCenteredOnUser.wrappedValue = $0 }
    coordinator.currentPoints = points
    coordinator.currentLines = lines
    coordinator.currentOverlays = overlays
    // Set before the styleURL below: a theme switch changes the styleURL and triggers
    // a reload, so didFinishLoading -> renderAll must already see the new theme.
    coordinator.currentIsDarkMode = isDarkMode
    // Likewise before the style loads: the name-pill layers are created from
    // `updatePointSource` inside `didFinishLoading`, and read this then.
    coordinator.currentLabelPlacement = labelPlacement

    // Style URL change — compare against our tracked value, not mapView.styleURL
    // which MapLibre may transiently nil during layout/rotation.
    let newStyleURL = mapStyle.styleURL(isDarkMode: isDarkMode, isOffline: isOffline)
    if coordinator.lastAppliedStyleURL != newStyleURL {
      coordinator.lastAppliedStyleURL = newStyleURL
      coordinator.isStyleLoaded = false
      mapView.styleURL = newStyleURL
    }
    coordinator.currentMapStyle = mapStyle

    // User location
    if mapView.showsUserLocation != showsUserLocation {
      mapView.showsUserLocation = showsUserLocation
    }

    // North lock
    if isInteractive {
      mapView.isRotateEnabled = !isNorthLocked
      if isNorthLocked, mapView.direction != 0 {
        mapView.setDirection(0, animated: true)
      }
    }

    // Update data layers (only when style is loaded and not mid-gesture).
    // Compare against lastApplied* so updates arriving during a gesture
    // are applied once the gesture ends.
    if coordinator.isStyleLoaded, !coordinator.isUserInteracting {
      if coordinator.lastAppliedMapStyle != mapStyle {
        coordinator.updateRasterLayerVisibility(mapView: mapView)
        coordinator.lastAppliedMapStyle = mapStyle
      }
      if coordinator.lastAppliedPoints != points {
        coordinator.updatePointSource(mapView: mapView)
        coordinator.lastAppliedPoints = points
      }
      if coordinator.lastAppliedLines != lines {
        coordinator.updateLineSource(mapView: mapView)
        coordinator.lastAppliedLines = lines
      }
      if coordinator.lastAppliedOverlays != overlays {
        coordinator.updateOverlays(mapView: mapView)
        coordinator.lastAppliedOverlays = overlays
      }
      if coordinator.currentShowLabels != showLabels {
        coordinator.currentShowLabels = showLabels
        coordinator.updateLabelVisibility(mapView: mapView, showLabels: showLabels)
      }
      if coordinator.lastAppliedLabelPlacement != labelPlacement {
        coordinator.lastAppliedLabelPlacement = labelPlacement
        coordinator.updateLabelPlacement(mapView: mapView, placement: labelPlacement)
      }
    }

    // Camera region (version-number pattern)
    updateCameraRegion(in: mapView, coordinator: coordinator)

    // Programmatic selection (version-number pattern). Runs once per bump, after the
    // camera update so the projection reads the just-applied camera. Dispatched async
    // so it never mutates SwiftUI state during this representable update, matching how
    // `onCameraRegionChange` defers its write-back.
    if coordinator.isStyleLoaded,
       coordinator.lastAppliedSelectionVersion != selectionRequestVersion {
      coordinator.lastAppliedSelectionVersion = selectionRequestVersion
      if let id = selectionRequestID,
         let point = coordinator.currentPoints.first(where: { $0.id == id }) {
        DispatchQueue.main.async { coordinator.selectPoint(point) }
      }
    }
  }

  /// Maximum absolute latitude MapLibre's `mbgl::LatLng` accepts; it throws an
  /// uncaught `std::domain_error` (aborting the app) for any value beyond ±90.
  private static let latitudeLimit = 90.0

  /// The corners this version bump wants framed: `cameraBounds` when a caller supplied one,
  /// otherwise `cameraRegion` converted.
  ///
  /// Returns nil — after recording the version as applied — for a value MapLibre would abort
  /// on, so a bad camera request is skipped rather than retried on every render. A caller that
  /// has simply supplied no camera at all leaves the version unrecorded, so a target arriving
  /// later under the same version still lands.
  private func requestedCameraBounds(coordinator: Coordinator) -> MLNCoordinateBounds? {
    if let cameraBounds {
      guard CLLocationCoordinate2DIsValid(cameraBounds.sw),
            CLLocationCoordinate2DIsValid(cameraBounds.ne) else {
        coordinator.lastAppliedRegionVersion = cameraRegionVersion
        return nil
      }
      return cameraBounds
    }

    guard let region = cameraRegion else { return nil }
    guard CLLocationCoordinate2DIsValid(region.center) else {
      coordinator.lastAppliedRegionVersion = cameraRegionVersion
      return nil
    }

    // Corners are center ± span/2, so a non-finite span makes MapLibre's LatLng
    // constructor throw and abort the process — and the latitude clamp below can't
    // catch it because Swift's max/min propagate NaN. Skip the update when non-finite.
    guard region.span.latitudeDelta.isFinite,
          region.span.longitudeDelta.isFinite else {
      coordinator.lastAppliedRegionVersion = cameraRegionVersion
      return nil
    }

    // Clamp latitude so a near-pole center can't push a corner past ±90 (another
    // LatLng abort). Longitude is left unclamped because MapLibre wraps it.
    let limit = Self.latitudeLimit
    return MLNCoordinateBounds(
      sw: CLLocationCoordinate2D(
        latitude: max(-limit, region.center.latitude - region.span.latitudeDelta / 2),
        longitude: region.center.longitude - region.span.longitudeDelta / 2
      ),
      ne: CLLocationCoordinate2D(
        latitude: min(limit, region.center.latitude + region.span.latitudeDelta / 2),
        longitude: region.center.longitude + region.span.longitudeDelta / 2
      )
    )
  }

  private func updateCameraRegion(in mapView: MLNMapView, coordinator: Coordinator) {
    guard cameraRegionVersion != coordinator.lastAppliedRegionVersion else { return }
    guard let bounds = requestedCameraBounds(coordinator: coordinator) else { return }

    let isInflated = mapView.window.map { mapView.bounds.height > $0.bounds.height * 1.5 } ?? false
    let animated = coordinator.lastAppliedRegionVersion > 0 && !isInflated
      && !UIAccessibility.isReduceMotionEnabled
    coordinator.lastAppliedRegionVersion = cameraRegionVersion

    var padding = cameraEdgePadding
    if let sheetFraction = cameraBottomSheetFraction {
      let insets = mapView.safeAreaInsets
      padding.top = max(padding.top, insets.top + 20)
      padding.left = max(padding.left, insets.left + 20)
      if sheetFraction > 0 {
        let stableHeight = mapView.window?.bounds.height ?? mapView.bounds.height
        padding.bottom = max(padding.bottom, stableHeight * sheetFraction)
      }
    }

    if let windowSize = mapView.window?.bounds.size,
       mapView.bounds.height > windowSize.height * 1.5 {
      let centerLat = (bounds.sw.latitude + bounds.ne.latitude) / 2
      let centerLon = (bounds.sw.longitude + bounds.ne.longitude) / 2
      let latSpanMeters = abs(bounds.ne.latitude - bounds.sw.latitude) * 111_000
      let lonSpanMeters = abs(bounds.ne.longitude - bounds.sw.longitude) * 111_000
        * cos(centerLat * .pi / 180)

      let usableWidth = max(1, Double(windowSize.width) - Double(padding.left + padding.right))
      let usableHeight = max(1, Double(windowSize.height) - Double(padding.top + padding.bottom))

      let mppForLat = latSpanMeters / usableHeight
      let mppForLon = lonSpanMeters / usableWidth
      let requiredMPP = max(mppForLat, mppForLon)

      let currentMPP = mapView.metersPerPoint(atLatitude: centerLat)
      let targetZoom = mapView.zoomLevel + log2(currentMPP / requiredMPP)

      let pixelOffset = (Double(padding.top) - Double(padding.bottom)) / 2
      let offsetDeg = pixelOffset * requiredMPP / 111_000
      let center = CLLocationCoordinate2D(
        latitude: min(Self.latitudeLimit, max(-Self.latitudeLimit, centerLat + offsetDeg)),
        longitude: centerLon
      )

      mapView.setCenter(center, zoomLevel: targetZoom, animated: false)
    } else {
      mapView.setVisibleCoordinateBounds(
        bounds,
        edgePadding: padding,
        animated: animated,
        completionHandler: nil
      )
    }
  }
}

// MARK: - Coordinator

extension MC1MapView {
  @MainActor
  class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate, UIGestureRecognizerDelegate {
    /// Non-zero frame avoids MapLibre zero-size Metal init (issue #67).
    let mapView = MLNMapView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))

    // Callbacks
    var onPointTap: ((MapPoint, CGPoint) -> Void)?
    var onMapTap: ((CLLocationCoordinate2D) -> Void)?
    var onMapLongPress: ((CLLocationCoordinate2D) -> Void)?
    var onCameraRegionChange: ((MKCoordinateRegion) -> Void)?
    var setIsStyleLoaded: ((Bool) -> Void)?
    var setIsCenteredOnUser: ((Bool) -> Void)?
    var onBadgeTap: ((MapPoint) -> Void)?
    var onUserCameraMove: (() -> Void)?

    // State
    var isUserInteracting = false
    var isUpdatingFromSwiftUI = false
    var isStyleLoaded = false
    var lastAppliedRegionVersion = 0
    var lastAppliedSelectionVersion = 0
    var pendingRegionTask: Task<Void, Never>?
    var currentShowLabels = true
    /// The placement the view asks for, read when the name-pill layers are
    /// created; `lastApplied` mirrors `currentShowLabels`' idiom for live changes.
    var currentLabelPlacement: MapLabelPlacement = .overlap
    var lastAppliedLabelPlacement: MapLabelPlacement = .overlap
    /// The basemap theme in force, mirrored from the view so `renderAll` can pick the
    /// location-dot recency palette at style-load time. Kept current by `updateUIView`.
    var currentIsDarkMode = false
    var lastAppliedStyleURL: URL?
    var currentMapStyle: MapStyleSelection?
    var lastAppliedMapStyle: MapStyleSelection?
    var currentPoints: [MapPoint] = []
    var currentLines: [MapLine] = []
    var currentOverlays: [MapOverlay] = []
    var lastAppliedPoints: [MapPoint] = []
    var lastAppliedClusterablePoints: [MapPoint] = []
    var lastAppliedFixedPoints: [MapPoint] = []
    var lastAppliedLines: [MapLine] = []
    var lastAppliedOverlays: [MapOverlay] = []
    var clusterSource: MLNShapeSource?
    var fixedSource: MLNShapeSource?
    /// Shape sources for tool-contributed overlays, keyed by ``MapOverlay/id``.
    var overlaySources: [String: MLNShapeSource] = [:]

    // MARK: - Style loading

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
      isStyleLoaded = true
      setIsStyleLoaded?(true)

      // Clear stale source/state references from the previous style.
      // Reset currentShowLabels to the new layer default (visible) so
      // updateUIView detects the mismatch and reapplies the user's preference.
      // A reload rebuilds the raster layers with isVisible == false, so clear
      // lastAppliedMapStyle to force updateUIView to re-apply the selected overlay.
      clusterSource = nil
      fixedSource = nil
      lastAppliedPoints = []
      lastAppliedClusterablePoints = []
      lastAppliedFixedPoints = []
      lastAppliedLines = []
      lastAppliedMapStyle = nil
      currentShowLabels = true
      lastAppliedLabelPlacement = .overlap
      resetOverlayState()

      PinSpriteRenderer.renderAll(into: style, isDarkMode: currentIsDarkMode)
      setupRasterSources(style: style, mapView: mapView)
      setupLineLayers(style: style)

      updatePointSource(mapView: mapView)
      updateLineSource(mapView: mapView)
      // After the line layers exist, so overlays find their insertion anchor.
      updateOverlays(mapView: mapView)
      lastAppliedOverlays = currentOverlays
    }

    func mapView(_ mapView: MLNMapView, didFailToLoadImage imageName: String) -> UIImage? {
      if let style = mapView.style,
         let image = PinSpriteRenderer.renderOnDemand(name: imageName, into: style) {
        return image
      }
      logger.error("didFailToLoadImage: \(imageName)")
      return nil
    }

    // MARK: - Region changes

    private static let userGestureReasons: MLNCameraChangeReason = [
      .gesturePan, .gesturePinch, .gestureZoomIn, .gestureZoomOut,
      .gestureRotate, .gestureTilt, .gestureOneFingerZoom
    ]

    func mapViewRegionIsChanging(_ mapView: MLNMapView) {
      isUserInteracting = true
    }

    func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
      // A user drag/zoom/rotate moves the camera off the user's location, so clear the
      // centered-on-user flag. Programmatic recenters keep it — the location button sets
      // it back to true when it centers the map.
      guard !reason.isDisjoint(with: Self.userGestureReasons) else { return }
      let report = setIsCenteredOnUser
      let moved = onUserCameraMove
      DispatchQueue.main.async {
        report?(false)
        moved?()
      }
    }

    func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
      isUserInteracting = false
      guard !isUpdatingFromSwiftUI else { return }

      let isUserGesture = !reason.isDisjoint(with: Self.userGestureReasons)
      guard isUserGesture else { return }

      // Debounce: cancel previous pending write-back
      pendingRegionTask?.cancel()
      pendingRegionTask = Task {
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled else { return }
        let region = mapView.mlnRegion
        self.onCameraRegionChange?(region)
      }
    }

    // MARK: - Gesture recognizer delegate

    nonisolated func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
      true
    }

    // MARK: - Tap handling

    /// Projects a point to its on-screen anchor (lifted above the pin by its style's
    /// callout clearance) and routes it through `onPointTap`, so a programmatic
    /// selection presents the callout exactly like a user tap.
    func selectPoint(_ mapPoint: MapPoint) {
      let pinScreenPos = mapView.convert(mapPoint.coordinate, toPointTo: mapView)
      let calloutAnchor = CGPoint(
        x: pinScreenPos.x,
        y: pinScreenPos.y - PinSpriteRenderer.calloutLift(for: mapPoint.pinStyle)
      )
      onPointTap?(mapPoint, calloutAnchor)
    }

    @objc func handleTap(_ sender: UITapGestureRecognizer) {
      guard sender.state == .ended else { return }
      let point = sender.location(in: mapView)
      let clusterRect = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
      logger.debug("handleTap at \(point.x, privacy: .public), \(point.y, privacy: .public)")

      // 1. Check cluster layers
      let clusterFeatures = mapView.visibleFeatures(
        in: clusterRect,
        styleLayerIdentifiers: [MapLayerID.clusterCircles]
      )
      if let cluster = clusterFeatures.first(where: { $0 is MLNPointFeatureCluster }) as? MLNPointFeatureCluster,
         let source = mapView.style?.source(withIdentifier: MapSourceID.points) as? MLNShapeSource {
        let zoom = source.zoomLevel(forExpanding: cluster)
        guard zoom >= 0 else { return }
        mapView.setCenter(
          cluster.coordinate,
          zoomLevel: zoom + 2.0,
          animated: !UIAccessibility.isReduceMotionEnabled
        )
        return
      }

      // 2. Pin icons, within the same 44 pt square the cluster probe uses, so a
      //    pin is a 44 pt target rather than an exact-pixel one; the nearest
      //    wins when several fall inside. Badges are decoration, not pins —
      //    their icon is a transparent 1×1 sprite — so they never match here.
      let iconFeatures = mapView.visibleFeatures(
        in: clusterRect,
        styleLayerIdentifiers: [MapLayerID.unclusteredIcons, MapLayerID.fixedIcons]
      )
      let candidates = iconFeatures.compactMap(mapPoint(for:)).filter { $0.pinStyle != .badge }
      logger.debug("iconFeatures: \(iconFeatures.count, privacy: .public), clusterFeatures: \(clusterFeatures.count, privacy: .public)")
      if let nearest = candidates.min(by: { lhs, rhs in
        distanceSquared(from: point, to: lhs.coordinate) < distanceSquared(from: point, to: rhs.coordinate)
      }) {
        logger.debug("Matched pin: \(nearest.label ?? "unnamed", privacy: .public)")
        selectPoint(nearest)
        return
      }

      // 3. Name pills, at the exact point and only after the icons: a pill
      //    sits 46 pt above its pin, so a rect probe here could let it beat a
      //    directly-tapped neighbour.
      let labelFeatures = mapView.visibleFeatures(
        at: point,
        styleLayerIdentifiers: [MapLayerID.nameLabels, MapLayerID.fixedNameLabels]
      )
      if let mapPoint = labelFeatures.lazy.compactMap(self.mapPoint(for:)).first {
        logger.debug("Matched pill: \(mapPoint.label ?? "unnamed", privacy: .public)")
        selectPoint(mapPoint)
        return
      }

      // 4. Badge pills: a host that listens gets the badge's point; otherwise
      //    the tap counts as a map tap, as it always has.
      let badgeFeatures = mapView.visibleFeatures(
        at: point,
        styleLayerIdentifiers: [MapLayerID.badgeText, MapLayerID.fixedBadgeText]
      )
      if let badge = badgeFeatures.lazy.compactMap(self.mapPoint(for:)).first {
        if let onBadgeTap {
          onBadgeTap(badge)
        } else {
          onMapTap?(mapView.convert(point, toCoordinateFrom: mapView))
        }
        return
      }
      if badgeFeatures.first != nil {
        onMapTap?(mapView.convert(point, toCoordinateFrom: mapView))
        return
      }

      // 5. Map background tap
      let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
      onMapTap?(coordinate)
    }

    /// The `MapPoint` a rendered feature stands for, by its `pointId`.
    private func mapPoint(for feature: MLNFeature) -> MapPoint? {
      guard let idString = feature.attribute(forKey: "pointId") as? String,
            let id = UUID(uuidString: idString) else { return nil }
      return currentPoints.first { $0.id == id }
    }

    private func distanceSquared(from point: CGPoint, to coordinate: CLLocationCoordinate2D) -> CGFloat {
      let projected = mapView.convert(coordinate, toPointTo: mapView)
      let dx = projected.x - point.x
      let dy = projected.y - point.y
      return dx * dx + dy * dy
    }

    @objc func handleLongPress(_ sender: UILongPressGestureRecognizer) {
      guard sender.state == .began else { return }
      let point = sender.location(in: mapView)
      let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
      onMapLongPress?(coordinate)
    }
  }
}

// MARK: - MLNMapView region helper

extension MLNMapView {
  var mlnRegion: MKCoordinateRegion {
    let bounds = visibleCoordinateBounds
    let center = CLLocationCoordinate2D(
      latitude: (bounds.sw.latitude + bounds.ne.latitude) / 2,
      longitude: (bounds.sw.longitude + bounds.ne.longitude) / 2
    )
    let span = MKCoordinateSpan(
      latitudeDelta: bounds.ne.latitude - bounds.sw.latitude,
      longitudeDelta: bounds.ne.longitude - bounds.sw.longitude
    )
    return MKCoordinateRegion(center: center, span: span)
  }
}
