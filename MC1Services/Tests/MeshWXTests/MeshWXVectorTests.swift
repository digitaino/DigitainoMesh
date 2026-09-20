import Foundation
import Testing

@testable import MeshWX

/// Conformance against the bot's own wire vectors (spec revision 5).
///
/// The kit's own bar: "your decoder is correct when it turns every `hex` into the
/// matching `decoded` JSON, and your encoder reproduces the same `hex`." Both halves run
/// here, field by field — no reflection, no round-trip-only shortcut, because a codec
/// that is wrong in both directions round-trips perfectly.
@Suite("MeshWX vectors")
struct MeshWXVectorTests {

  /// Every vector in the file reaches the tests below. No fixed count, since the bot adds
  /// vectors: the file is counted without the fixture type, so a vector the type cannot read —
  /// which would empty the whole list — fails here instead of passing over nothing.
  @Test func fixtureIsPresent() throws {
    let count = try #require(MeshWXVectors.fileCount, "the vector file did not load")
    #expect(count > 0)
    #expect(MeshWXVectors.all.count == count, "a vector the fixture type cannot read")
    #expect(Set(MeshWXVectors.all.map(\.name)).count == count, "vector names are unique")
    // Revision 2's whole-day forecast.
    #expect(MeshWXVectors.all.contains { $0.name == "forecast_seven_days" })
    // Revision 4's coverage statement: WX-AUS's real 39-byte message.
    #expect(MeshWXVectors.all.contains { $0.name == "coverage_wx_aus" })
    // Revision 5's two times, each beside the revision 4 form of the same message.
    #expect(MeshWXVectors.all.contains { $0.name == "observations_three_stations_ages" })
    #expect(MeshWXVectors.all.contains { $0.name == "severe_thunderstorm_warning_issued" })
  }

  @Test(arguments: MeshWXVectors.all)
  func decodesToTheDocumentedFields(_ vector: MeshWXVectors.Vector) throws {
    let data = try #require(Data(meshWXHex: vector.hex), "vector hex is not hex")
    let message = try MeshWXDecoder.decode(data)
    let want = vector.decoded

    // Header, for every type.
    #expect(message.header.seq == want.seq)
    #expect(message.header.bot == want.bot)
    #expect(message.header.rawType == want.type)
    #expect(message.header.flags == want.flags)
    #expect(message.header.type?.rawValue == want.type)

    switch message.payload {
    case .warning(let warning):
      #expect(want.name == "warning")
      try expectWarning(warning, matches: want)
    case .cancel(let cancel):
      #expect(want.name == "cancel")
      expectCancel(cancel, matches: want)
    case .digest(let digest):
      #expect(want.name == "digest")
      try expectDigest(digest, matches: want)
    case .observations(let observations):
      #expect(want.name == "observations")
      try expectObservations(observations, matches: want)
    case .forecast(let forecast):
      #expect(want.name == "forecast")
      try expectForecast(forecast, matches: want)
    case .text(let text):
      #expect(want.name == "text")
      expectText(text, matches: want)
    case .notAvailable(let notAvailable):
      #expect(want.name == "not_available")
      expectNotAvailable(notAvailable, matches: want)
    case .coverage(let coverage):
      #expect(want.name == "coverage")
      try expectCoverage(coverage, matches: want)
    case .request:
      // The publisher's file carries no Request vector yet; `theRequestVectorIsTheSixteenBytes…`
      // below tests the one the spec prints. This case exists so that the day it ships, the
      // vector reaches the suite instead of failing to compile.
      #expect(want.name == "request")
    case .areaSweep(let sweep):
      #expect(want.name == "area_sweep")
      try expectAreaSweep(sweep, matches: want)
    case .unknown:
      Issue.record("vector \(vector.name) decoded as an unknown type")
    }
  }

