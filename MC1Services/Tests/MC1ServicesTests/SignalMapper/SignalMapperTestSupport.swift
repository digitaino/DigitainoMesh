import Foundation
@testable import MC1Services
import MeshCore
import os
import SurveyKit

// MARK: - Fixture coordinates

/// Two coordinates far enough apart to land in different H3 res-9 cells, and one nudged
/// only a few meters so it must land in the *same* cell as the first. Res 9 is ~350 m
/// across, so "far" here only needs to be a few hundred meters.
enum MapperFixtureLocation {
  static let plaza = (latitude: 37.7749, longitude: -122.4194)
  static let acrossTown = (latitude: 37.8044, longitude: -122.2712)
  /// ~11 m north of ``plaza`` — same cell, different point.
  static let plazaNudged = (latitude: 37.7750, longitude: -122.4194)

  static func cell(_ location: (latitude: Double, longitude: Double)) -> H3Cell? {
    SurveyGrid.cell(
      containing: GeoCoordinate(latitude: location.latitude, longitude: location.longitude)
    )
  }
}

/// Builds a fix, defaulting to "perfectly usable right now".
func mapperFix(
  _ location: (latitude: Double, longitude: Double) = MapperFixtureLocation.plaza,
  accuracy: Double = 10,
  speed: Double? = nil,
  movedSinceCapture: Bool = false,
  at timestamp: Date
) -> MapperFix {
  MapperFix(
    latitude: location.latitude,
    longitude: location.longitude,
    horizontalAccuracyMeters: accuracy,
    speedMetersPerSecond: speed,
    timestamp: timestamp,
    movedSinceCapture: movedSinceCapture
  )
}

// MARK: - Movement hints

/// A movement hint the test sets by hand, for exercising the dwell counter and the engine's
/// "nil is not stationary" rule.
final class StubMovementHintProvider: MovementHintProvider {
  private let state: OSAllocatedUnfairLock<MovementHint>

  init(_ hint: MovementHint = .stationary) {
    state = OSAllocatedUnfairLock(initialState: hint)
  }

  func currentMovementHint() async -> MovementHint {
    state.withLock { $0 }
  }

  func set(_ hint: MovementHint) {
    state.withLock { $0 = hint }
  }
}

// MARK: - Fix provider

/// A fix provider the test sets by hand. Never refreshes anything — the point of the
/// protocol is that the engine cannot tell the difference.
final class StubMapperFixProvider: MapperFixProviding {
  private let state: OSAllocatedUnfairLock<MapperFix?>

  init(_ fix: MapperFix? = nil) {
    state = OSAllocatedUnfairLock(initialState: fix)
  }

  func latestFix() async -> MapperFix? {
    state.withLock { $0 }
  }

  func set(_ fix: MapperFix?) {
    state.withLock { $0 = fix }
  }
}

// MARK: - Entry source

/// A hand-fed stand-in for `RxLogService.entryStream()`.
///
/// One buffered stream, handed to the single subscriber the engine creates per `start()`.
/// Buffering is unbounded so a test can queue every entry before the engine has caught up
/// and still assert on all of them.
final class ScriptedRxEntrySource: MapperRxEntrySource {
  private let stream: AsyncStream<RxLogEntryDTO>
  private let continuation: AsyncStream<RxLogEntryDTO>.Continuation

  init() {
    (stream, continuation) = AsyncStream.makeStream(
      of: RxLogEntryDTO.self,
      bufferingPolicy: .unbounded
    )
  }

  func entryStream() -> AsyncStream<RxLogEntryDTO> {
    stream
  }

  func send(_ entry: RxLogEntryDTO) {
    continuation.yield(entry)
  }

  func finish() {
    continuation.finish()
  }
}

// MARK: - TX-heard source

/// A hand-fed stand-in for `HeardRepeatsService.events()`.
final class ScriptedTxHeardSource: MapperTxHeardSource {
  private let stream: AsyncStream<HeardRepeatEvent>
  private let continuation: AsyncStream<HeardRepeatEvent>.Continuation

