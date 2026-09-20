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

  /// Where the weather came from, in its place in the flags nibble (spec §2.2, revision 7: bits
  /// 3-2). Spelled out here rather than taken from the module, because these fixtures build the
  /// nibble by hand so the header and the body can never disagree.
  static func sourceBits(_ source: MeshWXDataSource) -> UInt8 {
    source.rawValue << 2
  }

  /// `issuedMinutes` puts the warning into the revision 5 form (spec §3): flags nibble bit 1 and
  /// the two trailing bytes, which the wire carries as the gap back from `expiresMinutes`.
  static func warning(
    seq: UInt8,
    identity: MeshWXWarningIdentity = svw42,
    expiresMinutes: UInt32 = t0Minutes + 45,
    isUpdate: Bool = false,
    windMph: UInt8 = 60,
    issuedMinutes: UInt32? = nil,
    source: MeshWXDataSource = .unstated,
    bot: UInt16 = botID
  ) -> MeshWXMessage {
    // Flags nibble: bit 0 update, bit 1 the issue time follows, bits 3-2 where the data came
    // from. Set here so the header and the body cannot disagree.
    let flags: UInt8 = (isUpdate ? 1 : 0) | (issuedMinutes == nil ? 0 : 2) | sourceBits(source)
    return MeshWXMessage(
      header: header(seq: seq, type: .warning, flags: flags, bot: bot),
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
        areas: [MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 453, run: 1)],
        issuedBeforeMinutes: issuedMinutes.map { UInt16(expiresMinutes - $0) }
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

  /// `ages` puts the batch into the revision 5 form (spec §6.1): flags nibble bit 0 and one age
  /// per station, in minutes behind `timestampMinutes`. All or nothing, so it must name every
  /// station in the batch or none of them.
  static func observations(
    seq: UInt8,
    timestampMinutes: UInt32 = t0Minutes,
    stations: [(UInt16, Int8?)],
    ages: [UInt16]? = nil,
    source: MeshWXDataSource = .unstated,
    bot: UInt16 = botID
  ) -> MeshWXMessage {
    MeshWXMessage(
      header: header(
        seq: seq, type: .observations, flags: (ages == nil ? 0 : 1) | sourceBits(source), bot: bot),
      payload: .observations(MeshWXObservations(
        timestampMinutes: timestampMinutes,
        stations: stations.enumerated().map { position, station in
          MeshWXStationObservation(
            stationIndex: station.0, tempF: station.1, sky: .few, ageMinutes: ages?[position])
        }
      ))
    )
  }

  static func forecast(
    seq: UInt8,
    point: UInt16 = 102,
    issuedMinutes: UInt32 = t0Minutes,
    source: MeshWXDataSource = .unstated,
    bot: UInt16 = botID
  ) -> MeshWXMessage {
    MeshWXMessage(
      header: header(seq: seq, type: .forecast, flags: sourceBits(source), bot: bot),
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

  /// `wasCut` puts the chunk into the revision 7 form (spec §8.1): flags nibble bit 0, which the
  /// bot sets on every chunk of a reply whose tail it had to drop.
  static func text(
    seq: UInt8,
    subject: MeshWXTextSubject = .warningNarrative,
    group: UInt8,
    index: UInt8,
    total: UInt8,
    text: String,
    wasCut: Bool = false,
    source: MeshWXDataSource = .unstated,
    bot: UInt16 = botID
  ) -> MeshWXMessage {
    MeshWXMessage(
      header: header(
        seq: seq, type: .text, flags: (wasCut ? 1 : 0) | sourceBits(source), bot: bot),
      payload: .text(MeshWXText(
        subject: subject, group: group, index: index, total: total, text: text, wasCut: wasCut))
    )
  }

  /// One packet of a national area sweep (spec §7C). The flags nibble is built by hand here, so
  /// the header and the body cannot disagree about the cut and the scope.
  static func areaSweep(
    seq: UInt8,
    builtMinutes: UInt32 = t0Minutes,
    group: UInt8,
    index: UInt8,
    total: UInt8,
    entries: [MeshWXAreaSweep.Entry],
    wasCut: Bool = false,
    includesAdvisories: Bool = false,
    source: MeshWXDataSource = .unstated,
    bot: UInt16 = botID
  ) -> MeshWXMessage {
    MeshWXMessage(
      header: header(
        seq: seq, type: .areaSweep,
        flags: (wasCut ? 1 : 0) | (includesAdvisories ? 2 : 0) | sourceBits(source), bot: bot),
      payload: .areaSweep(MeshWXAreaSweep(
        builtMinutes: builtMinutes, group: group, index: index, total: total, wasCut: wasCut,
        includesAdvisories: includesAdvisories, entries: entries))
    )
  }

  /// Texas zones 192-197 under a Severe Thunderstorm Warning.
  static let texasSweepEntry = MeshWXAreaSweep.Entry(
    event: 3, stateIndex: 42, isCounty: false, start: 192, run: 6)
  /// Oklahoma counties 1-4 under a Winter Storm Warning.
  static let oklahomaSweepEntry = MeshWXAreaSweep.Entry(
    event: 24, stateIndex: 35, isCounty: true, start: 1, run: 4)

  /// WX-AUS's real statement (spec §7A, the vector `coverage_wx_aus`): 120 km around Austin, the
  /// offices EWX/FWD/HGX/SJT, and its 36 zones as five runs, neither list cut.
  static let austinCoverage = MeshWXCoverage(
    latitude: 30.2672, longitude: -97.7431, radiusKilometres: 120, stationCap: 14,
    officeIndices: [35, 40, 51, 113],
    areas: [
      MeshWXAreaRun(stateIndex: 42, isCounty: false, start: 155, run: 6),
      MeshWXAreaRun(stateIndex: 42, isCounty: false, start: 170, run: 6),
      MeshWXAreaRun(stateIndex: 42, isCounty: false, start: 186, run: 12),
      MeshWXAreaRun(stateIndex: 42, isCounty: false, start: 205, run: 7),
      MeshWXAreaRun(stateIndex: 42, isCounty: false, start: 221, run: 5)
    ])

  static func coverage(seq: UInt8, _ coverage: MeshWXCoverage = austinCoverage, bot: UInt16 = botID) -> MeshWXMessage {
    // Flags nibble: bit 0 the zones were cut, bit 1 the offices were (spec §7A). Set here so the
    // header and the body cannot disagree.
    let flags: UInt8 = (coverage.areasCut ? 1 : 0) | (coverage.officesCut ? 2 : 0)
    return MeshWXMessage(
      header: header(seq: seq, type: .coverage, flags: flags, bot: bot),
      payload: .coverage(coverage)
    )
  }

  static func notAvailable(seq: UInt8, letter: Character, reason: MeshWXNotAvailableReason, bot: UInt16 = botID) -> MeshWXMessage {
    MeshWXMessage(
      header: header(seq: seq, type: .notAvailable, bot: bot),
      payload: .notAvailable(MeshWXNotAvailable(requestCode: UInt8(letter.asciiValue ?? 0), reason: reason))
    )
  }

  /// Another phone's `>` request, flooded on the channel (spec §7B). Not this phone's: the
  /// sender prefix and the seq are somebody else's, which is the whole point of the fixture.
  static func request(
    seq: UInt8 = 7,
    bot: UInt16 = botID,
    sender: Data = Data([0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F]),
    at timestamp: Date = t0,
    text: String = ">d"
  ) -> MeshWXMessage {
    MeshWXMessage(
      header: header(seq: seq, type: .request, bot: bot),
      payload: .request(MeshWXRequest(
        seq: seq, botID: bot, senderPrefix: sender,
        timestamp: UInt32(timestamp.timeIntervalSince1970), text: text))
    )
  }

  /// This phone's own 32-byte key, whose first six bytes a Request datagram carries.
  static let phonePublicKey = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]) + Data(repeating: 0x77, count: 26)

  static func selfInfo(publicKey: Data = phonePublicKey) -> SelfInfo {
    SelfInfo(
      advertisementType: 0, txPower: 20, maxTxPower: 20, publicKey: publicKey,
      latitude: 0, longitude: 0, multiAcks: 2, advertisementLocationPolicy: 0,
      telemetryModeEnvironment: 0, telemetryModeLocation: 0, telemetryModeBase: 2,
      manualAddContacts: false, radioFrequency: 915.0, radioBandwidth: 250.0,
      radioSpreadingFactor: 10, radioCodingRate: 5, name: "TestPhone")
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

/// A radio the tests control: datagrams and delivery confirmations are pushed in, DMs are
/// recorded with the ACK code the radio would expect back.
actor FakeWeatherTransport: WeatherTransport {
  private(set) var sent: [(publicKey: Data, text: String, timestamp: Date, attempt: UInt8, ackCode: Data)] = []
  /// The Request datagrams the service flooded on `#meshwx`, in order (spec §7B).
  private(set) var channelSent: [(text: String, botID: UInt16, timestamp: Date, seq: UInt8)] = []
  /// Whether this radio can send a channel datagram at all. False is the old firmware, or a
  /// radio with no `#meshwx` slot: `sendChannelRequest` then refuses and the service falls back
  /// to the DM ladder.
  var channelRequestsSupported = true
  /// The routes the service asked the radio to forget, in order: one per flood attempt.
  private(set) var resets: [Data] = []
  var failNextSend = false
  /// Confirms each send before the send returns, as a fast link can.
  private var confirmsDuringSend = false
  private var continuations: [AsyncStream<MeshEvent>.Continuation] = []
  private var acknowledgementContinuations: [AsyncStream<Data>.Continuation] = []

  /// The firmware's derivation over a fixed sender key: each transmission has its own code.
  static func ackCode(text: String, timestamp: Date, attempt: UInt8) -> Data {
    AckCodeBuilder.expectedAck(
      timestamp: UInt32(timestamp.timeIntervalSince1970), attempt: attempt, text: text,
      senderPublicKey: Data(repeating: 0x5A, count: 32))
  }
  /// Slot secrets the radio reports. Slot 3 — where fixture datagrams arrive — is `#meshwx`;
  /// an absent slot is unreadable.
  private var secrets: [UInt8: Data] = [3: WeatherChannel.secret]
  private(set) var secretLookups: [UInt8] = []
  /// Whether the fake radio is draining its queue: datagrams delivered meanwhile are backlog.
  private var drainingBacklog = false
  /// A link of the transport's own, as the debug bridge to a real bot reports one. Nil is what
  /// a radio answers.
  private var link: WeatherTransportLink?
  /// How often a channel request was refused because this radio cannot send one: what proves
  /// the service tried the channel before falling back to the DM.
  private(set) var channelRequestsRefused = 0

  /// - Parameter channelRequestsSupported: whether this radio can flood a Request datagram.
  init(channelRequestsSupported: Bool = true) {
    self.channelRequestsSupported = channelRequestsSupported
  }

  func isDrainingBacklog() async -> Bool {
    drainingBacklog
  }

  func resetPath(to publicKey: Data) async throws {
    resets.append(publicKey)
  }

  func linkState() async -> WeatherTransportLink? {
    link
  }

  func setLink(_ link: WeatherTransportLink?) {
    self.link = link
  }

  func setDrainingBacklog(_ draining: Bool) {
    drainingBacklog = draining
  }

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

  func acknowledgements() async -> AsyncStream<Data> {
    let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
    acknowledgementContinuations.append(continuation)
    return stream
  }

  func sendRequest(to publicKey: Data, text: String, timestamp: Date, attempt: UInt8) async throws -> Data {
    if failNextSend {
      failNextSend = false
      throw MeshCoreError.deviceError(code: 1)
    }
    let code = Self.ackCode(text: text, timestamp: timestamp, attempt: attempt)
    sent.append((publicKey, text, timestamp, attempt, code))
    if confirmsDuringSend {
      acknowledge(code)
      // Long enough for the service to take the confirmation before this send returns.
      try? await Task.sleep(for: .milliseconds(100))
    }
    return code
  }

  func sendChannelRequest(text: String, botID: UInt16, timestamp: Date, seq: UInt8) async throws {
    guard channelRequestsSupported else {
      channelRequestsRefused += 1
      throw WeatherTransportError.channelRequestsUnavailable("the fake radio has no #meshwx slot")
    }
    if failNextSend {
      failNextSend = false
      throw MeshCoreError.deviceError(code: 1)
    }
    channelSent.append((text, botID, timestamp, seq))
  }

  func setChannelRequestsSupported(_ supported: Bool) {
    channelRequestsSupported = supported
  }

  /// Pushes a delivery confirmation, as the radio's ACK push.
  func acknowledge(_ code: Data) {
    for continuation in acknowledgementContinuations {
      continuation.yield(code)
    }
  }

  func setConfirmsDuringSend(_ confirms: Bool) {
    confirmsDuringSend = confirms
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
