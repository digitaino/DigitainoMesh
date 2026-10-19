import Foundation
import MeshWX

/// What one bot's word means for another bot's copy of the same warning (phase 2, 18 October
/// 2026; spec §20).
///
/// Several cities' bots share `#meshwx`, meshes are bridged, and every bot is two self-asserted
/// bytes on the wire until messages are signed (wire revision 14). So one bot's word ends another
/// bot's copy only when the bot speaking demonstrably carries that warning's ground and is in
/// range:
///
/// - **A Cancel ends every bot's copy** when the cancelling bot was heard live within
///   ``liveWindow`` of the cancel (``isLiveCancel(isBacklog:lastLiveHeardAt:at:)``, recorded in its
///   `endings`) and its own **complete** statement of its area (Coverage, spec §10) touches the
///   warning, by the rule a digest is judged by (`WeatherStateReducer.touchesCoverage`). A
///   statement with no area filter at all is not evidence of covering anything. A copy issued
///   before the cancel is then ended, however long after it arrives: WX-AUS's feed running five
///   hours behind repeats a Flash Flood Warning WX-SAT cancelled at noon, and the phone shows it
///   as cancelled rather than in force. A copy issued at or after the cancel is a product of its
///   own.
/// - **Which copy to show**: one still in force over one that is not; then one from a bot heard
///   live in the last ``liveWindow`` over a later expiry from one that has not been; then the later
///   expiry. A bot long out of range does not hold a warning open on screen with an expiry nobody
///   in range has confirmed.
///
/// Pure, like the reducer: every input is an argument.
public enum WeatherCrossBot {
  /// Heard live this recently is "in range" (phase 2).
  public static let liveWindow: TimeInterval = 2 * 60 * 60
  /// How long an ending is remembered: the furthest ahead a warning's expiry is believed (spec
  /// §17.5), so no copy of the warning can outlive the memory of its cancel.
  public static let endingRetention: TimeInterval = WeatherStateReducer.warningHorizon
  /// At most this many endings per bot, newest kept.
  public static let maxEndings = 64

  /// One bot's cancel that ended a copy: when the phone heard it, and from whom.
  public struct Ending: Sendable, Hashable {
    public let endedAt: Date
    public let botID: UInt16
  }

  /// One bot's copy of an identity, judged.
  public struct Copy: Sendable {
    public let botID: UInt16
    public let stored: WeatherStoredWarning
    /// Another bot's trusted cancel that ended it, or nil.
    public let ending: Ending?
    /// Not expired, and not ended.
    public let inForce: Bool
    /// Its bot was heard live within ``liveWindow``.
    public let isLive: Bool
    public let liveHeardAt: Date?
  }

  /// Whether a Cancel heard at `at` was heard while its bot was in range: heard live itself, or,
  /// drained from the radio's queue, from a bot heard live within ``liveWindow`` before it.
  /// `lastLiveHeardAt` is the bot's before this message.
  public static func isLiveCancel(isBacklog: Bool, lastLiveHeardAt: Date?, at: Date) -> Bool {
    if !isBacklog { return true }
    guard let lastLiveHeardAt else { return false }
    return at.timeIntervalSince(lastLiveHeardAt) <= liveWindow
  }

  /// Records an ending in `state` and prunes the old ones.
  public static func recordEnding(_ identity: MeshWXWarningIdentity, at: Date, in state: inout WeatherBotState) {
    state.endings[identity] = at
    state.endings = prunedEndings(state.endings, now: at)
  }

  /// Endings younger than ``endingRetention``, at most ``maxEndings``, newest kept.
  public static func prunedEndings(
    _ endings: [MeshWXWarningIdentity: Date], now: Date
  ) -> [MeshWXWarningIdentity: Date] {
    let kept = endings
      .filter { now.timeIntervalSince($0.value) < endingRetention }
      .sorted { lhs, rhs in
        if lhs.value != rhs.value { return lhs.value > rhs.value }
        return WeatherStateReducer.identityOrder(lhs.key, rhs.key)
      }
      .prefix(maxEndings)
    return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
  }

  /// A complete statement with an area filter that touches the warning's ground.
  public static func speaks(
    for warning: MeshWXWarning, coverage: MeshWXCoverage?, areaCentre: WeatherAreaCentre?
  ) -> Bool {
    guard let coverage, coverage.isComplete, !coverage.hasNoAreaFilter else { return false }
    return WeatherStateReducer.touchesCoverage(warning, coverage, areaCentre: areaCentre)
  }

