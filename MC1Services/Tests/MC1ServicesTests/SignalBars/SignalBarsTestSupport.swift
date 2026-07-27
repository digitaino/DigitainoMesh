import Foundation
@testable import MC1Services
import MeshCore
import os

// MARK: - Identifiers

/// A hash ID from a literal the test knows is valid.
///
/// Non-throwing on purpose: `#require` cannot be nested inside another `#expect`, and
/// these IDs appear inside assertions constantly.
func nodeID(_ hex: String) -> NodeHexID {
  guard let id = NodeHexID(hex) else {
    preconditionFailure("invalid fixture hash \(hex)")
  }
  return id
}

// MARK: - Clock

/// A clock the test moves by hand, so probe timeouts and staleness are produced by
/// arithmetic rather than by waiting.
final class TestClock: Sendable {
  private let state: OSAllocatedUnfairLock<Date>

  init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
    state = OSAllocatedUnfairLock(initialState: start)
  }

  var now: Date {
    state.withLock { $0 }
  }

  /// A `now` provider to hand to the engine.
  var provider: @Sendable () -> Date {
    { [state] in state.withLock { $0 } }
  }

  @discardableResult
  func advance(_ interval: TimeInterval) -> Date {
    state.withLock { current in
      current = current.addingTimeInterval(interval)
      return current
    }
  }

  func set(_ date: Date) {
    state.withLock { $0 = date }
  }
}

// MARK: - Movement

struct FixedMovementHintProvider: MovementHintProvider {
  let hint: MovementHint

  init(_ hint: MovementHint) {
    self.hint = hint
  }

  func currentMovementHint() async -> MovementHint {
    hint
  }
}

// MARK: - Node directory

/// A literal pool of resolvable nodes, standing in for contacts + discovered nodes.
struct StubNodeDirectory: SignalBarsNodeDirectory {
  let nodes: [AnyResolvableNode]

  func resolvableNodes() async -> [AnyResolvableNode] {
    nodes
  }
}

/// Minimal ``RepeaterResolvable`` for directory fixtures.
struct StubResolvableNode: RepeaterResolvable {
  var publicKey: Data
  var latitude: Double = 0
  var longitude: Double = 0
  var hasLocation: Bool = false
  var lastAdvertTimestamp: UInt32 = 1
  var recencyDate: Date = .init(timeIntervalSince1970: 1_700_000_000)
  var resolvableName: String
}

// MARK: - Session

/// A scriptable stand-in for the radio: records everything the engine transmits and lets
/// the test push events into the engine's subscription.
actor MockSignalBarsSession: SignalBarsSessionOps, SessionEventStreaming {
  // MARK: Recorded traffic

  private(set) var syncWrites: [(id: SyncID, payload: Data)] = []
  private(set) var syncReads: [SyncID] = []
  private(set) var traces: [(tag: UInt32?, flags: UInt8, path: Data?)] = []
  private(set) var discoverRequests: [(filter: UInt8, prefixOnly: Bool)] = []

  // MARK: Stubs

  /// Blobs returned by `getSync(.signalBars)`, consumed in order; the last one repeats.
  var signalBarsBlobs: [Data] = []
  var getSyncError: (any Error)?
  var setSyncError: (any Error)?
  var traceError: (any Error)?
  var traceResult = MessageSentInfo(route: 0, expectedAck: Data(), suggestedTimeoutMs: 5000)

  func setSignalBarsBlobs(_ blobs: [Data]) {
    signalBarsBlobs = blobs
  }

  func setGetSyncError(_ error: (any Error)?) {
    getSyncError = error
  }

  func setTraceError(_ error: (any Error)?) {
    traceError = error
  }

  func setTraceResult(_ result: MessageSentInfo) {
    traceResult = result
  }

  // MARK: SignalBarsSessionOps

  func getSync(_ id: SyncID) async throws -> Data {
    syncReads.append(id)
    if let getSyncError { throw getSyncError }
    guard !signalBarsBlobs.isEmpty else { return Data() }
    return signalBarsBlobs.count == 1 ? signalBarsBlobs[0] : signalBarsBlobs.removeFirst()
  }

  func setSync(_ id: SyncID, payload: Data) async throws {
    syncWrites.append((id, payload))
    if let setSyncError { throw setSyncError }
  }

  func sendTrace(
    tag: UInt32?,
    authCode _: UInt32?,
    flags: UInt8,
    path: Data?
  ) async throws -> MessageSentInfo {
    traces.append((tag, flags, path))
    if let traceError { throw traceError }
    return traceResult
  }

  func sendNodeDiscoverRequest(
    filter: UInt8,
    prefixOnly: Bool,
    tag: UInt32?,
    since _: Date?
  ) async throws -> UInt32 {
    discoverRequests.append((filter, prefixOnly))
    return tag ?? 1
  }

  // MARK: SessionEventStreaming

  private var continuations: [UUID: AsyncStream<MeshEvent>.Continuation] = [:]

  nonisolated var connectionState: AsyncStream<ConnectionState> {
    AsyncStream { $0.finish() }
  }

  func events() async -> AsyncStream<MeshEvent> {
    makeStream(filter: nil)
  }

  func events(filter: EventFilter) async -> AsyncStream<MeshEvent> {
    makeStream(filter: filter)
  }

  func waitForEvent(filter _: EventFilter, timeout _: TimeInterval?) async -> MeshEvent? {
    nil
  }

  private func makeStream(filter: EventFilter?) -> AsyncStream<MeshEvent> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<MeshEvent>.makeStream()
    continuations[id] = continuation
    self.filters[id] = filter
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeStream(id) }
    }
    return stream
  }

  private var filters: [UUID: EventFilter?] = [:]

  private func removeStream(_ id: UUID) {
    continuations[id] = nil
    filters[id] = nil
  }

  /// Number of live subscriptions, so a test can wait for the engine to attach.
  var subscriberCount: Int {
    continuations.count
  }

  /// Pushes an event to every subscription whose filter accepts it.
  func emit(_ event: MeshEvent) {
    for (id, continuation) in continuations {
      let filter = filters[id] ?? nil
      if filter?.matches(event) ?? true {
        continuation.yield(event)
      }
    }
  }
}

