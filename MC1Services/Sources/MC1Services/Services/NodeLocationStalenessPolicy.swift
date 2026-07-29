import CoreLocation
import Foundation

/// Decides whether to offer a one-tap refresh of the radio's advert location.
///
/// A MeshCore radio carries a *manually configured* location in firmware, mirrored into the
/// Device row from `SelfInfo`. Nothing on the radio notices when the operator travels, so a
/// location typed in on a trip keeps going out with every advert — every peer and every map
/// on the mesh sees the stale spot. This policy is the whole decision: nothing here touches a
/// clock, a radio, or `UserDefaults`, so the entire rule is testable by passing values in.
public enum NodeLocationStalenessPolicy {
  /// 50 miles, in meters.
  ///
  /// Deliberately coarse. The radio's location is hand-entered and only meaningful at mesh
  /// scale, so the threshold has to sit far above a commute, a day trip, or a sloppy first
  /// phone fix, and only fire on "you moved and never told the radio". The motivating case
  /// was a radio still advertising a city on another island a month after the trip ended.
  public static let thresholdMeters: CLLocationDistance = 80467.2

  /// How long "Not Now" silences the prompt for that radio. One week: long enough that a
  /// user who genuinely wants the configured location left alone is not nagged, short enough
  /// that a user who tapped it away by reflex gets a second chance.
  public static let snoozeInterval: TimeInterval = 7 * 24 * 60 * 60

  /// Why no prompt was offered. Carried so callers can log the reason without re-deriving it.
  public enum SkipReason: Equatable, Sendable {
    /// The radio has no configured location (or a null-island sentinel) — nothing to correct.
    case deviceHasNoLocation
    /// No usable phone fix yet. The caller should re-evaluate when one arrives.
    case noPhoneFix
    /// The radio is close enough to where the phone is.
    case withinThreshold(distanceMeters: CLLocationDistance)
    /// The user chose "Not Now" recently; `until` is when asking becomes allowed again.
    case snoozed(until: Date)
  }

  public enum Decision: Equatable, Sendable {
    case prompt(distanceMeters: CLLocationDistance)
    case skip(SkipReason)

    /// The distance to show in the prompt, or `nil` when no prompt is warranted.
    public var promptDistanceMeters: CLLocationDistance? {
      guard case let .prompt(distance) = self else { return nil }
      return distance
    }
  }

  /// Evaluates the stale-location rule.
  ///
  /// Checks run cheapest-and-most-decisive first, and distance is resolved before the snooze
  /// so a radio that is *not* stale reports `.withinThreshold` rather than hiding behind a
  /// stale snooze record.
  ///
  /// - Parameters:
  ///   - deviceLatitude: The radio's configured latitude.
  ///   - deviceLongitude: The radio's configured longitude.
  ///   - deviceHasLocation: `DeviceDTO.hasLocation` — a non-zero, geographically valid fix.
  ///   - phoneCoordinate: The phone's current coordinate, or `nil` when no fix is available.
  ///   - lastSnoozedAt: When the user last chose "Not Now" for this radio, or `nil`.
  ///   - now: The current time, injected for testability.
  ///   - thresholdMeters: Distance at which the radio counts as stale.
  ///   - snoozeInterval: How long a "Not Now" suppresses the prompt.
  public static func evaluate(
    deviceLatitude: Double,
    deviceLongitude: Double,
    deviceHasLocation: Bool,
    phoneCoordinate: CLLocationCoordinate2D?,
    lastSnoozedAt: Date?,
    now: Date,
    thresholdMeters: CLLocationDistance = thresholdMeters,
    snoozeInterval: TimeInterval = snoozeInterval
  ) -> Decision {
    guard deviceHasLocation else { return .skip(.deviceHasNoLocation) }

    guard let phoneCoordinate, phoneCoordinate.isValidFix else {
      return .skip(.noPhoneFix)
    }

    let distance = distanceMeters(
      deviceLatitude: deviceLatitude,
      deviceLongitude: deviceLongitude,
      phoneCoordinate: phoneCoordinate
    )
    guard distance > thresholdMeters else {
      return .skip(.withinThreshold(distanceMeters: distance))
    }

    if let lastSnoozedAt {
      let expiry = lastSnoozedAt.addingTimeInterval(snoozeInterval)
      if now < expiry { return .skip(.snoozed(until: expiry)) }
    }

    return .prompt(distanceMeters: distance)
  }

  /// Great-circle distance between the radio's configured location and the phone's fix.
  public static func distanceMeters(
    deviceLatitude: Double,
    deviceLongitude: Double,
    phoneCoordinate: CLLocationCoordinate2D
  ) -> CLLocationDistance {
    let device = CLLocation(latitude: deviceLatitude, longitude: deviceLongitude)
    let phone = CLLocation(latitude: phoneCoordinate.latitude, longitude: phoneCoordinate.longitude)
    return device.distance(from: phone)
  }

  /// Locale-aware distance string for the prompt copy ("50 mi" in the US, "80 km" elsewhere).
  ///
  /// Uses the same `.measurement(width: .abbreviated, usage: .road)` style the map's path
  /// distance banner and the Line-of-Sight readouts use, so one radio distance never reads in
  /// different units in two places.
  public static func formattedDistance(
    _ meters: CLLocationDistance,
    locale: Locale = .autoupdatingCurrent
  ) -> String {
    Measurement(value: meters, unit: UnitLength.meters)
      .formatted(
        .measurement(width: .abbreviated, usage: .road)
          .locale(locale)
      )
  }
}