  /// Spec §7A: WX-AUS's real message is 39 bytes — 14 fixed, four offices, five runs — and it
  /// says the bot covers its own home county, which is what the app used to get wrong.
  @Test func theCoverageVectorIsTheMessageTheSpecDescribes() throws {
    let vector = try #require(MeshWXVectors.all.first { $0.name == "coverage_wx_aus" })
    let data = try #require(Data(meshWXHex: vector.hex))
    #expect(data.count == 39)
    guard case let .coverage(statement) = try MeshWXDecoder.decode(data).payload else {
      Issue.record("expected a coverage message")
      return
    }
    #expect(statement.centre == MeshWXCoordinate(latitude: 30.2672, longitude: -97.7431))
    #expect(statement.radiusKilometres == 120)
    // 13, not 14: from revision 5 WX-AUS's hourly batch carries the per-station ages, and the
    // nibble block costs it its farthest station (spec §6.1).
    #expect(statement.stationCap == 13)
    #expect(statement.isComplete)
    #expect(!statement.hasNoAreaFilter)

    let tables = MeshWXTables.shared
    #expect(statement.officeIndices.map { tables.officeCode($0) } == ["EWX", "FWD", "HGX", "SJT"])
    #expect(statement.areas.count == 5)
    #expect(statement.covers(ugc: "TXZ192", states: tables.states), "Travis, the bot's own county")
    #expect(statement.covers(ugc: "TXZ155", states: tables.states))
    #expect(statement.covers(ugc: "TXZ225", states: tables.states))
    #expect(!statement.covers(ugc: "TXZ198", states: tables.states), "between two runs")
    #expect(!statement.covers(ugc: "TXZ226", states: tables.states), "one past the last run")
  }

  /// Spec §6.1: the revision 5 batch is the revision 4 one with two bytes of nibbles appended
  /// and one flag bit set — 0, 20 and 110 minutes as 0x20, 0x0b — which is the whole
  /// compatibility claim, and the reason an old decoder reads the new bytes unchanged.
  @Test func theAgesVectorIsTheOldBatchWithANibbleBlockAppended() throws {
    let old = try #require(MeshWXVectors.all.first { $0.name == "observations_three_stations" })
    let new = try #require(
      MeshWXVectors.all.first { $0.name == "observations_three_stations_ages" })
    let oldBytes = try #require(Data(meshWXHex: old.hex))
    let newBytes = try #require(Data(meshWXHex: new.hex))
    #expect(oldBytes.count == 42)
    #expect(newBytes.count == 44, "three stations cost ceil(3 / 2) = 2 bytes")
    // Past the header — a different seq and the new flag bit — the two are byte for byte the
    // same until the block the old message does not have.
    #expect(newBytes.dropFirst(4).prefix(oldBytes.count - 4) == oldBytes.dropFirst(4))
    #expect(newBytes.suffix(2) == Data([0x20, 0x0B]))

