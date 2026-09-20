import Foundation
import OSLog
import Synchronization

/// Where `WeatherService` keeps the channel traffic log between launches
/// (docs/MESHWX_UI.md §12, revision 10).
///
/// A store of its own rather than a field of `WeatherBotState`: the log is about the *channel*,
/// not about a bot — it holds datagrams from bots this phone keeps no state for, datagrams that
/// never decoded far enough to name one, and this phone's own requests. Keeping it beside the
/// weather state also means clearing it, or failing to read it, cannot take the weather with it.
public protocol WeatherTrafficLogStore: Sendable {
  /// Oldest first, as the screen reads it.
  func load() async throws -> [WeatherTrafficEntry]
  func save(_ entries: [WeatherTrafficEntry]) async throws
}

/// The on-disk log: `Application Support/MeshWX/traffic.json`, written atomically, beside
/// `state.json`.
///
/// An actor, and one instance per file, for the reason `FileWeatherStateStore` is: two writers
/// each doing load-then-save lose one of the edits.
public actor FileWeatherTrafficLogStore: WeatherTrafficLogStore {
  /// Bumped when the shape changes; an older file is discarded rather than migrated. This one is
  /// a window on the last few hundred datagrams, so there is nothing in it worth a migration —
  /// the next afternoon on the channel refills it.
  static let formatVersion = 1

  public nonisolated let url: URL
  private let logger = Logger(subsystem: "com.mc1", category: "WeatherTrafficLogStore")

  public init(url: URL) {
    self.url = url
  }

  private static let instances = Mutex<[URL: FileWeatherTrafficLogStore]>([:])

  /// The one instance for a file.
  public static func shared(url: URL) -> FileWeatherTrafficLogStore {
    let key = url.standardizedFileURL
    return instances.withLock { stores in
      if let existing = stores[key] { return existing }
      let store = FileWeatherTrafficLogStore(url: key)
      stores[key] = store
      return store
    }
  }

  /// The app's default location, shared across connections — the channel is the channel whichever
  /// radio is listening to it.
  public static func `default`() -> FileWeatherTrafficLogStore {
    shared(url: defaultURL)
  }

  public static var defaultURL: URL {
    FileWeatherStateStore.defaultURL
      .deletingLastPathComponent()
      .appendingPathComponent("traffic.json")
  }

  private struct Snapshot: Codable {
    var version: Int
    var entries: [WeatherTrafficEntry]
  }

  public func load() throws -> [WeatherTrafficEntry] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let snapshot: Snapshot
    do {
      snapshot = try decoder.decode(Snapshot.self, from: try Data(contentsOf: url))
    } catch {
      logger.warning("Weather traffic log unreadable, starting empty: \(error.localizedDescription)")
      return []
    }
    guard snapshot.version == Self.formatVersion else { return [] }
    return Array(snapshot.entries.suffix(WeatherTrafficLog.limit))
  }

  public func save(_ entries: [WeatherTrafficEntry]) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let data = try encoder.encode(
      Snapshot(version: Self.formatVersion, entries: Array(entries.suffix(WeatherTrafficLog.limit))))
    try data.write(to: url, options: .atomic)
  }
}

/// A log that forgets on deinit, for tests and previews.
public actor InMemoryWeatherTrafficLogStore: WeatherTrafficLogStore {
  public private(set) var entries: [WeatherTrafficEntry]
  public private(set) var saveCount = 0

  public init(entries: [WeatherTrafficEntry] = []) {
    self.entries = entries
  }

  public func load() async throws -> [WeatherTrafficEntry] {
    entries
  }

  public func save(_ entries: [WeatherTrafficEntry]) async throws {
    self.entries = entries
    saveCount += 1
  }
}
