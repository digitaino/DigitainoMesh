import Foundation

/// The one strip above the weather when an alert covers the place (docs/MESHWX_UI.md §7).
///
/// Always the same height, whatever is happening: one alert named, its end time, and a count of
/// the others. A tornado warning and a heat advisory are the same shape on the page — the colour
/// and the name carry the difference — because a card that grows with the weather is a card the
/// eye stops trusting, and because the page below it has to stay where it was.
///
/// Only ``WeatherAlertPlacement/here`` earns the strip: an alert whose outline has not loaded, or
/// one that names no area at all, is never read as covering the place. Those are on the radio
/// page, in the alerts list, where they can be read rather than reacted to.
public struct WeatherWarningBanner: Sendable, Hashable {
  /// The one the strip names: the most important alert covering the place.
  public var item: WeatherAlertItem
  /// How many others also cover it. The strip stays one line; "+2 more" opens the list.
  public var more: Int

  public init(item: WeatherAlertItem, more: Int) {
    self.item = item
    self.more = more
  }

  public static func make(_ items: [WeatherAlertItem]) -> WeatherWarningBanner? {
    let here = items.filter { $0.placement == .here }
    guard let first = here.min(by: isBefore) else { return nil }
    return WeatherWarningBanner(item: first, more: here.count - 1)
  }

  /// §7.2's order, narrowed to the alerts that cover the place: a live alert before one that has
  /// just expired, then the event's rank, then the soonest expiry.
  static func isBefore(_ lhs: WeatherAlertItem, _ rhs: WeatherAlertItem) -> Bool {
    if isLive(lhs) != isLive(rhs) { return isLive(lhs) }
    if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
    if lhs.expiresAt != rhs.expiresAt { return lhs.expiresAt < rhs.expiresAt }
    return lhs.identity.etn < rhs.identity.etn
  }

  /// An upgrade whose replacement never arrived is live: it is the warning that is missing, not a
  /// warning that ended.
  static func isLive(_ item: WeatherAlertItem) -> Bool {
    item.kind != .expiredRecently
  }
}
