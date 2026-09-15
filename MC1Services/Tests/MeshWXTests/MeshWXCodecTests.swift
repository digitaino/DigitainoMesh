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
}
