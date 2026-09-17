import Foundation
import MeshWX

// MARK: - Subject

/// What one message on `#meshwx` was about, in the wire's own terms.
///
/// Wire values rather than words: this is built off the main actor from the held state, and the
/// view turns each case into a name a person reads. Nothing here names a requester — a broadcast
/// carries none, and the phone records none, so nothing downstream can claim one
/// (docs/MESHWX_UI.md §12).
public enum WeatherChannelSubject: Sendable, Hashable {
  /// The bot's alert list, with how many warnings it named.
  case alertList(entries: Int)
  case warning(MeshWXWarningIdentity)
  /// One observations batch, with how many stations it carried.
  case readings(stations: Int)
  /// One station's held reading.
  case reading(station: UInt16)
  /// A forecast. `label` is the request text for a place the bot resolved for itself, which is
  /// the only name that forecast has (spec §7); nil for a bundled point.
  case forecast(point: UInt16, label: String?)
  /// A text reply, with the request of this phone's that it answered where it answered one. A
  /// chunk carries only its subject, so a reply with no request is one nobody here asked for —
  /// which is not the same as knowing who did.
  case text(subject: MeshWXTextSubject, request: WeatherRequest?)
  /// The bot's statement of what it carries (spec §7A).
  case coverage
}

// MARK: - Heard on the channel

/// One thing the channel carried, as the weather radio's page lists it (docs/MESHWX_UI.md §12).
public struct WeatherHeardItem: Sendable, Hashable, Identifiable {
  public var id: String
  public var botID: UInt16
  public var subject: WeatherChannelSubject
  /// The content's own time on the bot's clock, where the message carries one: a list's build
  /// time, a batch's observation time, a forecast's issue time. Nil for a warning, a text reply
  /// and a statement, which carry none.
  public var contentAt: Date?
  /// When this phone received it.
  public var receivedAt: Date
}

/// What the channel has carried recently, scheduled broadcasts and answers alike.
///
/// Read from what the phone is holding, so a message it kept nothing of is not listed. Answers
/// to other people's requests are here beside the scheduled broadcasts and are not told apart
/// from them: on a broadcast channel they are the same thing, and which was which would be a
/// claim about who asked.
public enum WeatherHeard {
  /// How far back the page looks.
  public static let window: TimeInterval = 24 * 60 * 60
  /// A page, not a history.
  public static let limit = 30

  public static func make(states: [UInt16: WeatherBotState], now: Date, limit: Int = limit) -> [WeatherHeardItem] {
    var items: [WeatherHeardItem] = []
    for (botID, state) in states {
      func add(_ id: String, _ subject: WeatherChannelSubject, contentAt: Date?, receivedAt: Date) {
        guard now.timeIntervalSince(receivedAt) <= window else { return }
        items.append(WeatherHeardItem(
          id: "\(botID)-\(id)", botID: botID, subject: subject, contentAt: contentAt, receivedAt: receivedAt))
      }

      if let digest = state.digest {
        add("digest", .alertList(entries: digest.digest.entries.count),
            contentAt: digest.builtAt, receivedAt: digest.receivedAt)
      }
      for stored in state.warnings.values {
        let identity = stored.identity
        add("warning-\(identity.event).\(identity.office).\(identity.etn)", .warning(identity),
            contentAt: nil, receivedAt: stored.receivedAt)
      }
      // One row per batch rather than per station: fourteen readings arrived as one message, and
      // fourteen rows would bury everything else the channel carried. Keyed by the batch's own
      // time, not the station's: since revision 5 each reading carries when *that station*
      // reported (batch `ts` less its age), so one hourly batch holds fourteen different times
      // and grouping by those would be fourteen rows again.
      var batches: [UInt32: (stations: Int, receivedAt: Date)] = [:]
      for stored in state.observations.values {
        let key = stored.lastBatchMinutes ?? stored.timestampMinutes
        var batch = batches[key] ?? (0, stored.receivedAt)
        batch.stations += 1
        batch.receivedAt = max(batch.receivedAt, stored.receivedAt)
        batches[key] = batch
      }
      for (minutes, batch) in batches {
        add("batch-\(minutes)", .readings(stations: batch.stations),
            contentAt: Date(unixMinutes: minutes), receivedAt: batch.receivedAt)
      }
      for (point, stored) in state.forecasts {
        add("forecast-\(point)", .forecast(point: point, label: stored.requestLabel),
            contentAt: stored.issuedAt, receivedAt: stored.receivedAt)
      }
      for assembly in state.texts.values {
        add("text-\(assembly.group)", .text(subject: assembly.subject, request: assembly.request),
            contentAt: nil, receivedAt: assembly.lastReceivedAt)
      }
      if let coverage = state.coverage {
        add("coverage", .coverage, contentAt: nil, receivedAt: coverage.receivedAt)
      }
    }
    return Array(items.sorted { lhs, rhs in
      lhs.receivedAt != rhs.receivedAt ? lhs.receivedAt > rhs.receivedAt : lhs.id < rhs.id
    }.prefix(limit))
  }
}

// MARK: - Cache

