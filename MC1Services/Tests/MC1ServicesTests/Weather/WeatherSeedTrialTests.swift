import Foundation
@testable import MC1Services
import MeshWX
import Testing

/// Developer tooling, not a test of anything: writes a `WeatherService` state file built from
/// the kit's nine wire vectors (the Austin bot: a severe thunderstorm warning over Travis and
/// Hays, a winter storm warning by zones, three stations, a seven-period forecast and a
/// two-chunk narrative) to the path in `WEATHER_SEED_URL`, so a simulator or a device can be
/// shown the tool with real-shaped data and no radio.
///
/// Skipped unless the variable is set, so the suite never touches a real container by accident:
///
///     WEATHER_SEED_URL="$(xcrun simctl get_app_container booted com.digitaino.PocketMesh data)/Library/Application Support/MeshWX/state.json" \
///       swift test --filter WeatherSeedTrialTests
@Suite("Weather seed trial", .enabled(if: ProcessInfo.processInfo.environment["WEATHER_SEED_URL"] != nil))
struct WeatherSeedTrialTests {
  @Test
  func `write the kit vectors as a state file`() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["WEATHER_SEED_URL"])
    let url = URL(fileURLWithPath: path)

    // The kit vectors, verbatim (MeshWXTests/Fixtures/meshwx_v5_vectors.json), in wire order.
    let hexes = [
      "117a4c1003232a00c913c70183043c0630a804a80cf15a0068011affd2001affa6ffc4ffa2febe0042ff02aad10001aac50101",
      "127a4c1018230700d417c701010000022abf00042ac80001",
      "147a4c309c13c701070303232a002d0018230700380403232b001400",
      "157a4c409513c70103ca005848730c150a5c3b075c0354460100000a5fff00d0038080daff00ffffff00",
      "167a4c5066002413c70101077f491482715d7f2813827f481e13815a7f3c58947f451402e2567f0a01027f41ff0000",
      "177a4c6000170002534556455245205448554e44455253544f524d205741524e494e4720464f52204e4f5254484541535445524e204841595320414e4420534f5554485745535445524e2054524156495320434f554e5449455320554e54494c2031343520414d204344542e204174203132353720414d206120736576657265207468756e64657273746f726d20776173206e656172204472697070696e6720537072696e",
      "187a4c600017010267732c206d6f76696e672065617374206174203430206d70682e2048415a4152443a203630206d706820677573747320616e6420717561727465722073697a65206861696c2e20534f555243453a20526164617220696e646963617465642e"
    ]

    // The vectors' clocks are fixed at 2026-09-15 ~00:45 UTC; shift every time field to "now"
    // so the countdowns and stale badges read as live rather than long expired.
    let vectorNowMinutes: UInt32 = 29_823_900
    let nowMinutes = MeshWXPresentation.unixMinutes(for: Date())
    let shift = Int64(nowMinutes) - Int64(vectorNowMinutes)
    func shifted(_ minutes: UInt32) -> UInt32 { UInt32(clamping: Int64(minutes) + shift) }

    var state = WeatherBotState(botID: 19578)
    for hex in hexes {
      var message = try MeshWXDecoder.decode(Data(hex: hex))
      switch message.payload {
      case var .warning(warning):
        warning.expiresMinutes = shifted(warning.expiresMinutes)
        message.payload = .warning(warning)
      case var .digest(digest):
        digest.nowMinutes = shifted(digest.nowMinutes)
        digest.entries = digest.entries.map {
          MeshWXDigest.Entry(identity: $0.identity, expiresRelativeMinutes: $0.expiresRelativeMinutes, expiresMinutes: shifted($0.expiresMinutes))
        }
        message.payload = .digest(digest)
      case var .observations(batch):
        batch.timestampMinutes = shifted(batch.timestampMinutes)
        message.payload = .observations(batch)
      case var .forecast(forecast):
        forecast.issuedMinutes = shifted(forecast.issuedMinutes)
        message.payload = .forecast(forecast)
      default:
        break
      }
      _ = WeatherStateReducer.apply(message, to: &state, receivedAt: Date())
    }

    try await FileWeatherStateStore(url: url).save([state.botID: state])
    let reloaded = try await FileWeatherStateStore(url: url).load()
    #expect(reloaded[19578]?.warnings.count == 2)
    #expect(reloaded[19578]?.observations.count == 3)
    #expect(reloaded[19578]?.texts[23]?.isComplete == true)
    print("wrote weather seed to \(url.path)")
  }
}

