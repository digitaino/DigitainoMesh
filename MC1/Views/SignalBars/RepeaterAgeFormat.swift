import Foundation

/// Compact age readout for the repeater table's Age column: one unit, narrow width — "45s",
/// "2m", "3h", "2d" in English, localized by the shared units style.
///
/// The system relative style (`Text(_, style: .relative)`) spells out "2 min, 46 sec", which
/// cannot fit a table column and truncated to uselessness ("2 min, 4…"). One unit is the right
/// precision anyway: the column answers "is this measurement fresh", and the sub-minute tail of
/// a 2-minute age changes nothing.
///
/// Pure so the unit selection and clamping can be unit-tested; the table wraps it in a
/// `TimelineView` for live updates.
enum RepeaterAgeFormat {
  /// Formats the age of `lastHeard` as seen from `now`, in `locale`. A future `lastHeard`
  /// (clock skew) clamps to zero rather than counting up from a negative age.
  ///
  /// The value floors to its unit — an age reads "2m" until it is fully three minutes old —
  /// so the floored whole value is formatted rather than the raw duration, which the units
  /// style would round to nearest.
  static func compact(from lastHeard: Date, to now: Date, locale: Locale = .autoupdatingCurrent) -> String {
    let seconds = max(0, now.timeIntervalSince(lastHeard))
    let (unit, unitSeconds): (Duration.UnitsFormatStyle.Unit, TimeInterval) = switch seconds {
    case ..<60: (.seconds, 1)
    case ..<3600: (.minutes, 60)
    case ..<86400: (.hours, 3600)
    default: (.days, 86400)
    }
    let floored = (seconds / unitSeconds).rounded(.down) * unitSeconds
    return Duration.seconds(floored).formatted(
      .units(allowed: [unit], width: .narrow, maximumUnitCount: 1)
        .locale(locale)
    )
  }
}
