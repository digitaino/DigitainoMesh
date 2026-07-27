import CoreLocation
import UIKit

/// A weighted data layer a tool contributes to the shared map (§2.3).
///
/// `points` and `lines` on ``MC1MapView`` are the app's *own* vocabulary: a fixed set of pin
/// styles and line styles, each with a fixed look. A tool that measures something needs the
/// opposite — one kind of geometry whose thickness, size and opacity carry a number. That is
/// what an overlay is: a bag of features, each with a `weight` in `0...1`, plus a ``Paint``
/// saying how weight turns into pixels.
///
/// Registering one is a value assignment — `MC1MapView(overlays: […])` — and the map does the
/// rest: a source per overlay, style layers per overlay, both diffed on update and rebuilt
/// after a style reload. Overlays draw beneath the app's own lines and pins, so a heat layer
/// never buries the pins standing on it, and they draw among themselves in the order given.
///
/// **Colour is per overlay, not per feature**, matching how upstream colours its SNR trace
/// lines: one style layer per quality, selected by predicate. A tool colouring features
/// categorically registers one overlay per category (the traffic heatmap does this for its
/// SNR-tinted node bubbles); a tool colouring by magnitude puts the magnitude in `weight` and
/// lets opacity carry it (the heatmap does this for link traffic).
///
/// **Adding a consumer.** A hex-cell heat layer — the signal mapper's eventual need — is a
/// third `Geometry` case (`polygon`) and a third `Paint` case (`weightedFill`, an
/// `MLNFillStyleLayer` with the same weight ramp on `fillOpacity`). Registration, sourcing,
/// diffing, z-ordering and style-reload recovery are already done and unchanged.
struct MapOverlay: Identifiable, Equatable {
  /// Namespaces this overlay's source and style layers. Must be unique among the overlays
  /// handed to one map, and stable across updates — it is what the diff matches on.
  let id: String
  let features: [Feature]
  let paint: Paint

  // MARK: - Features

  /// One drawn thing, and how much of whatever is being measured it carries.
  struct Feature: Equatable {
    let id: String
    let geometry: Geometry
    /// `0...1`, where 1 is the heaviest feature in the layer. Values outside the range are
    /// clamped when the ramp is applied.
    let weight: Double
  }

  enum Geometry: Equatable {
    /// A run of two or more coordinates. A link between two nodes is the two-coordinate case.
    case polyline([CLLocationCoordinate2D])
    case point(CLLocationCoordinate2D)

    static func == (lhs: Geometry, rhs: Geometry) -> Bool {
      switch (lhs, rhs) {
      case let (.polyline(a), .polyline(b)):
        a.count == b.count && zip(a, b).allSatisfy(Geometry.sameCoordinate)
      case let (.point(a), .point(b)):
        Geometry.sameCoordinate(a, b)
      default:
        false
      }
    }

    private static func sameCoordinate(
      _ lhs: CLLocationCoordinate2D,
      _ rhs: CLLocationCoordinate2D
    ) -> Bool {
      lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
  }

  // MARK: - Paint

  /// How a feature's weight becomes pixels. Each range is read as "at weight 0 … at weight 1",
  /// interpolated linearly in between.
  enum Paint: Equatable {
    case weightedLine(WeightedLine)
    case weightedCircle(WeightedCircle)
  }

  struct WeightedLine: Equatable {
    var color: UIColor
    var width: ClosedRange<Double>
    var opacity: ClosedRange<Double>
    /// The halo drawn under the line, following upstream's casing idiom on its trace and
    /// message-path lines — it is what keeps a coloured line legible over satellite imagery.
    var casing: Casing?

    init(
      color: UIColor,
      width: ClosedRange<Double>,
      opacity: ClosedRange<Double> = 1...1,
      casing: Casing? = nil
    ) {
      self.color = color
      self.width = width
      self.opacity = opacity
      self.casing = casing
    }
  }

  struct WeightedCircle: Equatable {
    var color: UIColor
    var radius: ClosedRange<Double>
    var opacity: ClosedRange<Double>
    var strokeColor: UIColor
    var strokeWidth: Double

    init(
      color: UIColor,
      radius: ClosedRange<Double>,
      opacity: ClosedRange<Double> = 1...1,
      strokeColor: UIColor = .white,
      strokeWidth: Double = 0
    ) {
      self.color = color
      self.radius = radius
      self.opacity = opacity
      self.strokeColor = strokeColor
      self.strokeWidth = strokeWidth
    }
  }

  /// A wider, softer line drawn under a weighted line.
  struct Casing: Equatable {
    var color: UIColor
    /// Added to the line's own width at every weight, so the halo tracks the line as it grows.
    var extraWidth: Double
    var opacity: Double

    init(color: UIColor = .white, extraWidth: Double = 2, opacity: Double = 0.8) {
      self.color = color
      self.extraWidth = extraWidth
      self.opacity = opacity
    }
  }
}
