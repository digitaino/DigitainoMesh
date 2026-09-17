import Foundation

/// One request this phone put on the air, and how it ended (docs/MESHWX_UI.md §12).
///
/// This phone's own requests and nothing else: the channel's answers say nothing about who asked
/// for them, so the only requests that can honestly be listed are the ones this app sent. An
/// answer served from the five-minute rule is not one — nothing went out — and is not recorded.
public struct WeatherRequestLogEntry: Sendable, Hashable, Codable, Identifiable {
  /// How a request ended, in the four ways worth telling apart. The detail — which reason the
  /// bot gave, whether its radio confirmed the request — stays under the button that sent it
  /// (§11.2); this is the ledger.
  public enum Outcome: String, Sendable, Hashable, Codable {
    case answered
    /// Nothing came back through the one retry.
    case noAnswer
    /// The bot said it cannot serve this (spec §8.3).
    case notAvailable
    /// Your own radio would not send it.
    case refused
  }

  public var id: UUID
  public var request: WeatherRequest
  public var botID: UInt16
  public var sentAt: Date
  /// Nil while the request is still on the air.
  public var outcome: Outcome?

  public init(id: UUID, request: WeatherRequest, botID: UInt16, sentAt: Date, outcome: Outcome? = nil) {
    self.id = id
    self.request = request
    self.botID = botID
    self.sentAt = sentAt
    self.outcome = outcome
  }
}

/// The log's rules: newest first, a week, and a ceiling.
///
/// Small and capped on purpose. It exists so a person can see what their own phone has spent
/// shared airtime on — not to build a record of one, and not to outlive the answers it fetched.
public enum WeatherRequestLog {
  public static let limit = 40
  public static let retention: TimeInterval = 7 * 24 * 60 * 60

  /// The log with a request just sent at its head.
  public static func recording(
    _ entry: WeatherRequestLogEntry, in list: [WeatherRequestLogEntry], now: Date
  ) -> [WeatherRequestLogEntry] {
    ordered(list.filter { $0.id != entry.id } + [entry], now: now)
  }

  /// The same log with one request's outcome filled in. A request the log no longer holds — aged
  /// out under a phone left open for a week — settles into nothing rather than reappearing.
  public static func settling(
    id: UUID, outcome: WeatherRequestLogEntry.Outcome, in list: [WeatherRequestLogEntry]
  ) -> [WeatherRequestLogEntry] {
    list.map { entry in
      guard entry.id == id else { return entry }
      var settled = entry
      settled.outcome = outcome
      return settled
    }
  }

  /// Newest first, nothing older than a week, at most `limit` rows.
  public static func ordered(
    _ list: [WeatherRequestLogEntry], now: Date, limit: Int = limit
  ) -> [WeatherRequestLogEntry] {
    Array(list
      .filter { now.timeIntervalSince($0.sentAt) <= retention }
      .sorted { lhs, rhs in
        lhs.sentAt != rhs.sentAt ? lhs.sentAt > rhs.sentAt : lhs.id.uuidString < rhs.id.uuidString
      }
      .prefix(limit))
  }
}