// MARK: - Fixtures

enum SignalBarsFixtures {
  /// A device table blob as the firmware would serialize it.
  static func blob(_ entries: [SignalBarsBlob.Entry]) -> Data {
    SignalBarsBlob(version: 2, entries: entries).encode()
  }

  static func entry(
    hash: [UInt8],
    rxSnrX4: Int8 = 24,
    txSnrX4: Int8 = 0,
    hasRx: Bool = true,
    hasTx: Bool = false,
    txFailed: Bool = false,
    isBest: Bool = false,
    ageSeconds: UInt16 = 0,
    rttMs: UInt16 = 0
  ) -> SignalBarsBlob.Entry {
    SignalBarsBlob.Entry(
      id: hash[0],
      idHash: hash,
      rxSnrX4: rxSnrX4,
      txSnrX4: txSnrX4,
      hasRx: hasRx,
      hasTx: hasTx,
      txFailed: txFailed,
      isBest: isBest,
      ageSeconds: ageSeconds,
      rttMs: rttMs
    )
  }

  /// A 32-byte public key beginning with `prefix`.
  static func publicKey(_ prefix: [UInt8]) -> Data {
    var key = Data(prefix)
    key.append(contentsOf: [UInt8](repeating: 0xEE, count: 32 - prefix.count))
    return key
  }

  static func discoverResponse(
    publicKey key: Data,
    snr: Double = 6.0,
    snrIn: Double = 3.0,
    rssi: Int = -70
  ) -> DiscoverResponse {
    DiscoverResponse(
      nodeType: 2,
      snrIn: snrIn,
      snr: snr,
      rssi: rssi,
      pathLength: 1,
      tag: Data([0x01, 0x02, 0x03, 0x04]),
      publicKey: key
    )
  }

  /// An RX-log entry for a packet relayed through `path` (one hop per `hashSize` bytes).
  static func relayedPacket(
    path: [UInt8],
    hashSize: Int = 1,
    snr: Double? = 4.0,
    rssi: Int? = -80,
    payloadType: PayloadType = .textMessage
  ) -> ParsedRxLogData {
    ParsedRxLogData(
      snr: snr,
      rssi: rssi,
      rawPayload: Data(),
      routeType: .direct,
      payloadType: payloadType,
      payloadVersion: 0,
      payloadTypeBits: 2,
      transportCode: nil,
      pathLength: encodePathLen(hashSize: hashSize, hopCount: path.count / hashSize),
      pathNodes: path,
      packetPayload: Data()
    )
  }

  /// An RX-log entry for a trace reply carrying `tag` and the far end's SNR.
  static func traceReply(
    tag: UInt32,
    localSnr: Double? = 5.0,
    remoteSnrX4: Int8? = 12
  ) -> ParsedRxLogData {
    var payload = Data()
    payload.append(UInt8(tag & 0xFF))
    payload.append(UInt8((tag >> 8) & 0xFF))
    payload.append(UInt8((tag >> 16) & 0xFF))
    payload.append(UInt8((tag >> 24) & 0xFF))
    return ParsedRxLogData(
      snr: localSnr,
      rssi: -75,
      rawPayload: Data(),
      routeType: .direct,
      payloadType: .trace,
      payloadVersion: 0,
      payloadTypeBits: 0,
      transportCode: nil,
      pathLength: encodePathLen(hashSize: 1, hopCount: remoteSnrX4 == nil ? 0 : 1),
      pathNodes: remoteSnrX4.map { [UInt8(bitPattern: $0)] } ?? [],
      packetPayload: payload
    )
  }
}

/// Waits for an actor-isolated condition, for the few tests that exercise the engine's own
/// subscription tasks rather than stepping it directly.
func waitForCondition(
  timeout: Duration = .seconds(2),
  _ message: String = "condition not met",
  _ condition: @Sendable () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  struct ConditionTimeout: Error, CustomStringConvertible {
    let description: String
  }
  guard await condition() else { throw ConditionTimeout(description: message) }
}
