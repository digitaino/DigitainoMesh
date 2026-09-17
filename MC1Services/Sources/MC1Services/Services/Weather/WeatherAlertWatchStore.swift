import Foundation
import os
import Synchronization

/// Where the evaluator reads what is watched, and where the screens write it.
///
/// One protocol for the three things that decide whether anything is posted at all — the saved
/// places with their bells, the two toggles, and the phone's own last position — so the tests can
/// hand the notifier a watch list without touching defaults.
public protocol WeatherAlertWatchStore: Sendable {
  func watch() -> WeatherAlertWatch
}

/// The production store: one defaults key for the toggles, the saved places for the bells, and
/// one for the last position.
///
/// The position is read only while My location is watched, and is cleared when that bell goes
/// off (``WeatherLastPositionStore``): a phone that is not watching its own position has no
/// reason to keep one on disk.
///
/// `@unchecked Sendable`: the only stored property is a `UserDefaults` reference, which Apple
/// documents as thread-safe.
public struct DefaultsWeatherAlertWatchStore: WeatherAlertWatchStore, @unchecked Sendable {
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func watch() -> WeatherAlertWatch {
    let subscriptions = subscriptions
    return WeatherAlertWatch(
      places: WeatherSavedPlacesStore(defaults: defaults).watched,
      myLocation: subscriptions.watchesMyLocation ? WeatherLastPositionStore(defaults: defaults).position : nil,
      subscriptions: subscriptions)
  }

  public var subscriptions: WeatherAlertSubscriptions {
    get {
      guard let data = defaults.data(forKey: Self.key),
            let decoded = try? JSONDecoder().decode(WeatherAlertSubscriptions.self, from: data)
      else { return WeatherAlertSubscriptions() }
      return decoded
    }
    nonmutating set {
      guard let data = try? JSONEncoder().encode(newValue) else { return }
      defaults.set(data, forKey: Self.key)
      if !newValue.watchesMyLocation {
        WeatherLastPositionStore(defaults: defaults).clear()
      }
    }
  }

  private static let key = "weather.alertSubscriptions"
}

// MARK: - The phone's own position

/// The last position the app knows, kept so a warning arriving after a relaunch still has
/// somewhere to be matched against (docs/MESHWX_UI.md §16).
///
/// Written by `LocationService` from whatever fix the app happens to take — the app only has
/// location while it is in use, so this is "where the phone was", never a track: one row,
/// overwritten, and only while My location is watched. Turning that bell off deletes it.
///
/// `@unchecked Sendable`: see `WeatherSavedPlacesStore`.
public struct WeatherLastPositionStore: @unchecked Sendable {
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var position: WeatherLastPosition? {
    get {
      guard let data = defaults.data(forKey: Self.key) else { return nil }
      return try? JSONDecoder().decode(WeatherLastPosition.self, from: data)
    }
    nonmutating set {
      guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
        defaults.removeObject(forKey: Self.key)
        return
      }
      defaults.set(data, forKey: Self.key)
    }
  }

  public func clear() {
    defaults.removeObject(forKey: Self.key)
    // The next fix after the bell goes back on is worth writing whenever it arrives.
    Self.lastWrite.withLock { $0 = nil }
  }

  /// How far apart two fixes have to be before the newer one is worth writing: a survey stream
  /// delivers one a second, and a notification is matched within the place's own uncertainty
  /// anyway.
  static let minimumInterval: TimeInterval = 60

  /// Records a fix, if My location is watched and the last one written is a minute old.
  ///
  /// The whole rule lives here so the one call site inside `LocationService` is a single line
  /// that cannot grow: a phone that is not watching its own position writes nothing at all.
  public func record(latitude: Double, longitude: Double, horizontalAccuracy: Double, timestamp: Date) {
    guard DefaultsWeatherAlertWatchStore(defaults: defaults).subscriptions.watchesMyLocation else { return }
    let last = Self.lastWrite.withLock { $0 }
    if let last, timestamp.timeIntervalSince(last) < Self.minimumInterval { return }
    Self.lastWrite.withLock { $0 = timestamp }
    position = WeatherLastPosition(
      latitude: latitude, longitude: longitude, horizontalAccuracy: horizontalAccuracy, timestamp: timestamp)
  }

  /// When this process last wrote a position, so a fix a second does not become a write a second.
  private static let lastWrite = Mutex<Date?>(nil)

  private static let key = "weather.lastPosition"
}

// MARK: - What has been posted

/// Where the notifications this phone has posted are remembered, so a repeat of a warning
/// replaces one silently instead of sounding again — across a relaunch too.
public protocol WeatherAlertPostLedger: Sendable {
  func posts() -> [String: WeatherAlertPost]
  func save(_ posts: [String: WeatherAlertPost])
}

/// One JSON blob under one defaults key, pruned by `WeatherAlertNotificationRules.pruned`, so it
/// can never become a history of the weather.
///
/// `@unchecked Sendable`: see `WeatherSavedPlacesStore`.
public struct DefaultsWeatherAlertPostLedger: WeatherAlertPostLedger, @unchecked Sendable {
  private let defaults: UserDefaults
  private let logger = Logger(subsystem: "com.mc1", category: "WeatherAlerts")

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func posts() -> [String: WeatherAlertPost] {
    guard let data = defaults.data(forKey: Self.key),
          let decoded = try? JSONDecoder().decode([String: WeatherAlertPost].self, from: data)
    else { return [:] }
    return decoded
  }

  public func save(_ posts: [String: WeatherAlertPost]) {
    guard let data = try? JSONEncoder().encode(posts) else {
      logger.warning("Could not write the weather alert notification ledger")
      return
    }
    defaults.set(data, forKey: Self.key)
  }

  private static let key = "weather.alertPosts"
}
