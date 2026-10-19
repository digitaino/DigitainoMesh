import CoreLocation
import MapLibre
import MC1Services
import SurveyKit
import UIKit

/// Turns a ``SignalMapperMapSnapshot`` into the map's own vocabulary: hexagons through the
/// ``MapOverlay`` API, and a camera that frames them.
///
/// Two visual channels, kept apart the way the traffic map keeps its two: **how well** the
/// mesh reaches a cell is colour, **how much** was heard there is opacity. A cell with no
/// attributed reading has no SNR to grade and stays neutral rather than being coloured on a
/// guess.
///
/// This is the second consumer of the overlay API (§2.3), and the one it was designed for:
/// the fill paint and polygon geometry it uses were written into ``MapOverlay``'s notes as
/// "what the signal mapper will need" before either existed.
/// Which of the two coverage questions the map is currently answering.
///
/// One raw log, two reads of it (docs/SIGNAL_MAPPER_V3.md §3): what the mesh sounds like
/// from here, and what *hears us* from here — the second being the whole point of active
/// surveying.
enum SignalMapperMapLayer: String, CaseIterable, Identifiable {
  /// Downlink: cells coloured by the best SNR we heard a repeater directly at there.
  case heard
  /// Uplink: cells coloured by the best SNR a repeater reported for us, with a neutral
  /// "heard you" fill where only an echo proves it and a "no reach" fill where we probed
  /// and nobody answered.
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
  /// The reach layer's "they heard you, no number" cells (§1's neutral fill).
  static let heardYouOverlayID = "mapper-cells-heardyou"
  /// The ride's rings: hexagons this ride has evidence in, drawn over dimmed history.
  static let rideTouchedOverlayID = "mapper-ride-touched"
  /// The subset of those whose first ever evidence is this ride's — a heavier ring, so
  /// "new ground" is visible from a moving bike (mockup screen 3).
  static let rideFreshOverlayID = "mapper-ride-fresh"

  // MARK: - Overlays

  static func overlays(
    for snapshot: SignalMapperMapSnapshot,
    selected: SignalMapperMapCell?,
    layer: SignalMapperMapLayer = .heard,
    rideStartedAt: Date? = nil
  ) -> [MapOverlay] {
    // Fills first, rings above them, selection last: overlays stack in the order listed.
    cellOverlays(for: snapshot, layer: layer, rideStartedAt: rideStartedAt)
      + rideOverlays(for: snapshot, rideStartedAt: rideStartedAt)
      + [selectionOverlay(for: selected)]
  }

  /// One translucent hexagon per captured cell, tinted by how well we hear the mesh there
  /// (Heard) or how well it hears us (Reach), and solidified by how much was heard.
  ///
  /// Every overlay is declared on every layer, empty or not: the stack order is settled by
  /// the map's first apply, and a layer toggle must change feature sets only — stable ids
  /// keep the diff on its cheap in-place path.
  private static func cellOverlays(
    for snapshot: SignalMapperMapSnapshot,
    layer: SignalMapperMapLayer,
    rideStartedAt: Date?
  ) -> [MapOverlay] {
    // While a ride is open the history steps back so the ride's own rings can be read over
    // it (§3). Dimming the *fills* rather than hiding them keeps the answer to "have I been
    // here before" on screen, which is the question a ring is asking.
    let isRiding = rideStartedAt != nil
    let fillOpacity: ClosedRange<Double> = isRiding ? 0.07...0.22 : 0.18...0.55
    let outlineAlpha: Double = isRiding ? 0.3 : 0.7

    let qualityOverlays = SignalQuality.coverageOrder.map { quality in
      let members = snapshot.cells.filter { cell in
        switch layer {
        case .heard: cell.hearQuality == quality
        case .reach: cell.reach == .reported(quality)
        }
      }
      return MapOverlay(
        id: cellOverlayID(quality),
        features: members.map(Self.polygonFeature),
        paint: MapOverlay.WeightedFill(
          color: quality.uiColor,
          // Never fully opaque: the streets under a cell are what make it legible as
          // coverage of a *place* rather than an abstract grid.
          opacity: fillOpacity,
          outlineColor: quality.uiColor.withAlphaComponent(outlineAlpha)
        ).asPaint
      )
    }

    // "They heard me, but nobody said how well": echo-only evidence. The mockup draws this
    // hatched; `MapOverlay` has no fill pattern (fill paint is a colour and an opacity
    // ramp, §"Paint"), so it is a flat neutral at a *fixed* opacity — no weight ramp,
    // because there is no magnitude to ramp — under a brighter hairline than any other
    // fill uses. Flat-and-outlined is what separates it from the graded cells beside it.
    let heardYouMembers = layer == .reach ? snapshot.cells.filter { $0.reach == .heardYou } : []
    let heardYou = MapOverlay(
      id: heardYouOverlayID,
      features: heardYouMembers.map { cell in
        MapOverlay.Feature(
          id: cell.cell.stringValue,
          geometry: .polygon(cell.boundary.map(\.locationCoordinate)),
          weight: 1
        )
      },
      paint: MapOverlay.WeightedFill(
        color: .systemGray2,
        opacity: isRiding ? 0.12...0.12 : 0.3...0.3,
        outlineColor: UIColor.label.withAlphaComponent(isRiding ? 0.25 : 0.55)
      ).asPaint
    )

    // "We shouted from here and nobody heard": the reach layer's most important cells,
    // drawn in a flat neutral so they read as absence rather than as a sixth quality.
    let noReachMembers = layer == .reach ? snapshot.cells.filter { $0.reach == .noReach } : []
    let noReach = MapOverlay(
      id: noReachOverlayID,
      features: noReachMembers.map { cell in
        MapOverlay.Feature(
          id: cell.cell.stringValue,
          geometry: .polygon(cell.boundary.map(\.locationCoordinate)),
          weight: max(0.4, cell.weight)
        )
      },
      paint: MapOverlay.WeightedFill(
        color: .systemGray,
        opacity: isRiding ? 0.1...0.2 : 0.25...0.45,
        outlineColor: UIColor.systemGray.withAlphaComponent(outlineAlpha + 0.1)
      ).asPaint
    )
    return qualityOverlays + [heardYou, noReach]
  }

