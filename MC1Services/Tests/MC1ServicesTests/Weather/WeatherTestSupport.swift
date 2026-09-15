import Foundation
@testable import MC1Services
import MeshCore
import MeshWX

/// Shared fixtures for the weather suites: the Austin bot of the kit's vectors, message
/// builders, and a fake radio the service can be driven through.
enum WeatherFixture {
  /// `bot = 19578` (0x4C7A) in every kit vector: a public key starting `7A 4C`.
  static let botID: UInt16 = 19578
  static let botPublicKey: Data = Data([0x7A, 0x4C]) + Data(repeating: 0x11, count: 30)
  static let bot = WeatherBot(
    publicKey: botPublicKey, name: "WX-AUS", latitude: 30.27, longitude: -97.74, lastAdvert: nil
  )

  static let t0 = Date(timeIntervalSince1970: 1_789_436_700) // 2026-09-15 00:45 UTC
  /// Unix minutes of `t0`.
  static let t0Minutes: UInt32 = UInt32(1_789_436_700 / 60)

  static let svw42 = MeshWXWarningIdentity(event: 3, office: 35, etn: 42)
  static let svw43 = MeshWXWarningIdentity(event: 3, office: 35, etn: 43)
  static let wsw7 = MeshWXWarningIdentity(event: 24, office: 35, etn: 7)

  static func header(seq: UInt8, type: MeshWXMessageType, flags: UInt8 = 0, bot: UInt16 = botID) -> MeshWXHeader {
    MeshWXHeader(seq: seq, bot: bot, type: type, flags: flags)
  }

  static func warning(
    seq: UInt8,
    identity: MeshWXWarningIdentity = svw42,
    expiresMinutes: UInt32 = t0Minutes + 45,
    isUpdate: Bool = false,
    windMph: UInt8 = 60,
    bot: UInt16 = botID
  ) -> MeshWXMessage {
    MeshWXMessage(
      header: header(seq: seq, type: .warning, flags: isUpdate ? 1 : 0, bot: bot),
      payload: .warning(MeshWXWarning(
        identity: identity,
        expiresMinutes: expiresMinutes,
        tornado: .radarIndicated,
        hailQuarterInches: 4,
        windMph: windMph,
        isUpdate: isUpdate,
        polygon: [
          MeshWXCoordinate(latitude: 30.52, longitude: -97.98),
          MeshWXCoordinate(latitude: 30.61, longitude: -97.62),
          MeshWXCoordinate(latitude: 30.38, longitude: -97.41)
        ],
        areas: [MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 453, run: 1)]
      ))
    )
  }

  static func cancel(seq: UInt8, identity: MeshWXWarningIdentity = svw42, reason: MeshWXCancelReason = .expiredEarly, bot: UInt16 = botID) -> MeshWXMessage {
    MeshWXMessage(
      header: header(seq: seq, type: .cancel, flags: reason.rawValue, bot: bot),
      payload: .cancel(MeshWXCancel(identity: identity, reason: reason))
    )
  }

  static func digest(
    seq: UInt8,
    nowMinutes: UInt32 = t0Minutes,
    feedHealth: UInt8 = 7,
    entries: [(MeshWXWarningIdentity, UInt16)],
    bot: UInt16 = botID
  ) -> MeshWXMessage {
    MeshWXMessage(
      header: header(seq: seq, type: .digest, bot: bot),
      payload: .digest(MeshWXDigest(
        nowMinutes: nowMinutes,
        feedHealth: feedHealth,
        entries: entries.map {
          MeshWXDigest.Entry(identity: $0.0, expiresRelativeMinutes: $0.1, expiresMinutes: nowMinutes + UInt32($0.1))
        }
      ))
    )
  }

  static func observations(
    seq: UInt8,
    timestampMinutes: UInt32 = t0Minutes,
    stations: [(UInt16, Int8?)],
    bot: UInt16 = botID
  ) -> MeshWXMessage {
    MeshWXMessage(
      header: header(seq: seq, type: .observations, bot: bot),
      payload: .observations(MeshWXObservations(
        timestampMinutes: timestampMinutes,
        stations: stations.map { MeshWXStationObservation(stationIndex: $0.0, tempF: $0.1, sky: .few) }
      ))
    )
  }

  static func forecast(seq: UInt8, point: UInt16 = 102, issuedMinutes: UInt32 = t0Minutes, bot: UInt16 = botID) -> MeshWXMessage {
    MeshWXMessage(
      header: header(seq: seq, type: .forecast, bot: bot),
      payload: .forecast(MeshWXForecast(
        pointIndex: point,
        issuedMinutes: issuedMinutes,
        firstPeriod: 1,
        periods: [
          MeshWXForecastPeriod(lowF: 73, popPercent: 20, sky: .scattered, windDirection: .southSouthEast, windMph: 5),
          MeshWXForecastPeriod(highF: 93, popPercent: 40, sky: .broken, thunder: true, windDirection: .south, windMph: 10)
        ]
      ))
    )
  }

  static func text(seq: UInt8, subject: MeshWXTextSubject = .warningNarrative, group: UInt8, index: UInt8, total: UInt8, text: String, bot: UInt16 = botID) -> MeshWXMessage {
    MeshWXMessage(
      header: header(seq: seq, type: .text, bot: bot),
      payload: .text(MeshWXText(subject: subject, group: group, index: index, total: total, text: text))
    )
  }

  static func notAvailable(seq: UInt8, letter: Character, reason: MeshWXNotAvailableReason, bot: UInt16 = botID) -> MeshWXMessage {
    MeshWXMessage(
      header: header(seq: seq, type: .notAvailable, bot: bot),
      payload: .notAvailable(MeshWXNotAvailable(requestCode: UInt8(letter.asciiValue ?? 0), reason: reason))
    )
  }

  /// Wraps an encoded message in the datagram the firmware would deliver.
  static func datagram(_ message: MeshWXMessage, dataType: UInt16 = MeshWXWire.dataType, channelIndex: UInt8 = 3) throws -> ChannelDatagram {
    ChannelDatagram(
      channelIndex: channelIndex,
      pathLength: 0xFF,
      dataType: dataType,
      data: try MeshWXEncoder.encode(message),
      snr: 6.5
    )
  }
}

