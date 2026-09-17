import Foundation
import MC1Services
import MeshWX

/// The words of an alert notification, from the app's own string tables (docs/MESHWX_UI.md
/// §16).
///
/// The evaluator runs in the service layer, which has no localized strings, so it asks for them
/// through `WeatherAlertNotificationCopy` — the same boundary `NotificationStringProvider` draws
/// for chat notifications. `WeatherAlertDefaultCopy` in that package is the English of these very
/// entries, and stands in until `install` has run.
struct WeatherAlertNotificationCopyImpl: WeatherAlertNotificationCopy {
  var myLocationLabel: String { L10n.Weather.Weather.Notifications.myLocationLabel }

  func content(
    for subject: WeatherAlertNotificationSubject,
    tables: MeshWXTables
  ) -> WeatherAlertNotificationContent {
    let place = WeatherFormatting.placeName(subject.placeLabel)
    var parts: [String] = []
    if case let .near(kilometres, direction) = subject.placement {
      parts.append(L10n.Weather.Weather.Notifications.near(
        WeatherFormatting.distance(kilometres, direction: direction), place))
    } else {
      parts.append(place)
    }
    parts.append(L10n.Weather.Weather.Notifications.until(WeatherFormatting.clockTime(
      subject.expiresAt, now: subject.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)))
    // One tag, the one the warning is being called for: a lock screen is not the place for the
    // whole line the alerts card carries.
    if let tag = WeatherFormatting.tagTexts(for: subject.warning).first {
      parts.append(tag)
    }
    var body = parts.joined(separator: " · ")
    if subject.isLate {
      body += "\n" + L10n.Weather.Weather.Notifications.late
    }
    return WeatherAlertNotificationContent(
      title: WeatherFormatting.eventName(subject.warning.event, tables: tables),
      subtitle: subject.botName.map { L10n.Weather.Weather.Alerts.source($0) }
        ?? L10n.Weather.Weather.Alerts.sourceGeneric,
      body: body)
  }
}
