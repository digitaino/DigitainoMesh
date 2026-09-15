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
  /// - A gap with nothing known to be missing: `>d`, the list that says what is active.
  /// - One identity the list named that never arrived: `>w SV.W.EWX.42`, that warning alone.
  /// - Several missing, or an upgrade whose replacement never came: `>w <county>` for the
  ///   place's county; with no place, the county the upgraded warning covered; else `>w`.
  public static func missedMessages(
    source: WeatherBotState,
    placeCountyUGC: String?,
    tables: MeshWXTables
  ) -> WeatherRequest {
    if source.pendingUpgrades.isEmpty {
      if source.missingFromDigest.isEmpty { return .digest }
      if source.missingFromDigest.count == 1,
         let identity = identityString(source.missingFromDigest[0], tables: tables) {
        return .warning(identity: identity)
      }
    }
    if let placeCountyUGC { return .warningsTouching(ugc: placeCountyUGC) }
    if let ugc = newestUpgrade(in: source).flatMap({ tables.namedAreas(for: $0.warning).first?.ugc }) {
      return .warningsTouching(ugc: ugc)
    }
    return .activeWarnings
  }

  /// The one request for the warnings a list named that this phone does not hold ("Listed, not
  /// received · Ask"): that warning, or every warning touching the place's county when several
  /// are missing, or every active warning when the place has no county. Nil when nothing is
  /// missing.
  public static func missingWarnings(
    source: WeatherBotState,
    placeCountyUGC: String?,
    tables: MeshWXTables
  ) -> WeatherRequest? {
    let missing = source.missingFromDigest
    guard !missing.isEmpty else { return nil }
    if missing.count == 1, let identity = identityString(missing[0], tables: tables) {
      return .warning(identity: identity)
    }
    return placeCountyUGC.map { .warningsTouching(ugc: $0) } ?? .activeWarnings
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
