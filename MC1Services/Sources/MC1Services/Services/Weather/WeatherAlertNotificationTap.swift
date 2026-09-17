import Foundation
import MeshWX
import Observation

/// Where a tapped alert notification is left for the Weather tool to pick up.
///
/// The notification delegate is per connection and the tool's model lives for one visit, so
/// neither can hold what a tap asked for: this is the one process-wide place both can see. The
/// app target's router reads it, opens the Weather tool, and the tool opens that alert.
@Observable
@MainActor
public final class WeatherAlertNotificationTap {
  public static let shared = WeatherAlertNotificationTap()

  /// What the tapped notification named.
  public struct Target: Sendable, Hashable {
    public var identity: MeshWXWarningIdentity
    public var botID: UInt16
    public var placeID: String
    /// When the tap happened, so a tap nobody followed up on does not open an alert an hour
    /// later.
    public var tappedAt: Date

    public init(identity: MeshWXWarningIdentity, botID: UInt16, placeID: String, tappedAt: Date = Date()) {
      self.identity = identity
      self.botID = botID
      self.placeID = placeID
      self.tappedAt = tappedAt
    }
  }

  /// How long a tap waits for the Weather tool to open before it is dropped.
  public static let freshness: TimeInterval = 10 * 60

  /// The alert a tap asked for, until something takes it. Nil most of the time.
  public private(set) var pending: Target?

  public init() {}

  /// Reads a tapped notification's `userInfo`; anything that is not one of ours is ignored.
  public func receive(userInfo: [AnyHashable: Any]) {
    guard userInfo[WeatherAlertNotificationKeys.type] as? String == WeatherAlertNotificationKeys.weatherAlert,
          let event = (userInfo[WeatherAlertNotificationKeys.event] as? String).flatMap(UInt8.init),
          let office = (userInfo[WeatherAlertNotificationKeys.office] as? String).flatMap(UInt8.init),
          let etn = (userInfo[WeatherAlertNotificationKeys.etn] as? String).flatMap(UInt16.init),
          let botID = (userInfo[WeatherAlertNotificationKeys.botID] as? String).flatMap(UInt16.init)
    else { return }
    pending = Target(
      identity: MeshWXWarningIdentity(event: event, office: office, etn: etn),
      botID: botID,
      placeID: userInfo[WeatherAlertNotificationKeys.placeID] as? String ?? "")
  }

  /// Takes the pending alert, leaving nothing behind: a tap opens one screen, once — and only
  /// while it is recent, so a tap the user never followed does not open an alert an hour later.
  public func take(now: Date = Date()) -> Target? {
    let target = pending
    pending = nil
    guard let target, now.timeIntervalSince(target.tappedAt) < Self.freshness else { return nil }
    return target
  }
}
