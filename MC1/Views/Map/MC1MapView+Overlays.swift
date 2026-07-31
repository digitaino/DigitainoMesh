import MapLibre
import UIKit

/// Source and layer identifiers for tool-contributed overlays. Namespaced under the overlay's
/// own id so two tools — or one tool's several layers — can never collide with each other or
/// with the fixed ids in ``MapLayerID``/``MapSourceID``.
enum MapOverlayID {
  static func source(_ overlay: String) -> String {
    "overlay-\(overlay)"
  }

  static func lineLayer(_ overlay: String) -> String {
    "overlay-\(overlay)-line"
  }

  static func casingLayer(_ overlay: String) -> String {
    "overlay-\(overlay)-casing"
  }

  static func circleLayer(_ overlay: String) -> String {
    "overlay-\(overlay)-circle"
  }

  static func fillLayer(_ overlay: String) -> String {
    "overlay-\(overlay)-fill"
  }

  /// Every layer an overlay may own, casing first so teardown order matches build order.
  static func layers(_ overlay: String) -> [String] {
    [casingLayer(overlay), lineLayer(overlay), circleLayer(overlay), fillLayer(overlay)]
  }
}

extension MC1MapView.Coordinator {
  /// Feature attribute carrying the normalized weight the paint ramps read.
  private static let weightAttribute = "overlayWeight"

  // MARK: - Update

  /// Brings the map's overlay layers in line with `currentOverlays`.
  ///
  /// Overlays are matched by id: one that vanished has its layers and source torn out, one
  /// that changed shape has its source's features replaced in place, and one whose paint
  /// changed has its layers rebuilt (the ramps are baked into the style layer, not the data).
  ///
  /// A declared overlay is sourced and layered on the *first* apply whether or not it has any
  /// features yet, because layers are inserted below one fixed anchor: creation order is stack
  /// order, so an overlay whose data only arrives on a later update would otherwise jump above
  /// the ones already drawn (links over the node bubbles standing on them). Empty initialization
  /// is what the line source does too — created at style load, fed by `.shape` afterwards.
  func updateOverlays(mapView: MLNMapView) {
    guard let style = mapView.style else { return }

    let liveIDs = Set(currentOverlays.map(\.id))
    for staleID in overlaySources.keys where !liveIDs.contains(staleID) {
      removeOverlay(id: staleID, from: style)
    }

    for overlay in currentOverlays {
      let previous = lastAppliedOverlays.first { $0.id == overlay.id }
      if let previous, previous.paint != overlay.paint {
        removeOverlay(id: overlay.id, from: style)
      }
      apply(overlay, style: style)
    }
  }

  /// Drops every overlay source/layer reference after a style reload, so the next update
  /// rebuilds them against the new style rather than writing to freed objects.
  func resetOverlayState() {
    overlaySources.removeAll()
    lastAppliedOverlays = []
  }

  // MARK: - Apply

  private func apply(_ overlay: MapOverlay, style: MLNStyle) {
    let features = overlay.features.compactMap(shapeFeature(for:))

    if let source = overlaySources[overlay.id] {
      source.shape = MLNShapeCollectionFeature(shapes: features)
      return
    }

    let source = MLNShapeSource(
      identifier: MapOverlayID.source(overlay.id),
      features: features,
      options: nil
    )
    style.addSource(source)
    overlaySources[overlay.id] = source
    addLayers(for: overlay, source: source, style: style)
  }

  private func removeOverlay(id: String, from style: MLNStyle) {
    for layerID in MapOverlayID.layers(id) {
      guard let layer = style.layer(withIdentifier: layerID) else { continue }
      style.removeLayer(layer)
    }
    if let source = style.source(withIdentifier: MapOverlayID.source(id)) {
      style.removeSource(source)
    }
    overlaySources[id] = nil
  }

  // MARK: - Layers

