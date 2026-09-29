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
  /// The phone's own; fixed only by tests, which must not read the machine's clock settings.
  var calendar: Calendar = .autoupdatingCurrent
  var locale: Locale = .autoupdatingCurrent

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
    // When it applies, as every alert says it (revision 12), without the countdown: "40 min left"
    // in a notification centre is stale the moment it is read. A watch that has not started says
    // "from Wed 7:00 PM until Fri 7:00 PM" rather than posing as in force.
    parts.append(WeatherFormatting.alertWindow(
      beginsAt: subject.beginsAt, expiresAt: subject.expiresAt, now: subject.now,
      calendar: calendar, locale: locale, countdown: false))
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
