import CoreLocation
import MapLibre
import MC1Services
import SurveyKit
import UIKit

/// Turns a ``SignalMapperCoverageSnapshot`` into the map's own vocabulary: hexagons through
/// the ``MapOverlay`` API, and a camera that frames them.
///
/// Two visual channels, kept apart the way the traffic map keeps its two: **how well** the
/// mesh reaches a cell is colour, **how much** was observed there is opacity. A cell proved
/// only by an acknowledgement has no SNR to grade and stays neutral rather than being
/// coloured on a guess.
///
/// This is the second consumer of the overlay API (§2.3), and the one it was designed for:
/// the fill paint and polygon geometry it uses were written into ``MapOverlay``'s notes as
/// "what the signal mapper will need" before either existed.
/// Which of the two coverage questions the map is currently answering.
///
/// One capture store, two reads of it (docs/ACTIVE_SURVEY_M3_5.md §2.5): what the mesh
/// sounds like from here, and what *hears us* from here — the second being the whole
/// point of active surveying, and invisible until M3.5 because the builder used to
/// discard the uplink aggregates.
enum SignalMapperMapLayer: String, CaseIterable, Identifiable {
  /// Downlink: cells coloured by the mean SNR of everything we received there.
  case heard
  /// Uplink: cells coloured by the mean SNR repeaters reported for our transmissions,
  /// with a distinct "no reach" tint where we probed and nobody ever heard us.
  case reach

  var id: String {
    rawValue
  }
}

enum SignalMapperCoverageRenderer {
  // MARK: - Overlay ids

  /// Cells are split one overlay per quality, because colour is a per-overlay property
  /// (see ``MapOverlay``). The selection ring is its own overlay so it can sit above them.
  static func cellOverlayID(_ quality: SignalQuality) -> String {
    "mapper-cells-\(quality.overlayToken)"
  }

  static let selectionOverlayID = "mapper-selection"
  /// The reach layer's "probed, never heard" cells. Declared on both layers (empty on
  /// Heard) so toggling swaps *features*, never the overlay set — `MapOverlay.id` is the
  /// diff key, and an id change would tear down and rebuild every `MLNShapeSource` on
  /// each toggle (M3.5 review M13).
  static let noReachOverlayID = "mapper-cells-noreach"

  // MARK: - Overlays

  static func overlays(
    for snapshot: SignalMapperCoverageSnapshot,
    selected: SignalMapperCoverageCell?,
    layer: SignalMapperMapLayer = .heard
  ) -> [MapOverlay] {
    // Fills first, ring last: overlays stack in the order they are listed.
    cellOverlays(for: snapshot, layer: layer) + [selectionOverlay(for: selected)]
  }

  /// One translucent hexagon per captured cell, tinted by how well the mesh reaches it
  /// (Heard) or how well it hears us (Reach), and solidified by how much was observed.
  ///
  /// Every overlay is declared on every layer, empty or not: the stack order is settled by
  /// the map's first apply, and a layer toggle must change feature sets only — stable ids
  /// keep the diff on its cheap in-place path.
  private static func cellOverlays(
    for snapshot: SignalMapperCoverageSnapshot,
    layer: SignalMapperMapLayer
  ) -> [MapOverlay] {
    let qualityOverlays = SignalQuality.coverageOrder.map { quality in
      let members = snapshot.cells.filter { cell in
        switch layer {
        case .heard: cell.quality == quality
        case .reach: cell.reachQuality == quality
        }
      }
      return MapOverlay(
        id: cellOverlayID(quality),
        features: members.map { cell in
          MapOverlay.Feature(
            id: cell.cell.stringValue,
            geometry: .polygon(cell.boundary.map(\.locationCoordinate)),
            weight: cell.normalizedWeight
          )
        },
        paint: MapOverlay.WeightedFill(
          color: quality.uiColor,
          // Never fully opaque: the streets under a cell are what make it legible as
          // coverage of a *place* rather than an abstract grid.
          opacity: 0.18...0.55,
          outlineColor: quality.uiColor.withAlphaComponent(0.7)
        ).asPaint
      )
    }

    // "We shouted from here and nobody heard": the reach layer's most important cells,
    // drawn in a flat neutral so they read as absence rather than as a sixth quality.
    let noReachMembers = layer == .reach ? snapshot.cells.filter(\.isUnreachedProbed) : []
    let noReach = MapOverlay(
      id: noReachOverlayID,
      features: noReachMembers.map { cell in
        MapOverlay.Feature(
          id: cell.cell.stringValue,
          geometry: .polygon(cell.boundary.map(\.locationCoordinate)),
          weight: max(0.4, cell.normalizedWeight)
        )
      },
      paint: MapOverlay.WeightedFill(
        color: .systemGray,
        opacity: 0.25...0.45,
        outlineColor: UIColor.systemGray.withAlphaComponent(0.8)
      ).asPaint
    )
    return qualityOverlays + [noReach]
  }

