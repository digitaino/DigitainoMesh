import Foundation
@testable import MC1Services
import MeshCore
import MeshWX
import Testing

/// The service's contract with the radio and with the spec's etiquette (§8.2, §13): what it
/// accepts, what it sends, what settles a request, and what it never sends twice.
@Suite("WeatherService")
struct WeatherServiceTests {
  private typealias F = WeatherFixture

  private struct Harness {
    let transport: FakeWeatherTransport
    let store: InMemoryWeatherStateStore
    let clock: WeatherTestClock
    let service: WeatherService
    let events: AsyncStream<WeatherEvent>
  }

  /// - Parameter channelRequests: whether the fake radio can flood a Request datagram (spec
  ///   §7B). **False by default**, so every test below that is about the DM ladder drives the
  ///   ladder; the channel path is a section of its own and asks for it.
  private func makeHarness(
    answerTimeout: Duration = .seconds(15),
    channelRequests: Bool = false,
    channelAnswerTimeout: Duration = .seconds(10)
  ) -> Harness {
    let transport = FakeWeatherTransport(channelRequestsSupported: channelRequests)
    let store = InMemoryWeatherStateStore()
    let clock = WeatherTestClock()
    let service = WeatherService(
      transport: transport,
      store: store,
      now: { clock.now },
      answerTimeout: answerTimeout,
      channelAnswerTimeout: channelAnswerTimeout,
      stationIndex: { $0 == "KAUS" ? 202 : nil }
    )
    return Harness(transport: transport, store: store, clock: clock, service: service, events: service.events())
  }

  /// Collects settled outcomes as they are emitted.
  private func collectSettlements(_ events: AsyncStream<WeatherEvent>) -> LockedValue<[(WeatherPendingRequest, WeatherRequestOutcome)]> {
    let box = LockedValue<[(WeatherPendingRequest, WeatherRequestOutcome)]>([])
    Task {
      for await event in events {
        if case let .requestSettled(request, outcome) = event {
          box.value.append((request, outcome))
        }
      }
    }
    return box
  }

  private func isAlreadyReceived(_ outcome: WeatherRequestOutcome?) -> Bool {
    if case .alreadyReceived = outcome { return true }
    return false
  }

  // MARK: - Ingest

  @Test
  func `only datagrams with the MeshWX data type are decoded`() async throws {
    let h = makeHarness()
    await h.service.startEventMonitoring()

    await h.transport.deliver(try F.datagram(F.warning(seq: 17), dataType: 0xFFFF))
    await h.transport.deliver(try F.datagram(F.warning(seq: 17)))

    #expect(await weatherWaitUntil { await h.service.state(for: F.botID)?.warnings.count == 1 })
    let state = try #require(await h.service.state(for: F.botID))
    #expect(state.lastSeq == 17)
    #expect(await h.store.saveCount == 1)
    #expect(await h.service.sessionInfo().lastChannelDatagramAt == h.clock.now)
  }

  @Test
  func `a datagram on a slot that is not meshwx is ignored and counted`() async throws {
    let h = makeHarness()
    await h.service.startEventMonitoring()
    await h.transport.setSecret(Data(repeating: 0x42, count: 16), at: 5)
    #expect(await h.service.ingest(try F.datagram(F.warning(seq: 1), channelIndex: 5)) == nil)
    #expect(await h.service.allStates().isEmpty)
    #expect(await h.service.sessionInfo().foreignDatagramsIgnored == 1)
    #expect(await h.service.sessionInfo().lastChannelDatagramAt == nil)
  }

  @Test
  func `an unreadable slot is accepted rather than dropping weather`() async throws {
    let h = makeHarness()
    #expect(await h.service.ingest(try F.datagram(F.warning(seq: 1), channelIndex: 9)) != nil)
    #expect(await h.service.state(for: F.botID)?.warnings.count == 1)
  }

  @Test
  func `a slot that was not meshwx is checked again after a minute`() async throws {
    let h = makeHarness()
    await h.service.startEventMonitoring()
    await h.transport.setSecret(Data(repeating: 0x42, count: 16), at: 5)
    #expect(await h.service.ingest(try F.datagram(F.warning(seq: 1), channelIndex: 5)) == nil)

    // The user adds #meshwx into slot 5 from the prompt.
    await h.transport.setSecret(WeatherChannel.secret, at: 5)
    h.clock.advance(by: 30)
    #expect(await h.service.ingest(try F.datagram(F.warning(seq: 2), channelIndex: 5)) == nil)
    h.clock.advance(by: 31)
    #expect(await h.service.ingest(try F.datagram(F.warning(seq: 3), channelIndex: 5)) != nil)
  }

  @Test
  func `a meshwx slot is looked up once per session`() async throws {
    let h = makeHarness()
    await h.service.startEventMonitoring()
    _ = await h.service.ingest(try F.datagram(F.warning(seq: 1)))
    _ = await h.service.ingest(try F.datagram(F.cancel(seq: 2)))
    #expect(await h.transport.secretLookups == [3])
  }

  @Test
  func `undecodable bytes are dropped without touching state`() async throws {
    let h = makeHarness()
    let truncated = ChannelDatagram(channelIndex: 3, pathLength: 0xFF, dataType: MeshWXWire.dataType, data: Data([0x11, 0x7A]), snr: 1)
    #expect(await h.service.ingest(truncated) == nil)
    #expect(await h.service.allStates().isEmpty)
  }

