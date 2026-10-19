import Foundation

/// How far back a traffic aggregation reaches.
///
/// The RX log is a rolling buffer, so a fixed ladder of windows is wrong at both ends: on a
/// radio connected ten minutes ago every window shows the same thing, and on one with a week
/// of history a 15-minute window shows nothing. ``available(oldestEntry:now:)`` therefore
/// offers a ladder scaled to the log actually on hand — the rule legacy's
/// `TrafficHeatmapViewModel.computeTimePeriods` encoded, lifted out of the view model so it
/// can be tested without a store.
///
/// Display names are deliberately absent: this type is the app's *filter*, and the app target
/// owns the localized label for each case.
public enum TrafficTimeWindow: String, Sendable, Hashable, CaseIterable, Identifiable {
  case minutes15 = "15m"
  case minutes30 = "30m"
  case hour1 = "1h"
  case hours3 = "3h"
  case hours6 = "6h"
  case hours12 = "12h"
  case day1 = "1d"
  case days3 = "3d"
  case days7 = "7d"
  /// Everything the log still holds.
  case all

  public var id: String {
    rawValue
  }

  /// How far back the window reaches, or `nil` for everything on record.
  public var duration: TimeInterval? {
    switch self {
    case .minutes15: 900
    case .minutes30: 1800
    case .hour1: 3600
    case .hours3: 10800
    case .hours6: 21600
    case .hours12: 43200
    case .day1: 86400
    case .days3: 259_200
    case .days7: 604_800
    case .all: nil
    }
  }

  /// The receive time at or after which an entry falls inside the window, or `nil` when the
  /// window admits everything.
  public func cutoff(now: Date) -> Date? {
    duration.map { now.addingTimeInterval(-$0) }
  }

  /// Whether an entry received at `date` falls inside the window.
  public func contains(_ date: Date, now: Date) -> Bool {
    guard let cutoff = cutoff(now: now) else { return true }
    return date >= cutoff
  }

  // MARK: - Ladder

  /// The windows worth offering for a log whose oldest surviving entry is `oldestEntry`.
  ///
  /// Three bounded choices plus ``all``, picked so the widest bounded window is of the same
  /// order as the log's own span. An empty log offers ``all`` alone. A clock that has moved
  /// backwards since the entry was written (so the log reads as "from the future") is treated
  /// as the shortest span rather than rejected.
  public static func available(oldestEntry: Date?, now: Date) -> [TrafficTimeWindow] {
    guard let oldestEntry else { return [.all] }
    let span = now.timeIntervalSince(oldestEntry)

    let ladder: [TrafficTimeWindow] = switch span {
    case ..<3600: [.minutes15, .minutes30]
    case ..<21600: [.minutes30, .hour1, .hours3]
    case ..<86400: [.hour1, .hours6, .hours12]
    case ..<604_800: [.hours6, .day1, .days3]
    default: [.day1, .days3, .days7]
    }
    return ladder + [.all]
  }
}
