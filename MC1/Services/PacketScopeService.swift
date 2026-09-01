import Foundation
import MC1Services
import os.log

private let logger = Logger(subsystem: "com.mc1", category: "PacketScopeService")

// MARK: - Models

/// One observer's reception of a packet, as reported by a CoreScope instance.
///
/// One observer can appear several times for a single transmission — it hears the
/// same packet arrive by different routes. Measured on the live instance: 25
/// observations from 9 observers for one packet, up to 4.4 receptions per observer.
/// ``PacketScopeReception`` folds those together for display.
struct PacketScopeObservation: Sendable, Equatable, Identifiable {
  let id: Int
  let observerID: String
  let observerName: String
  let observerIATA: String?
  let snr: Double?
  let rssi: Int?
  /// Short repeater hashes of the path the packet took to this observer, in hop
  /// order; empty when the observer heard the original transmission directly.
  let pathHops: [String]
  /// Full 64-hex node public keys for `pathHops`, positionally aligned, with `nil`
  /// in any slot the server could not resolve — which is common: measured at ~30%
  /// of hop slots across a 200-hash sample, and ~14% of observations carry no
  /// resolved path at all. Empty when the server resolved none.
  ///
  /// **The element type must stay optional.** The server emits JSON `null` in
  /// unresolved slots, and decoding those into a non-optional `[String]` throws —
  /// which fails the whole batch response, not just the one row, so a single
  /// unresolved hop anywhere would blank the entire screen.
  ///
  /// Worth keeping even though the app resolves hop names locally: a full public
  /// key identifies a repeater exactly, where a short hash can collide — which is
  /// the whole reason the local resolver needs proximity disambiguation.
  let resolvedPath: [String?]
  let timestamp: Date?
}

/// Every reception by one observer, folded into a single row.
struct PacketScopeReception: Sendable, Equatable, Identifiable {
  let observerID: String
  let observerName: String
  let observerIATA: String?
  /// Best signal this observer saw across its receptions — the honest headline for
  /// "how well did this observer hear it", since the weaker copies arrived by
  /// longer routes.
  let bestSNR: Double?
  let bestRSSI: Int?
  /// Distinct routes this observer heard the packet by, shortest first. The
  /// `hops`/`resolvedHops` pair is positional, so a caller can name a hop from the
  /// public key when it has one and fall back to the short hash when it does not.
  let routes: [Route]
  let firstHeard: Date?
  let receptionCount: Int

  var id: String {
    observerID
  }

  /// Fewest hops this observer heard it in — its best-case distance from the sender.
  var shortestHopCount: Int? {
    routes.map(\.hops.count).min()
  }

  struct Route: Sendable, Equatable, Hashable {
    let hops: [String]
    /// Positionally aligned with `hops`; `nil` where the server had no answer.
    let resolvedHops: [String?]
  }
}

/// What the whole observer network saw of one transmission.
struct PacketScopeSummary: Sendable, Equatable {
  let observerCount: Int
  let receptionCount: Int
  let bestSNR: Double?
  let shortestHopCount: Int?
  let firstHeard: Date?
  let lastHeard: Date?

  /// How long the packet took to finish propagating across the observers that
  /// heard it — first reception to last. Nil unless at least two are timestamped.
  var propagationSpread: TimeInterval? {
    guard let firstHeard, let lastHeard, lastHeard > firstHeard else { return nil }
    return lastHeard.timeIntervalSince(firstHeard)
  }
}

// MARK: - Folding

enum PacketScopeFold {
  /// Groups raw observations by observer, strongest signal first.
  ///
  /// Ordering is fully deterministic — SNR, then reception count, then observer id —
  /// so a refresh that returns the same data never reshuffles rows under the reader.
  static func receptions(from observations: [PacketScopeObservation]) -> [PacketScopeReception] {
    let grouped = Dictionary(grouping: observations, by: \.observerID)
    return grouped.values.compactMap { group -> PacketScopeReception? in
      guard let first = group.first else { return nil }
      var seenRoutes: [PacketScopeReception.Route] = []
      for observation in group {
        let route = PacketScopeReception.Route(
          hops: observation.pathHops,
          resolvedHops: observation.resolvedPath
        )
        if !seenRoutes.contains(route) { seenRoutes.append(route) }
      }
      return PacketScopeReception(
        observerID: first.observerID,
        observerName: first.observerName,
        observerIATA: first.observerIATA,
        bestSNR: group.compactMap(\.snr).max(),
        // rssi 0 is the server's "not reported", not a plausible reading.
        bestRSSI: group.compactMap(\.rssi).filter { $0 != 0 }.max(),
        routes: seenRoutes.sorted { $0.hops.count < $1.hops.count },
        firstHeard: group.compactMap(\.timestamp).min(),
        receptionCount: group.count
      )
    }
    .sorted { lhs, rhs in
      if lhs.bestSNR != rhs.bestSNR {
        return (lhs.bestSNR ?? -.infinity) > (rhs.bestSNR ?? -.infinity)
      }
      if lhs.receptionCount != rhs.receptionCount {
        return lhs.receptionCount > rhs.receptionCount
      }
      return lhs.observerID < rhs.observerID
    }
  }

  static func summary(from observations: [PacketScopeObservation]) -> PacketScopeSummary {
    let timestamps = observations.compactMap(\.timestamp)
    return PacketScopeSummary(
      observerCount: Set(observations.map(\.observerID)).count,
      receptionCount: observations.count,
      bestSNR: observations.compactMap(\.snr).max(),
      shortestHopCount: observations.map(\.pathHops.count).min(),
      firstHeard: timestamps.min(),
      lastHeard: timestamps.max()
    )
  }
}

