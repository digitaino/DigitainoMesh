import Foundation
import OSLog

/// Where `WeatherService` keeps its per-bot state between launches.
///
/// A JSON file rather than SwiftData: nothing joins weather state, it is a cache of what a
/// bot said, and a schema migration for a cache is a cost with no benefit (docs/MESHWX.md).
public protocol WeatherStateStore: Sendable {
  func load() async throws -> [UInt16: WeatherBotState]
  func save(_ states: [UInt16: WeatherBotState]) async throws
}

/// The on-disk store: `Application Support/MeshWX/state.json`, written atomically.
public struct FileWeatherStateStore: WeatherStateStore {
  /// Bumped when the shape changes; an older file is discarded rather than migrated, since
  /// the next broadcast rebuilds everything within hours.
  static let formatVersion = 1

  public let url: URL
  private let logger = Logger(subsystem: "com.mc1", category: "WeatherStateStore")

  public init(url: URL) {
    self.url = url
  }

  /// The app's default location. Shared by every connection: state belongs to bots, not to
  /// the radio that happened to hear them.
  public static func `default`() -> FileWeatherStateStore {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return FileWeatherStateStore(url: base.appendingPathComponent("MeshWX/state.json"))
  }

  private struct Snapshot: Codable {
    var version: Int
    var bots: [WeatherBotState]
  }

  public func load() async throws -> [UInt16: WeatherBotState] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let snapshot: Snapshot
    do {
      snapshot = try decoder.decode(Snapshot.self, from: data)
    } catch {
      logger.warning("Weather state unreadable, starting empty: \(error.localizedDescription)")
      return [:]
    }
    guard snapshot.version == Self.formatVersion else {
      logger.info("Weather state format \(snapshot.version) is not \(Self.formatVersion); starting empty")
      return [:]
    }
    return Dictionary(snapshot.bots.map { ($0.botID, $0) }, uniquingKeysWith: { first, _ in first })
  }

  public func save(_ states: [UInt16: WeatherBotState]) async throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let snapshot = Snapshot(
      version: Self.formatVersion,
      bots: states.values.sorted { $0.botID < $1.botID }
    )
    let data = try encoder.encode(snapshot)
    try data.write(to: url, options: .atomic)
  }
}

/// A store that forgets on deinit, for tests and previews.
public actor InMemoryWeatherStateStore: WeatherStateStore {
  public private(set) var states: [UInt16: WeatherBotState]
  public private(set) var saveCount = 0

  public init(states: [UInt16: WeatherBotState] = [:]) {
    self.states = states
  }

  public func load() async throws -> [UInt16: WeatherBotState] {
    states
  }

  public func save(_ states: [UInt16: WeatherBotState]) async throws {
    self.states = states
    saveCount += 1
  }
}