    let message = try MeshWXDecoder.decode(newBytes)
    #expect(message.header.flags & MeshWXWire.flagObservationAges != 0)
    guard case let .observations(batch) = message.payload else {
      Issue.record("expected an observations batch")
      return
    }
    #expect(batch.carriesAges)
    #expect(batch.stations.map(\.ageMinutes) == [0, 20, 110])
    // Each station's own time, which is what "as of" reads (spec §10.5). The newest is the
    // batch time itself, and the oldest is nearly two hours behind it.
    #expect(batch.stations.map { batch.reportMinutes(for: $0) }
      == [29_823_893, 29_823_873, 29_823_783])
    #expect(batch.stations.map(\.isAgeSaturated) == [false, false, false])

    guard case let .observations(oldBatch) = try MeshWXDecoder.decode(oldBytes).payload else {
      Issue.record("expected an observations batch")
      return
    }
    #expect(!oldBatch.carriesAges)
    #expect(oldBatch.stations.allSatisfy { $0.ageMinutes == nil })
    // Without the ages every station reads as the batch time, which is all that message says.
    #expect(oldBatch.stations.allSatisfy { oldBatch.reportMinutes(for: $0) == 29_823_893 })
  }

  /// Spec §3: the same severe thunderstorm warning, 53 bytes rather than 51, with the issue time
  /// as the last two bytes — 21 minutes before the expiry — and flags nibble bit 1 set.
  @Test func theIssuedVectorIsTheOldWarningWithTwoTrailingBytes() throws {
    let old = try #require(
      MeshWXVectors.all.first { $0.name == "severe_thunderstorm_warning_polygon" })
    let new = try #require(
      MeshWXVectors.all.first { $0.name == "severe_thunderstorm_warning_issued" })
    let oldBytes = try #require(Data(meshWXHex: old.hex))
    let newBytes = try #require(Data(meshWXHex: new.hex))
    #expect(oldBytes.count == 51)
    #expect(newBytes.count == 53)
    #expect(newBytes.dropFirst(4).prefix(oldBytes.count - 4) == oldBytes.dropFirst(4))
    #expect(newBytes.suffix(2) == Data([0x15, 0x00]), "21 minutes, little-endian")

    let message = try MeshWXDecoder.decode(newBytes)
    #expect(message.header.flags & MeshWXWire.flagWarningIssued != 0)
    guard case let .warning(warning) = message.payload else {
      Issue.record("expected a warning")
      return
    }
    #expect(warning.issuedBeforeMinutes == 21)
    #expect(warning.issuedMinutes == warning.expiresMinutes - 21)
    #expect(warning.issuedMinutes == 29_823_924)
    #expect(!warning.isIssueTimeSaturated)
    // The polygon and the areas are untouched: the time went on the end, not into them.
    #expect(warning.polygon?.count == 6)
    #expect(warning.areas?.count == 2)

    guard case let .warning(oldWarning) = try MeshWXDecoder.decode(oldBytes).payload else {
      Issue.record("expected a warning")
      return
    }
    #expect(oldWarning.issuedBeforeMinutes == nil)
    #expect(oldWarning.issuedMinutes == nil)
  }

  /// Spec §7B: the app's own `>d`, as the sixteen bytes the spec prints — the one message this
  /// app transmits, so the encoder's output is checked against the publisher's hex byte for byte
  /// in both directions.
  @Test func theRequestVectorIsTheSixteenBytesTheSpecPrints() throws {
    let want = try #require(Data(meshWXHex: MeshWXVectors.requestDigestHex))
    #expect(want == Data([
      0x01, 0x1D, 0x04, 0x90, 0x01, 0x02, 0x03, 0x04,
      0x05, 0x06, 0x60, 0x0B, 0xAC, 0x6A, 0x3E, 0x64
    ]))
    #expect(want.count == 16)

    let request = MeshWXRequest(
      seq: 1, botID: 0x041D, senderPrefix: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]),
      timestamp: 1_789_660_000, text: ">d")
    #expect(try request.encode() == want)
    #expect(try MeshWXEncoder.request(
      seq: 1, bot: 0x041D, senderPrefix: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]),
      timestamp: 1_789_660_000, text: ">d") == want)

    let message = try MeshWXDecoder.decode(want)
    #expect(message.header.seq == 1)
    #expect(message.header.bot == 0x041D)
    #expect(message.header.rawType == 9)
    #expect(message.header.type == .request)
    #expect(message.header.flags == 0)
    guard case let .request(decoded) = message.payload else {
      Issue.record("expected a request")
      return
    }
    #expect(decoded == request)
    // The header fields ride on the body too, and a re-encode takes them from the header.
    #expect(try MeshWXEncoder.encode(message) == want)
  }

  @Test(arguments: MeshWXVectors.all)
  func reEncodesToTheSameBytes(_ vector: MeshWXVectors.Vector) throws {
    let data = try #require(Data(meshWXHex: vector.hex))
    let message = try MeshWXDecoder.decode(data)
    let encoded = try MeshWXEncoder.encode(message)
    #expect(encoded.meshWXHex == vector.hex)
  }

  // MARK: - Per-type comparisons

  private func expectWarning(_ warning: MeshWXWarning, matches want: MeshWXVectors.Decoded) throws {
    #expect(warning.identity.event == want.event)
    #expect(warning.identity.office == want.office)
    #expect(warning.identity.etn == want.etn)
    #expect(warning.expiresMinutes == want.expiresMin)
    #expect(warning.tornado.rawValue == want.tornado)
    #expect(warning.floodSource.rawValue == want.floodSource)
    #expect(warning.floodDamage.rawValue == want.floodDamage)
    #expect(warning.hailQuarterInches == want.hailQin)
    #expect(warning.windMph == want.windMph)
    #expect(warning.isUpdate == want.update)
    // Revision 5 (spec §3): absent in the revision 4 vector, and in the new one it resolves to
    // the same absolute minutes the bot's decoder reports, not to the two bytes on the wire.
    #expect(warning.issuedMinutes == want.issuedMin)

    if let wantPolygon = want.polygon {
      let polygon = try #require(warning.polygon)
      #expect(polygon.count == wantPolygon.count)
      for (vertex, expected) in zip(polygon, wantPolygon) {
        #expect(expected.count == 2)
        // Exact equality, not a tolerance: the wire is a fixed-point grid and the
        // decoder reconstructs it in integers, so anything but an exact match is a bug
        // in the accumulation, not float noise to be forgiven.
        #expect(vertex.latitude == expected[0])
        #expect(vertex.longitude == expected[1])
      }
    } else {
      #expect(warning.polygon == nil)
    }

    if let wantAreas = want.areas {
      let areas = try #require(warning.areas)
      #expect(areas.count == wantAreas.count)
      for (area, expected) in zip(areas, wantAreas) {
        #expect(area.stateIndex == expected.state)
        #expect(area.isCounty == expected.county)
        #expect(area.start == expected.start)
        #expect(area.run == expected.run)
      }
    } else {
      #expect(warning.areas == nil)
    }
  }

  private func expectCancel(_ cancel: MeshWXCancel, matches want: MeshWXVectors.Decoded) {
    #expect(cancel.identity.event == want.event)
    #expect(cancel.identity.office == want.office)
    #expect(cancel.identity.etn == want.etn)
    #expect(cancel.reason.rawValue == want.reason)
  }

  private func expectDigest(_ digest: MeshWXDigest, matches want: MeshWXVectors.Decoded) throws {
    #expect(digest.nowMinutes == want.nowMin)
    #expect(digest.feedHealth == want.feedHealth)
    let wantEntries = try #require(want.entries?.digest)
    #expect(digest.entries.count == wantEntries.count)
    for (entry, expected) in zip(digest.entries, wantEntries) {
      #expect(entry.identity.event == expected.event)
      #expect(entry.identity.office == expected.office)
      #expect(entry.identity.etn == expected.etn)
      #expect(entry.expiresRelativeMinutes == expected.expiresRel)
      #expect(entry.expiresMinutes == expected.expiresMin)
    }
  }

  /// Spec §7C. The sweep's entries go under `entries`, the same key a Digest uses for a wholly
  /// different shape, so the fixture tells them apart by what the JSON holds
  /// (`MeshWXVectors.Decoded.EntriesField`) — and `#require` here means a renamed key fails the
  /// suite instead of passing over a nil.
  private func expectAreaSweep(_ sweep: MeshWXAreaSweep, matches want: MeshWXVectors.Decoded) throws {
    #expect(sweep.builtMinutes == (try #require(want.sweepBuiltMinutes)))
    #expect(sweep.group == want.group)
    #expect(sweep.index == want.idx)
    #expect(sweep.total == want.total)
    // The two flag bits, read twice: off the header above and out of the decoded body here.
    #expect(sweep.wasCut == (want.cut ?? false))
    #expect(sweep.includesAdvisories == (want.advisories ?? false))

    let wantEntries = try #require(want.entries?.sweep)
    #expect(sweep.entries.count == wantEntries.count)
    let states = MeshWXTables.shared.states
    for (entry, expected) in zip(sweep.entries, wantEntries) {
      #expect(entry.event == expected.event)
      #expect(entry.stateIndex == expected.state)
      #expect(entry.isCounty == expected.county)
      #expect(entry.start == expected.start)
      #expect(entry.run == expected.run)
      // Where the vector prints the codes, the expansion is checked against the publisher's own
      // list rather than against this implementation's arithmetic.
      if let ugcs = expected.ugcs {
        #expect(entry.ugcCodes(states: states) == ugcs)
      }
    }
  }

  private func expectObservations(
    _ observations: MeshWXObservations, matches want: MeshWXVectors.Decoded
  ) throws {
    #expect(observations.timestampMinutes == want.tsMin)
    let wantStations = try #require(want.stations?.list)
    #expect(observations.stations.count == wantStations.count)
    for (station, expected) in zip(observations.stations, wantStations) {
      #expect(station.stationIndex == expected.station)
      #expect(station.tempF == expected.tempF)
      #expect(station.dewpointF == expected.dewpointF)
      #expect(station.windDirection.degrees == expected.windDirDeg)
      #expect(station.windDirection.abbreviation == expected.windDir)
      #expect(station.sky.rawValue == expected.sky)
      #expect(station.windMph == expected.windMph)
      #expect(station.gustMph == expected.gustMph)
      #expect(station.visibilityMiles == expected.visibilityMi)
      #expect(station.pressureInHg == expected.pressureInhg)
      #expect(station.humidityPercent == expected.humidityPct)
      #expect(station.feelsDeltaF == expected.feelsDeltaF)
      // Revision 5 (spec §6.1): nil in a batch without the flag, minutes in one with it.
      #expect(station.ageMinutes == expected.ageMin)
    }
  }

  private func expectForecast(_ forecast: MeshWXForecast, matches want: MeshWXVectors.Decoded)
    throws
  {
    #expect(forecast.pointIndex == want.point)
    #expect(forecast.issuedMinutes == want.issuedMin)
    #expect(forecast.firstPeriod == want.firstPeriod)
    let wantPeriods = try #require(want.periods)
    #expect(forecast.periods.count == wantPeriods.count)
    for (period, expected) in zip(forecast.periods, wantPeriods) {
      #expect(period.highF == expected.highF)
      #expect(period.lowF == expected.lowF)
      #expect(period.popPercent == expected.popPct)
      #expect(period.sky.rawValue == expected.sky)
      #expect(period.thunder == expected.thunder)
      #expect(period.wintry == expected.wintry)
      #expect(period.windy == expected.windy)
      #expect(period.fog == expected.fog)
      #expect(period.windDirection.degrees == expected.windDirDeg)
      #expect(period.windDirection.abbreviation == expected.windDir)
      #expect(period.windMph == expected.windMph)
    }
  }

  private func expectText(_ text: MeshWXText, matches want: MeshWXVectors.Decoded) {
    #expect(text.subject.rawValue == want.subject)
    #expect(text.group == want.group)
    #expect(text.index == want.idx)
    #expect(text.total == want.total)
    #expect(text.text == want.text)
  }

  private func expectCoverage(_ coverage: MeshWXCoverage, matches want: MeshWXVectors.Decoded)
    throws
  {
    #expect(coverage.latitude == want.lat)
    #expect(coverage.longitude == want.lon)
    #expect(coverage.radiusKilometres == want.radiusKm)
    // The cap on an hourly batch, not a count of anything in this message.
    #expect(coverage.stationCap == want.stations?.cap)
    #expect(coverage.officeIndices == want.offices)
    #expect(coverage.areasCut == want.zonesCut)
    #expect(coverage.officesCut == want.officesCut)

    let wantAreas = try #require(want.areas)
    #expect(coverage.areas.count == wantAreas.count)
    for (area, expected) in zip(coverage.areas, wantAreas) {
      #expect(area.stateIndex == expected.state)
      #expect(area.isCounty == expected.county)
      #expect(area.start == expected.start)
      #expect(area.run == expected.run)
    }
  }

  private func expectNotAvailable(
    _ notAvailable: MeshWXNotAvailable, matches want: MeshWXVectors.Decoded
  ) {
    #expect(notAvailable.requestCode == want.requestCode)
    #expect(String(notAvailable.requestLetter) == want.request)
    #expect(notAvailable.reason.rawValue == want.reason)
  }
}