private extension Data {
  init(hex: String) {
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
      index = next
    }
    self.init(bytes)
  }
}

/// Screenshot and review scenarios with live timestamps, written to
/// `WEATHER_SEED_DIR/<scenario>/state.json`: `phone` is the owner's phone as it was on the night
/// of 2026-09-14 (WX-AUS's 14-station batch, its Austin forecast, New York and San Juan forecasts
/// somebody else asked for, no alert list); `storm` adds a tornado warning over downtown Austin, a
/// severe thunderstorm near Llano, a heat advisory by zones and a fresh alert list listing all
/// three. Skipped unless the variable is set.
///
///     WEATHER_SEED_DIR=/path/to/seed swift test --filter WeatherSeedScenarioTests
@Suite("Weather seed scenarios", .enabled(if: ProcessInfo.processInfo.environment["WEATHER_SEED_DIR"] != nil))
struct WeatherSeedScenarioTests {
  static let botID: UInt16 = 0x041D
  static let stations: [(UInt16, Int8)] = [
    (1929, 88), (976, 82), (593, 86), (194, 86), (875, 84), (229, 84), (202, 84),
    (606, 88), (860, 88), (1208, 86), (296, 86), (169, 86), (1014, 86), (1723, 84)
  ]

  func header(_ seq: UInt8, _ type: MeshWXMessageType) -> MeshWXHeader {
    MeshWXHeader(seq: seq, bot: Self.botID, type: type)
  }

  func coordinates(_ points: [(Double, Double)]) -> [MeshWXCoordinate] {
    points.map { MeshWXCoordinate(latitude: $0.0, longitude: $0.1) }
  }

  func daily(_ point: UInt16, issued: UInt32, _ temps: [(Int8, Int8)], pop: [UInt8]) -> MeshWXForecast {
    MeshWXForecast(
      pointIndex: point, issuedMinutes: issued, firstPeriod: 0,
      periods: zip(temps, pop).map { MeshWXForecastPeriod(highF: $0.0.0, lowF: $0.0.1, popPercent: $0.1, sky: $0.1 >= 30 ? .broken : .scattered, thunder: $0.1 >= 30) })
  }

  func phoneState(now: Date) -> WeatherBotState {
    var state = WeatherBotState(botID: Self.botID)
    let nowMinutes = MeshWXPresentation.unixMinutes(for: now)
    _ = WeatherStateReducer.apply(
      MeshWXMessage(header: header(230, .observations), payload: .observations(MeshWXObservations(
        timestampMinutes: nowMinutes - 2,
        stations: Self.stations.enumerated().map { offset, station in
          MeshWXStationObservation(
            stationIndex: station.0, tempF: station.1, dewpointF: 72, windDirection: .southSouthEast, sky: .few,
            windMph: UInt8(5 + offset % 7), gustMph: offset % 4 == 0 ? 21 : 0, visibilityMiles: 10,
            pressureInHg: 30.01, humidityPercent: UInt8(55 + offset), feelsDeltaF: 5)
        }))),
      to: &state, receivedAt: now.addingTimeInterval(-120))
    _ = WeatherStateReducer.apply(
      MeshWXMessage(header: header(231, .forecast), payload: .forecast(daily(103, issued: nowMinutes - 208,
        [(102, 77), (100, 78), (98, 75), (97, 73), (98, 74), (99, 76), (96, 81)], pop: [5, 5, 20, 5, 0, 10, 30]))),
      to: &state, receivedAt: now.addingTimeInterval(-540))
    _ = WeatherStateReducer.apply(
      MeshWXMessage(header: header(232, .forecast), payload: .forecast(daily(1010, issued: nowMinutes - 588,
        [(91, 80), (93, 80), (92, 80), (93, 79), (92, 79), (92, 79), (92, 80)], pop: [50, 50, 60, 60, 40, 40, 40]))),
      to: &state, receivedAt: now.addingTimeInterval(-540))
    _ = WeatherStateReducer.apply(
      MeshWXMessage(header: header(233, .forecast), payload: .forecast(daily(304, issued: nowMinutes - 259,
        [(72, 60), (79, 66), (80, 68), (82, 64), (77, 66), (79, 64), (75, 66)], pop: [0, 0, 0, 20, 20, 40, 30]))),
      to: &state, receivedAt: now.addingTimeInterval(-420))
    _ = WeatherStateReducer.apply(
      MeshWXMessage(header: header(234, .text), payload: .text(MeshWXText(
        subject: .spaceWeather, group: 234, index: 0, total: 1,
        text: "Kp 24h max 4, next 3d 4.7/4.7/3.7 (G1 Tue). SFI 104 SSN 51 xray B2.7."))),
      to: &state, receivedAt: now.addingTimeInterval(-1500))
    return state
  }

