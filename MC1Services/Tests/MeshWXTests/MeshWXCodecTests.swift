import Foundation
import Testing

@testable import MeshWX

/// Everything the nine vectors do not reach: the failure paths, the chunker, and the
/// UGC run packing.
@Suite("MeshWX codec")
struct MeshWXCodecTests {

  // MARK: - Header and unknown types

  @Test func headerSplitsTheTypeByte() throws {
    // seq 17, bot 0x4c7a, type 1 with the update flag set.
    let header = try MeshWXDecoder.decodeHeader(Data([0x11, 0x7A, 0x4C, 0x11]))
    #expect(header.seq == 17)
    #expect(header.bot == 19578)
    #expect(header.rawType == 1)
    #expect(header.type == .warning)
    #expect(header.flags == 1)
  }

  @Test func unknownTypeKeepsTheHeaderAndDropsTheBody() throws {
    // Nibble 12 is in the third-party experimental range (spec §2.2): the bot never
    // sends it, so it must be ignored — but `(bot, seq)` tracking still needs it, which
    // is why this is a decode, not an error.
    let message = try MeshWXDecoder.decode(Data([0x05, 0x7A, 0x4C, 0xC3, 0xAA, 0xBB]))
    #expect(message.header.seq == 5)
    #expect(message.header.rawType == 12)
    #expect(message.header.type == nil)
    #expect(message.header.flags == 3)
    #expect(message.payload == .unknown)
  }

