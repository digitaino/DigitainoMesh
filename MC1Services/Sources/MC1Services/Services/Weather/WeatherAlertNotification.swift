import Foundation
import MeshWX
import Synchronization

// MARK: - What is posted

/// The words of one alert notification. Built by ``WeatherAlertNotificationCopy`` so the app
/// target's localized tables decide them, exactly as `NotificationStringProvider` does for chats.
public struct WeatherAlertNotificationContent: Sendable, Hashable {
  /// The event: "Tornado Warning".
  public var title: String
  /// Where it came from: "National Weather Service via WX-AUS".
  public var subtitle: String
  /// "Austin · until 9:41 PM · radar indicated", and the late note under it when the message was
  /// drained from the radio's queue.
  public var body: String

  public init(title: String, subtitle: String, body: String) {
    self.title = title
    self.subtitle = subtitle
    self.body = body
  }
}

/// One notification, ready to post: what it says, how loudly, and everything a tap needs to open
/// the alert it stands for.
public struct WeatherAlertNotification: Sendable, Hashable, Identifiable {
  public var identifier: String
  public var threadIdentifier: String
  public var content: WeatherAlertNotificationContent
  /// A sound and a banner. False is a silent delivery: Notification Center only, which is what a
  /// replacement and the rank-6 toggle get.
  public var sound: Bool
  public var identity: MeshWXWarningIdentity
  public var botID: UInt16
  public var placeID: String

  public var id: String { identifier }

  public init(
    identifier: String,
    threadIdentifier: String,
    content: WeatherAlertNotificationContent,
    sound: Bool,
    identity: MeshWXWarningIdentity,
    botID: UInt16,
    placeID: String
  ) {
    self.identifier = identifier
    self.threadIdentifier = threadIdentifier
    self.content = content
    self.sound = sound
    self.identity = identity
    self.botID = botID
    self.placeID = placeID
  }

  /// The `userInfo` a tap is read back from (`WeatherAlertNotificationTap`). Strings only, so it
  /// survives the round trip through the notification store.
  public var userInfo: [String: String] {
    [
      WeatherAlertNotificationKeys.type: WeatherAlertNotificationKeys.weatherAlert,
      WeatherAlertNotificationKeys.event: String(identity.event),
      WeatherAlertNotificationKeys.office: String(identity.office),
      WeatherAlertNotificationKeys.etn: String(identity.etn),
      WeatherAlertNotificationKeys.botID: String(botID),
      WeatherAlertNotificationKeys.placeID: placeID
    ]
  }
}

/// `userInfo` keys, shared by the poster and the tap reader.
public enum WeatherAlertNotificationKeys {
  public static let type = "type"
  public static let weatherAlert = "weatherAlert"
  public static let event = "wxEvent"
  public static let office = "wxOffice"
  public static let etn = "wxEtn"
  public static let botID = "wxBot"
  public static let placeID = "wxPlace"
}

// MARK: - Copy

/// One alert as the words are chosen for it.
public struct WeatherAlertNotificationSubject: Sendable, Hashable {
  public var warning: MeshWXWarning
  /// The watched place's short name: "Austin".
  public var placeLabel: String
  /// Covering the place, or near it with a distance and a direction.
  public var placement: WeatherAlertPlacement
  /// The bot's advertised name where the phone knows it: "WX-AUS".
  public var botName: String?
  /// The message was drained from the radio's queue at connect, so the warning was sent while
  /// the radio was out of range.
  public var isLate: Bool
  public var now: Date

  public init(
    warning: MeshWXWarning,
    placeLabel: String,
    placement: WeatherAlertPlacement,
    botName: String?,
    isLate: Bool,
    now: Date
  ) {
    self.warning = warning
    self.placeLabel = placeLabel
    self.placement = placement
    self.botName = botName
    self.isLate = isLate
    self.now = now
  }

  public var expiresAt: Date { Date(unixMinutes: warning.expiresMinutes) }
}

