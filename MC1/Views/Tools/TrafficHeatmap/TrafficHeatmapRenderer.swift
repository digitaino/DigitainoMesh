import CoreLocation
import MapLibre
import MC1Services
import UIKit

/// Turns a ``TrafficHeatmapSnapshot`` into the map's own vocabulary: pins through upstream's
/// point system, weight-driven geometry through the ``MapOverlay`` API, and a camera that
/// frames the result.
///
/// Two layers of meaning, kept apart on purpose, the way legacy's guide explained them:
/// **how much** traffic a node or link carries is size and opacity, **how well** our radio
/// hears a node is colour. Links are never coloured by signal — the radio only ever learns the
/// quality of the final hop into itself, so a colour on a link between two remote repeaters
/// would be an invention.
enum TrafficHeatmapRenderer {
  // MARK: - Overlay ids

  /// One overlay carries all the links; the node bubbles are split one overlay per signal
  /// quality, because colour is a per-overlay property (see ``MapOverlay``). This mirrors how
  /// upstream colours its SNR trace lines: a layer per quality, not a colour per feature.
  static let linkOverlayID = "traffic-links"

  static func bubbleOverlayID(_ quality: SNRQuality) -> String {
    "traffic-nodes-\(quality.overlayToken)"
  }

  // MARK: - Points

  /// A pin per placed node, through upstream's pin system so taps, labels and callouts work
  /// exactly as they do everywhere else on the map.
  ///
  /// Pin ids are derived from the public key rather than minted fresh, so a reload of unchanged
  /// data diffs to "no change" and the map does not churn its point source.
  static func points(for snapshot: TrafficHeatmapSnapshot) -> [MapPoint] {
    snapshot.nodes.map { node in
      MapPoint(
        id: pointID(for: node.publicKey),
        coordinate: node.coordinate.coordinate,
        pinStyle: .repeater,
        label: node.name,
        isClusterable: false,
        hopIndex: nil,
        badgeText: nil
      )
    }
  }

  /// A stable id for a node's pin: the first 16 bytes of its public key — already a unique
  /// identifier — reinterpreted as a UUID, zero-padded if a stored key is somehow shorter.
  static func pointID(for publicKey: Data) -> UUID {
    var bytes = [UInt8](publicKey.prefix(16))
    bytes.append(contentsOf: repeatElement(0, count: 16 - bytes.count))
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3],
      bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11],
      bytes[12], bytes[13], bytes[14], bytes[15]
    ))
  }

  // MARK: - Overlays

  static func overlays(for snapshot: TrafficHeatmapSnapshot) -> [MapOverlay] {
    // Links first, so the bubbles that mark their endpoints sit above them.
    [linkOverlay(for: snapshot.segments)] + bubbleOverlays(for: snapshot.nodes)
  }

  /// Links: one colour for all of them, with traffic carried by width and opacity. The white
  /// casing is upstream's line idiom — it is what keeps a coloured line legible over satellite
  /// imagery.
  private static func linkOverlay(for segments: [TrafficSegmentLoad]) -> MapOverlay {
    MapOverlay(
      id: linkOverlayID,
      features: segments.map { segment in
        MapOverlay.Feature(
          id: segment.id,
          geometry: .polyline([
            segment.endpointA.coordinate.coordinate,
            segment.endpointB.coordinate.coordinate,
          ]),
          weight: segment.normalizedWeight
        )
      },
      paint: MapOverlay.WeightedLine(
        color: .systemTeal,
        width: 1.5...7,
        opacity: 0.35...0.95,
        casing: MapOverlay.Casing(extraWidth: 2.5)
      ).asPaint
    )
  }

  /// Node bubbles: a translucent disc under each pin, sized by how much traffic the node
  /// relayed and tinted by how well our radio hears it. A node only ever seen relaying for
  /// others has no direct reading at all and stays neutral.
  ///
  /// Every quality is declared whether or not it has members in this snapshot, so the stack
  /// order is settled by the map's first apply rather than by which tint happened to show up
  /// first (see `updateOverlays`).
  private static func bubbleOverlays(for nodes: [TrafficNodeLoad]) -> [MapOverlay] {
    SNRQuality.trafficBubbleOrder.map { quality in
      let members = nodes.filter { SNRQuality(snr: $0.averageSNR) == quality }
      return MapOverlay(
        id: bubbleOverlayID(quality),
        features: members.map { node in
          MapOverlay.Feature(
            id: node.publicKey.uppercaseHexString(),
            geometry: .point(node.coordinate.coordinate),
            weight: node.normalizedWeight
          )
        },
        paint: MapOverlay.WeightedCircle(
          color: quality.uiColor,
          radius: 8...26,
          opacity: 0.28...0.55,
          strokeColor: quality.uiColor,
          strokeWidth: 1
        ).asPaint
      )
    }
  }

  // MARK: - Camera

  /// The corners that frame every placed node, padded so pins near the edge are not clipped by
  /// the floating controls. Nil when nothing is placed.
  static func cameraBounds(
    for snapshot: TrafficHeatmapSnapshot,
    paddingMultiplier: Double = 1.4
  ) -> MLNCoordinateBounds? {
    let coordinates = snapshot.nodes.map(\.coordinate)
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

    // A single node has no extent of its own, so pad it out to a legible neighbourhood.
    let minimumSpan = 0.01
    let latitudePad = max((maxLatitude - minLatitude) * (paddingMultiplier - 1) / 2, minimumSpan)
    let longitudePad = max((maxLongitude - minLongitude) * (paddingMultiplier - 1) / 2, minimumSpan)

    // Padding is clamped, not wrapped: a corner past ±180 is not a valid coordinate, and the
    // map drops the whole camera move — leaving "Center on Traffic" inert for that dataset,
    // because the version it bumped is already marked applied.
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
  static func cameraBounds(around coordinate: CLLocationCoordinate2D, span: Double = 0.02) -> MLNCoordinateBounds {
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

// MARK: - Paint sugar

private extension MapOverlay.WeightedLine {
  var asPaint: MapOverlay.Paint {
    .weightedLine(self)
  }
}

private extension MapOverlay.WeightedCircle {
  var asPaint: MapOverlay.Paint {
    .weightedCircle(self)
  }
}

// MARK: - Signal quality

extension SNRQuality {
  /// Best signal first, unknown last, so the legend and the overlay stack read the same way.
  static let trafficBubbleOrder: [SNRQuality] = [.excellent, .good, .fair, .poor, .unknown]

  /// Stable, identifier-safe token for the overlay id this quality's bubbles live under.
  var overlayToken: String {
    switch self {
    case .excellent: "excellent"
    case .good: "good"
    case .fair: "fair"
    case .poor: "poor"
    case .unknown: "unknown"
    }
  }
}
