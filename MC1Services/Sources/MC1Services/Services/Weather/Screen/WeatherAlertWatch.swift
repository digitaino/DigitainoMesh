import Foundation
import MeshWX

// MARK: - What the user asked to be told about

/// The two extras beyond storm warnings, and whether the phone's own position is watched
/// (docs/MESHWX_UI.md §16).
///
/// Nothing here is on by default: a bell is the only thing that starts a subscription, and
/// the two toggles start off inside it.
public struct WeatherAlertSubscriptions: Sendable, Hashable, Codable {
  /// The phone's own last known position is watched. The position itself is separate
  /// (``WeatherLastPosition``): the app only has one while it is in use, so it can be hours old
  /// and the screen always says how old.
  public var watchesMyLocation: Bool
  /// Warnings that are neither storm warnings nor watches — rank 6 — delivered silently.
  public var notifiesOtherWarnings: Bool
  /// Tornado and Extreme Wind Warnings within 50 km that do not cover the place.
  public var notifiesTornadoNearby: Bool

  public init(
    watchesMyLocation: Bool = false,
    notifiesOtherWarnings: Bool = false,
    notifiesTornadoNearby: Bool = false
  ) {
    self.watchesMyLocation = watchesMyLocation
    self.notifiesOtherWarnings = notifiesOtherWarnings
    self.notifiesTornadoNearby = notifiesTornadoNearby
  }

  private enum CodingKeys: String, CodingKey {
    case watchesMyLocation, notifiesOtherWarnings, notifiesTornadoNearby
  }

  /// Every field absent is "nothing is watched", which is what a phone that has never opened the
  /// screen means.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    watchesMyLocation = try container.decodeIfPresent(Bool.self, forKey: .watchesMyLocation) ?? false
    notifiesOtherWarnings = try container.decodeIfPresent(Bool.self, forKey: .notifiesOtherWarnings) ?? false
    notifiesTornadoNearby = try container.decodeIfPresent(Bool.self, forKey: .notifiesTornadoNearby) ?? false
  }
}

/// The phone's own position as the notifier reads it: the last fix the app happened to take,
/// which is only ever while the app was in use.
///
/// Persisted on its own (`LocationService` records it, and only while My location is watched), so
/// a warning arriving after a relaunch is still matched against somewhere rather than nowhere. It
/// is never worded as following the user: every screen that shows it shows its age.
public struct WeatherLastPosition: Sendable, Hashable, Codable {
  public var latitude: Double
  public var longitude: Double
  /// Metres; negative when the fix carried no usable accuracy.
  public var horizontalAccuracy: Double
  public var timestamp: Date

  public init(latitude: Double, longitude: Double, horizontalAccuracy: Double, timestamp: Date) {
    self.latitude = latitude
    self.longitude = longitude
    self.horizontalAccuracy = horizontalAccuracy
    self.timestamp = timestamp
  }

  public var sample: WeatherLocationSample {
    WeatherLocationSample(
      latitude: latitude, longitude: longitude, horizontalAccuracy: horizontalAccuracy, timestamp: timestamp)
  }
}

/// Everything the evaluator reads before it decides anything: which places are watched, the
/// phone's last position when it is one of them, and the two toggles.
public struct WeatherAlertWatch: Sendable, Hashable {
  /// Saved places with their bell on, newest choice first.
  public var places: [WeatherSavedPlace]
  /// The last position the app knows, and only when My location is watched.
  public var myLocation: WeatherLastPosition?
  public var subscriptions: WeatherAlertSubscriptions

  public init(
    places: [WeatherSavedPlace] = [],
    myLocation: WeatherLastPosition? = nil,
    subscriptions: WeatherAlertSubscriptions = WeatherAlertSubscriptions()
  ) {
    self.places = places
    self.myLocation = myLocation
    self.subscriptions = subscriptions
  }

  /// Nothing is watched: the evaluator stops before it reads any state. Opt-in is enforced here,
  /// not by a preference somewhere else (docs/MESHWX_UI.md §3.1 N-2).
  public var isEmpty: Bool { places.isEmpty && myLocation == nil }
}

// MARK: - The places a warning is matched against

/// One watched place, resolved for a warning that has just arrived.
public struct WeatherWatchedPlace: Sendable, Hashable, Identifiable {
  /// The id of the phone's own position, which no saved place can collide with.
  public static let myLocationID = "myLocation"

  public var id: String
  public var place: WeatherPlace
  /// The fix time for My location, so the row and the report can say how old it is.
  public var positionAt: Date?

  public var isMyLocation: Bool { id == Self.myLocationID }

  public init(id: String, place: WeatherPlace, positionAt: Date? = nil) {
    self.id = id
    self.place = place
    self.positionAt = positionAt
  }

  public init(saved: WeatherSavedPlace) {
    self.init(id: saved.id, place: saved.place)
  }

  /// The phone's own place, from the last position the app knows. `label` is resolved by the
  /// caller, which has the tables; the age is the position's own.
  public static func myLocation(_ position: WeatherLastPosition, label: String, now: Date) -> WeatherWatchedPlace {
    WeatherWatchedPlace(
      id: myLocationID,
      place: WeatherPlace.location(position.sample, label: label, now: now),
      positionAt: position.timestamp)
  }
}

// MARK: - Gate

/// Whether a warning reaches the user at all, and with what (docs/MESHWX_UI.md §16).
///
/// The ranks are `WeatherAlertPriority.rank`: 0 Tornado, 1 Extreme Wind, 2 catastrophic Flash
/// Flood, 3 tornado-tagged Severe Thunderstorm, 4 Flash Flood, 5 Severe Thunderstorm, 6 other
/// warnings, 7–9 watches, advisories and statements.
public enum WeatherAlertDelivery: Sendable, Hashable {
  /// Rank 0–5 covering the place, and a nearby tornado the user asked for: a sound.
  case sound
  /// Rank 6 with the toggle on: in Notification Center, no sound, no banner.
  case silent
}

public enum WeatherAlertGate {
  /// The highest rank that is a storm warning, and the only ranks a backlog may still notify for.
  public static let stormWarningRank = WeatherAlertFolding.neverFoldedRank
  /// Rank 6: a warning that is not one of the six storm warnings.
  public static let otherWarningRank = 6
  /// Tornado and Extreme Wind: the only two that notify from *near* a place.
  public static let tornadoRank = 1

  /// How a warning of `rank` reaches a watched place, or nil for nothing at all.
  ///
  /// - Storm warnings (0–5) notify with sound, and only where they cover the place.
  /// - Other warnings (6) are the opt-in silent toggle, again only where they cover.
  /// - Watches, advisories and statements (7–9) never notify; they stay on the dashboard.
  /// - A Tornado or Extreme Wind Warning within 50 km that does *not* cover the place is the
  ///   second opt-in toggle. Near is only ever produced inside 50 km
  ///   (`WeatherAlertPlacement.nearKilometres`).
  /// - Anything the phone cannot place — no outline yet, no geometry at all, elsewhere — notifies
  ///   nothing: "not placed" is never read as "here".
  public static func delivery(
    rank: Int,
    placement: WeatherAlertPlacement,
    subscriptions: WeatherAlertSubscriptions
  ) -> WeatherAlertDelivery? {
    switch placement {
    case .here:
      if rank <= stormWarningRank { return .sound }
      if rank == otherWarningRank { return subscriptions.notifiesOtherWarnings ? .silent : nil }
      return nil
    case .near:
      guard rank <= tornadoRank, subscriptions.notifiesTornadoNearby else { return nil }
      return .sound
    case .checking, .unplaced, .elsewhere:
      return nil
    }
  }
}
