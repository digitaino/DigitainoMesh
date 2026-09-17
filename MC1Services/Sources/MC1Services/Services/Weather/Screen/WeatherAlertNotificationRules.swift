import Foundation
import MeshWX

// MARK: - What was posted

/// One notification this phone has posted: the warning it stands for, the place it was posted
/// for, and what the user was last told about it.
///
/// Kept between launches. A repeat of a warning must replace its notification silently rather
/// than sound again, and the phone can be relaunched between the two (docs/MESHWX_UI.md §16).
public struct WeatherAlertPost: Sendable, Hashable, Codable, Identifiable {
  /// The request identifier, which is also this row's key.
  public var identifier: String
  public var identity: MeshWXWarningIdentity
  /// The watched place, `WeatherWatchedPlace.id`.
  public var placeID: String
  /// The bot whose copy was posted first. A second bot holding the same warning updates this
  /// notification rather than posting a second one.
  public var botID: UInt16
  public var tornado: MeshWXTornadoTag
  public var floodDamage: MeshWXFloodDamage
  /// The expiry the notification last showed.
  public var expiresMinutes: UInt32
  /// Whether the warning covered the place, as against being near it.
  public var coversPlace: Bool
  /// The last post of any kind, sounding or silent.
  public var postedAt: Date
  /// The last post the user could hear, and the expiry it named. An extension sounds again only
  /// once it is 20 minutes past this, and only against the time the user was actually told.
  public var alertedAt: Date
  public var alertedExpiresMinutes: UInt32

  public var id: String { identifier }

  public init(
    identifier: String,
    identity: MeshWXWarningIdentity,
    placeID: String,
    botID: UInt16,
    tornado: MeshWXTornadoTag,
    floodDamage: MeshWXFloodDamage,
    expiresMinutes: UInt32,
    coversPlace: Bool,
    postedAt: Date,
    alertedAt: Date,
    alertedExpiresMinutes: UInt32
  ) {
    self.identifier = identifier
    self.identity = identity
    self.placeID = placeID
    self.botID = botID
    self.tornado = tornado
    self.floodDamage = floodDamage
    self.expiresMinutes = expiresMinutes
    self.coversPlace = coversPlace
    self.postedAt = postedAt
    self.alertedAt = alertedAt
    self.alertedExpiresMinutes = alertedExpiresMinutes
  }

  public var expiresAt: Date { Date(unixMinutes: expiresMinutes) }
}

/// What one arriving warning should do to the notification standing for it at one watched place.
public enum WeatherAlertNotificationDecision: Sendable, Hashable {
  /// Nothing reaches the user: not watched, not covered, not severe enough, already expired, or
  /// a repeat of something the user has already dismissed.
  case none
  /// Post it. `sound` is false for a silent replacement and for the rank-6 toggle;
  /// `isLate` marks a warning drained from the radio's queue at connect.
  case post(sound: Bool, isLate: Bool)
  /// Take the delivered notification away: the warning was cancelled, removed by a list, or no
  /// longer covers this place.
  case remove
}

// MARK: - Rules

/// The rules for turning warnings into notifications (docs/MESHWX_UI.md §16), as pure
/// functions: the evaluator does the I/O, this decides.
public enum WeatherAlertNotificationRules {
  /// A repeat sounds again on an extension only once the last sounding post is this old.
  public static let escalationQuietPeriod: TimeInterval = 20 * 60
  /// An expiry is only "extended" past the minute the wire truncates to and the two clocks'
  /// disagreement — the same margin a digest is judged by.
  public static let extensionMargin: TimeInterval = WeatherStateReducer.digestMargin
  /// A post is forgotten this long after the warning it stands for expired. Nothing is scheduled
  /// for an expiry; this only keeps the ledger from growing.
  public static let postRetention: TimeInterval = 6 * 60 * 60

  /// `wx-4C7A-SV.W.EWX.42@zip:78701`: the bot, the identity as the bot itself spells it
  /// (spec §8.2), and the place it was posted for — one notification per warning per watched
  /// place. The bot is the one that delivered the copy first; another bot's copy of the same
  /// warning updates this identifier instead of posting its own.
  public static func identifier(
    botID: UInt16,
    identity: MeshWXWarningIdentity,
    placeID: String,
    tables: MeshWXTables
  ) -> String {
    let name = WeatherAlertRequests.identityString(identity, tables: tables)
      ?? "\(identity.event).\(identity.office).\(identity.etn)"
    return "wx-\(String(format: "%04X", botID))-\(name)@\(placeID)"
  }

  /// Notifications for one place are threaded together, so a night of warnings for Austin is one
  /// group rather than a column.
  public static func threadIdentifier(placeID: String) -> String {
    "wx-place-\(placeID)"
  }