  @Test
  func `write the phone and storm scenarios`() async throws {
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WEATHER_SEED_DIR"]))
    let now = Date()
    let nowMinutes = MeshWXPresentation.unixMinutes(for: now)

    let phone = phoneState(now: now)
    try await FileWeatherStateStore(url: directory.appendingPathComponent("phone/state.json")).save([Self.botID: phone])

    var storm = phoneState(now: now)
    let tornado = MeshWXWarning(
      identity: MeshWXWarningIdentity(event: 1, office: 35, etn: 12), expiresMinutes: nowMinutes + 35,
      tornado: .observed,
      polygon: coordinates([(30.36, -97.84), (30.37, -97.66), (30.24, -97.62), (30.18, -97.78)]),
      areas: [MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 453, run: 1)])
    let llanoStorm = MeshWXWarning(
      identity: MeshWXWarningIdentity(event: 3, office: 35, etn: 44), expiresMinutes: nowMinutes + 50,
      hailQuarterInches: 5, windMph: 60,
      polygon: coordinates([(30.85, -98.80), (30.86, -98.55), (30.66, -98.52), (30.62, -98.78)]),
      areas: [MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 299, run: 1)])
    let heat = MeshWXWarning(
      identity: MeshWXWarningIdentity(event: 14, office: 35, etn: 5), expiresMinutes: nowMinutes + 360,
      areas: [MeshWXAreaRun(stateIndex: 42, isCounty: false, start: 192, run: 3)])
    for (offset, warning) in [tornado, llanoStorm, heat].enumerated() {
      _ = WeatherStateReducer.apply(
        MeshWXMessage(header: header(UInt8(235 + offset), .warning), payload: .warning(warning)),
        to: &storm, receivedAt: now.addingTimeInterval(TimeInterval(-180 + offset * 10)))
    }
    let digest = MeshWXDigest(
      nowMinutes: nowMinutes - 1, feedHealth: 2,
      entries: [tornado, llanoStorm, heat].map {
        MeshWXDigest.Entry(
          identity: $0.identity,
          expiresRelativeMinutes: UInt16($0.expiresMinutes - (nowMinutes - 1)),
          expiresMinutes: $0.expiresMinutes)
      })
    _ = WeatherStateReducer.apply(
      MeshWXMessage(header: header(238, .digest), payload: .digest(digest)),
      to: &storm, receivedAt: now.addingTimeInterval(-60))
    try await FileWeatherStateStore(url: directory.appendingPathComponent("storm/state.json")).save([Self.botID: storm])

    #expect(storm.warnings.count == 3)
    #expect(storm.missingFromDigest.isEmpty)
    #expect(!storm.needsDigest)
    print("wrote weather scenarios to \(directory.path)")
  }
}
