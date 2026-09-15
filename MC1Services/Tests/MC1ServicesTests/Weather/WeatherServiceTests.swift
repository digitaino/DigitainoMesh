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

  private func makeHarness(answerTimeout: Duration = .seconds(15)) -> Harness {
    let transport = FakeWeatherTransport()
    let store = InMemoryWeatherStateStore()
    let clock = WeatherTestClock()
    let service = WeatherService(
      transport: transport,
      store: store,
      now: { clock.now },
      answerTimeout: answerTimeout,
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

  private func isServedFromCache(_ outcome: WeatherRequestOutcome?) -> Bool {
    if case .servedFromCache = outcome { return true }
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

    _ = await h.service.ingest(F.forecast(seq: 1, point: 7))   // a different point
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
  func `a coverage observation request is not settled by somebody's single-station reply`() async throws {
    let h = makeHarness()
    _ = try await h.service.send(.observations, to: F.bot)
    _ = await h.service.ingest(F.observations(seq: 1, stations: [(202, 88)]))
    #expect(await h.service.pendingRequests().count == 1)
    _ = await h.service.ingest(F.observations(seq: 2, stations: [(202, 88), (860, 84)]))
    #expect(await weatherWaitUntil { await h.service.pendingRequests().isEmpty })
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
  func `a text request is settled by its subject's first chunk and remembered on the reply`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    _ = try await h.service.send(.stormReports(state: "TX"), to: F.bot)
    _ = await h.service.ingest(F.text(seq: 1, subject: .spaceWeather, group: 1, index: 0, total: 1, text: "quiet sun"))
    #expect(await h.service.pendingRequests().count == 1)
    _ = await h.service.ingest(F.text(seq: 2, subject: .stormReports, group: 2, index: 0, total: 2, text: "0115 HAIL"))
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
    #expect(isServedFromCache(settled.value.last?.1))
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
    guard case let .servedFromCache(receivedAt) = settled.value.first?.1 else {
      Issue.record("expected servedFromCache, got \(String(describing: settled.value.first?.1))")
      return
    }
    #expect(receivedAt == h.clock.now.addingTimeInterval(-40))
  }

  @Test
  func `a single-station reply answers that station but not the coverage batch`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.observations(seq: 1, stations: [(202, 88)]))
    #expect(try await h.service.send(.observation(station: "KAUS"), to: F.bot) == nil)
    #expect(try await h.service.send(.observations, to: F.bot) != nil)
  }

  @Test
  func `a text request is sent again even inside the cache window`() async throws {
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
  func `no answer and no sound from the bot means one retry, then timed out`() async throws {
    let h = makeHarness(answerTimeout: .milliseconds(40))
    let settled = collectSettlements(h.events)
    _ = try await h.service.send(.spaceWeather, to: F.bot)
    #expect(await weatherWaitUntil { await h.transport.sent.count == 2 })
    #expect(await h.transport.sent.map(\.text) == [">space", ">space"])
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .timedOut(botWasHeard: false))
    #expect(settled.value.first?.0.attempt == 1)
    #expect(await h.service.pendingRequests().isEmpty)
  }

  @Test
  func `a bot heard after the request gets no retry`() async throws {
    let h = makeHarness(answerTimeout: .milliseconds(40))
    let settled = collectSettlements(h.events)
    _ = try await h.service.send(.spaceWeather, to: F.bot)
    h.clock.advance(by: 1)
    _ = await h.service.ingest(F.observations(seq: 1, stations: [(202, 88), (860, 84)]))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .timedOut(botWasHeard: true))
    #expect(await h.transport.sent.count == 1)
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
