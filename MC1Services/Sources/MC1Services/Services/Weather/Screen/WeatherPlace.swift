import Foundation
import MeshWX

/// A phone fix reduced to the values a weather screen compares.
///
/// A value type on purpose: SwiftUI watches it with `onChange`, and a `CLLocation` compares by
/// identity, so a fresh object per read would restart work on every render.
public struct WeatherLocationSample: Sendable, Hashable {
  public var latitude: Double
  public var longitude: Double
  /// Metres; negative when the fix carries no usable accuracy.
  public var horizontalAccuracy: Double
  public var timestamp: Date

  public init(latitude: Double, longitude: Double, horizontalAccuracy: Double, timestamp: Date) {
    self.latitude = latitude
    self.longitude = longitude
    self.horizontalAccuracy = horizontalAccuracy
    self.timestamp = timestamp
  }

  public var coordinate: MeshWXCoordinate {
    MeshWXCoordinate(latitude: latitude, longitude: longitude)
  }
}

/// The one place the Weather screen answers for (docs/MESHWX_UI.md §5).
public struct WeatherPlace: Sendable, Hashable {
  public enum Kind: Sendable, Hashable {
    /// Where the phone is, from a fix no older than an hour.
    case current
    /// Where the phone was: shown with its age and never enough for a "no alerts" claim.
    case lastKnown
    /// A town the user searched for.
    case searched
  }

  public var kind: Kind
  public var coordinate: MeshWXCoordinate
  /// "Austin, TX".
  public var label: String
  /// How far from `coordinate` the user may really be. An alert that passes within this
  /// distance covers the place.
  public var uncertaintyKilometres: Double
  /// The fix time for a location place.
  public var locatedAt: Date?

  public init(
    kind: Kind,
    coordinate: MeshWXCoordinate,
    label: String,
    uncertaintyKilometres: Double,
    locatedAt: Date? = nil
  ) {
    self.kind = kind
    self.coordinate = coordinate
    self.label = label
    self.uncertaintyKilometres = uncertaintyKilometres
    self.locatedAt = locatedAt
  }

  public static let lastKnownAfter: TimeInterval = 60 * 60
  static let freshFixAge: TimeInterval = 5 * 60
  static let maximumDriftKilometres = 25.0
  static let searchedUncertaintyKilometres = 5.0

  /// The place for a phone fix.
  public static func location(_ sample: WeatherLocationSample, label: String, now: Date) -> WeatherPlace {
    let age = max(0, now.timeIntervalSince(sample.timestamp))
    return WeatherPlace(
      kind: age > lastKnownAfter ? .lastKnown : .current,
      coordinate: sample.coordinate,
      label: label,
      uncertaintyKilometres: uncertainty(accuracyMetres: sample.horizontalAccuracy, age: age),
      locatedAt: sample.timestamp
    )
  }

  /// The place for a searched town: its census centre, with a radius a town spans.
  public static func searched(_ place: MeshWXPlace) -> WeatherPlace {
    WeatherPlace(
      kind: .searched,
      coordinate: MeshWXCoordinate(latitude: place.lat, longitude: place.lon),
      label: WeatherNames.placeLabel(name: place.name, state: place.state),
      uncertaintyKilometres: searchedUncertaintyKilometres
    )
  }

  /// max(accuracy, 0.5 km) + 1 km for each minute of age past five, capped at 25 km.
  ///
  /// A kilometre a minute is someone driving. For someone walking it over-includes a
  /// neighbouring county, and the cost of that is being shown an alert close enough to be
  /// worth seeing — the cheap side of the error.
  static func uncertainty(accuracyMetres: Double, age: TimeInterval) -> Double {
    let accuracy = accuracyMetres >= 0 ? accuracyMetres / 1000 : 1
    let drift = min(max(0, age - freshFixAge) / 60, maximumDriftKilometres)
    return max(accuracy, 0.5) + drift
  }
}
