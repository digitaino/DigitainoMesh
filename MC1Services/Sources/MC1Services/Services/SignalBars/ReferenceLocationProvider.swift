import CoreLocation
import Foundation

/// A point to measure candidate distances from — the phone's fix, or failing that the
/// connected radio's own position.
///
/// Plain degrees rather than a `CLLocation`, matching how ``MovementHintProvider`` keeps
/// CoreMotion out of this package: the app target owns the location frameworks, this
/// package only ranks with the numbers.
public struct ReferenceCoordinate: Sendable, Equatable {
  public let latitude: Double
  public let longitude: Double

  public init(latitude: Double, longitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
  }

  /// Great-circle distance in meters to a candidate node's position.
  public func distanceMeters(toLatitude latitude: Double, longitude: Double) -> Double {
    RFCalculator.distance(
      from: CLLocationCoordinate2D(latitude: self.latitude, longitude: self.longitude),
      to: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    )
  }
}

/// Supplies the current ``ReferenceCoordinate``, if one is known.
///
/// Pull-based like ``MovementHintProvider``: the engine asks at name-resolution time, so
/// an implementation only has to keep its latest reading.
public protocol ReferenceLocationProvider: Sendable {
  func currentReferenceCoordinate() async -> ReferenceCoordinate?
}

/// The default provider: no location. Hash collisions then rank by recency alone.
public struct NoReferenceLocationProvider: ReferenceLocationProvider {
  public init() {}

  public func currentReferenceCoordinate() async -> ReferenceCoordinate? {
    nil
  }
}

/// A ``ReferenceLocationProvider`` whose value is pushed in from outside.
///
/// The only real sources of a location are the app target's CoreLocation service and the
/// connected radio's device record, neither of which this package reaches into. The app
/// pushes fixes in; the engine reads the latest out.
public actor ReferenceLocationRelay: ReferenceLocationProvider {
  /// How far the reference must move before proximity ranking could plausibly change.
  /// Collisions are disambiguated at neighbourhood-to-city scale, so a couple of hundred
  /// meters of fix drift is noise not worth a re-resolve.
  public static let significantMoveMeters: Double = 250

  private var current: ReferenceCoordinate?
  /// The coordinate the last `true` return announced, so drift accumulates against a
  /// fixed point instead of resetting on every push.
  private var lastAnnounced: ReferenceCoordinate?

  public init() {}

  public func currentReferenceCoordinate() async -> ReferenceCoordinate? {
    current
  }

  /// Stores the freshest fix.
  /// - Returns: `true` when it moved enough from the last announced fix that resolved
  ///   names may rank differently — the caller should then ask the engine to re-resolve.
  @discardableResult
  public func update(_ coordinate: ReferenceCoordinate) -> Bool {
    current = coordinate
    if let lastAnnounced,
       lastAnnounced.distanceMeters(toLatitude: coordinate.latitude, longitude: coordinate.longitude)
       < Self.significantMoveMeters {
      return false
    }
    lastAnnounced = coordinate
    return true
  }
}