  @Test
  func `a duplicate is reported but not persisted again`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.warning(seq: 17))
    let changes = await h.service.ingest(F.warning(seq: 17))
    #expect(changes == [.duplicate(seq: 17)])
    #expect(await h.store.saveCount == 1)
  }

  @Test
  func `state loads from the store once and prunes long-expired warnings`() async throws {
    var stale = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.warning(seq: 1, identity: F.svw42, expiresMinutes: F.t0Minutes - 120), to: &stale, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.warning(seq: 2, identity: F.svw43, expiresMinutes: F.t0Minutes - 10), to: &stale, receivedAt: F.t0)
    let store = InMemoryWeatherStateStore(states: [F.botID: stale])
    let clock = WeatherTestClock()
    let service = WeatherService(transport: FakeWeatherTransport(), store: store, now: { clock.now })

    let loaded = try #require(await service.state(for: F.botID))
    // Expired two hours ago: gone. Expired ten minutes ago: kept for the "just ended" hour.
    #expect(Set(loaded.warnings.keys) == [F.svw43])
  }

  @Test
  func `session info records when monitoring started and clears on stop`() async throws {
    let h = makeHarness()
    #expect(await h.service.sessionInfo().startedAt == nil)
    await h.service.startEventMonitoring()
    #expect(await h.service.sessionInfo().startedAt == h.clock.now)
    await h.service.stopEventMonitoring()
    #expect(await h.service.sessionInfo().startedAt == nil)
  }

  // MARK: - Sending

  @Test
  func `a request goes out as a DM to the bot's key with the spec's text`() async throws {
    let h = makeHarness()
    let pending = try await h.service.send(.forecast(point: 102), to: F.bot)
    #expect(pending?.request == .forecast(point: 102))
    #expect(pending?.botID == F.botID)
    let sent = await h.transport.sent
    #expect(sent.count == 1)
    #expect(sent.first?.publicKey == F.botPublicKey)
    #expect(sent.first?.text == ">f 102")
    #expect(await h.service.pendingRequests().count == 1)
  }

  @Test
  func `requests are spaced five seconds apart`() async throws {
    let h = makeHarness()
    _ = try await h.service.send(.digest, to: F.bot)
    h.clock.advance(by: 2)
    await #expect(throws: WeatherRequestError.self) {
      try await h.service.send(.observations, to: F.bot)
    }
    h.clock.advance(by: 3.1)
    _ = try await h.service.send(.observations, to: F.bot)
    #expect(await h.transport.sent.count == 2)
  }

  @Test
  func `a radio refusal surfaces as a transport error and leaves nothing pending`() async throws {
    let h = makeHarness()
    await h.transport.setFailNextSend(true)
    await #expect(throws: WeatherRequestError.self) {
      try await h.service.send(.digest, to: F.bot)
    }
    #expect(await h.service.pendingRequests().isEmpty)
  }

  // MARK: - Settling

  @Test
  func `the expected answer settles the request and no other`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    _ = try await h.service.send(.forecast(point: 102), to: F.bot)

    _ = await h.service.ingest(F.forecast(seq: 1, point: 304))   // a different point, far away
    _ = await h.service.ingest(F.observations(seq: 2, stations: [(202, 88), (860, 84)]))
    #expect(await h.service.pendingRequests().count == 1)

    _ = await h.service.ingest(F.forecast(seq: 3, point: 102))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .answered)
    #expect(await h.service.pendingRequests().isEmpty)
  }

  @Test
  func `a one-station observation request is settled only by a batch holding that station`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    _ = try await h.service.send(.observation(station: "KAUS"), to: F.bot)
    _ = await h.service.ingest(F.observations(seq: 1, stations: [(860, 84)]))
    #expect(await h.service.pendingRequests().count == 1)
    _ = await h.service.ingest(F.observations(seq: 2, stations: [(202, 88)]))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .answered)
  }

  @Test
  func `a coverage observation request is settled by its bot's batch, even a batch of one, and not by another bot's`() async throws {
    let h = makeHarness()
    _ = try await h.service.send(.observations, to: F.bot)
    _ = await h.service.ingest(F.observations(seq: 1, stations: [(202, 88), (860, 84)], bot: 0x0102))
    #expect(await h.service.pendingRequests().count == 1)
    // Only one station reported in the bot's area.
    _ = await h.service.ingest(F.observations(seq: 2, stations: [(202, 88)]))
    #expect(await weatherWaitUntil { await h.service.pendingRequests().isEmpty })
    h.clock.advance(by: 6)
    #expect(try await h.service.send(.observations, to: F.bot) == nil, "that answer was this phone's `>o`")
  }

  @Test
  func `a warnings request is settled by the first warning or by the digest that ends the reply`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    _ = try await h.service.send(.activeWarnings, to: F.bot)
    _ = await h.service.ingest(F.digest(seq: 1, entries: []))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.0.request == .activeWarnings)
  }

  @Test
  func `a request for one warning is settled only by that warning, with no digest to wait for`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    _ = try await h.service.send(.warning(identity: "SV.W.EWX.43"), to: F.bot)
    _ = await h.service.ingest(F.warning(seq: 1, identity: F.svw42))
    _ = await h.service.ingest(F.digest(seq: 2, entries: [(F.svw43, 30)]))
    #expect(await h.service.pendingRequests().count == 1)
    _ = await h.service.ingest(F.warning(seq: 3, identity: F.svw43))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .answered)
  }

  @Test
  func `an area request is settled only by a warning naming that county or zone`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    // The fixture's warning names Travis County, TXC453.
    _ = try await h.service.send(.warningsTouching(ugc: "TXC209"), to: F.bot)
    _ = await h.service.ingest(F.warning(seq: 1, identity: F.svw42))
    _ = await h.service.ingest(F.digest(seq: 2, entries: [(F.svw42, 30)]))
    #expect(await h.service.pendingRequests().count == 1)
    _ = await h.service.ingest(F.notAvailable(seq: 3, letter: "w", reason: .noData))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .notAvailable(.noData))

    h.clock.advance(by: 6)
    _ = try await h.service.send(.warningsTouching(ugc: "txc453"), to: WeatherBot(
      publicKey: Data([0x02, 0x01]) + Data(repeating: 0x22, count: 30), name: "WX-SAT", latitude: 0, longitude: 0, lastAdvert: nil))
    _ = await h.service.ingest(F.warning(seq: 1, identity: F.svw43, bot: 0x0102))
    #expect(await weatherWaitUntil { settled.value.count == 2 })
  }

  /// The bot matches the county against the product's full list, then cuts the list it sends to
  /// 30, 12 or 6 runs, or drops it, to fit one packet.
  @Test
  func `a county request takes a warning whose area list may have been cut, only from the bot asked`() {
    func warning(runs: Int) -> MeshWXPayload {
      guard case var .warning(warning) = F.warning(seq: 1).payload else { return F.warning(seq: 1).payload }
      warning.areas = runs == 0
        ? nil
        : (0..<runs).map { MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 100 + 2 * UInt16($0), run: 1) }
      return .warning(warning)
    }
    func settles(_ payload: MeshWXPayload, fromAddressedBot: Bool) -> Bool {
      WeatherService.reply(
        payload, satisfies: .warningsTouching(ugc: "TXC209"), fromAddressedBot: fromAddressedBot,
        stationIndex: { _ in nil }, tables: .shared)
    }
    for runs in [0, 6, 12, 30] {
      #expect(settles(warning(runs: runs), fromAddressedBot: true), "\(runs) runs may be a cut list")
      #expect(!settles(warning(runs: runs), fromAddressedBot: false))
    }
    #expect(!settles(warning(runs: 5), fromAddressedBot: true), "a whole list that does not name it")
    #expect(settles(F.warning(seq: 1).payload, fromAddressedBot: false) == false)
  }

  @Test
  func `a forecast request takes a nearby or unbundled point from the bot asked, never from another bot`() async throws {
    let h = makeHarness()
    _ = try await h.service.send(.forecast(point: 102), to: F.bot)
    _ = await h.service.ingest(F.forecast(seq: 1, point: 103, bot: 0x0102)) // 17 km away, but another bot
    _ = await h.service.ingest(F.forecast(seq: 2, point: 304))               // the bot asked, but New York
    #expect(await h.service.pendingRequests().count == 1)
    _ = await h.service.ingest(F.forecast(seq: 3, point: 103))               // Camp Mabry for Bergstrom
    #expect(await weatherWaitUntil { await h.service.pendingRequests().isEmpty })

    h.clock.advance(by: 6)
    _ = try await h.service.send(.forecast(point: 1010), to: F.bot)
    _ = await h.service.ingest(F.forecast(seq: 1, point: 0xFFFF, bot: 0x0102))
    #expect(await h.service.pendingRequests().count == 1)
    _ = await h.service.ingest(F.forecast(seq: 4, point: 0xFFFF))
    #expect(await weatherWaitUntil { await h.service.pendingRequests().isEmpty })
  }

  /// Revision 8: Wright-Patterson (KFFO) never reports, so the bot answers `>o KFFO` with Dayton
  /// International (KDAY), 16.6 km away, alone and under KDAY's index. That is the answer, from the
  /// bot asked; a neighbour inside somebody else's batch, or anything past 40 km, is not.
  @Test
  func `a station request takes the nearest reporting station, alone, from the bot asked`() {
    let tables = MeshWXTables.shared
    func batch(_ icaos: [String]) -> MeshWXPayload {
      .observations(MeshWXObservations(
        timestampMinutes: 29_000_000,
        stations: icaos.map { MeshWXStationObservation(stationIndex: tables.stationIndex(forICAO: $0)!, tempF: 72) }))
    }
    func settles(_ payload: MeshWXPayload, fromAddressedBot: Bool = true) -> Bool {
      WeatherService.reply(
        payload, satisfies: .observations(station: "KFFO"), fromAddressedBot: fromAddressedBot,
        stationIndex: { tables.stationIndex(forICAO: $0) }, tables: tables)
    }
    #expect(settles(batch(["KFFO"])))
    #expect(settles(batch(["KDAY"])), "16.6 km: the stand-in the bot chose")
    #expect(!settles(batch(["KDAY"]), fromAddressedBot: false))
    #expect(!settles(batch(["KDAY", "KMGY"])), "a batch that does not name it is somebody else's")
    #expect(!settles(batch(["KCMH"])), "Columbus is about 100 km away")
  }

  @Test
  func `a text request is settled by its subject's first chunk and remembered on the reply`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    _ = try await h.service.send(.stormReports(state: "TX"), to: F.bot)
    _ = await h.service.ingest(F.text(seq: 1, subject: .spaceWeather, group: 1, index: 0, total: 1, text: "quiet sun"))
    #expect(await h.service.pendingRequests().count == 1)
    _ = await h.service.ingest(F.text(seq: 2, subject: .stormReports, group: 2, index: 0, total: 2, text: "0115 HAIL 2 N AUSTIN TRAVIS TX"))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    let state = try #require(await h.service.state(for: F.botID))
    #expect(state.texts[2]?.request == .stormReports(state: "TX"))
    #expect(state.texts[1]?.request == nil, "somebody else's space weather is not this phone's")
  }

  @Test
  func `a not-available reply settles the oldest request with its letter`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    _ = try await h.service.send(.forecastForPlace("nowhere zz"), to: F.bot)
    h.clock.advance(by: 6)
    _ = try await h.service.send(.forecast(point: 102), to: F.bot)

    _ = await h.service.ingest(F.notAvailable(seq: 1, letter: "o", reason: .noData)) // not ours
    #expect(await h.service.pendingRequests().count == 2)

    _ = await h.service.ingest(F.notAvailable(seq: 2, letter: "f", reason: .unknownLocation))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.0.request == .forecastForPlace("nowhere zz"))
    #expect(settled.value.first?.1 == .notAvailable(.unknownLocation))
    #expect(await h.service.pendingRequests().map(\.request) == [.forecast(point: 102)])
  }

  @Test
  func `a not-available from another bot does not refuse the request`() async throws {
    let h = makeHarness()
    _ = try await h.service.send(.forecast(point: 102), to: F.bot)
    _ = await h.service.ingest(F.notAvailable(seq: 1, letter: "f", reason: .noData, bot: 0x0102))
    #expect(await h.service.pendingRequests().count == 1)
  }

  @Test
  func `a place forecast answered as an unbundled point is labelled with the request`() async throws {
    let h = makeHarness()
    _ = try await h.service.send(.forecastForPlace("round rock tx"), to: F.bot)
    _ = await h.service.ingest(F.forecast(seq: 1, point: 0xFFFF))
    #expect(await weatherWaitUntil { await h.service.pendingRequests().isEmpty })
    let state = try #require(await h.service.state(for: F.botID))
    #expect(state.forecasts[0xFFFF]?.requestLabel == "round rock tx")
  }

  @Test
  func `a forecast is answered by any bot and marked as asked for here`() async throws {
    let h = makeHarness()
    _ = try await h.service.send(.forecast(point: 102), to: F.bot)
    _ = await h.service.ingest(F.forecast(seq: 1, point: 102, bot: 0x0102))
    #expect(await weatherWaitUntil { await h.service.pendingRequests().isEmpty })
    #expect(await h.service.state(for: 0x0102)?.forecasts[102]?.requestedHere == true)
  }

  @Test
  func `a forecast nobody here asked for is not marked as asked for here`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.forecast(seq: 1, point: 304))
    #expect(await h.service.state(for: F.botID)?.forecasts[304]?.requestedHere == false)
  }

  @Test
  func `messages from another bot do not settle a coverage request`() async throws {
    let h = makeHarness()
    _ = try await h.service.send(.digest, to: F.bot)
    _ = await h.service.ingest(F.digest(seq: 1, entries: [], bot: 0x0102))
    #expect(await h.service.pendingRequests().count == 1)
    #expect(await h.service.allStates().count == 1)
  }

  // MARK: - Five-minute rule and timeouts

  @Test
  func `an answered request is not re-sent within five minutes`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    _ = try await h.service.send(.digest, to: F.bot)
    _ = await h.service.ingest(F.digest(seq: 1, entries: []))
    #expect(await weatherWaitUntil { settled.value.count == 1 })

    h.clock.advance(by: 4 * 60)
    let second = try await h.service.send(.digest, to: F.bot)
    #expect(second == nil)
    #expect(await weatherWaitUntil { settled.value.count == 2 })
    #expect(isAlreadyReceived(settled.value.last?.1))
    #expect(await h.transport.sent.count == 1)

    h.clock.advance(by: 2 * 60)
    let third = try await h.service.send(.digest, to: F.bot)
    #expect(third != nil)
    #expect(await h.transport.sent.count == 2)
  }

  /// Twenty phones tapping after a siren: whoever's answer arrives first answers everyone.
  @Test
  func `an alert list somebody else asked for answers this phone's request without sending`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    _ = await h.service.ingest(F.digest(seq: 1, entries: []))
    h.clock.advance(by: 40)
    #expect(try await h.service.send(.digest, to: F.bot) == nil)
    #expect(await h.transport.sent.isEmpty)
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    guard case let .alreadyReceived(receivedAt, contentAsOf) = settled.value.first?.1 else {
      Issue.record("expected alreadyReceived, got \(String(describing: settled.value.first?.1))")
      return
    }
    #expect(receivedAt == h.clock.now.addingTimeInterval(-40))
    #expect(contentAsOf == Date(unixMinutes: F.t0Minutes))
  }

  @Test
  func `an alert list is asked for again when a gap opened after it arrived`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.digest(seq: 1, entries: []))
    h.clock.advance(by: 30)
    // seq 2 is lost.
    _ = await h.service.ingest(F.observations(seq: 3, stations: [(202, 88), (860, 84)]))
    #expect(try await h.service.send(.digest, to: F.bot) != nil)
  }

  @Test
  func `a list built too soon after a gap to clear it is asked for again once a new one would`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.observations(seq: 1, stations: [(202, 88), (860, 84)]))
    _ = await h.service.ingest(F.observations(seq: 3, stations: [(202, 88), (860, 84)]))
    h.clock.advance(by: 20)
    _ = await h.service.ingest(F.digest(seq: 4, nowMinutes: F.t0Minutes, entries: []))
    #expect(await h.service.state(for: F.botID)?.needsDigest == true)
    h.clock.advance(by: 30)
    #expect(try await h.service.send(.digest, to: F.bot) == nil, "a list built now could not clear the gap either")
    h.clock.advance(by: 100)
    #expect(try await h.service.send(.digest, to: F.bot) != nil)
  }

  @Test
  func `a single-station reply answers that station but not the coverage batch`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.observations(seq: 1, stations: [(202, 88)]))
    #expect(try await h.service.send(.observation(station: "KAUS"), to: F.bot) == nil)
    #expect(try await h.service.send(.observations, to: F.bot) != nil)
  }

  /// Spec §8.1: a reply with a part missing may be asked for again after 20 s.
  @Test
  func `a text request whose reply is incomplete is sent again inside the five minutes`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    _ = try await h.service.send(.hazardousOutlook, to: F.bot)
    _ = await h.service.ingest(F.text(seq: 1, subject: .hazardousOutlook, group: 1, index: 0, total: 2, text: "part one"))
    #expect(await weatherWaitUntil { settled.value.count == 1 })

    h.clock.advance(by: 25)
    let again = try await h.service.send(.hazardousOutlook, to: F.bot)
    #expect(again != nil)
    #expect(await h.transport.sent.count == 2)
  }

  @Test
  func `no answer and no sound from the bot means two sends on the route, one by flood, then timed out`() async throws {
    let h = makeHarness(answerTimeout: .milliseconds(40))
    let settled = collectSettlements(h.events)
    _ = try await h.service.send(.spaceWeather, to: F.bot)
    #expect(await weatherWaitUntil { await h.transport.sent.count == 3 })
    let sent = await h.transport.sent
    #expect(sent.map(\.text) == [">space", ">space", ">space"])
    #expect(sent.map(\.attempt) == [0, 1, 2])
    // The route is forgotten exactly once, before the third send and after the second.
    #expect(await h.transport.resets == [F.botPublicKey])
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .timedOut(botWasHeard: false))
    #expect(settled.value.first?.0.attempt == WeatherService.floodAttempt)
    #expect(await h.service.pendingRequests().isEmpty)
  }

  @Test
  func `a bot heard after the request, but not confirming it, is asked once more by flood`() async throws {
    let h = makeHarness(answerTimeout: .milliseconds(40))
    let settled = collectSettlements(h.events)
    _ = try await h.service.send(.spaceWeather, to: F.bot)
    h.clock.advance(by: 1)
    _ = await h.service.ingest(F.observations(seq: 1, stations: [(202, 88), (860, 84)]))
    // Heard means in range, so a second send along the same route would only add to the noise:
    // the route is the suspect, and the one resend is the flood.
    #expect(await weatherWaitUntil { await h.transport.sent.count == 2 })
    #expect(await h.transport.sent.map(\.attempt) == [0, 2])
    #expect(await h.transport.resets == [F.botPublicKey])
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .timedOut(botWasHeard: true))
    #expect(await h.transport.sent.count == 2)
  }

  @Test
  func `an answer during the retry window settles without a second transmission`() async throws {
    let h = makeHarness(answerTimeout: .seconds(1))
    let settled = collectSettlements(h.events)
    _ = try await h.service.send(.spaceWeather, to: F.bot)
    _ = await h.service.ingest(F.text(seq: 1, subject: .spaceWeather, group: 1, index: 0, total: 1, text: "quiet"))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    try await Task.sleep(for: .milliseconds(50))
    #expect(await h.transport.sent.count == 1)
  }

  // MARK: - Retry timestamp and delivery confirmation

  @Test
  func `every resend carries the first send's timestamp and text, under its own attempt and code`() async throws {
    let h = makeHarness(answerTimeout: .milliseconds(40))
    let settled = collectSettlements(h.events)
    let first = try #require(try await h.service.send(.spaceWeather, to: F.bot))
    h.clock.advance(by: 15)
    #expect(await weatherWaitUntil { await h.transport.sent.count == 3 })
    let sent = await h.transport.sent
    #expect(sent.map(\.attempt) == [0, 1, 2])
    #expect(sent.map(\.text) == [">space", ">space", ">space"])
    #expect(sent.map(\.timestamp) == [first.timestamp, first.timestamp, first.timestamp])
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    let request = try #require(settled.value.first?.0)
    #expect(request.timestamp == first.timestamp)
    #expect(request.sentAt > first.timestamp, "a resend's send time moves on; its wire timestamp does not")
    #expect(request.ackCodes == Set(sent.map(\.ackCode)))
    #expect(request.ackCodes.count == 3)
  }

  @Test
  func `a confirmation of the first send marks the request received by the bot's radio`() async throws {
    let h = makeHarness(answerTimeout: .milliseconds(300))
    let settled = collectSettlements(h.events)
    await h.service.startEventMonitoring()
    _ = try await h.service.send(.spaceWeather, to: F.bot)
    let first = try #require(await h.transport.sent.first)
    await h.transport.acknowledge(first.ackCode)
    #expect(await weatherWaitUntil { await h.service.pendingRequests().first?.botRadioReceived == true })
    // A confirmed request that gets no answer goes out once more along the route — the bot
    // answers a copy from its cache — and is never flooded: the route provably works.
    #expect(await weatherWaitUntil { await h.transport.sent.count == 2 })
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .timedOut(botWasHeard: false, botRadioReceived: true))
    #expect(await h.transport.sent.map(\.attempt) == [0, 1])
    #expect(await h.transport.resets.isEmpty)
  }

  @Test
  func `a confirmation of the retry counts too`() async throws {
    let h = makeHarness(answerTimeout: .milliseconds(150))
    let settled = collectSettlements(h.events)
    await h.service.startEventMonitoring()
    _ = try await h.service.send(.spaceWeather, to: F.bot)
    #expect(await weatherWaitUntil { await h.transport.sent.count == 2 })
    let retry = try #require(await h.transport.sent.last)
    #expect(retry.attempt == 1)
    await h.transport.acknowledge(retry.ackCode)
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .timedOut(botWasHeard: false, botRadioReceived: true))
    // Confirmed on the second send: no flood follows.
    #expect(await h.transport.sent.count == 2)
    #expect(await h.transport.resets.isEmpty)
  }

  @Test
  func `a confirmation no request expects marks nothing`() async throws {
    let h = makeHarness(answerTimeout: .milliseconds(40))
    let settled = collectSettlements(h.events)
    await h.service.startEventMonitoring()
    _ = try await h.service.send(.spaceWeather, to: F.bot)
    await h.transport.acknowledge(Data([0xDE, 0xAD, 0xBE, 0xEF]))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .timedOut(botWasHeard: false, botRadioReceived: false))
  }

  @Test
  func `a confirmation that lands before the send returns still counts`() async throws {
    let h = makeHarness()
    await h.service.startEventMonitoring()
    await h.transport.setConfirmsDuringSend(true)
    let pending = try #require(try await h.service.send(.spaceWeather, to: F.bot))
    #expect(pending.botRadioReceived)
    #expect(await h.service.pendingRequests().first?.botRadioReceived == true)
  }

  @Test
  func `a confirmed request that is answered settles as answered`() async throws {
    let h = makeHarness(answerTimeout: .seconds(5))
    let settled = collectSettlements(h.events)
    await h.service.startEventMonitoring()
    _ = try await h.service.send(.spaceWeather, to: F.bot)
    let first = try #require(await h.transport.sent.first)
    await h.transport.acknowledge(first.ackCode)
    #expect(await weatherWaitUntil { await h.service.pendingRequests().first?.botRadioReceived == true })
    _ = await h.service.ingest(F.text(seq: 1, subject: .spaceWeather, group: 1, index: 0, total: 1, text: "quiet"))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .answered)
    #expect(await h.transport.sent.count == 1)
  }

  // MARK: - Requests on the channel (spec §7B)

  @Test
  func `a request goes out as a datagram flooded on the channel, not as a DM`() async throws {
    let h = makeHarness(channelRequests: true)
    let pending = try #require(try await h.service.send(.forecast(point: 102), to: F.bot))
    #expect(pending.transportKind == .channel)
    #expect(pending.attempt == 0)
    #expect(await h.transport.sent.isEmpty, "nothing goes out as a DM")
    let flooded = await h.transport.channelSent
    #expect(flooded.count == 1)
    #expect(flooded.first?.text == ">f 102")
    #expect(flooded.first?.botID == F.botID)
    #expect(flooded.first?.timestamp == pending.timestamp)
    #expect(flooded.first?.seq == pending.seq)
    // There is no acknowledgement for a datagram, so nothing is ever waiting on one.
    #expect(pending.ackCodes.isEmpty)
    #expect(!pending.botRadioReceived)
  }

  /// Spec §7B: one more per **new** request, wrapping; the five-second spacing still applies.
  @Test
  func `each new request takes the next seq`() async throws {
    let h = makeHarness(channelRequests: true)
    _ = try await h.service.send(.digest, to: F.bot)
    h.clock.advance(by: 5.1)
    _ = try await h.service.send(.observations, to: F.bot)
    h.clock.advance(by: 2)
    await #expect(throws: WeatherRequestError.self) {
      try await h.service.send(.coverage, to: F.bot)
    }
    #expect(await h.transport.channelSent.map(\.seq) == [0, 1])
    #expect(await h.transport.channelSent.map(\.text) == [">d", ">o"])
  }

  @Test
  func `no answer means one resend of the same bytes, then timed out`() async throws {
    #expect(WeatherService.channelAnswerTimeout == .seconds(10))
    let h = makeHarness(channelRequests: true, channelAnswerTimeout: .milliseconds(40))
    let settled = collectSettlements(h.events)
    let first = try #require(try await h.service.send(.spaceWeather, to: F.bot))
    #expect(await weatherWaitUntil { await h.transport.channelSent.count == 2 })
    let flooded = await h.transport.channelSent
    // The same bytes: same text, same `ts`, same `seq`, which is what makes the resend a copy
    // of one request to the bot rather than a second request.
    #expect(flooded.map(\.text) == [">space", ">space"])
    #expect(flooded.map(\.timestamp) == [first.timestamp, first.timestamp])
    #expect(flooded.map(\.seq) == [first.seq, first.seq])
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .timedOut(botWasHeard: false, botRadioReceived: false))
    #expect(settled.value.first?.0.attempt == 1)
    #expect(settled.value.first?.0.sentAt ?? .distantPast >= first.timestamp)
    // Never a third time; never a DM; and no route to forget.
    try await Task.sleep(for: .milliseconds(150))
    #expect(await h.transport.channelSent.count == 2)
    #expect(await h.transport.sent.isEmpty)
    #expect(await h.transport.resets.isEmpty)
  }

  @Test
  func `an answer settles a channel request after one send`() async throws {
    let h = makeHarness(channelRequests: true, channelAnswerTimeout: .seconds(1))
    let settled = collectSettlements(h.events)
    _ = try await h.service.send(.spaceWeather, to: F.bot)
    _ = await h.service.ingest(F.text(seq: 1, subject: .spaceWeather, group: 1, index: 0, total: 1, text: "quiet"))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .answered)
    try await Task.sleep(for: .milliseconds(60))
    #expect(await h.transport.channelSent.count == 1)
  }

  @Test
  func `a bot heard while a channel request was out is named in the timeout`() async throws {
    let h = makeHarness(channelRequests: true, channelAnswerTimeout: .milliseconds(40))
    let settled = collectSettlements(h.events)
    _ = try await h.service.send(.spaceWeather, to: F.bot)
    h.clock.advance(by: 1)
    _ = await h.service.ingest(F.observations(seq: 1, stations: [(202, 88), (860, 84)]))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .timedOut(botWasHeard: true, botRadioReceived: false))
    // Heard or not, a datagram gets its one resend: there is no route to suspect and nothing
    // to forget, so the second send is the whole of the escalation.
    #expect(await h.transport.channelSent.count == 2)
    #expect(await h.transport.resets.isEmpty)
  }

  /// Spec §7B: "An app whose radio cannot send channel datagrams keeps using the DM."
  @Test
  func `a radio that cannot flood a datagram falls back to the DM ladder`() async throws {
    let h = makeHarness(answerTimeout: .milliseconds(40), channelRequests: false)
    let settled = collectSettlements(h.events)
    let pending = try #require(try await h.service.send(.spaceWeather, to: F.bot))
    #expect(await h.transport.channelRequestsRefused == 1, "the channel is tried first, every time")
    #expect(await h.transport.channelSent.isEmpty)
    #expect(pending.transportKind == .dm)
    // The ladder is untouched: two sends on the route, then the flood after a route reset.
    #expect(await weatherWaitUntil { await h.transport.sent.count == 3 })
    #expect(await h.transport.sent.map(\.attempt) == [0, 1, 2])
    #expect(await h.transport.resets == [F.botPublicKey])
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .timedOut(botWasHeard: false))
    // The fallback is silent: nothing about it reaches the request's own seq counter.
    #expect(await h.transport.channelRequestsRefused == 1)
  }

  /// Requests are flooded now, so a phone on `#meshwx` hears everybody else's. One is not an
  /// answer, not the bot, and not the bot's `seq`.
  @Test
  func `another phone's request on the channel changes nothing`() async throws {
    let h = makeHarness(channelRequests: true, channelAnswerTimeout: .milliseconds(60))
    let settled = collectSettlements(h.events)
    await h.service.startEventMonitoring()
    _ = try await h.service.send(.digest, to: F.bot)

    #expect(await h.service.ingest(try F.datagram(F.request(seq: 250, text: ">o KAUS"))) == nil)
    #expect(await h.service.allStates().isEmpty, "nothing is stored, and no bot is invented")
    #expect(await h.service.sessionInfo().lastChannelDatagramAt == nil)
    #expect(await h.service.pendingRequests().count == 1, "somebody's question is not an answer")
    // And it did not count as hearing the bot: the timeout still reads "nothing came back".
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .timedOut(botWasHeard: false, botRadioReceived: false))
  }

  // MARK: - The transport's own link

  @Test
  func `the service passes on a link the transport provides of its own`() async throws {
    let h = makeHarness()
    #expect(await h.service.transportLink() == nil)
    await h.transport.setLink(.up(bot: F.bot))
    let link = try #require(await h.service.transportLink())
    #expect(link.bot.name == "WX-AUS")
    #expect(link.bot.botID == F.botID)
    #expect(link.bot.publicKey == F.botPublicKey)
  }

  @Test
  func `a transport with no link of its own reports none`() async throws {
    // The radio's transport: whether it is connected stays the app's business, and the default
    // implementation is what every other transport gets.
    let transport = SessionWeatherTransport(session: MockMeshCoreSession())
    #expect(await transport.linkState() == nil)
    let service = WeatherService(transport: transport, store: InMemoryWeatherStateStore())
    #expect(await service.transportLink() == nil)
  }

  // MARK: - Session transport

  @Test
  func `the session transport puts the given timestamp and attempt on the wire and returns the expected ACK`() async throws {
    let session = MockMeshCoreSession()
    let transport = SessionWeatherTransport(session: session)
    let timestamp = Date(timeIntervalSince1970: 1_789_000_000)
    let code = try await transport.sendRequest(to: F.botPublicKey, text: ">space", timestamp: timestamp, attempt: 1)
    #expect(code == Data([0x01, 0x02, 0x03, 0x04]))
    let invocation = try #require(await session.sendMessageInvocations.first)
    #expect(invocation.text == ">space")
    #expect(invocation.timestamp == timestamp)
    #expect(invocation.attempt == 1)
  }

  /// The spec's own vector, produced by the transport: `>d` to bot `0x041D` from this phone's
  /// key at `ts` 1789660000 with `seq` 1 is the sixteen bytes of §7B, flooded on the slot that
  /// holds `#meshwx` under data type 0xFF10.
  @Test
  func `the session transport floods the spec's request bytes on the meshwx slot`() async throws {
    let session = MockMeshCoreSession()
    await session.setCurrentSelfInfo(F.selfInfo())
    await session.setStubbedChannel(
      ChannelInfo(index: 2, name: WeatherChannel.name, secret: WeatherChannel.secret), at: 2)
    let transport = SessionWeatherTransport(session: session)

    try await transport.sendChannelRequest(
      text: ">d", botID: 0x041D, timestamp: Date(timeIntervalSince1970: 1_789_660_000), seq: 1)

    let sent = try #require(await session.sendChannelDataInvocations.first)
    #expect(await session.sendChannelDataInvocations.count == 1)
    #expect(sent.channelIndex == 2)
    #expect(sent.dataType == MeshWXWire.dataType)
    #expect(sent.payload == Data([
      0x01, 0x1D, 0x04, 0x90, 0x01, 0x02, 0x03, 0x04,
      0x05, 0x06, 0x60, 0x0B, 0xAC, 0x6A, 0x3E, 0x64
    ]))
    #expect(sent.pathLength == 0xFF, "flooded: no stored route can lose it")
    #expect(sent.pathBytes.isEmpty)

    // The slot is found once and remembered; nothing goes out as a DM.
    try await transport.sendChannelRequest(
      text: ">d", botID: 0x041D, timestamp: Date(timeIntervalSince1970: 1_789_660_000), seq: 1)
    #expect(await session.getChannelIndices == [0, 1, 2])
    #expect(await session.sendMessageInvocations.isEmpty)
  }

  /// The owner's radio keeps `#meshwx` in slot 31 (17 September): the first cut scanned 0-7 and
  /// sent every request as a DM. The app's own table names the slot without a round trip; and
  /// with no table at all the scan reaches it.
  @Test
  func `the session transport finds meshwx in a high slot, from the table first and by scanning otherwise`() async throws {
    let session = MockMeshCoreSession()
    await session.setCurrentSelfInfo(F.selfInfo())
    await session.setStubbedChannel(
      ChannelInfo(index: 31, name: WeatherChannel.name, secret: WeatherChannel.secret), at: 31)

    let fromTable = SessionWeatherTransport(session: session, storedWeatherSlot: { 31 })
    try await fromTable.sendChannelRequest(text: ">d", botID: F.botID, timestamp: F.t0, seq: 0)
    #expect(await session.sendChannelDataInvocations.last?.channelIndex == 31)
    #expect(await session.getChannelIndices.isEmpty, "the table answered; the radio was not asked")

    let scanning = SessionWeatherTransport(session: session)
    try await scanning.sendChannelRequest(text: ">d", botID: F.botID, timestamp: F.t0, seq: 0)
    #expect(await session.sendChannelDataInvocations.last?.channelIndex == 31)
    #expect(await session.getChannelIndices.contains(31))
    #expect(await session.sendMessageInvocations.isEmpty, "nothing went out as a DM")
  }

  @Test
  func `the session transport refuses a channel request it cannot make`() async throws {
    // No slot carries #meshwx.
    let noChannel = MockMeshCoreSession()
    await noChannel.setCurrentSelfInfo(F.selfInfo())
    await #expect(throws: WeatherTransportError.self) {
      try await SessionWeatherTransport(session: noChannel)
        .sendChannelRequest(text: ">d", botID: F.botID, timestamp: F.t0, seq: 0)
    }

    // The radio has the channel but has not said who it is, so no sender prefix can be named.
    let noKey = MockMeshCoreSession()
    await noKey.setStubbedChannel(
      ChannelInfo(index: 1, name: WeatherChannel.name, secret: WeatherChannel.secret), at: 1)
    await #expect(throws: WeatherTransportError.self) {
      try await SessionWeatherTransport(session: noKey)
        .sendChannelRequest(text: ">d", botID: F.botID, timestamp: F.t0, seq: 0)
    }

    // Firmware older than v1.15.0: the command does not exist, and the gate says so before
    // anything is asked of the radio at all.
    let old = MockMeshCoreSession()
    await old.setCurrentSelfInfo(F.selfInfo())
    await old.setStubbedChannel(
      ChannelInfo(index: 1, name: WeatherChannel.name, secret: WeatherChannel.secret), at: 1)
    let gated = SessionWeatherTransport(session: old, supportsChannelData: { false })
    await #expect(throws: WeatherTransportError.self) {
      try await gated.sendChannelRequest(text: ">d", botID: F.botID, timestamp: F.t0, seq: 0)
    }
    #expect(await old.sendChannelDataInvocations.isEmpty)
    #expect(await old.getChannelIndices.isEmpty)
  }

  @Test
  func `the session transport passes on the radio's ACK pushes and nothing else`() async throws {
    let session = MockMeshCoreSession()
    let transport = SessionWeatherTransport(session: session)
    let codes = await transport.acknowledgements()
    let received = LockedValue<[Data]>([])
    let consumer = Task {
      for await code in codes {
        received.value.append(code)
      }
    }
    defer { consumer.cancel() }
    await session.yieldEvent(.channelDataReceived(try F.datagram(F.digest(seq: 1, entries: []))))
    await session.yieldEvent(.acknowledgement(code: Data([0x0A, 0x0B, 0x0C, 0x0D]), tripTime: 250))
    #expect(await weatherWaitUntil { received.value == [Data([0x0A, 0x0B, 0x0C, 0x0D])] })
  }

  @Test
  func `stopping monitoring fails whatever is still pending`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    await h.service.startEventMonitoring()
    _ = try await h.service.send(.digest, to: F.bot)
    await h.service.stopEventMonitoring()
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .failed("disconnected"))
  }

  // MARK: - Retention

  /// Readings are kept one per station; what grows is the number of stations, one for every
  /// `>o <ICAO>` anyone on the channel ever asked for. A station goes once neither the bot's
  /// batches nor the channel has carried it for two days.
  @Test
  func `a station nothing has carried for two days is forgotten`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.observations(seq: 1, stations: [(202, 88), (860, 84)]))
    // Somebody's one-off request for a station this bot's batch never carries.
    _ = await h.service.ingest(F.observations(seq: 2, timestampMinutes: F.t0Minutes + 1, stations: [(976, 70)]))
    #expect(await h.service.state(for: F.botID)?.observations.count == 3)

    h.clock.advance(by: 49 * 3600)
    _ = await h.service.ingest(F.observations(
      seq: 3, timestampMinutes: F.t0Minutes + 49 * 60, stations: [(202, 80), (860, 79)]))
    let state = try #require(await h.service.state(for: F.botID))
    #expect(Set(state.observations.keys) == [202, 860])
  }

  @Test
  func `readings are capped per bot, the bot's own area first`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.observations(seq: 1, stations: [(202, 88), (860, 84)]))
    for offset in 0..<70 {
      _ = await h.service.ingest(F.observations(
        seq: UInt8(2 + offset), timestampMinutes: F.t0Minutes + UInt32(offset),
        stations: [(UInt16(1000 + offset), 70)]))
    }
    let state = try #require(await h.service.state(for: F.botID))
    #expect(state.observations.count == WeatherService.maxObservationsPerBot)
    #expect(state.observations[202] != nil)
    #expect(state.observations[860] != nil, "the bot's own area outlives answers to one-off questions")
  }

  @Test
  func `clearing a bot forgets its state and its answers`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.digest(seq: 1, entries: []))
    await h.service.clearState(for: F.botID)
    #expect(await h.service.state(for: F.botID) == nil)
    #expect(await h.store.states.isEmpty)
    #expect(try await h.service.send(.digest, to: F.bot) != nil)
  }
}
