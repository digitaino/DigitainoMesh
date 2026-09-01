import Foundation
import MC1Services
import os.log

private let logger = Logger(subsystem: "com.mc1", category: "PacketScopeService")

// MARK: - Models

/// One observer's reception of a packet, as reported by a CoreScope instance.
struct PacketScopeObservation: Sendable, Equatable, Identifiable {
  let id: Int
  let observerName: String
  let observerIATA: String?
  let snr: Double?
  let rssi: Int?
  /// Short repeater hashes of the path the packet took to this observer, in hop
  /// order; empty when the observer heard the original transmission directly.
  let pathHops: [String]
  let timestamp: Date?
}

// MARK: - Errors

enum PacketScopeServiceError: LocalizedError {
  case disabled
  case invalidBaseURL
  case networkError(String)
  case invalidResponse
  case apiError(String)

  var errorDescription: String? {
    switch self {
    case .disabled:
      L10n.Localizable.PacketScope.Error.disabled
    case .invalidBaseURL:
      L10n.Localizable.PacketScope.Error.invalidBaseUrl
    case let .networkError(description):
      L10n.Localizable.Common.Error.networkError(description)
    case .invalidResponse:
      L10n.Localizable.Common.Error.invalidResponse
    case let .apiError(message):
      L10n.Localizable.Common.Error.apiError(message)
    }
  }
}

// MARK: - Protocol

/// Protocol for CoreScope packet lookups (for testability)
protocol PacketScopeServicing: Sendable {
  /// Observations for each content hash, keyed by hash. A hash no observer heard
  /// maps to an empty array — which is itself information: the packet never
  /// reached the observer backbone.
  func observations(for hashes: [String]) async throws -> [String: [PacketScopeObservation]]
}

// MARK: - Service

/// Queries a CoreScope observer network (default: scope.digitaino.com) for the
/// mesh-side view of a packet — which observers heard it, at what signal, via
/// which path.
///
/// ## Privacy contract
/// A content hash is the mesh-wide identity of a packet: sending it to the server
/// tells the server which transmissions this user cares about. Every call is
/// therefore gated on the `packetScopeEnabled` opt-in (default off) — enforced
/// *here*, not in the views, so no future call site can bypass it — and only
/// well-formed hashes are ever put on the wire. Nothing else about the message
/// (text, parties, location) is sent.
///
/// The base URL is user-configurable: coverage is per-instance and regional, so
/// users outside this instance's mesh point at their own CoreScope or leave the
/// feature off.
actor PacketScopeService: PacketScopeServicing {
  // MARK: - Constants

  private static let batchEndpointPath = "/api/packets/observations"
  private static let requestTimeout: TimeInterval = 15
  /// The API accepts more, but a conversation screen never legitimately needs
  /// more than this in one call; anything larger indicates a runaway caller.
  private static let maxHashesPerRequest = 100

  // MARK: - Dependencies

  private let session: URLSession
  private let defaults: UserDefaults

  // MARK: - Initialization

  init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
    self.session = session
    self.defaults = defaults
  }

  // MARK: - Public

  func observations(for hashes: [String]) async throws -> [String: [PacketScopeObservation]] {
    guard defaults.bool(forKey: AppStorageKey.packetScopeEnabled.rawValue) else {
      throw PacketScopeServiceError.disabled
    }

    // Only well-formed content hashes go on the wire; anything else is a caller
    // bug that must not turn into a request carrying arbitrary strings.
    let validHashes = Array(Set(hashes.filter(Self.isValidContentHash))).sorted()
    guard !validHashes.isEmpty else { return [:] }
    guard validHashes.count <= Self.maxHashesPerRequest else {
      throw PacketScopeServiceError.apiError("too many hashes in one request")
    }

    guard let url = endpointURL() else {
      throw PacketScopeServiceError.invalidBaseURL
    }

    var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(BatchRequest(hashes: validHashes))

    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw PacketScopeServiceError.networkError(error.localizedDescription)
    }

    guard let http = response as? HTTPURLResponse else {
      throw PacketScopeServiceError.invalidResponse
    }
    guard (200...299).contains(http.statusCode) else {
      logger.warning("Batch observations returned HTTP \(http.statusCode)")
      throw PacketScopeServiceError.apiError("HTTP \(http.statusCode)")
    }

    let decoded: BatchResponse
    do {
      decoded = try JSONDecoder().decode(BatchResponse.self, from: data)
    } catch {
      logger.warning("Failed to decode batch observations: \(error.localizedDescription)")
      throw PacketScopeServiceError.invalidResponse
    }

    // Queried-but-unheard hashes get explicit empty arrays so callers can tell
    // "nobody heard it" from "we never asked".
    var results: [String: [PacketScopeObservation]] = [:]
    for hash in validHashes {
      results[hash] = (decoded.results[hash] ?? []).map(PacketScopeObservation.init(wire:))
    }
    return results
  }

  // MARK: - Helpers

  /// A CoreScope content hash: exactly 16 lowercase hex characters.
  static func isValidContentHash(_ hash: String) -> Bool {
    hash.count == 16 && hash.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) }
  }

  private func endpointURL() -> URL? {
    let stored = defaults.string(forKey: AppStorageKey.packetScopeBaseURL.rawValue)
    let base = (stored?.isEmpty == false ? stored! : AppStorageKey.defaultPacketScopeBaseURL)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: base),
          components.scheme == "https",
          components.host?.isEmpty == false else {
      return nil
    }
    components.path = Self.batchEndpointPath
    components.query = nil
    components.fragment = nil
    return components.url
  }

  // MARK: - Wire types

  private struct BatchRequest: Encodable {
    let hashes: [String]
  }

  private struct BatchResponse: Decodable {
    let results: [String: [WireObservation]]
  }

  /// The server's observation row, decoded defensively: only `id` is load-bearing
  /// for identity; every RF field is optional because different observer versions
  /// omit different columns.
  struct WireObservation: Decodable {
    let id: Int
    let observerName: String?
    let observerIata: String?
    let snr: Double?
    let rssi: Int?
    let pathJson: String?
    let timestamp: String?

    private enum CodingKeys: String, CodingKey {
      case id
      case observerName = "observer_name"
      case observerIata = "observer_iata"
      case snr, rssi
      case pathJson = "path_json"
      case timestamp
    }
  }
}

// MARK: - Wire mapping

extension PacketScopeObservation {
  init(wire: PacketScopeService.WireObservation) {
    id = wire.id
    observerName = wire.observerName ?? "?"
    observerIATA = wire.observerIata
    snr = wire.snr
    rssi = wire.rssi
    pathHops = wire.pathJson
      .flatMap { $0.data(using: .utf8) }
      .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    // The server emits ISO 8601 with and without fractional seconds; try both.
    // Formatters are built per call rather than cached statically —
    // ISO8601DateFormatter is not Sendable, and this path runs a handful of
    // times per lookup, not per frame.
    timestamp = wire.timestamp.flatMap { raw in
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
  }
}
