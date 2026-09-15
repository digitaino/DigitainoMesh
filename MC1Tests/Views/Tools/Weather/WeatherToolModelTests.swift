import Foundation
import MC1Services
import MeshWX
import Testing

@testable import MC1

/// When a new phone fix is worth moving the place for.
@Suite("Weather location samples")
struct WeatherLocationSampleTests {
  static let now = WeatherFormattingTests.now

  func sample(latitude: Double = 30.2672, accuracy: Double = 50, after seconds: TimeInterval = 0) -> WeatherLocationSample {
    WeatherLocationSample(latitude: latitude, longitude: -97.7431, horizontalAccuracy: accuracy, timestamp: Self.now.addingTimeInterval(seconds))
  }

  @Test
  func `a survey stream's next fix a second later changes nothing`() {
    #expect(!WeatherToolModel.isMeaningfulChange(from: sample(), to: sample(latitude: 30.2673, after: 1)))
  }

  @Test
  func `a fix a minute newer replaces the place`() {
    #expect(WeatherToolModel.isMeaningfulChange(from: sample(), to: sample(after: 61)))
  }

  @Test
  func `a fix half a kilometre away replaces the place`() {
    #expect(WeatherToolModel.isMeaningfulChange(from: sample(), to: sample(latitude: 30.30, after: 5)))
  }

  @Test
  func `a much more accurate fix replaces a coarse one, a slightly better one does not`() {
    #expect(WeatherToolModel.isMeaningfulChange(from: sample(accuracy: 3000), to: sample(accuracy: 65, after: 5)))
    #expect(!WeatherToolModel.isMeaningfulChange(from: sample(accuracy: 100), to: sample(accuracy: 60, after: 5)))
    #expect(WeatherToolModel.isMeaningfulChange(from: sample(accuracy: -1), to: sample(accuracy: 60, after: 5)))
    #expect(!WeatherToolModel.isMeaningfulChange(from: sample(accuracy: 100), to: sample(accuracy: -1, after: 5)))
  }
}

/// The model's request bookkeeping and the store's visit lifetime, without a radio.
@Suite("Weather tool model")
@MainActor
struct WeatherToolModelTests {
  static let botID: UInt16 = 0x041D

  @Test
  func `a request is pending from the tap, before the service has answered`() {
    let model = WeatherToolModel()
    model.beginRequest(.digest)
    guard case .pending = model.status(for: .digest) else {
      Issue.record("expected pending, got \(model.status(for: .digest))")
      return
    }
    #expect(model.activeRequest == .digest)
    model.endRequest(.digest)
    #expect(model.activeRequest == nil)
    // No snapshot yet, so nothing can be asked: the block shows, not the old pending state.
    #expect(model.status(for: .digest) == .blocked(.noBot))
  }

  @Test
  func `a second call clears only the fingerprint it recorded`() {
    let model = WeatherToolModel()
    let first = UUID()
    let second = UUID()
    model.recordFingerprint(WeatherToolModel.Fingerprint(token: first, value: 1, kind: .other), for: .digest)
    model.recordFingerprint(WeatherToolModel.Fingerprint(token: second, value: 2, kind: .other), for: .digest)
    model.clearFingerprint(for: .digest, token: first)
    #expect(model.fingerprints[.digest]?.token == second)
    model.clearFingerprint(for: .digest, token: second)
    #expect(model.fingerprints[.digest] == nil)
  }

  @Test
  func `a forecast answer with the same issue time is nothing new`() throws {
    var state = WeatherBotState(botID: Self.botID)
    state.forecasts[103] = WeatherStoredForecast(
      forecast: MeshWXForecast(pointIndex: 103, issuedMinutes: 29_000_000, firstPeriod: 0, periods: []), receivedAt: .now)
    let before = try #require(WeatherToolModel.fingerprint(.forecast(point: 103), sourceBotID: Self.botID, states: [Self.botID: state]))
    #expect(before.kind == .forecast)
    #expect(before.value == 29_000_000)
    state.forecasts[103]?.forecast.issuedMinutes = 29_000_060
    let after = WeatherToolModel.fingerprint(.forecast(point: 103), sourceBotID: Self.botID, states: [Self.botID: state])
    #expect(after?.value != before.value)
  }

  @Test
  func `alert lists and text replies have fingerprints too`() {
    var state = WeatherBotState(botID: Self.botID)
    state.digest = WeatherStoredDigest(digest: MeshWXDigest(nowMinutes: 50, feedHealth: 2, entries: []), receivedAt: .now)
    #expect(WeatherToolModel.fingerprint(.digest, sourceBotID: Self.botID, states: [Self.botID: state])?.value == 50)

    func textPrint() -> Int? {
      WeatherToolModel.fingerprint(.spaceWeather, sourceBotID: Self.botID, states: [Self.botID: state])?.value
    }
    #expect(textPrint() == nil)
    // Somebody else's reply on the same subject is not an answer to this phone.
    state.texts[3] = WeatherTextAssembly(
      subject: .spaceWeather, group: 3, total: 1, chunks: [0: "Kp 3"], firstReceivedAt: .now, lastReceivedAt: .now)
    #expect(textPrint() == nil)

    state.texts[5] = WeatherTextAssembly(
      subject: .spaceWeather, group: 5, total: 1, chunks: [0: "Kp 4"], firstReceivedAt: .now, lastReceivedAt: .now,
      request: .spaceWeather)
    let one = textPrint()
    #expect(one != nil)
    state.texts[5]?.lastReceivedAt = .now.addingTimeInterval(60)
    #expect(textPrint() == one)
    state.texts[4] = WeatherTextAssembly(
      subject: .spaceWeather, group: 4, total: 1, chunks: [0: "Kp 6"], firstReceivedAt: .now, lastReceivedAt: .now)
    #expect(textPrint() == one)
    state.texts[9] = WeatherTextAssembly(
      subject: .spaceWeather, group: 9, total: 1, chunks: [0: "Kp 5"], firstReceivedAt: .now, lastReceivedAt: .now,
      request: .spaceWeather)
    #expect(textPrint() != one)
  }