/// Where a notification's words come from. The app target implements it over `Weather.strings`;
/// the fallback below is the English of those same entries, the way `NotificationStringProvider`
/// has an English fallback for every chat notification.
public protocol WeatherAlertNotificationCopy: Sendable {
  func content(for subject: WeatherAlertNotificationSubject, tables: MeshWXTables) -> WeatherAlertNotificationContent
  /// What the phone's own place is called when no town is near enough to name it.
  var myLocationLabel: String { get }
}

/// The English of `Weather.strings`, used until the app installs its localized copy and by the
/// tests, which are the reference for the wording.
public struct WeatherAlertDefaultCopy: WeatherAlertNotificationCopy {
  public var myLocationLabel: String { "your location" }

  public init() {}

  public func content(
    for subject: WeatherAlertNotificationSubject,
    tables: MeshWXTables
  ) -> WeatherAlertNotificationContent {
    let event = tables.eventLabel(for: subject.warning.event)
    let source = subject.botName.map { "National Weather Service via \($0)" }
      ?? "National Weather Service via the weather radio"
    var parts: [String] = []
    let place = Self.shortName(subject.placeLabel)
    switch subject.placement {
    case let .near(kilometres, direction):
      parts.append("\(Self.kilometres(kilometres)) \(direction.abbreviation) of \(place)")
    default:
      parts.append(place)
    }
    parts.append("until \(Self.time(subject.expiresAt))")
    if let tag = Self.tag(subject.warning) { parts.append(tag) }
    var body = parts.joined(separator: " · ")
    if subject.isLate {
      body += "\nReceived late — sent while your radio was out of range."
    }
    return WeatherAlertNotificationContent(title: event, subtitle: source, body: body)
  }

  /// "Austin, TX" → "Austin": a notification has one line for the place and the state adds
  /// nothing to a town the user chose themselves.
  static func shortName(_ label: String) -> String {
    guard let comma = label.lastIndex(of: ","), comma != label.startIndex else { return label }
    return String(label[..<comma])
  }

  /// "9:41 PM" on the phone's clock.
  static func time(_ date: Date) -> String {
    date.formatted(Date.FormatStyle(locale: .autoupdatingCurrent, calendar: .autoupdatingCurrent).hour().minute())
  }

  static func kilometres(_ kilometres: Double) -> String {
    kilometres < 0.5 ? "under 1 km" : "\(Int(kilometres.rounded())) km"
  }

  /// The one tag worth a line in a notification: what the warning is being called for. The order
  /// is the order of `MeshWXPresentation.tags`, whose first entry is the tornado tag.
  static func tag(_ warning: MeshWXWarning) -> String? {
    switch MeshWXPresentation.tags(for: warning).first {
    case let .tornado(value):
      switch value {
      case .none: return nil
      case .possible: return "tornado possible"
      case .radarIndicated: return "radar indicated"
      case .observed: return "tornado observed"
      }
    case let .floodDamage(value):
      switch value {
      case .catastrophic: return "catastrophic damage"
      case .considerable: return "considerable damage"
      case .none, .reserved: return nil
      }
    case let .floodSource(value):
      switch value {
      case .radar: return "radar indicated"
      case .radarAndGauge: return "radar and gauges"
      case .observed: return "flooding observed"
      case .none: return nil
      }
    case let .hail(inches):
      return "\(inches.formatted(.number.precision(.fractionLength(2)))) in hail"
    case let .wind(mph):
      return "\(Int(mph)) mph wind"
    case nil:
      return nil
    }
  }
}

/// Where the app installs its localized copy, once, at launch.
///
/// A process-wide holder rather than an injected dependency because the container that owns the
/// notifier is built inside this package, per connection, and the words live in the app target's
/// string tables. The same shape as `DebugLogBuffer.shared`, and with the same rule: installed
/// once, read from any isolation.
public enum WeatherAlertNotificationCopyRegistry {
  private static let installed = Mutex<(any WeatherAlertNotificationCopy)?>(nil)

  public static func install(_ copy: any WeatherAlertNotificationCopy) {
    installed.withLock { $0 = copy }
  }

  /// The app's copy, or the English fallback until it is installed — which is what a background
  /// launch with no scene gets.
  public static var current: any WeatherAlertNotificationCopy {
    installed.withLock { $0 } ?? WeatherAlertDefaultCopy()
  }
}
