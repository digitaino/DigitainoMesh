import Foundation
import os
import UserNotifications

/// What the alert evaluator needs from the notification centre. A protocol so every rule in
/// docs/MESHWX_UI.md §16 is tested against a recorder rather than against iOS.
public protocol WeatherAlertNotificationPoster: Sendable {
  /// Adds or replaces the notification under its identifier.
  func post(_ notification: WeatherAlertNotification) async
  /// Takes delivered notifications away: a cancelled warning, or one that no longer covers the
  /// place. Never an all-clear in their place.
  func remove(identifiers: [String]) async
  /// The weather notifications still in Notification Center. One the user has dismissed or
  /// opened is not put back by a repeat.
  func deliveredIdentifiers() async -> Set<String>
  /// Whether iOS will show anything at all.
  func isAuthorized() async -> Bool
}

/// The production poster.
///
/// It talks to `UNUserNotificationCenter` directly rather than through `NotificationService`:
/// weather notifications carry no badge, no actions and no unread count, and the service's
/// sync-window suppression is about chat messages arriving in bulk, which a warning is not.
public struct UserNotificationWeatherAlertPoster: WeatherAlertNotificationPoster {
  private let logger = Logger(subsystem: "com.mc1", category: "WeatherAlerts")

  public init() {}

  public func post(_ notification: WeatherAlertNotification) async {
    let content = UNMutableNotificationContent()
    content.title = notification.content.title
    content.subtitle = notification.content.subtitle
    content.body = notification.content.body
    if notification.sound {
      content.sound = .default
      content.interruptionLevel = .active
    } else {
      // Notification Center, with no sound and no banner: a replacement must not interrupt the
      // user again. There is no time-sensitive or critical entitlement here, so `.active` is the
      // loudest level available and `.passive` the quietest.
      content.sound = nil
      content.interruptionLevel = .passive
    }
    content.threadIdentifier = notification.threadIdentifier
    content.userInfo = notification.userInfo
    do {
      try await UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil))
    } catch {
      logger.warning("Failed to post a weather alert notification: \(error.localizedDescription)")
    }
  }

  public func remove(identifiers: [String]) async {
    guard !identifiers.isEmpty else { return }
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
  }

  public func deliveredIdentifiers() async -> Set<String> {
    let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
    return Set(delivered.lazy
      .filter { $0.request.content.userInfo[WeatherAlertNotificationKeys.type] as? String
        == WeatherAlertNotificationKeys.weatherAlert }
      .map(\.request.identifier))
  }

  public func isAuthorized() async -> Bool {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral: return true
    default: return false
    }
  }
}