  /// Builds an overlay's style layers and slots them under the app's own content.
  ///
  /// Every overlay layer is inserted below the lowest line layer, which the style-load pass
  /// always creates first. That keeps tool overlays beneath the app's lines and pins — a heat
  /// layer must never bury the pins standing on it — while inserting each new overlay below
  /// the same anchor leaves them stacked in the order the tool listed them.
  private func addLayers(for overlay: MapOverlay, source: MLNShapeSource, style: MLNStyle) {
    let weight = NSExpression(forKeyPath: Self.weightAttribute)
    let anchor = style.layer(withIdentifier: MapLayerID.lineLOSCasing)

    switch overlay.paint {
    case let .weightedLine(paint):
      if let casing = paint.casing {
        let layer = MLNLineStyleLayer(identifier: MapOverlayID.casingLayer(overlay.id), source: source)
        layer.lineColor = NSExpression(forConstantValue: casing.color)
        layer.lineOpacity = NSExpression(forConstantValue: casing.opacity)
        layer.lineWidth = ramp(
          weight,
          from: paint.width.lowerBound + casing.extraWidth,
          to: paint.width.upperBound + casing.extraWidth
        )
        layer.lineJoin = NSExpression(forConstantValue: "round")
        layer.lineCap = NSExpression(forConstantValue: "round")
        insert(layer, into: style, below: anchor)
      }

      let layer = MLNLineStyleLayer(identifier: MapOverlayID.lineLayer(overlay.id), source: source)
      layer.lineColor = NSExpression(forConstantValue: paint.color)
      layer.lineWidth = ramp(weight, from: paint.width.lowerBound, to: paint.width.upperBound)
      layer.lineOpacity = ramp(weight, from: paint.opacity.lowerBound, to: paint.opacity.upperBound)
      layer.lineJoin = NSExpression(forConstantValue: "round")
      layer.lineCap = NSExpression(forConstantValue: "round")
      insert(layer, into: style, below: anchor)

    case let .weightedCircle(paint):
      let layer = MLNCircleStyleLayer(identifier: MapOverlayID.circleLayer(overlay.id), source: source)
      layer.circleColor = NSExpression(forConstantValue: paint.color)
      layer.circleRadius = ramp(weight, from: paint.radius.lowerBound, to: paint.radius.upperBound)
      layer.circleOpacity = ramp(weight, from: paint.opacity.lowerBound, to: paint.opacity.upperBound)
      layer.circleStrokeColor = NSExpression(forConstantValue: paint.strokeColor)
      layer.circleStrokeWidth = NSExpression(forConstantValue: paint.strokeWidth)
      insert(layer, into: style, below: anchor)

    case let .weightedFill(paint):
      let layer = MLNFillStyleLayer(identifier: MapOverlayID.fillLayer(overlay.id), source: source)
      layer.fillColor = NSExpression(forConstantValue: paint.color)
      layer.fillOpacity = ramp(weight, from: paint.opacity.lowerBound, to: paint.opacity.upperBound)
      if let outlineColor = paint.outlineColor {
        layer.fillOutlineColor = NSExpression(forConstantValue: outlineColor)
      }
      insert(layer, into: style, below: anchor)
    }
  }

  private func insert(_ layer: MLNStyleLayer, into style: MLNStyle, below anchor: MLNStyleLayer?) {
    if let anchor {
      style.insertLayer(layer, below: anchor)
    } else {
      style.addLayer(layer)
    }
  }

  /// A linear interpolation of `weight` between the two ends of a paint range. MapLibre clamps
  /// the input to the stop range, so a weight outside `0...1` lands on the nearer end.
  private func ramp(_ weight: NSExpression, from: Double, to: Double) -> NSExpression {
    guard from != to else { return NSExpression(forConstantValue: from) }
    return NSExpression(
      forMLNInterpolating: weight,
      curveType: .linear,
      parameters: nil,
      stops: NSExpression(forConstantValue: [0: from, 1: to])
    )
  }

  // MARK: - Features

  private func shapeFeature(for feature: MapOverlay.Feature) -> (MLNShape & MLNFeature)? {
    let shape: MLNShape & MLNFeature
    switch feature.geometry {
    case let .polyline(coordinates):
      guard coordinates.count >= 2 else { return nil }
      var coords = coordinates
      shape = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
    case let .point(coordinate):
      let point = MLNPointFeature()
      point.coordinate = coordinate
      shape = point
    case let .polygon(coordinates):
      guard coordinates.count >= 3 else { return nil }
      var coords = coordinates
      shape = MLNPolygonFeature(coordinates: &coords, count: UInt(coords.count))
    }
    shape.attributes = [
      "overlayFeatureID": feature.id,
      Self.weightAttribute: feature.weight,
    ]
    return shape
  }
}
