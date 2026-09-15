import Foundation
@testable import MC1Services
import MeshWX

/// The owner's phone as it was at 23:20 CDT on 2026-09-14 (devicectl copy): WX-AUS (bot 0x041D)
/// with its 14-station hourly batch, the bot's Austin Camp Mabry forecast, and New York and
/// San Juan forecasts somebody else asked for. No warnings and no digest.
enum WeatherPhoneFixture {
  static let botID: UInt16 = 0x041D
  /// 2026-09-15 04:20 UTC = 23:20 CDT on the 14th.
  static let now = Date(timeIntervalSince1970: 1_789_446_000)
  static var nowMinutes: UInt32 { UInt32(now.timeIntervalSince1970 / 60) }

  static let austin = MeshWXCoordinate(latitude: 30.2672, longitude: -97.7431)
  static let roundRock = MeshWXCoordinate(latitude: 30.5083, longitude: -97.6789)
  static let dallas = MeshWXCoordinate(latitude: 32.7767, longitude: -96.7970)

  static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Chicago")!
    return calendar
  }

  static let stations: [(UInt16, Int8)] = [
    (1929, 88), (976, 82), (593, 86), (194, 86), (875, 84), (229, 84), (202, 84),
    (606, 88), (860, 88), (1208, 86), (296, 86), (169, 86), (1014, 86), (1723, 84)
  ]

  static func dailyForecast(point: UInt16, issuedMinutes: UInt32, temps: [(Int8, Int8)]) -> MeshWXForecast {
    MeshWXForecast(
      pointIndex: point, issuedMinutes: issuedMinutes, firstPeriod: 0,
      periods: temps.map { MeshWXForecastPeriod(highF: $0.0, lowF: $0.1, popPercent: 10, sky: .scattered) })
  }

  static func header(_ seq: UInt8, _ type: MeshWXMessageType) -> MeshWXHeader {
    MeshWXHeader(seq: seq, bot: botID, type: type)
  }

  static func state(observationsAgo: TimeInterval = 120) -> WeatherBotState {
    var state = WeatherBotState(botID: botID)
    let tsMinutes = UInt32((now.timeIntervalSince1970 - observationsAgo) / 60)
    _ = WeatherStateReducer.apply(
      MeshWXMessage(header: header(230, .observations), payload: .observations(MeshWXObservations(
        timestampMinutes: tsMinutes,
        stations: stations.map { MeshWXStationObservation(stationIndex: $0.0, tempF: $0.1, sky: .few, windMph: 5) }))),
      to: &state, receivedAt: now.addingTimeInterval(-observationsAgo))
    let issued103 = nowMinutes - 208  // 19:52 CDT
    _ = WeatherStateReducer.apply(
      MeshWXMessage(header: header(231, .forecast), payload: .forecast(dailyForecast(
        point: 103, issuedMinutes: issued103,
        temps: [(102, 77), (100, 78), (98, 75), (97, 73), (98, 74), (99, 76), (96, 81)]))),
      to: &state, receivedAt: now.addingTimeInterval(-540))
    _ = WeatherStateReducer.apply(
      MeshWXMessage(header: header(232, .forecast), payload: .forecast(dailyForecast(
        point: 1010, issuedMinutes: nowMinutes - 588,
        temps: [(91, 80), (93, 80), (92, 80), (93, 79), (92, 79), (92, 79), (92, 80)]))),
      to: &state, receivedAt: now.addingTimeInterval(-540))
    _ = WeatherStateReducer.apply(
      MeshWXMessage(header: header(233, .forecast), payload: .forecast(dailyForecast(
        point: 304, issuedMinutes: nowMinutes - 259,
        temps: [(72, 60), (79, 66), (80, 68), (82, 64), (77, 66), (79, 64), (75, 66)]))),
      to: &state, receivedAt: now.addingTimeInterval(-420))
    return state
  }

  static func place(_ coordinate: MeshWXCoordinate, kind: WeatherPlace.Kind = .current, radius: Double = 0.5, label: String = "Austin, TX") -> WeatherPlace {
    WeatherPlace(kind: kind, coordinate: coordinate, label: label, uncertaintyKilometres: radius, locatedAt: now)
  }
}

/// Geometry whose outlines have not loaded yet.
struct UnloadedGeometry: WeatherAreaGeometry {
  var isLoaded: Bool { false }
  func distanceKilometres(from point: MeshWXCoordinate, toArea ugc: String) -> Double? { nil }
  func centre(ofArea ugc: String) -> MeshWXCoordinate? { nil }
}