// MARK: - Errors

enum PacketScopeServiceError: LocalizedError {
  case disabled
  case invalidBaseURL
  /// Every hash the caller offered was malformed, so nothing was sent. Distinct
  /// from an empty result: "we never asked" must never render as "nobody heard
  /// it", which is a definitive claim about the mesh.
  case noValidHashes
  case networkError(String)
  case invalidResponse
  case apiError(String)

  var errorDescription: String? {
    switch self {
    case .disabled:
      L10n.Localizable.PacketScope.Error.disabled
    case .invalidBaseURL:
      L10n.Localizable.PacketScope.Error.invalidBaseUrl
    case .noValidHashes:
      L10n.Localizable.PacketScope.Error.unreadableHash
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
  /// The API accepts 200, but a conversation screen never legitimately needs more
  /// than this in one call; anything larger indicates a runaway caller.
  private static let maxHashesPerRequest = 100
  /// Ceiling on observations kept per hash. Nothing in the protocol bounds what a
  /// server may return, and the whole decoded set is held in view state — measured
  /// reality is a max of 40 for one transmission, so this is pure headroom against
  /// a hostile or broken response, not a real truncation.
  private static let maxObservationsPerHash = 500

  // MARK: - Dependencies

  private let session: URLSession
  private let defaults: UserDefaults

  // MARK: - Initialization

  init(session: URLSession? = nil, defaults: UserDefaults = .standard) {
    self.session = session ?? URLSession(
      configuration: .ephemeral,
      delegate: PacketScopeRedirectGuard(),
      delegateQueue: nil
    )
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
    // An empty request is a no-op; a request whose every hash was rejected is a
    // failure the caller must be able to tell apart from "no observer heard it".
    guard !validHashes.isEmpty else {
      if hashes.isEmpty { return [:] }
      throw PacketScopeServiceError.noValidHashes
    }
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
      let rows = decoded.results[hash] ?? []
      if rows.count > Self.maxObservationsPerHash {
        logger.warning("Truncating \(rows.count) observations for one hash")
      }
      results[hash] = rows
        .prefix(Self.maxObservationsPerHash)
        .map(PacketScopeObservation.init(wire:))
    }
    return results
  }

  // MARK: - Helpers

  /// A CoreScope content hash: exactly 16 lowercase ASCII hex characters.
  ///
  /// `isASCII` is load-bearing — Swift's `isHexDigit` also accepts full-width
  /// forms (U+FF10…), so without it "２８６ｄ…" passes as a valid hash. And
  /// `utf8.count` rather than `count`, because `count` measures grapheme
  /// clusters, not bytes.
  static func isValidContentHash(_ hash: String) -> Bool {
    hash.utf8.count == 16 && hash.allSatisfy {
      $0.isASCII && $0.isHexDigit && !$0.isUppercase
    }
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
    let observerId: String?
    let observerName: String?
    let observerIata: String?
    let snr: Double?
    let rssi: Int?
    let pathJson: String?
    /// Optional *elements*: the server puts `null` in unresolved slots. See
    /// `PacketScopeObservation.resolvedPath`.
    let resolvedPath: [String?]?
    let timestamp: String?

    private enum CodingKeys: String, CodingKey {
      case id
      case observerId = "observer_id"
      case observerName = "observer_name"
      case observerIata = "observer_iata"
      case snr, rssi
      case pathJson = "path_json"
      case resolvedPath = "resolved_path"
      case timestamp
    }
  }
}

// MARK: - Redirect guard

/// Refuses any redirect that leaves the configured host.
///
/// A 307/308 preserves the method *and body*, so without this a compromised or
/// merely misconfigured server could bounce the batch POST — packet hashes and
/// all — to a host the user never pointed at. The endpoint is a fixed path on a
/// known host; there is no legitimate cross-host redirect for it. Same-host
/// redirects (http→https upgrades, trailing-slash normalisation) still follow.
///
/// Narrower than `RedirectSafetyDelegate`, which re-runs the SSRF allow-list for
/// link previews: that one guards arbitrary user-supplied URLs, this one guards a
/// single known endpoint, so host equality is the whole rule.
final class PacketScopeRedirectGuard: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection _: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    let originalHost = task.originalRequest?.url?.host?.lowercased()
    let newHost = request.url?.host?.lowercased()
    guard let originalHost, let newHost, originalHost == newHost,
          request.url?.scheme == "https"
    else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}

// MARK: - Wire mapping

extension PacketScopeObservation {
  init(wire: PacketScopeService.WireObservation) {
    id = wire.id
    // Grouping key. Falling back to the row id when the server omits it keeps an
    // unidentified observation its own row rather than silently merging it into
    // another observer's.
    observerID = wire.observerId ?? "row-\(wire.id)"
    observerName = wire.observerName ?? "?"
    observerIATA = wire.observerIata
    snr = wire.snr
    rssi = wire.rssi
    let hops = wire.pathJson
      .flatMap { $0.data(using: .utf8) }
      .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    pathHops = hops
    // Positional pairing with `pathHops` is the contract callers rely on, so a
    // resolved list of a different length is dropped rather than mis-aligned.
    let resolved = wire.resolvedPath ?? []
    resolvedPath = resolved.count == hops.count ? resolved : []
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
