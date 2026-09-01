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
  func `malformed hashes never reach the wire`() async throws {
    let defaults = makeDefaults()
    defaults.set(true, forKey: AppStorageKey.packetScopeEnabled.rawValue)
    let service = makeService(defaults: defaults)
    ScopeBatchURLProtocol.requestCount = 0

    // Uppercase, short, injection-shaped: all rejected client-side.
    let results = try await service.observations(
      for: ["286DCBDEAB84B458", "abc", "../../etc/passwd", ""]
    )
    #expect(results.isEmpty)
    #expect(ScopeBatchURLProtocol.requestCount == 0)
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

/// Serves the batch-observations endpoint with a captured slice of the real
/// scope.digitaino.com response (one observation with fractional-seconds
/// timestamp and resolved path, one with neither).
final class ScopeBatchURLProtocol: URLProtocol {
  nonisolated(unsafe) static var requestCount = 0

  override class func canInit(with _: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
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