  /// When a bot's trusted cancel ended this copy: the earliest one, or nil.
  public static func ending(
    of copy: WeatherStoredWarning, in states: [UInt16: WeatherBotState], areaCentre: WeatherAreaCentre?
  ) -> Ending? {
    var best: Ending?
    for (botID, state) in states {
      guard let endedAt = state.endings[copy.identity] else { continue }
      if let issuedAt = copy.issuedAt, issuedAt >= endedAt { continue }
      guard speaks(for: copy.warning, coverage: state.coverage?.coverage, areaCentre: areaCentre) else { continue }
      if let held = best, held.endedAt < endedAt || (held.endedAt == endedAt && held.botID < botID) { continue }
      best = Ending(endedAt: endedAt, botID: botID)
    }
    return best
  }

  /// Whether the bot was heard live within ``liveWindow`` of `now`.
  public static func isLive(_ state: WeatherBotState?, now: Date) -> Bool {
    guard let heard = state?.lastLiveHeardAt else { return false }
    return now.timeIntervalSince(heard) <= liveWindow
  }

  /// Whether copy `lhs` is shown over copy `rhs`: in force over not; a bot heard live in the
  /// window over one that has not been, and among bots out of range the one heard more recently;
  /// then the later expiry, then the later message. Two bots both in range are not ranked by which
  /// spoke last, which would swap the copy shown, and the expiry it names, every few minutes.
  public static func prefers(
    _ lhs: (inForce: Bool, isLive: Bool, liveHeardAt: Date?, stored: WeatherStoredWarning),
    over rhs: (inForce: Bool, isLive: Bool, liveHeardAt: Date?, stored: WeatherStoredWarning)
  ) -> Bool {
    if lhs.inForce != rhs.inForce { return lhs.inForce }
    if lhs.isLive != rhs.isLive { return lhs.isLive }
    if !lhs.isLive {
      let left = lhs.liveHeardAt ?? .distantPast
      let right = rhs.liveHeardAt ?? .distantPast
      if left != right { return left > right }
    }
    if lhs.stored.warning.expiresMinutes != rhs.stored.warning.expiresMinutes {
      return lhs.stored.warning.expiresMinutes > rhs.stored.warning.expiresMinutes
    }
    return lhs.stored.receivedAt > rhs.stored.receivedAt
  }

  /// Every bot's copy of one identity, judged, in bot order. `excluding` leaves out the copies of
  /// those bots.
  public static func copies(
    of identity: MeshWXWarningIdentity, in states: [UInt16: WeatherBotState],
    areaCentre: WeatherAreaCentre?, now: Date, excluding: Set<UInt16> = []
  ) -> [Copy] {
    states.keys.sorted().compactMap { botID -> Copy? in
      guard !excluding.contains(botID), let state = states[botID], let stored = state.warnings[identity] else {
        return nil
      }
      let ending = ending(of: stored, in: states, areaCentre: areaCentre)
      return Copy(
        botID: botID, stored: stored, ending: ending,
        inForce: ending == nil && !stored.isExpired(at: now),
        isLive: isLive(state, now: now), liveHeardAt: state.lastLiveHeardAt)
    }
  }

  /// The copy to judge an identity by (``prefers(_:over:)``), or nil when no bot holds one.
  public static func preferred(
    _ identity: MeshWXWarningIdentity, in states: [UInt16: WeatherBotState],
    areaCentre: WeatherAreaCentre?, now: Date, excluding: Set<UInt16> = []
  ) -> Copy? {
    var best: Copy?
    for copy in copies(of: identity, in: states, areaCentre: areaCentre, now: now, excluding: excluding) {
      guard let held = best else { best = copy; continue }
      if prefers(
        (copy.inForce, copy.isLive, copy.liveHeardAt, copy.stored),
        over: (held.inForce, held.isLive, held.liveHeardAt, held.stored)) {
        best = copy
      }
    }
    return best
  }

  /// Whether any bot still holds a copy of the identity in force: not expired, not ended.
  public static func isInForce(
    _ identity: MeshWXWarningIdentity, in states: [UInt16: WeatherBotState],
    areaCentre: WeatherAreaCentre?, now: Date
  ) -> Bool {
    copies(of: identity, in: states, areaCentre: areaCentre, now: now).contains(where: \.inForce)
  }
}