  /// What to do with one warning at one watched place.
  ///
  /// - Parameters:
  ///   - delivery: what the gate allows for this rank and placement, nil for nothing.
  ///   - rank: `WeatherAlertPriority.rank`, for the backlog rule.
  ///   - isBacklog: the message was drained from the radio's queue at connect. It is hours old
  ///     and says nothing about now, so it notifies only while the warning is still active and
  ///     only for a storm warning — and says it arrived late.
  ///   - posted: what this phone has already told the user about this warning at this place.
  ///   - isDelivered: the notification is still in Notification Center. A repeat of one the user
  ///     has dismissed or opened is not put back, but an escalation is.
  public static func decide(
    warning: MeshWXWarning,
    rank: Int,
    placement: WeatherAlertPlacement,
    delivery: WeatherAlertDelivery?,
    isBacklog: Bool,
    posted: WeatherAlertPost?,
    isDelivered: Bool,
    now: Date
  ) -> WeatherAlertNotificationDecision {
    let expiresAt = Date(unixMinutes: warning.expiresMinutes)
    // An expired warning never notifies, live or late. What was already posted stays: it names
    // its own end time, and taking it away would read as an all-clear.
    guard expiresAt > now else { return .none }
    // The phone cannot place this one — the outlines are still loading, or the bundle has no
    // outline for its areas. That is never read as "not here", so it neither posts nor takes
    // away what an earlier message did post (§7.1).
    switch placement {
    case .checking, .unplaced: return .none
    case .here, .near, .elsewhere: break
    }
    let coversPlace = placement == .here
    // The gate closed on a warning already posted — the update no longer covers this place, or
    // the user turned the toggle off — so what stands is no longer true for it.
    guard let delivery else { return posted == nil ? .none : .remove }
    if isBacklog, rank > WeatherAlertGate.stormWarningRank { return .none }

    guard let posted else {
      return .post(sound: delivery == .sound, isLate: isBacklog)
    }
    if isEscalation(warning: warning, coversPlace: coversPlace, posted: posted, now: now) {
      return .post(sound: delivery == .sound, isLate: isBacklog)
    }
    // A repeat or an update replaces what is on screen, silently. One the user has already
    // dismissed or opened is not brought back for that.
    guard isDelivered else { return .none }
    return .post(sound: false, isLate: isBacklog)
  }

  /// Whether a repeat of a warning is worth sounding again for:
  ///
  /// - the tornado tag rose (possible → radar indicated → observed);
  /// - flood damage reached catastrophic;
  /// - it now covers the place, where the user was only told it was near;
  /// - or its expiry was extended, and the user was last told more than 20 minutes ago.
  ///
  /// Everything else is the same warning said again, which replaces the notification in silence.
  static func isEscalation(
    warning: MeshWXWarning,
    coversPlace: Bool,
    posted: WeatherAlertPost,
    now: Date
  ) -> Bool {
    if warning.tornado.rawValue > posted.tornado.rawValue { return true }
    if warning.floodDamage == .catastrophic, posted.floodDamage != .catastrophic { return true }
    // Near became here: the reason the user asked to hear about tornadoes nearby was this
    // moment. Not in the owner's list of escalations, and it is one (docs/MESHWX_UI.md §3.1 N-6).
    if coversPlace, !posted.coversPlace { return true }
    let extended = Date(unixMinutes: warning.expiresMinutes)
      > Date(unixMinutes: posted.alertedExpiresMinutes).addingTimeInterval(extensionMargin)
    return extended && now.timeIntervalSince(posted.alertedAt) > escalationQuietPeriod
  }

  /// The record left by a post, from the one it replaces.
  public static func record(
    identifier: String,
    warning: MeshWXWarning,
    placeID: String,
    botID: UInt16,
    coversPlace: Bool,
    sound: Bool,
    posted: WeatherAlertPost?,
    now: Date
  ) -> WeatherAlertPost {
    WeatherAlertPost(
      identifier: identifier,
      identity: warning.identity,
      placeID: placeID,
      botID: botID,
      tornado: warning.tornado,
      floodDamage: warning.floodDamage,
      expiresMinutes: warning.expiresMinutes,
      coversPlace: coversPlace,
      postedAt: now,
      alertedAt: sound ? now : (posted?.alertedAt ?? now),
      alertedExpiresMinutes: sound
        ? warning.expiresMinutes
        : (posted?.alertedExpiresMinutes ?? warning.expiresMinutes))
  }

  /// Posts for warnings that ended long enough ago that no repeat can follow. Nothing is removed
  /// from Notification Center by this: it is only what the phone stops remembering.
  public static func pruned(_ posts: [String: WeatherAlertPost], now: Date) -> [String: WeatherAlertPost] {
    posts.filter { now.timeIntervalSince($0.value.expiresAt) < postRetention }
  }
}
