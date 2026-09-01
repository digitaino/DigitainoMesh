import Foundation
@testable import MC1
import MC1Services
import Testing

/// UserDefaults is documented thread-safe; Foundation just hasn't annotated it.
/// Test-target-only, so production code cannot lean on this.
extension UserDefaults: @unchecked @retroactive Sendable {}

/// The lookup client's three contracts: the opt-in gate is enforced in the
/// service (no call site can bypass it), only well-formed content hashes ever
/// reach the wire, and the server's real response shape decodes — including
/// "nobody heard it", which must come back as an explicit empty array.
@Suite("PacketScopeService", .serialized)
struct PacketScopeServiceTests {
  /// Isolated defaults so tests can flip the opt-in without touching the
  /// developer's real settings.
  private func makeDefaults() -> UserDefaults {
    let suiteName = "PacketScopeServiceTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private func makeService(defaults: UserDefaults) -> PacketScopeService {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ScopeBatchURLProtocol.self]
    return PacketScopeService(session: URLSession(configuration: config), defaults: defaults)
  }

  @Test
  func `throws when the opt-in is off, before any request is made`() async {
    let defaults = makeDefaults()
    let service = makeService(defaults: defaults)
    ScopeBatchURLProtocol.requestCount = 0

    await #expect(throws: PacketScopeServiceError.self) {
      _ = try await service.observations(for: ["286dcbdeab84b458"])
    }
    #expect(ScopeBatchURLProtocol.requestCount == 0)
  }

  @Test
  func `decodes the live API shape and returns explicit empties for unheard hashes`() async throws {
    let defaults = makeDefaults()
    defaults.set(true, forKey: AppStorageKey.packetScopeEnabled.rawValue)
    let service = makeService(defaults: defaults)

    let results = try await service.observations(
      for: ["286dcbdeab84b458", "b120e42c91ae7ca9"]
    )

    let heard = try #require(results["286dcbdeab84b458"])
    #expect(heard.count == 2)
    #expect(heard[0].observerName == "LCC Observer")
    #expect(heard[0].snr == 12.2)
    #expect(heard[0].rssi == -37)
    #expect(heard[0].pathHops == ["DA1C", "8D1C"])
    #expect(heard[0].timestamp != nil)
    // Second row: no fractional seconds in the timestamp, empty path.
    #expect(heard[1].pathHops.isEmpty)
    #expect(heard[1].timestamp != nil)

    // Queried but absent from the response: explicit empty, not nil.
    #expect(results["b120e42c91ae7ca9"] == [])
  }

  @Test
  func `malformed hashes never reach the wire`() async {
    let defaults = makeDefaults()
    defaults.set(true, forKey: AppStorageKey.packetScopeEnabled.rawValue)
    let service = makeService(defaults: defaults)
    ScopeBatchURLProtocol.requestCount = 0

    // Uppercase, short, injection-shaped: all rejected client-side — and the
    // rejection surfaces as an error, not an empty result, because the view
    // renders empty as the definitive "no observer heard this packet".
    await #expect(throws: PacketScopeServiceError.self) {
      _ = try await service.observations(
        for: ["286DCBDEAB84B458", "abc", "../../etc/passwd", ""]
      )
    }
    #expect(ScopeBatchURLProtocol.requestCount == 0)
  }

  @Test
  func `a null slot in the resolved path decodes instead of failing the response`() throws {
    // The server emits JSON null for hops it could not resolve — measured at ~30%
    // of hop slots. Typing the array's elements non-optionally made one null
    // anywhere fail the whole batch decode, blanking the screen for every hash in
    // the request rather than losing one hop name.
    let json = #"""
    {"results":{"aaaaaaaaaaaaaaaa":[{"id":1,"observer_id":"A","observer_name":"A",
    "snr":1.0,"rssi":-50,"path_json":"[\"DA1C\",\"8D1C\"]",
    "resolved_path":["da1cc653e9491d047e27b894ef530decc31bdbd8308a7cef47e01ed54856eb71",null],
    "timestamp":"2026-09-01T02:18:16.000Z"}]}}
    """#
    struct Envelope: Decodable { let results: [String: [PacketScopeService.WireObservation]] }
    let decoded = try JSONDecoder().decode(Envelope.self, from: Data(json.utf8))
    let wire = try #require(decoded.results["aaaaaaaaaaaaaaaa"]?.first)
    let observation = PacketScopeObservation(wire: wire)

    #expect(observation.pathHops == ["DA1C", "8D1C"])
    #expect(observation.resolvedPath.count == 2)
    #expect(observation.resolvedPath[0]?.hasPrefix("da1c") == true)
    #expect(observation.resolvedPath[1] == nil)
  }

  @Test
  func `hashes that are all malformed raise rather than reading as unobserved`() async {
    // "We never asked" must not render as "nobody heard it" — one is a client
    // failure, the other a definitive claim about the mesh.
    let defaults = makeDefaults()
    defaults.set(true, forKey: AppStorageKey.packetScopeEnabled.rawValue)
    let service = makeService(defaults: defaults)
    ScopeBatchURLProtocol.requestCount = 0

    await #expect(throws: PacketScopeServiceError.self) {
      _ = try await service.observations(for: ["not-a-hash"])
    }
    #expect(ScopeBatchURLProtocol.requestCount == 0)
  }

  @Test
  func `an empty request stays a no-op`() async throws {
    let defaults = makeDefaults()
    defaults.set(true, forKey: AppStorageKey.packetScopeEnabled.rawValue)
    let service = makeService(defaults: defaults)
    let results = try await service.observations(for: [])
    #expect(results.isEmpty)
  }

  @Test
  func `full-width unicode hex is not a valid hash`() {
    // Swift's isHexDigit accepts U+FF10.. forms, so without an ASCII check these
    // would pass the "only validated hex leaves the device" guarantee.
    #expect(!PacketScopeService.isValidContentHash("\u{FF12}86dcbdeab84b45\u{FF18}"))
    #expect(!PacketScopeService.isValidContentHash("286dcbdeab84b45\u{FF18}"))
    #expect(PacketScopeService.isValidContentHash("286dcbdeab84b458"))
  }

  @Test
  func `content hash validation`() {
    #expect(PacketScopeService.isValidContentHash("286dcbdeab84b458"))
    #expect(!PacketScopeService.isValidContentHash("286DCBDEAB84B458"))
    #expect(!PacketScopeService.isValidContentHash("286dcbdeab84b45"))
    #expect(!PacketScopeService.isValidContentHash("286dcbdeab84b4589"))
    #expect(!PacketScopeService.isValidContentHash("zz6dcbdeab84b458"))
    #expect(!PacketScopeService.isValidContentHash(""))
  }
}

/// The redirect guard is the control that keeps packet hashes from being bounced
/// to a host the user never configured — a 307/308 preserves the POST body, so
/// "the server is trusted" is not enough on its own.
@Suite("PacketScopeRedirectGuard")
struct PacketScopeRedirectGuardTests {
  private func decision(from: String, to: String) async -> URLRequest? {
    let guardDelegate = PacketScopeRedirectGuard()
    let session = URLSession(configuration: .ephemeral)
    let task = session.dataTask(with: URLRequest(url: URL(string: from)!))
    let response = HTTPURLResponse(
      url: URL(string: from)!, statusCode: 307, httpVersion: nil, headerFields: nil
    )!
    return await withCheckedContinuation { continuation in
      guardDelegate.urlSession(
        session,
        task: task,
        willPerformHTTPRedirection: response,
        newRequest: URLRequest(url: URL(string: to)!)
      ) { continuation.resume(returning: $0) }
    }
  }

  @Test
  func `a redirect to another host is refused`() async {
    let result = await decision(
      from: "https://scope.digitaino.com/api/packets/observations",
      to: "https://evil.example.com/collect"
    )
    #expect(result == nil)
  }

  @Test
  func `a downgrade to http on the same host is refused`() async {
    let result = await decision(
      from: "https://scope.digitaino.com/api/packets/observations",
      to: "http://scope.digitaino.com/api/packets/observations"
    )
    #expect(result == nil)
  }

  @Test
  func `a same-host path redirect is allowed`() async {
    let result = await decision(
      from: "https://scope.digitaino.com/api/packets/observations",
      to: "https://scope.digitaino.com/api/v2/packets/observations"
    )
    #expect(result?.url?.path == "/api/v2/packets/observations")
  }

  @Test
  func `host comparison ignores case`() async {
    let result = await decision(
      from: "https://scope.digitaino.com/api/packets/observations",
      to: "https://SCOPE.Digitaino.COM/api/packets/observations"
    )
    #expect(result != nil)
  }

  @Test
  func `a subdomain of the configured host is still another host`() async {
    let result = await decision(
      from: "https://scope.digitaino.com/api/packets/observations",
      to: "https://scope.digitaino.com.evil.example/collect"
    )
    #expect(result == nil)
  }
}

/// One transmission produces several observations per observer — it arrives by
/// different routes. Measured on the live instance: 25 observations from 9
/// observers for one packet. These pin the fold that makes that legible.
@Suite("PacketScopeFold")
struct PacketScopeFoldTests {
  private func observation(
    id: Int,
    observer: String,
    snr: Double?,
    rssi: Int? = nil,
    hops: [String] = [],
    resolved: [String] = [],
    secondsAfterEpoch: TimeInterval? = nil
  ) -> PacketScopeObservation {
    PacketScopeObservation(
      id: id,
      observerID: observer,
      observerName: "Observer \(observer)",
      observerIATA: "AUS",
      snr: snr,
      rssi: rssi,
      pathHops: hops,
      resolvedPath: resolved,
      timestamp: secondsAfterEpoch.map { Date(timeIntervalSince1970: $0) }
    )
  }

  @Test
  func `one observer heard by several routes folds into one row keeping its best signal`() throws {
    let observations = [
      observation(id: 1, observer: "A", snr: 4.0, rssi: -90, hops: ["DA1C", "8D1C"]),
      observation(id: 2, observer: "A", snr: 12.2, rssi: -37, hops: ["ABBA"]),
      observation(id: 3, observer: "A", snr: 9.0, rssi: -50, hops: ["ABBA"]),
    ]
    let receptions = PacketScopeFold.receptions(from: observations)

    #expect(receptions.count == 1)
    let row = try #require(receptions.first)
    #expect(row.bestSNR == 12.2)
    #expect(row.bestRSSI == -37)
    #expect(row.receptionCount == 3)
    // Two *distinct* routes, deduplicated, shortest first.
    #expect(row.routes.count == 2)
    #expect(row.routes.first?.hops == ["ABBA"])
    #expect(row.shortestHopCount == 1)
  }

  @Test
  func `rssi of zero is the server's not-reported and never wins best`() throws {
    let observations = [
      observation(id: 1, observer: "A", snr: 1.0, rssi: 0),
      observation(id: 2, observer: "A", snr: 2.0, rssi: -80),
    ]
    let row = try #require(PacketScopeFold.receptions(from: observations).first)
    #expect(row.bestRSSI == -80)
  }

  @Test
  func `every rssi unreported yields no rssi rather than a fake zero`() throws {
    let observations = [observation(id: 1, observer: "A", snr: 1.0, rssi: 0)]
    let row = try #require(PacketScopeFold.receptions(from: observations).first)
    #expect(row.bestRSSI == nil)
  }

  @Test
  func `rows order by signal and break ties deterministically`() {
    let observations = [
      observation(id: 1, observer: "cc", snr: 5.0),
      observation(id: 2, observer: "aa", snr: 5.0),
      observation(id: 3, observer: "aa", snr: 5.0),
      observation(id: 4, observer: "bb", snr: 9.0),
      observation(id: 5, observer: "dd", snr: nil),
    ]
    let ids = PacketScopeFold.receptions(from: observations).map(\.observerID)
    // bb strongest; aa before cc on reception count; unsigned dd last.
    #expect(ids == ["bb", "aa", "cc", "dd"])
  }

  @Test
  func `summary counts observers not receptions and measures the propagation spread`() {
    let observations = [
      observation(id: 1, observer: "A", snr: 4.0, hops: ["X", "Y"], secondsAfterEpoch: 100),
      observation(id: 2, observer: "A", snr: 6.0, hops: ["X"], secondsAfterEpoch: 103),
      observation(id: 3, observer: "B", snr: 12.0, hops: [], secondsAfterEpoch: 107),
    ]
    let summary = PacketScopeFold.summary(from: observations)

    #expect(summary.observerCount == 2)
    #expect(summary.receptionCount == 3)
    #expect(summary.bestSNR == 12.0)
    #expect(summary.shortestHopCount == 0)
    #expect(summary.propagationSpread == 7)
  }

  @Test
  func `a single timestamped reception has no spread to report`() {
    let summary = PacketScopeFold.summary(from: [
      observation(id: 1, observer: "A", snr: 1.0, secondsAfterEpoch: 100),
    ])
    #expect(summary.propagationSpread == nil)
  }

  @Test
  func `a resolved path of mismatched length is dropped rather than mis-paired`() {
    // Positional pairing is the contract; a short resolved list would name the
    // wrong repeater, which is worse than naming none.
    let wire = PacketScopeService.WireObservation(
      id: 1, observerId: "A", observerName: "A", observerIata: nil,
      snr: nil, rssi: nil,
      pathJson: #"["DA1C","8D1C"]"#, resolvedPath: ["abc"], timestamp: nil
    )
    let observation = PacketScopeObservation(wire: wire)
    #expect(observation.pathHops.count == 2)
    #expect(observation.resolvedPath.isEmpty)
  }
}

/// Serves the batch-observations endpoint with a captured slice of the real
/// scope.digitaino.com response (one observation with fractional-seconds
/// timestamp and resolved path, one with neither).
final class ScopeBatchURLProtocol: URLProtocol {
  nonisolated(unsafe) static var requestCount = 0

  override static func canInit(with _: URLRequest) -> Bool {
    true
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    Self.requestCount += 1
    let body = """
    {"results":{"286dcbdeab84b458":[
      {"id":5728503,"hash":"286dcbdeab84b458","observer_id":"A33D","observer_name":"LCC Observer","observer_iata":"AUS","snr":12.2,"rssi":-37,"path_json":"[\\"DA1C\\",\\"8D1C\\"]","direction":"rx","timestamp":"2026-09-01T02:18:16.000Z"},
      {"id":5728500,"hash":"286dcbdeab84b458","observer_name":"Dripping","observer_iata":"AUS","snr":-7,"rssi":-109,"path_json":"[]","direction":"rx","timestamp":"2026-09-01T02:18:16Z"}
    ]}}
    """
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