  /// The ride's rings: every hexagon with evidence stamped since the run started, and a
  /// heavier ring on the ones this ride put on the map for the first time.
  ///
  /// Declared always, empty when no ride is open, for the same stable-id reason the layer
  /// overlays are.
  private static func rideOverlays(
    for snapshot: SignalMapperMapSnapshot,
    rideStartedAt: Date?
  ) -> [MapOverlay] {
    var touched: [MapOverlay.Feature] = []
    var fresh: [MapOverlay.Feature] = []
    if let rideStartedAt {
      for cell in snapshot.cells {
        switch cell.rideRing(since: rideStartedAt) {
        case .touched: touched.append(ringFeature(for: cell))
        case .fresh: fresh.append(ringFeature(for: cell))
        case nil: continue
        }
      }
    }
    return [
      MapOverlay(
        id: rideTouchedOverlayID,
        features: touched,
        paint: MapOverlay.WeightedLine(
          color: .tintColor,
          width: 1.5...1.5,
          opacity: 0.75...0.75
        ).asPaint
      ),
      MapOverlay(
        id: rideFreshOverlayID,
        features: fresh,
        paint: MapOverlay.WeightedLine(
          color: .tintColor,
          width: 3...3,
          opacity: 0.95...0.95,
          casing: MapOverlay.Casing(color: .systemBackground, extraWidth: 1.5, opacity: 0.6)
        ).asPaint
      )
    ]
  }

  /// A ring around the tapped cell, drawn as a closed polyline through the paint the
  /// traffic map's links already use.
  private static func selectionOverlay(for cell: SignalMapperMapCell?) -> MapOverlay {
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

  private static func polygonFeature(for cell: SignalMapperMapCell) -> MapOverlay.Feature {
    MapOverlay.Feature(
      id: cell.cell.stringValue,
      geometry: .polygon(cell.boundary.map(\.locationCoordinate)),
      weight: cell.weight
    )
  }

  private static func ringFeature(for cell: SignalMapperMapCell) -> MapOverlay.Feature {
    var ring = cell.boundary.map(\.locationCoordinate)
    if let first = ring.first {
      ring.append(first)
    }
    return MapOverlay.Feature(id: cell.cell.stringValue, geometry: .polyline(ring), weight: 1)
  }

  // MARK: - Hit testing

  /// The captured cell a tap landed in, or nil for a tap on bare map.
  ///
  /// The grid answers this exactly — a coordinate is in one res-9 cell and no other — so
  /// there is no proximity tolerance to tune and no feature query to run.
  static func cell(
    at coordinate: CLLocationCoordinate2D,
    in snapshot: SignalMapperMapSnapshot,
    layer: SignalMapperMapLayer = .heard
  ) -> SignalMapperMapCell? {
    guard let hit = snapshot.cell(containing: GeoCoordinate(
      latitude: coordinate.latitude,
      longitude: coordinate.longitude
    )) else { return nil }
    // The reach layer omits cells with neither uplink evidence nor a refused probe; a tap
    // on one of those is a tap on bare map there.
    return hit.isDrawn(on: layer) ? hit : nil
  }

  // MARK: - Camera

  /// The corners that frame every captured cell, padded so cells near the edge are not
  /// clipped by the floating controls. Nil when nothing was captured.
  static func cameraBounds(
    for snapshot: SignalMapperMapSnapshot,
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
