import Foundation
@testable import MC1Services
import MeshWX
import Testing

@Suite("Weather screen snapshot")
struct WeatherScreenSnapshotTests {
  typealias P = WeatherPhoneFixture

  /// WX-AUS as the owner's radio holds it: key prefix 1D 04, advert position 0,0.
  let wxAus = WeatherBot(
    publicKey: Data([0x1D, 0x04]) + Data(repeating: 0x55, count: 30),
    name: "WX-AUS", latitude: 0, longitude: 0, lastAdvert: nil)

  func inputs(
    states: [UInt16: WeatherBotState]? = nil,
    bots: [WeatherBot]? = nil,
    place: WeatherPlace? = WeatherPhoneFixture.place(WeatherPhoneFixture.austin),
    connected: Bool = true,
    firmware: Bool? = true,
    channel: Bool = true,
    session: WeatherSessionInfo = WeatherSessionInfo(startedAt: WeatherPhoneFixture.now.addingTimeInterval(-3600))
  ) -> WeatherScreenSnapshot.Inputs {
    WeatherScreenSnapshot.Inputs(
      states: states ?? [P.botID: P.state()], bots: bots ?? [wxAus], preferredBotID: nil, place: place,
      isRadioConnected: connected, firmwareSupportsWeather: firmware, firmwareVersion: "v1.14.0",
      hasWeatherChannel: channel, session: session, now: P.now, calendar: P.calendar)
  }

  func snapshot(_ inputs: WeatherScreenSnapshot.Inputs) -> WeatherScreenSnapshot {
    WeatherScreenSnapshot.make(inputs, geometry: MeshWXGeometry.shared, tables: .shared)
  }

  @Test
  func `the owner's phone at 23:20 reads as it should`() throws {
    #expect(wxAus.botID == P.botID)
    let screen = snapshot(inputs())
    #expect(screen.banner == nil)
    #expect(screen.source?.botID == P.botID)
    #expect(screen.source?.bot?.name == "WX-AUS")
    #expect(screen.requestBlock == nil)
    #expect(screen.alertStatus == .notChecked)
    #expect(screen.alerts.isEmpty)
    guard case let .reading(primary) = screen.primaryStation else {
      Issue.record("expected a primary station")
      return
    }
    #expect(primary.station.icao == "KATT")
    guard case let .forecast(forecast) = screen.forecast else {
      Issue.record("expected a forecast")
      return
    }
    #expect(forecast.point.index == 103)
    #expect(screen.otherPlaces.map(\.point.index) == [304, 1010])
    #expect(screen.readings.count == 14)
  }

  @Test
  func `offline, requests are blocked but the picture stays`() {
    let screen = snapshot(inputs(connected: false))
    #expect(screen.requestBlock == .radioOffline)
    #expect(screen.banner == nil)
    #expect(screen.readings.count == 14)
  }

  @Test
  func `a bot with no advert can be read but not asked`() {
    let screen = snapshot(inputs(bots: []))
    #expect(screen.source?.botID == P.botID)
    #expect(screen.source?.bot == nil)
    #expect(screen.requestBlock == .botNotAnnounced)
  }

  @Test
  func `old firmware is the banner and the block`() {
    let screen = snapshot(inputs(firmware: false))
    #expect(screen.banner == .firmwareTooOld(version: "v1.14.0"))
    #expect(screen.requestBlock == .firmwareTooOld)
  }

  @Test
  func `a missing channel is a banner only until weather arrives on the radio`() {
    #expect(snapshot(inputs(channel: false)).banner == .channelMissing)
    #expect(snapshot(inputs(channel: false)).requestBlock == .channelMissing)
    let arriving = WeatherSessionInfo(startedAt: P.now.addingTimeInterval(-600), lastChannelDatagramAt: P.now.addingTimeInterval(-60))
    #expect(snapshot(inputs(channel: false, session: arriving)).banner == nil)
  }

  @Test
  func `nothing heard and no bots is its own banner`() {
    let screen = snapshot(inputs(states: [:], bots: []))
    #expect(screen.banner == .noBotHeard)
    #expect(screen.requestBlock == .noBot)
    #expect(screen.primaryStation == .noObservations)
  }

  @Test
  func `a bot quiet for two hours is flagged`() {
    var state = P.state()
    state.lastHeardAt = P.now.addingTimeInterval(-2 * 3600)
    #expect(snapshot(inputs(states: [P.botID: state])).sourceQuietSince == P.now.addingTimeInterval(-2 * 3600))
    #expect(snapshot(inputs()).sourceQuietSince == nil)
  }

  @Test
  func `a text somebody else asked for is not this phone's`() {
    var state = P.state()
    _ = WeatherStateReducer.apply(
      MeshWXMessage(header: P.header(240, .text), payload: .text(MeshWXText(subject: .spaceWeather, group: 240, index: 0, total: 1, text: "Kp 4"))),
      to: &state, receivedAt: P.now)
    let screen = snapshot(inputs(states: [P.botID: state]))
    #expect(screen.texts.count == 1)
    #expect(screen.texts.first?.isOwn == false)
  }
}

@Suite("Weather request status")
struct WeatherRequestStatusTests {
  let now = WeatherPhoneFixture.now
  let bot = WeatherFixture.bot

  func pending(_ request: WeatherRequest, attempt: Int = 0) -> WeatherPendingRequest {
    WeatherPendingRequest(request: request, botID: bot.botID, botPublicKey: bot.publicKey, sentAt: now, attempt: attempt)
  }

  @Test
  func `a request on the air shows as pending even if the radio then drops`() {
    #expect(WeatherRequestStatus.resolve(request: .digest, block: .radioOffline, pending: [pending(.digest, attempt: 1)], outcomes: [:], now: now)
            == .pending(attempt: 1, sentAt: now))
  }

  @Test
  func `a block wins over waiting and over old outcomes`() {
    #expect(WeatherRequestStatus.resolve(request: .digest, block: .channelMissing, pending: [pending(.observations)], outcomes: [:], now: now)
            == .blocked(.channelMissing))
  }

  @Test
  func `one at a time, and an outcome stays for five minutes`() {
    #expect(WeatherRequestStatus.resolve(request: .digest, block: nil, pending: [pending(.observations)], outcomes: [:], now: now) == .waitingForOther)
    let outcomes = [WeatherRequest.digest: WeatherSettledOutcome(outcome: .timedOut(botWasHeard: false), at: now.addingTimeInterval(-60))]
    #expect(WeatherRequestStatus.resolve(request: .digest, block: nil, pending: [], outcomes: outcomes, now: now)
            == .settled(.timedOut(botWasHeard: false), at: now.addingTimeInterval(-60)))
    #expect(WeatherRequestStatus.resolve(request: .digest, block: nil, pending: [], outcomes: outcomes, now: now.addingTimeInterval(300)) == .idle)
  }
}
