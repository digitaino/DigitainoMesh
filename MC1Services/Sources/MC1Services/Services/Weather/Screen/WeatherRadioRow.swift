import Foundation

/// The row at the foot of every place page (docs/MESHWX_UI.md §10):
///
///     WX-AUS · heard 2 min ago · alerts as of 8:02 PM  ›
///
/// It is the only thing on the page that says anything about the alert list, and it is the way to
/// the radio page. The page above it says nothing about alerts on a quiet day — no check, no
/// status line, no "none for your location" — so the honesty the page gave up lives here: the row
/// **turns orange** when the alert list is old or missing, or when this phone missed messages from
/// the radio. Silence on the page is then never silence everywhere; it is one row away from being
/// accounted for.
public struct WeatherRadioRow: Sendable, Hashable {
  /// Live traffic only: a backlog drained from your radio's queue at connect is not the radio
  /// being in range now. Nil with nothing heard live this session.
  public var heardAt: Date?
  /// When the alert list was built, on the bot's clock. Nil when none has arrived.
  public var listBuiltAt: Date?
  /// A gap, a warning the list named that never arrived, or an unfinished upgrade.
  public var missedMessages: Bool
  /// The list is older than its three-hour cadence allows, or none has arrived at all.
  public var listIsOld: Bool

  public init(heardAt: Date? = nil, listBuiltAt: Date? = nil, missedMessages: Bool = false, listIsOld: Bool = true) {
    self.heardAt = heardAt
    self.listBuiltAt = listBuiltAt
    self.missedMessages = missedMessages
    self.listIsOld = listIsOld
  }

  /// Orange. Nothing else on the page changes colour with the weather data, so this reads as the
  /// one thing worth opening.
  public var needsAttention: Bool { missedMessages || listIsOld }

  public static func make(source: WeatherScreenSnapshot.Source?, state: WeatherBotState?, now: Date) -> WeatherRadioRow {
    let digest = state?.digest
    return WeatherRadioRow(
      heardAt: source?.lastLiveHeardAt,
      listBuiltAt: digest?.builtAt,
      missedMessages: state.map {
        $0.needsDigest || !$0.missingFromDigest.isEmpty || !$0.pendingUpgrades.isEmpty
      } ?? false,
      // No list at all is not "fresh": until one arrives the phone cannot tell whether anything
      // is active, and the row is the only place that now says so.
      listIsOld: digest.map { now.timeIntervalSince($0.builtAt) > WeatherAlertStatus.listFreshFor } ?? true)
  }
}