  /// A ring around the tapped cell, drawn as a closed polyline through the paint the
  /// traffic map's links already use.
  private static func selectionOverlay(for cell: SignalMapperCoverageCell?) -> MapOverlay {
    var ring = (cell?.boundary ?? []).map(\.locationCoordinate)
    if let first = ring.first {
      ring.append(first)
    }
    return MapOverlay(
      id: selectionOverlayID,
      features: ring.count >= 2 ? [MapOverlay.Feature(
        id: cell?.cell.stringValue ?? "none",
        geometry: .polyline(ring),
        weight: 1
      )] : [],
      paint: MapOverlay.WeightedLine(
        color: .label,
        width: 2.5...2.5,
        opacity: 0.9...0.9,
        casing: MapOverlay.Casing(extraWidth: 2)
      ).asPaint
    )
  }

  // MARK: - Hit testing

  /// The captured cell a tap landed in, or nil for a tap on bare map.
  ///
  /// The grid answers this exactly — a coordinate is in one res-9 cell and no other — so
  /// there is no proximity tolerance to tune and no feature query to run.
  static func cell(
    at coordinate: CLLocationCoordinate2D,
    in snapshot: SignalMapperCoverageSnapshot,
    layer: SignalMapperMapLayer = .heard
  ) -> SignalMapperCoverageCell? {
    guard let tapped = SurveyGrid.cell(containing: GeoCoordinate(
      latitude: coordinate.latitude,
      longitude: coordinate.longitude
    )) else { return nil }
    guard let hit = snapshot.cells.first(where: { $0.cell == tapped }) else { return nil }
    // The reach layer omits cells with neither uplink evidence nor probes; a tap on one
    // of those is a tap on bare map there.
    if layer == .reach, hit.reachQuality == nil, !hit.isUnreachedProbed {
      return nil
    }
    return hit
  }

  // MARK: - Camera

  /// The corners that frame every captured cell, padded so cells near the edge are not
  /// clipped by the floating controls. Nil when nothing was captured.
  static func cameraBounds(
    for snapshot: SignalMapperCoverageSnapshot,
    paddingMultiplier: Double = 1.4
  ) -> MLNCoordinateBounds? {
    // Corners of the cells' boundaries, not their centres: a cell is ~350 m across and a
    // one-cell map framed on its centre would clip its own hexagon.
    let coordinates = snapshot.cells.flatMap(\.boundary)
    guard let first = coordinates.first else { return nil }

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

    let minimumSpan = 0.004
    let latitudePad = max((maxLatitude - minLatitude) * (paddingMultiplier - 1) / 2, minimumSpan)
    let longitudePad = max((maxLongitude - minLongitude) * (paddingMultiplier - 1) / 2, minimumSpan)

    // Padding is clamped, not wrapped: a corner past ±180 is not a valid coordinate, and
    // the map drops the whole camera move.
    return MLNCoordinateBounds(
      sw: CLLocationCoordinate2D(
        latitude: max(-90, minLatitude - latitudePad),
        longitude: max(-180, minLongitude - longitudePad)
      ),
      ne: CLLocationCoordinate2D(
        latitude: min(90, maxLatitude + latitudePad),
        longitude: min(180, maxLongitude + longitudePad)
      )
    )
  }

  /// The corners framing a neighbourhood around one coordinate, for the location button.
  static func cameraBounds(
    around coordinate: CLLocationCoordinate2D,
    span: Double = 0.02
  ) -> MLNCoordinateBounds {
    MLNCoordinateBounds(
      sw: CLLocationCoordinate2D(
        latitude: max(-90, coordinate.latitude - span / 2),
        longitude: max(-180, coordinate.longitude - span / 2)
      ),
      ne: CLLocationCoordinate2D(
        latitude: min(90, coordinate.latitude + span / 2),
        longitude: min(180, coordinate.longitude + span / 2)
      )
    )
  }
}

// MARK: - Coordinate bridging

extension GeoCoordinate {
  /// SurveyKit's dependency-free coordinate as CoreLocation's. The bridge lives on the app
  /// side on purpose: SurveyKit stays buildable on Linux for the server.
  var locationCoordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }
}

// MARK: - Paint sugar

private extension MapOverlay.WeightedFill {
  var asPaint: MapOverlay.Paint {
    .weightedFill(self)
  }
}

private extension MapOverlay.WeightedLine {
  var asPaint: MapOverlay.Paint {
    .weightedLine(self)
  }
}