  init() {
    (stream, continuation) = AsyncStream.makeStream(
      of: HeardRepeatEvent.self,
      bufferingPolicy: .unbounded
    )
  }

  func events() -> AsyncStream<HeardRepeatEvent> {
    stream
  }

  func send(_ event: HeardRepeatEvent) {
    continuation.yield(event)
  }

  func finish() {
    continuation.finish()
  }
}

/// A heard repeat of one of our own packets, with the path and readings the service writes.
func mapperHeardRepeat(
  messageID: UUID = UUID(),
  count: Int = 1,
  receivedAt: Date,
  snr: Double? = 7,
  rssi: Int? = -75,
  hashSize: Int = 1,
  pathNodes: [UInt8] = [0x42],
  isFlood: Bool = true
) -> HeardRepeatEvent {
  HeardRepeatEvent(
    messageID: messageID,
    count: count,
    detail: MessageRepeatDTO(
      messageID: messageID,
      receivedAt: receivedAt,
      pathNodes: Data(pathNodes),
      pathLength: encodePathLen(hashSize: hashSize, hopCount: pathNodes.count / hashSize),
      snr: snr,
      rssi: rssi,
      rxLogEntryID: UUID()
    ),
    isFlood: isFlood
  )
}

// MARK: - ACK source

/// A hand-fed stand-in for `MessageService.statusEvents()`.
final class ScriptedAckSource: MapperAckSource {
  private let stream: AsyncStream<MessageStatusEvent>
  private let continuation: AsyncStream<MessageStatusEvent>.Continuation

  init() {
    (stream, continuation) = AsyncStream.makeStream(
      of: MessageStatusEvent.self,
      bufferingPolicy: .unbounded
    )
  }

  func statusEvents() -> AsyncStream<MessageStatusEvent> {
    stream
  }

  func send(_ event: MessageStatusEvent) {
    continuation.yield(event)
  }

  func finish() {
    continuation.finish()
  }
}

// MARK: - RX entries

/// A minimal RX entry.
///
/// `packetHash` is derived from `packetPayload` by `ParsedRxLogData`, so `payload` is what
/// makes two entries distinct packets rather than duplicates of one.
func mapperRxEntry(
  payload: Data,
  receivedAt: Date,
  snr: Double? = 8,
  rssi: Int? = -70,
  routeType: RouteType = .flood,
  hashSize: Int = 1,
  pathNodes: [UInt8] = [0x42],
  radioID: UUID = UUID()
) -> RxLogEntryDTO {
  let parsed = ParsedRxLogData(
    snr: snr,
    rssi: rssi,
    rawPayload: Data([0x15]) + payload,
    routeType: routeType,
    payloadType: .groupText,
    payloadVersion: 0,
    payloadTypeBits: 5,
    transportCode: nil,
    pathLength: encodePathLen(hashSize: hashSize, hopCount: pathNodes.count / hashSize),
    pathNodes: pathNodes,
    packetPayload: payload
  )
  return RxLogEntryDTO(radioID: radioID, receivedAt: receivedAt, from: parsed)
}

// MARK: - Waiting

/// Polls `condition` until it holds or the budget runs out.
///
/// The engine ingests on its own task, so there is no synchronous moment at which a fed
/// entry has definitely been folded. Polling a counter is how the tests find that moment
/// without sleeping a fixed amount and hoping.
@discardableResult
func waitForMapper(
  timeout: Duration = .seconds(5),
  _ condition: @Sendable () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(2))
  }
  return await condition()
}

/// Waits until the engine has accounted for `count` entries — folded or dropped.
@discardableResult
func waitForMapperAccounted(
  _ engine: SignalMapperCaptureEngine,
  count: Int,
  timeout: Duration = .seconds(5)
) async -> Bool {
  await waitForMapper(timeout: timeout) {
    let snapshot = await engine.snapshot()
    return snapshot.sampleCount + snapshot.droppedCount >= count
  }
}