/// A radio the tests control: datagrams are pushed in, DMs are recorded.
actor FakeWeatherTransport: WeatherTransport {
  private(set) var sent: [(publicKey: Data, text: String)] = []
  var failNextSend = false
  private var continuations: [AsyncStream<MeshEvent>.Continuation] = []
  /// Slot secrets the radio reports. Slot 3 — where fixture datagrams arrive — is `#meshwx`;
  /// an absent slot is unreadable.
  private var secrets: [UInt8: Data] = [3: WeatherChannel.secret]
  private(set) var secretLookups: [UInt8] = []

  func channelSecret(at index: UInt8) async -> Data? {
    secretLookups.append(index)
    return secrets[index]
  }

  func setSecret(_ secret: Data?, at index: UInt8) {
    secrets[index] = secret
  }

  func datagramEvents() async -> AsyncStream<MeshEvent> {
    let (stream, continuation) = AsyncStream.makeStream(of: MeshEvent.self)
    continuations.append(continuation)
    return stream
  }

  func sendRequest(to publicKey: Data, text: String) async throws {
    if failNextSend {
      failNextSend = false
      throw MeshCoreError.deviceError(code: 1)
    }
    sent.append((publicKey, text))
  }

  func deliver(_ datagram: ChannelDatagram) {
    for continuation in continuations {
      continuation.yield(.channelDataReceived(datagram))
    }
  }

  func deliver(_ event: MeshEvent) {
    for continuation in continuations {
      continuation.yield(event)
    }
  }

  func setFailNextSend(_ fail: Bool) {
    failNextSend = fail
  }
}

/// A settable clock for the service.
final class WeatherTestClock: Sendable {
  private let storage: LockedValue<Date>

  init(_ start: Date = WeatherFixture.t0) {
    storage = LockedValue(start)
  }

  var now: Date { storage.value }

  func advance(by seconds: TimeInterval) {
    storage.value = storage.value.addingTimeInterval(seconds)
  }
}

/// Minimal lock box; `Mutex` from Synchronization would do but keeps the test target's
/// deployment floor simple.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
  private var stored: Value
  private let lock = NSLock()

  init(_ value: Value) {
    stored = value
  }

  var value: Value {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

/// Polls until `predicate` is true or the deadline passes.
func weatherWaitUntil(
  timeout: Duration = .seconds(2),
  poll: Duration = .milliseconds(10),
  _ predicate: @Sendable () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while clock.now < deadline {
    if await predicate() { return true }
    try? await Task.sleep(for: poll)
  }
  return await predicate()
}