  @Test
  func `only a complete reply this phone asked for, under five minutes old, replaces the button`() {
    let now = WeatherFormattingTests.now
    let owned = WeatherTextAssembly(
      subject: .metarOrTAF, group: 7, total: 1, chunks: [0: "KAUS 150553Z"], firstReceivedAt: now, lastReceivedAt: now,
      request: .metar(station: "KAUS"))
    #expect(WeatherToolModel.isFreshOwnedReply(owned, for: .metar(station: "KAUS"), now: now.addingTimeInterval(60)))
    #expect(!WeatherToolModel.isFreshOwnedReply(owned, for: .metar(station: "KAUS"), now: now.addingTimeInterval(5 * 60)))
    #expect(!WeatherToolModel.isFreshOwnedReply(owned, for: .taf(station: "KAUS"), now: now))
    var partial = owned
    partial.total = 2
    #expect(!WeatherToolModel.isFreshOwnedReply(partial, for: .metar(station: "KAUS"), now: now))
    var overheard = owned
    overheard.request = nil
    #expect(!WeatherToolModel.isFreshOwnedReply(overheard, for: .metar(station: "KAUS"), now: now))
  }

  @Test
  func `a pick from a picker is applied, and your location without permission asks the caller`() {
    let model = WeatherToolModel()
    let town = WeatherPlace(
      kind: .searched, coordinate: MeshWXCoordinate(latitude: 30.5, longitude: -97.7), label: "Round Rock, TX",
      uncertaintyKilometres: 5)
    model.pendingPlaceAction = .place(town)
    #expect(model.applyPendingPlaceAction(isLocationAuthorized: false) == false)
    #expect(model.searchedPlace == town)
    #expect(model.pendingPlaceAction == nil)

    model.pendingPlaceAction = .currentLocation
    #expect(model.applyPendingPlaceAction(isLocationAuthorized: false) == true)
  }

  @MainActor
  final class OpenTool {
    var isOpen = true
  }

  @Test
  func `the visit's model survives while the tool is open and goes when it is left`() {
    let store = WeatherModelStore()
    let tool = OpenTool()
    let model = store.rootAppeared { tool.isOpen }
    #expect(store.isCurrent(model))

    // A shell swap: the old root goes, a new one comes, the model is the same.
    store.rootDisappeared()
    #expect(store.rootAppeared { tool.isOpen } === model)

    // A pushed detail: no root on screen, the tool still open.
    store.rootDisappeared()
    store.evaluate()
    #expect(store.model === model)

    // Back to the tool list.
    tool.isOpen = false
    store.evaluate()
    #expect(store.model == nil)
    #expect(store.rootAppeared { true } !== model)
  }
}

/// Picking a town asks for its forecast only when the card would offer the same ask, and airport
/// codes find stations.
@Suite("Weather place search")
@MainActor
struct WeatherPlaceSearchTests {
  @Test
  func `a town with no forecast held asks for its point`() throws {
    let point = try #require(MeshWXTables.shared.point(at: 103))
    #expect(WeatherToolModel.forecastRequest(for: .missing(point: point, kilometres: 4)) == .forecast(point: 103))
  }

  @Test
  func `a town with no forecast point near, or no place, asks for nothing`() {
    #expect(WeatherToolModel.forecastRequest(for: .noPointNearby(nearest: nil, kilometres: nil)) == nil)
    #expect(WeatherToolModel.forecastRequest(for: .noPlace) == nil)
  }

  @Test
  func `airport codes are three or four letters and digits`() {
    #expect(WeatherPlacePickerView.looksLikeStationCode("TJSJ"))
    #expect(WeatherPlacePickerView.looksLikeStationCode("7R5"))
    #expect(!WeatherPlacePickerView.looksLikeStationCode("San Juan"))
    #expect(!WeatherPlacePickerView.looksLikeStationCode("sj"))
  }

  @Test
  func `a code finds its station, and the station becomes a searched place named by its town`() throws {
    let found = WeatherPlacePickerView.stations(matchingCode: "tjsj", near: nil, tables: .shared)
    let result = try #require(found.first)
    #expect(result.station.icao == "TJSJ")
    let place = WeatherPlacePickerView.place(for: result)
    #expect(place.kind == .searched)
    #expect(place.coordinate == MeshWXCoordinate(latitude: result.station.lat, longitude: result.station.lon))
    #expect(place.label.hasSuffix(", PR"))
  }

  @Test
  func `a town name is not searched as a code`() {
    #expect(WeatherPlacePickerView.stations(matchingCode: "Austin", near: nil, tables: .shared).isEmpty)
  }
}
