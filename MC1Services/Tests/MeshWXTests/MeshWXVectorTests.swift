import Foundation
import Testing

@testable import MeshWX

/// Conformance against the kit's nine wire vectors.
///
/// The kit's own bar: "your decoder is correct when it turns every `hex` into the
/// matching `decoded` JSON, and your encoder reproduces the same `hex`." Both halves run
/// here, field by field — no reflection, no round-trip-only shortcut, because a codec
/// that is wrong in both directions round-trips perfectly.
@Suite("MeshWX vectors")
struct MeshWXVectorTests {

  @Test func fixtureIsPresent() {
    #expect(MeshWXVectors.all.count == 9, "expected the kit's nine vectors")
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
    case .unknown:
      Issue.record("vector \(vector.name) decoded as an unknown type")
    }
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
    let wantEntries = try #require(want.entries)
    #expect(digest.entries.count == wantEntries.count)
    for (entry, expected) in zip(digest.entries, wantEntries) {
      #expect(entry.identity.event == expected.event)
      #expect(entry.identity.office == expected.office)
      #expect(entry.identity.etn == expected.etn)
      #expect(entry.expiresRelativeMinutes == expected.expiresRel)
      #expect(entry.expiresMinutes == expected.expiresMin)
    }
  }

  private func expectObservations(
    _ observations: MeshWXObservations, matches want: MeshWXVectors.Decoded
  ) throws {
    #expect(observations.timestampMinutes == want.tsMin)
    let wantStations = try #require(want.stations)
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

  private func expectNotAvailable(
    _ notAvailable: MeshWXNotAvailable, matches want: MeshWXVectors.Decoded
  ) {
    #expect(notAvailable.requestCode == want.requestCode)
    #expect(String(notAvailable.requestLetter) == want.request)
    #expect(notAvailable.reason.rawValue == want.reason)
  }
}
