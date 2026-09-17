import Foundation
import MeshWX

/// Which request an alerts button sends (docs/MESHWX_UI.md §7.4, §12).
///
/// Decided from the *source* bot's state alone: the bot the request goes to is the one whose
/// gaps, missing identities and upgrade markers the request can repair. Another bot's list says
/// nothing about what this one would send back.
public enum WeatherAlertRequests {
  /// "Ask for alerts" under a missed-messages status line.
  ///
  /// - An upgrade whose replacement never came: `>w <county>` for the place's county; with no
  ///   place, the county the upgraded warning covered; else `>w`. Upgrades are storm-based
  ///   warnings, and those carry county codes.
  /// - Warnings the list named that never arrived: one of them by identity, per tap
  ///   (`missingWarnings`).
  /// - A gap with nothing known to be missing: `>d`, the list that says what is active.
  public static func missedMessages(
    source: WeatherBotState,
    placeCountyUGC: String?,
    placeOffice: String?,
    notAvailable: Set<MeshWXWarningIdentity> = [],
    tables: MeshWXTables
  ) -> WeatherRequest {
    if !source.pendingUpgrades.isEmpty {
      if let placeCountyUGC { return .warningsTouching(ugc: placeCountyUGC) }
      let areas = newestUpgrade(in: source).map { tables.namedAreas(for: $0.warning) } ?? []
      if let ugc = (areas.first(where: \.isCounty) ?? areas.first)?.ugc {
        return .warningsTouching(ugc: ugc)
      }
      return .activeWarnings
    }
    return missingWarnings(source: source, placeOffice: placeOffice, notAvailable: notAvailable, tables: tables)
      ?? .digest
  }

  /// The one request for the warnings a list named that this phone does not hold ("Listed, not
  /// received · Ask"), or nil when nothing is missing.
  ///
  /// One warning per tap, by identity: `>w <county>` never finds a zone-coded watch or advisory,
  /// and `>w` and `>w <county>` stop at six, so asking by area can leave the list unfinished
  /// however often it is tapped. The most important goes first: the higher
  /// `WeatherAlertPriority` rank, then the place's own office, then identity order. An identity
  /// the bot has said it does not have since this list arrived (`notAvailable`) is passed over;
  /// once all have been, `>d` asks for a list that no longer names them. With none the bundle
  /// can spell, `>w`.
  public static func missingWarnings(
    source: WeatherBotState,
    placeOffice: String?,
    notAvailable: Set<MeshWXWarningIdentity> = [],
    tables: MeshWXTables
  ) -> WeatherRequest? {
    guard !source.missingFromDigest.isEmpty else { return nil }
    let spellable = source.missingFromDigest.compactMap { identity in
      identityString(identity, tables: tables).map { (identity: identity, text: $0) }
    }
    guard !spellable.isEmpty else { return .activeWarnings }
    let next = spellable
      .filter { !notAvailable.contains($0.identity) }
      .min { isAskedBefore($0.identity, $1.identity, placeOffice: placeOffice, tables: tables) }
    return next.map { .warning(identity: $0.text) } ?? .digest
  }

  /// The order missing warnings are asked for in: priority, then the place's office, then identity.
  static func isAskedBefore(
    _ lhs: MeshWXWarningIdentity,
    _ rhs: MeshWXWarningIdentity,
    placeOffice: String?,
    tables: MeshWXTables
  ) -> Bool {
    let lhsRank = WeatherAlertPriority.rank(event: lhs.event, tables: tables)
    let rhsRank = WeatherAlertPriority.rank(event: rhs.event, tables: tables)
    if lhsRank != rhsRank { return lhsRank < rhsRank }
    let lhsHome = placeOffice != nil && tables.officeCode(lhs.office) == placeOffice
    let rhsHome = placeOffice != nil && tables.officeCode(rhs.office) == placeOffice
    if lhsHome != rhsHome { return lhsHome }
    return WeatherStateReducer.identityOrder(lhs, rhs)
  }

  /// `SV.W.EWX.42`: an identity as the bot's `>w` and `>wt` requests spell it (spec §8.2), or nil
  /// when the bundle cannot name the event or the office.
  public static func identityString(_ identity: MeshWXWarningIdentity, tables: MeshWXTables) -> String? {
    guard let vtec = tables.vtec(for: identity.event),
          let office = tables.officeCode(identity.office) else { return nil }
    return "\(vtec).\(office).\(identity.etn)"
  }

  /// The identity an `event.office.etn` string names, read case-insensitively; nil for anything
  /// the tables cannot resolve.
  public static func identity(from string: String, tables: MeshWXTables) -> MeshWXWarningIdentity? {
    let parts = string.trimmingCharacters(in: .whitespaces).uppercased().split(separator: ".")
    guard parts.count == 4,
          let etn = UInt16(parts[3]),
          let event = tables.eventByCode["\(parts[0]).\(parts[1])"],
          let officePosition = tables.offices.firstIndex(of: String(parts[2])),
          let office = UInt8(exactly: officePosition)
    else { return nil }
    return MeshWXWarningIdentity(event: event, office: office, etn: etn)
  }

  /// The most recently cancelled upgrade, ties broken by identity so the pick does not depend on
  /// dictionary order.
  private static func newestUpgrade(in state: WeatherBotState) -> WeatherPendingUpgrade? {
    state.pendingUpgrades.values.min { lhs, rhs in
      if lhs.cancelledAt != rhs.cancelledAt { return lhs.cancelledAt > rhs.cancelledAt }
      return WeatherStateReducer.identityOrder(lhs.warning.identity, rhs.warning.identity)
    }
  }
}