  @Test func unknownTypeHasNoEncoding() throws {
    let message = try MeshWXDecoder.decode(Data([0x05, 0x7A, 0x4C, 0xC3]))
    #expect(throws: MeshWXEncodeError.self) {
      _ = try MeshWXEncoder.encode(message)
    }
  }

  // MARK: - Truncation

  @Test func truncatedHeaderThrows() {
    #expect(throws: MeshWXDecodeError.truncated(what: "header", need: 4, have: 3)) {
      _ = try MeshWXDecoder.decode(Data([0x11, 0x7A, 0x4C]))
    }
  }

  @Test func truncatedWarningBodyThrows() {
    // Type 1 with only 10 of the 15 fixed bytes.
    let short = Data([0x11, 0x7A, 0x4C, 0x10, 0x03, 0x23, 0x2A, 0x00, 0xC9, 0x13])
    #expect(throws: MeshWXDecodeError.truncated(what: "warning", need: 15, have: 10)) {
      _ = try MeshWXDecoder.decode(short)
    }
  }

  @Test func truncatedPolygonThrows() throws {
    // A warning whose tag byte promises a 6-vertex polygon but stops after the anchor.
    var data = Data([0x11, 0x7A, 0x4C, 0x10, 0x03, 0x23, 0x2A, 0x00, 0xC9, 0x13, 0xC7, 0x01])
    data.append(contentsOf: [0x02, 0x00, 0x00])  // tags: polygon only
    data.append(contentsOf: [0x06])  // 6 vertices promised
    data.append(contentsOf: [0x30, 0xA8, 0x04, 0xA8, 0x0C, 0xF1])  // anchor only
    #expect(throws: MeshWXDecodeError.self) {
      _ = try MeshWXDecoder.decode(data)
    }
  }

  @Test func truncatedDigestEntriesThrow() {
    // count says 3, only one entry follows.
    var data = Data([0x14, 0x7A, 0x4C, 0x30])
    data.append(contentsOf: [0x9C, 0x13, 0xC7, 0x01, 0x07, 0x03])
    data.append(contentsOf: [0x03, 0x23, 0x2A, 0x00, 0x2D, 0x00])
    #expect(throws: MeshWXDecodeError.truncated(what: "digest entries", need: 28, have: 16)) {
      _ = try MeshWXDecoder.decode(data)
    }
  }

  @Test func truncatedObservationStationsThrow() {
    var data = Data([0x15, 0x7A, 0x4C, 0x40])
    data.append(contentsOf: [0x95, 0x13, 0xC7, 0x01, 0x02])  // 2 stations promised
    data.append(contentsOf: [0xCA, 0x00, 0x58, 0x48, 0x73])  // 5 bytes of the first
    #expect(throws: MeshWXDecodeError.self) {
      _ = try MeshWXDecoder.decode(data)
    }
  }

  @Test func badUTF8InTextThrows() {
    // 0xFF is never a legal UTF-8 byte.
    let data = Data([0x17, 0x7A, 0x4C, 0x60, 0x00, 0x17, 0x00, 0x01, 0x48, 0xFF, 0x69])
    #expect(throws: MeshWXDecodeError.badUTF8) {
      _ = try MeshWXDecoder.decode(data)
    }
  }

  @Test func emptyTextBodyIsValid() throws {
    let message = try MeshWXDecoder.decode(Data([0x17, 0x7A, 0x4C, 0x60, 0x08, 0x17, 0x00, 0x01]))
    guard case .text(let text) = message.payload else {
      Issue.record("expected a text payload")
      return
    }
    #expect(text.text.isEmpty)
    #expect(text.subject == .general)
  }

  // MARK: - Text chunking

  @Test func chunkingNeverSplitsACodePoint() throws {
    // A 4-byte emoji starting at byte 155: a naive 157-byte cut lands in the middle of
    // it and produces two chunks neither of which is valid UTF-8.
    let filler = String(repeating: "A", count: 155)
    let original = filler + "😀" + String(repeating: "B", count: 40)
    #expect(original.utf8.count == 199)

    let chunks = try MeshWXEncoder.textChunks(
      seqStart: 200, bot: 19578, subject: .warningNarrative, text: original)
    #expect(chunks.count == 2)
    #expect(chunks.allSatisfy { $0.count <= MeshWXWire.maxData })

    var reassembled = ""
    for (position, chunk) in chunks.enumerated() {
      let message = try MeshWXDecoder.decode(chunk)
      guard case .text(let text) = message.payload else {
        Issue.record("chunk \(position) is not a text message")
        return
      }
      // Sequence numbers run on from seqStart and wrap; the group stays put so the
      // receiver can bucket the reply.
      #expect(message.header.seq == UInt8(200 + position))
      #expect(text.group == 200)
      #expect(text.index == UInt8(position))
      #expect(text.total == 2)
      #expect(text.subject == .warningNarrative)
      reassembled += text.text
    }
    #expect(reassembled == original)

    // The cut backed off the boundary rather than through it: the emoji is whole and
    // leads the second chunk.
    let first = try MeshWXDecoder.decode(chunks[0])
    guard case .text(let firstText) = first.payload else { return }
    #expect(firstText.text == filler)
    #expect(firstText.text.utf8.count == 155)
    let second = try MeshWXDecoder.decode(chunks[1])
    guard case .text(let secondText) = second.payload else { return }
    #expect(secondText.text.hasPrefix("😀"))
  }

  @Test func chunkSequenceWrapsPast255() throws {
    let chunks = try MeshWXEncoder.textChunks(
      seqStart: 254, bot: 1, subject: .general, text: String(repeating: "x", count: 400))
    #expect(chunks.count == 3)
    let seqs = try chunks.map { try MeshWXDecoder.decodeHeader($0).seq }
    #expect(seqs == [254, 255, 0])
    // The group is the *first* chunk's seq, so it does not wrap with them.
    let groups = try chunks.map { chunk -> UInt8 in
      guard case .text(let text) = try MeshWXDecoder.decode(chunk).payload else { return 0 }
      return text.group
    }
    #expect(groups == [254, 254, 254])
  }

  @Test func emptyTextStillProducesOneChunk() throws {
    let chunks = try MeshWXEncoder.textChunks(seqStart: 0, bot: 1, subject: .general, text: "")
    #expect(chunks.count == 1)
    #expect(chunks[0].count == MeshWXWire.textFixedSize)
  }

  @Test func textOverEightChunksIsRefused() {
    // 8 × 157 = 1256 bytes is the whole budget of a reply.
    let tooLong = String(repeating: "z", count: 1257)
    #expect(throws: MeshWXEncodeError.textTooLong(chunks: 9)) {
      _ = try MeshWXEncoder.textChunks(seqStart: 0, bot: 1, subject: .general, text: tooLong)
    }
  }

  @Test func oversizeTextChunkIsRefused() {
    #expect(throws: MeshWXEncodeError.self) {
      _ = try MeshWXEncoder.text(
        seq: 0, bot: 1, subject: .general, group: 0, index: 0, total: 1,
        text: String(repeating: "q", count: 158))
    }
  }

  // MARK: - UGC runs (spec §3)

  private let states = ["AL", "AK", "AZ", "TX"]  // TX at index 3 for these tests

  @Test func consecutiveZonesMergeIntoOneRun() {
    let runs = MeshWXAreaRun.runs(
      fromUGCs: ["TXZ191", "TXZ192", "TXZ193", "TXZ194", "TXZ200"], states: states)
    #expect(runs.count == 2)
    #expect(runs[0] == MeshWXAreaRun(stateIndex: 3, isCounty: false, start: 191, run: 4))
    #expect(runs[1] == MeshWXAreaRun(stateIndex: 3, isCounty: false, start: 200, run: 1))
  }

  @Test func runsExpandBackToTheSameCodes() {
    let ugcs = ["TXZ191", "TXZ192", "TXZ193", "TXZ194", "TXZ200"]
    let runs = MeshWXAreaRun.runs(fromUGCs: ugcs, states: states)
    #expect(runs.flatMap { $0.ugcCodes(states: states) } == ugcs)
  }

  @Test func countiesAndZonesNeverMergeAcrossKinds() {
    // Same state, same numbers, different kind: two runs, counties after zones because
    // the sort puts the zone flag first (matching the reference's tuple ordering).
    let runs = MeshWXAreaRun.runs(fromUGCs: ["TXC191", "TXZ191", "TXZ192"], states: states)
    #expect(runs.count == 2)
    #expect(runs[0] == MeshWXAreaRun(stateIndex: 3, isCounty: false, start: 191, run: 2))
    #expect(runs[1] == MeshWXAreaRun(stateIndex: 3, isCounty: true, start: 191, run: 1))
  }

  @Test func duplicatesCollapseAndOrderDoesNotMatter() {
    let scrambled = MeshWXAreaRun.runs(
      fromUGCs: ["TXZ194", "TXZ191", "TXZ192", "TXZ191", "TXZ193"], states: states)
    #expect(scrambled == [MeshWXAreaRun(stateIndex: 3, isCounty: false, start: 191, run: 4)])
  }

  @Test func unparseableOrUnknownCodesAreSkipped() {
    // Wrong length, wrong kind letter, non-numeric tail, and a state this bundle does
    // not carry: an old bundle must lose the area, not the whole warning.
    let runs = MeshWXAreaRun.runs(
      fromUGCs: ["TXZ19", "TXX191", "TXZ19A", "ZZZ191", "txz192"], states: states)
    #expect(runs == [MeshWXAreaRun(stateIndex: 3, isCounty: false, start: 192, run: 1)])
  }

  @Test func expansionWithoutTheStateYieldsNothing() {
    // The run is still decodable, it just cannot be named (spec §9, append-only tables).
    let run = MeshWXAreaRun(stateIndex: 99, isCounty: true, start: 453, run: 1)
    #expect(run.ugcCodes(states: states).isEmpty)
    #expect(run.numbers == [453])
  }

  @Test func ugcNumbersArePaddedToThreeDigits() {
    let run = MeshWXAreaRun(stateIndex: 3, isCounty: true, start: 7, run: 2)
    #expect(run.ugcCodes(states: states) == ["TXC007", "TXC008"])
  }

  // MARK: - Compass rounding

  @Test func compassRoundsHalvesToEvenLikeTheReference() {
    // 348.75° is exactly halfway between sectors 15 and 16; Python's round() takes the
    // even one (16), which folds to 0 — north. Rounding half *up* here would report a
    // north-north-westerly as north-north-west and disagree with the bot.
    #expect(MeshWXCompass(degrees: 348.75) == .north)
    #expect(MeshWXCompass(degrees: 11.25) == .north)
    #expect(MeshWXCompass(degrees: 157) == .southSouthEast)
    #expect(MeshWXCompass(degrees: 292.5) == .westNorthWest)
    #expect(MeshWXCompass(degrees: 360) == .north)
    #expect(MeshWXCompass(degrees: -22.5) == .northNorthWest)
    #expect(MeshWXCompass(degrees: nil) == .north)
    #expect(MeshWXCompass(degrees: .nan) == .north)
  }

  // MARK: - Encoder limits

  @Test func encoderRefusesOutOfSpecCounts() {
    let identity = MeshWXWarningIdentity(event: 3, office: 35, etn: 42)
    let twoVertices = [
      MeshWXCoordinate(latitude: 30, longitude: -97),
      MeshWXCoordinate(latitude: 31, longitude: -98),
    ]
    #expect(throws: MeshWXEncodeError.self) {
      _ = try MeshWXEncoder.warning(
        seq: 0, bot: 1, identity: identity, expiresMinutes: 0, polygon: twoVertices)
    }
    #expect(throws: MeshWXEncodeError.self) {
      _ = try MeshWXEncoder.observations(seq: 0, bot: 1, timestampMinutes: 0, stations: [])
    }
    let fifteen = (0..<15).map { MeshWXStationObservation(stationIndex: UInt16($0)) }
    #expect(throws: MeshWXEncodeError.self) {
      _ = try MeshWXEncoder.observations(seq: 0, bot: 1, timestampMinutes: 0, stations: fifteen)
    }
    let entries = (0..<26).map {
      (identity: MeshWXWarningIdentity(event: 3, office: 35, etn: UInt16($0)), expiresMinutes: UInt32(10))
    }
    #expect(throws: MeshWXEncodeError.self) {
      _ = try MeshWXEncoder.digest(
        seq: 0, bot: 1, nowMinutes: 0, feedHealth: 0, entries: entries)
    }
  }

  @Test func polygonDeltaBeyondI16IsRefused() {
    // 0.001° resolution caps a hop at ±32.767°; a polygon spanning more than that has
    // to be re-anchored rather than silently wrapped.
    let identity = MeshWXWarningIdentity(event: 3, office: 35, etn: 42)
    let stretched = [
      MeshWXCoordinate(latitude: 0, longitude: 0),
      MeshWXCoordinate(latitude: 40, longitude: 0),
      MeshWXCoordinate(latitude: 40, longitude: 1),
    ]
    #expect(throws: MeshWXEncodeError.self) {
      _ = try MeshWXEncoder.warning(
        seq: 0, bot: 1, identity: identity, expiresMinutes: 0, polygon: stretched)
    }
  }

  @Test func digestClampsRelativeExpiry() throws {
    let identity = MeshWXWarningIdentity(event: 3, office: 35, etn: 1)
    let data = try MeshWXEncoder.digest(
      seq: 1, bot: 1, nowMinutes: 1000, feedHealth: 0,
      entries: [
        (identity, UInt32(900)),  // already expired: clamps to 0
        (identity, UInt32(1000 + 70000)),  // past the u16: clamps to 65535
      ])
    guard case .digest(let digest) = try MeshWXDecoder.decode(data).payload else {
      Issue.record("expected a digest")
      return
    }
    #expect(digest.entries[0].expiresRelativeMinutes == 0)
    #expect(digest.entries[0].expiresMinutes == 1000)
    #expect(digest.entries[1].expiresRelativeMinutes == 65535)
  }

  @Test func notAvailableTakesTheFirstLetterOfTheRequest() throws {
    let data = try MeshWXEncoder.notAvailable(
      seq: 25, bot: 19578, request: ">f round rock tx", reason: .unknownLocation)
    #expect(data.meshWXHex == "197a4c706601")
    #expect(throws: MeshWXEncodeError.emptyRequest) {
      _ = try MeshWXEncoder.notAvailable(seq: 0, bot: 1, request: ">  ", reason: .noData)
    }
  }

  // MARK: - Request (type 9, spec §7B)

  @Test func aRequestRefusesWhatTheBotCouldNotRead() {
    let sender = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
    // Not six bytes of key: the bot pairs a datagram with the same phone's DMs on this prefix.
    #expect(throws: MeshWXEncodeError.badCount(what: "request sender", count: 5, allowed: 6...6)) {
      _ = try MeshWXEncoder.request(
        seq: 0, bot: 1, senderPrefix: sender.prefix(5), timestamp: 1, text: ">d")
    }
    // Not a `>` request, or nothing after the `>`.
    #expect(throws: MeshWXEncodeError.emptyRequest) {
      _ = try MeshWXEncoder.request(seq: 0, bot: 1, senderPrefix: sender, timestamp: 1, text: "d")
    }
    #expect(throws: MeshWXEncodeError.emptyRequest) {
      _ = try MeshWXEncoder.request(seq: 0, bot: 1, senderPrefix: sender, timestamp: 1, text: ">")
    }
    // 41 bytes of text: one past what §7B allows.
    let long = ">f " + String(repeating: "x", count: 38)
    #expect(throws: MeshWXEncodeError.oversize(what: "request text", bytes: 41)) {
      _ = try MeshWXEncoder.request(seq: 0, bot: 1, senderPrefix: sender, timestamp: 1, text: long)
    }
    #expect(throws: Never.self) {
      _ = try MeshWXEncoder.request(
        seq: 0, bot: 1, senderPrefix: sender, timestamp: 1, text: String(long.dropLast()))
    }
  }

  @Test func aRequestRoundTripsItsTextAndTimeWhoeverSentIt() throws {
    // Another phone's request, as it arrives on the channel: the whole grammar of §8.2 at its
    // longest, to a bot named `0xFFFF` — every bot on the channel.
    let request = MeshWXRequest(
      seq: 200, botID: MeshWXRequest.anyBot,
      senderPrefix: Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]),
      timestamp: 1_789_660_000, text: ">metar round rock tx")
    let data = try request.encode()
    #expect(data.count == MeshWXWire.requestFixedSize + 20)
    let message = try MeshWXDecoder.decode(data)
    guard case let .request(decoded) = message.payload else {
      Issue.record("expected a request")
      return
    }
    #expect(decoded == request)
    #expect(decoded.text == ">metar round rock tx")
    #expect(try MeshWXEncoder.encode(message) == data)
  }

  @Test func aTruncatedRequestIsRefusedRatherThanReadPastItsEnd() {
    // Header plus five of the six sender bytes: one short of the fixed part.
    let short = Data([0x01, 0x1D, 0x04, 0x90, 0x01, 0x02, 0x03, 0x04, 0x05])
    #expect(throws: MeshWXDecodeError.truncated(what: "request", need: 14, have: 9)) {
      _ = try MeshWXDecoder.decode(short)
    }
  }

  @Test func aRequestWithNoTextDecodesAsEmptyRatherThanTrapping() throws {
    // The encoder never makes one, but the bytes can arrive: the packet ends where the text
    // would start.
    let bare = Data([0x01, 0x1D, 0x04, 0x90, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x60, 0x0B, 0xAC, 0x6A])
    guard case let .request(decoded) = try MeshWXDecoder.decode(bare).payload else {
      Issue.record("expected a request")
      return
    }
    #expect(decoded.text.isEmpty)
    #expect(decoded.timestamp == 1_789_660_000)
  }

  @Test func observationSentinelsSurviveARoundTrip() throws {
    // Every optional field at its sentinel at once: the case a real station with a dead
    // sensor produces, and the one where an off-by-one in the field order shows up.
    let blank = MeshWXStationObservation(
      stationIndex: 976, windDirection: .westNorthWest, sky: .thunderstorm)
    let data = try MeshWXEncoder.observations(
      seq: 1, bot: 1, timestampMinutes: 29_823_893, stations: [blank])
    guard case .observations(let observations) = try MeshWXDecoder.decode(data).payload else {
      Issue.record("expected observations")
      return
    }
    #expect(observations.stations == [blank])
    #expect(observations.stations[0].feelsLikeF == nil)
  }

  @Test func pressureOutsideTheEncodableWindowIsRefused() {
    let station = MeshWXStationObservation(stationIndex: 1, pressureInHg: 28.50)
    #expect(throws: MeshWXEncodeError.self) {
      _ = try MeshWXEncoder.observations(seq: 0, bot: 1, timestampMinutes: 0, stations: [station])
    }
  }

  @Test func forecastWindNibbleSaturatesAtSeventyFive() throws {
    let period = MeshWXForecastPeriod(windDirection: .west, windMph: 200)
    let data = try MeshWXEncoder.forecast(
      seq: 1, bot: 1, pointIndex: 102, issuedMinutes: 0, firstPeriod: 0, periods: [period])
    guard case .forecast(let forecast) = try MeshWXDecoder.decode(data).payload else {
      Issue.record("expected a forecast")
      return
    }
    #expect(forecast.periods[0].windMph == 75)
    #expect(forecast.periods[0].windDirection == .west)
  }

  @Test func warningWithNoPolygonOrAreasClearsBothTagBits() throws {
    let data = try MeshWXEncoder.warning(
      seq: 1, bot: 1, identity: MeshWXWarningIdentity(event: 41, office: 35, etn: 3),
      expiresMinutes: 29_824_980, polygon: [], areas: [])
    #expect(data.count == MeshWXWire.warningFixedSize)
    guard case .warning(let warning) = try MeshWXDecoder.decode(data).payload else {
      Issue.record("expected a warning")
      return
    }
    #expect(warning.polygon == nil)
    #expect(warning.areas == nil)
  }

  // MARK: - Per-station ages (spec §6.1, revision 5)

  private func observationsBody(_ data: Data) throws -> MeshWXObservations? {
    guard case let .observations(batch) = try MeshWXDecoder.decode(data).payload else { return nil }
    return batch
  }

  private func station(_ index: UInt16, age: UInt16? = nil) -> MeshWXStationObservation {
    MeshWXStationObservation(stationIndex: index, tempF: 88, sky: .few, ageMinutes: age)
  }

  /// Station `i` is the low nibble of byte `i / 2` when `i` is even and the high nibble when it is
  /// odd, so an even count fills both nibbles of its last byte and an odd count pads the high one.
  @Test func agePlacementIsLowNibbleFirstAndAnOddCountPadsTheLastByte() throws {
    let odd = try MeshWXEncoder.observations(
      seq: 29, bot: 19578, timestampMinutes: 29_823_893,
      stations: [station(202, age: 0), station(860, age: 20), station(976, age: 110)])
    #expect(odd.count == MeshWXWire.observationsFixedSize + 33 + 2)
    #expect(odd[3] & 0x0F == MeshWXWire.flagObservationAges)
    // 0 and 20 share a byte (2 in the high nibble), 110 pads: the vector's own 0x20, 0x0b.
    #expect(odd.suffix(2) == Data([0x20, 0x0B]))
    let oddBatch = try #require(try observationsBody(odd))
    #expect(oddBatch.stations.map(\.ageMinutes) == [0, 20, 110])

    let even = try MeshWXEncoder.observations(
      seq: 30, bot: 19578, timestampMinutes: 29_823_893,
      stations: [
        station(202, age: 10), station(860, age: 30), station(976, age: 40), station(1, age: 150),
      ])
    #expect(even.count == MeshWXWire.observationsFixedSize + 44 + 2, "four stations, two bytes")
    #expect(even.suffix(2) == Data([0x31, 0xF4]))
    let evenBatch = try #require(try observationsBody(even))
    #expect(evenBatch.stations.map(\.ageMinutes) == [10, 30, 40, 150])
    #expect(try MeshWXEncoder.encode(try MeshWXDecoder.decode(even)) == even)
  }

  /// The old form: no flag, no block, and every station's age nil — which is "the batch does not
  /// say", not "this station is the batch time".
  @Test func aBatchWithoutTheAgesFlagCarriesNoAgesAtAll() throws {
    let data = try MeshWXEncoder.observations(
      seq: 21, bot: 19578, timestampMinutes: 29_823_893,
      stations: [station(202), station(860), station(976)])
    #expect(data.count == MeshWXWire.observationsFixedSize + 33, "no block on the end")
    #expect(data[3] & 0x0F == 0)
    let batch = try #require(try observationsBody(data))
    #expect(batch.stations.allSatisfy { $0.ageMinutes == nil })
    #expect(!batch.carriesAges)
    // Every station reads as the batch time, which is all a revision 4 batch states.
    #expect(batch.stations.allSatisfy { batch.reportMinutes(for: $0) == 29_823_893 })
  }

  /// 15 steps is a saturation, not a reading: it means "150 minutes or more", so anything past it
  /// clamps rather than wrapping to a fresh-looking 0.
  @Test func theAgeNibbleRoundsHalfUpAndSaturatesAtOneHundredAndFifty() throws {
    let data = try MeshWXEncoder.observations(
      seq: 1, bot: 1, timestampMinutes: 1000,
      stations: [
        station(1, age: 4), station(2, age: 5), station(3, age: 144), station(4, age: 145),
        station(5, age: 900),
      ])
    let batch = try #require(try observationsBody(data))
    #expect(batch.stations.map(\.ageMinutes) == [0, 10, 140, 150, 150])
    #expect(batch.stations.map(\.isAgeSaturated) == [false, false, false, true, true])
    // A saturated station is at least that old, so its report time is a ceiling.
    #expect(batch.reportMinutes(for: batch.stations[4]) == 850)
  }

  /// All or nothing (spec §6.1): a batch honest about two stations and silent about the third
  /// would leave the third to be guessed at, which is worse than saying nothing.
  @Test func aBatchWhereOnlySomeStationsKnowTheirAgeIsRefused() {
    #expect(throws: MeshWXEncodeError.partialObservationAges(known: 2, stations: 3)) {
      _ = try MeshWXEncoder.observations(
        seq: 1, bot: 1, timestampMinutes: 1000,
        stations: [station(1, age: 0), station(2, age: 20), station(3)])
    }
  }

  /// Spec §6.1: 14 stations are 163 bytes and the nibbles cost 7 more, so a full batch with ages
  /// does not fit — the ages cost the fourteenth station, never the other way round.
  @Test func aBatchOfFourteenWithAgesDoesNotFitOnePacket() throws {
    let thirteen = (0..<MeshWXWire.maxStationsWithAges).map {
      station(UInt16($0), age: UInt16($0 * 10))
    }
    let data = try MeshWXEncoder.observations(
      seq: 1, bot: 1, timestampMinutes: 1000, stations: thirteen)
    #expect(data.count == 159)
    #expect(data.count <= MeshWXWire.maxData)

    let fourteen = thirteen + [station(99, age: 30)]
    #expect(throws: MeshWXEncodeError.oversize(what: "observations", bytes: 170)) {
      _ = try MeshWXEncoder.observations(
        seq: 1, bot: 1, timestampMinutes: 1000, stations: fourteen)
    }
    // Without the ages the same fourteen still fit, as they always did.
    let bare = fourteen.map { MeshWXStationObservation(stationIndex: $0.stationIndex, sky: .few) }
    #expect(try MeshWXEncoder.observations(
      seq: 1, bot: 1, timestampMinutes: 1000, stations: bare).count == 163)
  }

  @Test func truncatedAgeBlockThrows() {
    // Flags nibble 1 promises the ages; two stations need one byte and none follows.
    var data = Data([0x1D, 0x7A, 0x4C, 0x41])
    data.append(contentsOf: [0x95, 0x13, 0xC7, 0x01, 0x02])
    data.append(contentsOf: [0xCA, 0x00, 0x58, 0x48, 0x73, 0x0C, 0x15, 0x0A, 0x5C, 0x3B, 0x07])
    data.append(contentsOf: [0x5C, 0x03, 0x54, 0x46, 0x01, 0x00, 0x00, 0x0A, 0x5F, 0xFF, 0x00])
    #expect(throws: MeshWXDecodeError.truncated(what: "observation ages", need: 32, have: 31)) {
      _ = try MeshWXDecoder.decode(data)
    }
  }

  // MARK: - Warning issue time (spec §3, revision 5)

  private func warningBody(_ data: Data) throws -> MeshWXWarning? {
    guard case let .warning(warning) = try MeshWXDecoder.decode(data).payload else { return nil }
    return warning
  }

  private let svw = MeshWXWarningIdentity(event: 3, office: 35, etn: 42)

  /// The wire carries the gap, not the instant, so the issue time survives a message drained from
  /// an offline queue hours late: both ends of the subtraction ride in the same packet.
  @Test func theIssueTimeIsMinutesBeforeTheExpiryAndSetsItsOwnFlagBit() throws {
    let expires: UInt32 = 29_823_945
    let data = try MeshWXEncoder.warning(
      seq: 28, bot: 19578, identity: svw, expiresMinutes: expires,
      issuedMinutes: expires - 90)
    #expect(data.count == MeshWXWire.warningFixedSize + MeshWXWire.warningIssuedSize)
    #expect(data[3] & 0x0F == MeshWXWire.flagWarningIssued)
    let warning = try #require(try warningBody(data))
    #expect(warning.issuedBeforeMinutes == 90)
    #expect(warning.issuedMinutes == expires - 90)
    #expect(!warning.isIssueTimeSaturated)
    #expect(try MeshWXEncoder.encode(try MeshWXDecoder.decode(data)) == data)

    // The update bit is bit 0 and the issue time bit 1: both fit in the same nibble.
    let both = try MeshWXEncoder.warning(
      seq: 29, bot: 19578, identity: svw, expiresMinutes: expires, isUpdate: true,
      issuedMinutes: expires - 5)
    #expect(both[3] & 0x0F == 0x3)
    let updated = try #require(try warningBody(both))
    #expect(updated.isUpdate)
    #expect(updated.issuedBeforeMinutes == 5)
  }

  @Test func aWarningWithoutTheIssuedFlagHasNoIssueTime() throws {
    let data = try MeshWXEncoder.warning(
      seq: 17, bot: 19578, identity: svw, expiresMinutes: 29_823_945)
    #expect(data.count == MeshWXWire.warningFixedSize)
    #expect(data[3] & 0x0F == 0)
    let warning = try #require(try warningBody(data))
    #expect(warning.issuedBeforeMinutes == nil)
    #expect(warning.issuedMinutes == nil)
    #expect(!warning.isIssueTimeSaturated)
  }

  /// 65535 minutes is 45.5 days, longer than any NWS product runs from issuance to expiry, so the
  /// u16 saturates rather than wrapping — and a product issued after its own expiry, which no real
  /// one is, encodes as 0 rather than failing the message.
  @Test func theIssueTimeSaturatesRatherThanWrapping() throws {
    let expires: UInt32 = 30_000_000
    let ancient = try MeshWXEncoder.warning(
      seq: 1, bot: 1, identity: svw, expiresMinutes: expires, issuedMinutes: expires - 200_000)
    let saturated = try #require(try warningBody(ancient))
    #expect(saturated.issuedBeforeMinutes == MeshWXWire.issuedBeforeSaturatedMinutes)
    #expect(saturated.isIssueTimeSaturated)
    #expect(saturated.issuedMinutes == expires - 65535, "a ceiling: issued at or before this")
    #expect(try MeshWXEncoder.encode(try MeshWXDecoder.decode(ancient)) == ancient)

    let backwards = try MeshWXEncoder.warning(
      seq: 2, bot: 1, identity: svw, expiresMinutes: expires, issuedMinutes: expires + 10)
    let clamped = try #require(try warningBody(backwards))
    #expect(clamped.issuedBeforeMinutes == 0)
    #expect(clamped.issuedMinutes == expires)
  }

  @Test func truncatedIssueTimeThrows() {
    // Flags nibble 2 promises the two bytes; the fixed part stops without them.
    var data = Data([0x1C, 0x7A, 0x4C, 0x12])
    data.append(contentsOf: [0x03, 0x23, 0x2A, 0x00, 0xC9, 0x13, 0xC7, 0x01, 0x00, 0x04, 0x3C])
    data.append(0x15)
    #expect(throws: MeshWXDecodeError.truncated(what: "warning issue time", need: 17, have: 16)) {
      _ = try MeshWXDecoder.decode(data)
    }
  }

  // MARK: - Coverage (type 8, spec §7A)

  private func coverageBody(_ data: Data) throws -> MeshWXCoverage? {
    guard case let .coverage(coverage) = try MeshWXDecoder.decode(data).payload else { return nil }
    return coverage
  }

  /// The two flags are separate bits and each one alone is enough to stop a denial.
  @Test func eachCutFlagIsItsOwnBitAndEitherWithholdsCompleteness() throws {
    let runs = [MeshWXAreaRun(stateIndex: 42, isCounty: false, start: 155, run: 6)]
    for (areasCut, officesCut, nibble) in [
      (false, false, UInt8(0)), (true, false, UInt8(1)), (false, true, UInt8(2)), (true, true, UInt8(3)),
    ] {
      let data = try MeshWXEncoder.coverage(
        seq: 9, bot: 19578, latitude: 30.2672, longitude: -97.7431, radiusKilometres: 120,
        stationCap: 14, officeIndices: [35, 40], areas: runs, areasCut: areasCut,
        officesCut: officesCut)
      #expect(data[3] & 0x0F == nibble)
      let statement = try #require(try coverageBody(data))
      #expect(statement.areasCut == areasCut)
      #expect(statement.officesCut == officesCut)
      #expect(statement.isComplete == (!areasCut && !officesCut))
      // A cut list is never the whole area, so it can never be read as "no filter" either.
      #expect(!statement.hasNoAreaFilter)
      #expect(try MeshWXEncoder.encode(try MeshWXDecoder.decode(data)) == data)
    }
  }

  /// `n` = 0 and `k` = 0: no area filter at all, which is an answer, not an empty message.
  @Test func noOfficesAndNoRunsMeanNoAreaFilterAtAll() throws {
    let data = try MeshWXEncoder.coverage(
      seq: 1, bot: 1, latitude: 0, longitude: 0, radiusKilometres: 0, stationCap: 0,
      officeIndices: [], areas: [])
    #expect(data.count == MeshWXWire.coverageFixedSize + 1, "the empty run list is still counted")
    let statement = try #require(try coverageBody(data))
    #expect(statement.hasNoAreaFilter)
    #expect(statement.officeIndices.isEmpty)
    #expect(statement.areas.isEmpty)
    #expect(try MeshWXEncoder.encode(try MeshWXDecoder.decode(data)) == data)
  }

  /// 0,0 with radius 0 is the bot saying it has no centre — the same non-position an advert
  /// carries (spec §1) — so the runs are the whole answer.
  @Test func aStatementWithNoCentreIsReadFromItsRunsAlone() throws {
    let states = MeshWXTables.shared.states
    let runs = [MeshWXAreaRun(stateIndex: 42, isCounty: false, start: 186, run: 12)]
    let data = try MeshWXEncoder.coverage(
      seq: 2, bot: 1, latitude: 0, longitude: 0, radiusKilometres: 0, stationCap: 0,
      officeIndices: [35], areas: runs)
    let statement = try #require(try coverageBody(data))
    #expect(statement.centre == nil)
    #expect(!statement.hasNoAreaFilter)
    #expect(!statement.circleContains(MeshWXCoordinate(latitude: 0, longitude: 0)))
    #expect(statement.covers(ugc: "TXZ192", states: states))
    #expect(!statement.covers(ugc: "TXZ198", states: states))
    #expect(!statement.covers(ugc: "TXC192", states: states), "a county is not the zone of that number")
    #expect(try MeshWXEncoder.encode(try MeshWXDecoder.decode(data)) == data)
  }

  /// A centre with radius 0 states no circle either: the field, not the coordinate, is what says
  /// there is one.
  @Test func theStatedCircleIsKilometresFromTheCentreAndZeroIsNoCircle() {
    let austin = MeshWXCoordinate(latitude: 30.2672, longitude: -97.7431)
    let roundRock = MeshWXCoordinate(latitude: 30.5083, longitude: -97.6789)
    let dallas = MeshWXCoordinate(latitude: 32.7767, longitude: -96.7970)
    let circle = MeshWXCoverage(
      latitude: austin.latitude, longitude: austin.longitude, radiusKilometres: 120,
      stationCap: 14, officeIndices: [35], areas: [])
    #expect(circle.circleContains(austin))
    #expect(circle.circleContains(roundRock))
    #expect(!circle.circleContains(dallas))

    var noRadius = circle
    noRadius.radiusKilometres = 0
    #expect(noRadius.centre != nil, "a centre was stated; only the circle was not")
    #expect(!noRadius.circleContains(austin))
  }

  @Test func truncatedCoverageOfficesAndRunsThrow() {
    // 14 fixed bytes saying four offices follow.
    var fixed = Data([0x1B, 0x7A, 0x4C, 0x80])
    fixed.append(contentsOf: [0x50, 0x9E, 0x04, 0xE9, 0x15, 0xF1, 0x78, 0x00, 0x0E, 0x04])
    #expect(throws: MeshWXDecodeError.truncated(what: "coverage", need: 14, have: 12)) {
      _ = try MeshWXDecoder.decode(Data(fixed.prefix(12)))
    }

    let twoOffices = fixed + Data([0x23, 0x28])
    #expect(throws: MeshWXDecodeError.truncated(what: "coverage offices", need: 18, have: 16)) {
      _ = try MeshWXDecoder.decode(twoOffices)
    }

    // Offices complete, `k` says five runs, one follows. The runs are the warning's own list, so
    // the failure names it.
    let oneRun = fixed + Data([0x23, 0x28, 0x33, 0x71]) + Data([0x05, 0x2A, 0x9B, 0x00, 0x06])
    #expect(throws: MeshWXDecodeError.truncated(what: "area runs", need: 39, have: 23)) {
      _ = try MeshWXDecoder.decode(oneRun)
    }
  }

  @Test func coverageRefusesListsPastTheirCaps() {
    let runs = [MeshWXAreaRun(stateIndex: 42, isCounty: false, start: 155, run: 6)]
    #expect(throws: MeshWXEncodeError.self) {
      _ = try MeshWXEncoder.coverage(
        seq: 0, bot: 1, latitude: 0, longitude: 0, radiusKilometres: 0, stationCap: 0,
        officeIndices: Array(repeating: 35, count: 25), areas: runs)
    }
    let thirtyOne = (0..<31).map {
      MeshWXAreaRun(stateIndex: 42, isCounty: false, start: UInt16(100 + $0 * 2), run: 1)
    }
    #expect(throws: MeshWXEncodeError.self) {
      _ = try MeshWXEncoder.coverage(
        seq: 0, bot: 1, latitude: 0, longitude: 0, radiusKilometres: 0, stationCap: 0,
        officeIndices: [], areas: thirtyOne)
    }
  }

  /// Spec §7A: the two caps are chosen so a full list never costs the other one.
  @Test func theFullestCoverageStillFitsOnePacket() throws {
    let offices = (0..<MeshWXWire.maxCoverageOffices).map { UInt8($0) }
    let runs = (0..<MeshWXWire.maxAreaRuns).map {
      MeshWXAreaRun(stateIndex: 42, isCounty: false, start: UInt16(100 + $0 * 2), run: 1)
    }
    let data = try MeshWXEncoder.coverage(
      seq: 1, bot: 1, latitude: 30.2672, longitude: -97.7431, radiusKilometres: 120,
      stationCap: 14, officeIndices: offices, areas: runs)
    #expect(data.count == 159)
    #expect(data.count <= MeshWXWire.maxData)
  }

  // MARK: - Data source (spec §2.2, revision 7)

  private func textBody(_ data: Data) throws -> MeshWXText? {
    guard case let .text(text) = try MeshWXDecoder.decode(data).payload else { return nil }
    return text
  }

  /// One message of every type that carries weather, under one source.
  private func weatherMessages(from source: MeshWXDataSource) throws -> [(String, Data)] {
    [
      ("warning", try MeshWXEncoder.warning(
        seq: 1, bot: 19578, identity: svw, expiresMinutes: 29_823_945, source: source)),
      ("digest", try MeshWXEncoder.digest(
        seq: 2, bot: 19578, nowMinutes: 29_823_900, feedHealth: 7,
        entries: [(svw, 29_823_945)], source: source)),
      ("observations", try MeshWXEncoder.observations(
        seq: 3, bot: 19578, timestampMinutes: 29_823_893,
        stations: [station(202, age: 20), station(860, age: 40)], source: source)),
      ("forecast", try MeshWXEncoder.forecast(
        seq: 4, bot: 19578, pointIndex: 102, issuedMinutes: 29_823_880, firstPeriod: 1,
        periods: [MeshWXForecastPeriod(lowF: 73, popPercent: 20, sky: .scattered)],
        source: source)),
      ("text", try MeshWXEncoder.text(
        seq: 5, bot: 19578, subject: .forecastDiscussion, group: 5, index: 0, total: 1,
        text: "AREA FORECAST DISCUSSION", source: source))
    ]
  }

  /// Every type that carries weather states where it came from, and the statement has to survive
  /// a re-encode byte for byte: it rides on the header, so an encoder that took it only from the
  /// body would drop it silently.
  @Test(arguments: MeshWXDataSource.allCases)
  func theDataSourceRoundTripsOnEveryTypeThatCarriesWeather(_ source: MeshWXDataSource) throws {
    for (name, data) in try weatherMessages(from: source) {
      let message = try MeshWXDecoder.decode(data)
      #expect(message.header.dataSource == source, "\(name)")
      #expect(try MeshWXEncoder.encode(message) == data, "\(name) re-encodes to the same bytes")
    }
  }

  /// Bits 3-2, which is the one place in the nibble that was free: the update bit and the issue
  /// time bit keep bits 0 and 1, and each type's own flags are untouched.
  @Test func theSourceSitsInBitsThreeAndTwoAndLeavesTheOtherFlagsAlone() throws {
    let expires: UInt32 = 29_823_945
    let data = try MeshWXEncoder.warning(
      seq: 28, bot: 19578, identity: svw, expiresMinutes: expires, isUpdate: true,
      issuedMinutes: expires - 90, source: .internet)
    // internet = 2, shifted up two: 0b1000, beside the update (0b1) and issued (0b10) bits.
    #expect(data[3] & 0x0F == 0b1011)
    let warning = try #require(try warningBody(data))
    #expect(warning.isUpdate)
    #expect(warning.issuedBeforeMinutes == 90)
    #expect(try MeshWXDecoder.decodeHeader(data).dataSource == .internet)

    // And on a batch that also carries the per-station ages (spec §6.1), which own bit 0.
    let batch = try MeshWXEncoder.observations(
      seq: 29, bot: 19578, timestampMinutes: 29_823_893,
      stations: [station(202, age: 20)], source: .mixed)
    #expect(batch[3] & 0x0F == 0b1101)
    #expect(try #require(try observationsBody(batch)).stations.map(\.ageMinutes) == [20])
    #expect(try MeshWXDecoder.decodeHeader(batch).dataSource == .mixed)
  }

  /// A bot older than revision 7 sets none of these bits, and that is not a claim: it reads as
  /// unstated on every type, and the bytes are the ones it always sent.
  @Test func aBotThatStatesNothingIsUnstatedRatherThanGoes() throws {
    for (name, data) in try weatherMessages(from: .unstated) {
      #expect(data[3] & MeshWXWire.flagDataSourceMask == 0, "\(name)")
      #expect(try MeshWXDecoder.decodeHeader(data).dataSource == .unstated, "\(name)")
    }
    // The types with no weather product behind them always send 0 (spec §2.2, revision 7).
    let notAvailable = try MeshWXEncoder.notAvailable(
      seq: 6, bot: 19578, requestCode: 102, reason: .noData)
    let coverage = try MeshWXEncoder.coverage(
      seq: 7, bot: 19578, latitude: 30.2672, longitude: -97.7431, radiusKilometres: 120,
      stationCap: 14, officeIndices: [35], areas: [])
    let request = try MeshWXEncoder.request(
      seq: 8, bot: 19578, senderPrefix: Data([1, 2, 3, 4, 5, 6]), timestamp: 1_789_436_700,
      text: ">d")
    for data in [notAvailable, coverage, request] {
      #expect(try MeshWXDecoder.decodeHeader(data).dataSource == .unstated)
    }
  }

  /// **The Cancel exception.** Its whole nibble is a reason code (spec §4), so reason 12 is
  /// `other(12)` and never "mixed": reading bits 3-2 there would invent a source out of the
  /// reason a warning ended, and re-encoding what was read would rewrite the reason.
  @Test func aCancelsNibbleIsStillAllReasonAndStatesNoSource() throws {
    for raw in UInt8(0)...15 {
      let reason = MeshWXCancelReason(rawValue: raw)
      let data = try MeshWXEncoder.cancel(seq: 9, bot: 19578, identity: svw, reason: reason)
      let message = try MeshWXDecoder.decode(data)
      #expect(message.header.flags == raw)
      #expect(message.header.dataSource == .unstated, "reason \(raw) is not a source")
      guard case let .cancel(cancel) = message.payload else {
        Issue.record("expected a cancel payload")
        return
      }
      #expect(cancel.reason == reason)
      #expect(cancel.reason.rawValue == raw)
      #expect(try MeshWXEncoder.encode(message) == data)
    }
  }

  // MARK: - Text cut for the air (spec §8.1, revision 7)

  /// Bit 0 of a Text's nibble: the product was longer than eight packets and the bot dropped the
  /// tail. It sits beside the source bits and survives a re-encode.
  @Test func theTextCutFlagIsBitZeroAndRoundTrips() throws {
    let cut = try MeshWXEncoder.text(
      seq: 5, bot: 19578, subject: .forecastDiscussion, group: 5, index: 3, total: 4,
      text: "…SHORT TERM…", wasCut: true, source: .goesSatellite)
    #expect(cut[3] & 0x0F == 0b0101, "cut on bit 0, GOES on bits 3-2")
    let text = try #require(try textBody(cut))
    #expect(text.wasCut)
    #expect(try MeshWXDecoder.decodeHeader(cut).dataSource == .goesSatellite)
    #expect(try MeshWXEncoder.encode(try MeshWXDecoder.decode(cut)) == cut)

    let whole = try MeshWXEncoder.text(
      seq: 6, bot: 19578, subject: .forecastDiscussion, group: 6, index: 0, total: 1,
      text: "…SHORT TERM…")
    #expect(whole[3] & 0x0F == 0)
    #expect(try #require(try textBody(whole)).wasCut == false)
  }

  /// The bot marks *every* chunk, not only the last: a phone that never receives the last one
  /// still has to know the reply is short of the product.
  @Test func aCutReplyMarksEveryChunkOfIt() throws {
    let chunks = try MeshWXEncoder.textChunks(
      seqStart: 40, bot: 19578, subject: .forecastDiscussion,
      text: String(repeating: "x", count: 400), wasCut: true, source: .internet)
    #expect(chunks.count == 3)
    for chunk in chunks {
      #expect(try #require(try textBody(chunk)).wasCut)
      #expect(try MeshWXDecoder.decodeHeader(chunk).dataSource == .internet)
      #expect(try MeshWXEncoder.encode(try MeshWXDecoder.decode(chunk)) == chunk)
    }
  }
}