/// The kinds of thing the phone is holding from the channel (docs/MESHWX_UI.md §12).
public enum WeatherCacheGroup: Sendable, Hashable, CaseIterable {
  case readings
  case forecasts
  /// METAR and TAF: the coded airport reports, text subject 5.
  case airportReports
  /// The full text of a warning, text subject 0.
  case warningNarratives
  /// Warnings the phone holds for somewhere other than the place on screen.
  case warningsElsewhere
}

/// One thing the phone is holding, and the screen that shows it in full.
public struct WeatherCachedItem: Sendable, Hashable, Identifiable {
  /// The screen a row opens, where one exists. A forecast has none: the place picker is where a
  /// point becomes a place (§12).
  public enum Destination: Sendable, Hashable {
    case station(UInt16)
    case alert(MeshWXWarningIdentity)
  }

  public var id: String
  public var group: WeatherCacheGroup
  public var botID: UInt16
  public var subject: WeatherChannelSubject
  public var contentAt: Date?
  public var receivedAt: Date
  public var destination: Destination?
}

/// Everything the phone kept from `#meshwx`, grouped and counted.
///
/// One disclosed row at the foot of the weather radio's page, and nothing from it on the main
/// screens: the point is to be able to see what is being held — and how much of it is somebody
/// else's question — without any of it claiming to be an answer to yours.
public struct WeatherCache: Sendable, Hashable {
  public struct Group: Sendable, Hashable, Identifiable {
    public var group: WeatherCacheGroup
    /// Newest arrival first.
    public var items: [WeatherCachedItem]

    public var id: WeatherCacheGroup { group }
    public var count: Int { items.count }
  }

  /// Only the groups with something in them, in `WeatherCacheGroup.allCases` order.
  public var groups: [Group]
  public var total: Int

  public static let empty = WeatherCache(groups: [], total: 0)

  public init(groups: [Group], total: Int) {
    self.groups = groups
    self.total = total
  }

  /// - Parameters:
  ///   - readings: the snapshot's own readings, already one per station across bots, so the list
  ///     counts what the phone would show rather than every copy two bots sent.
  ///   - alerts: the placed alerts; the ones elsewhere are the warnings this phone is keeping for
  ///     somewhere other than the place on screen.
  public static func make(
    states: [UInt16: WeatherBotState],
    readings: [WeatherStationReading],
    alerts: [WeatherAlertItem],
    tables: MeshWXTables
  ) -> WeatherCache {
    var items: [WeatherCacheGroup: [WeatherCachedItem]] = [:]
    func add(_ item: WeatherCachedItem) {
      items[item.group, default: []].append(item)
    }

    for reading in readings {
      add(WeatherCachedItem(
        id: "reading-\(reading.index)",
        group: .readings,
        botID: reading.botID,
        subject: .reading(station: reading.index),
        contentAt: reading.stored.observedAt,
        receivedAt: reading.stored.receivedAt,
        destination: .station(reading.index)))
    }

    for (botID, state) in states {
      for (point, stored) in state.forecasts {
        add(WeatherCachedItem(
          id: "forecast-\(botID)-\(point)",
          group: .forecasts,
          botID: botID,
          subject: .forecast(point: point, label: stored.requestLabel),
          contentAt: stored.issuedAt,
          receivedAt: stored.receivedAt,
          destination: nil))
      }
      for assembly in state.texts.values {
        let group: WeatherCacheGroup
        switch assembly.subject {
        case .metarOrTAF: group = .airportReports
        case .warningNarrative: group = .warningNarratives
        // The Weather Service products have a screen of their own (§12); this page is for what
        // would otherwise go unaccounted for.
        default: continue
        }
        add(WeatherCachedItem(
          id: "text-\(botID)-\(assembly.group)",
          group: group,
          botID: botID,
          subject: .text(subject: assembly.subject, request: assembly.request),
          contentAt: nil,
          receivedAt: assembly.lastReceivedAt,
          destination: destination(of: assembly.request, tables: tables)))
      }
    }

    for alert in alerts where alert.placement == .elsewhere {
      add(WeatherCachedItem(
        id: "alert-\(alert.identity.event).\(alert.identity.office).\(alert.identity.etn)",
        group: .warningsElsewhere,
        botID: alert.botIDs.first ?? 0,
        subject: .warning(alert.identity),
        contentAt: nil,
        receivedAt: alert.receivedAt,
        destination: .alert(alert.identity)))
    }

    let groups = WeatherCacheGroup.allCases.compactMap { group -> Group? in
      guard let rows = items[group], !rows.isEmpty else { return nil }
      return Group(group: group, items: rows.sorted { lhs, rhs in
        lhs.receivedAt != rhs.receivedAt ? lhs.receivedAt > rhs.receivedAt : lhs.id < rhs.id
      })
    }
    return WeatherCache(groups: groups, total: groups.reduce(0) { $0 + $1.count })
  }

  /// Where a text reply's row goes: only a reply that answered a request of this phone's names
  /// the station or the warning it is about. One nobody here asked for carries its subject and
  /// nothing else, and gets no destination rather than a guessed one.
  static func destination(
    of request: WeatherRequest?, tables: MeshWXTables
  ) -> WeatherCachedItem.Destination? {
    switch request {
    case let .metar(station), let .taf(station):
      return tables.stationIndex(forICAO: station).map { .station($0) }
    case let .warningText(identity):
      return WeatherAlertRequests.identity(from: identity, tables: tables).map { .alert($0) }
    default:
      return nil
    }
  }
}
