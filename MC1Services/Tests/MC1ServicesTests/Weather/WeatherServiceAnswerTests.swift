import Foundation
@testable import MC1Services
import MeshCore
import MeshWX
import Testing

/// What counts as an answer: the request flow from send to settlement, the five-minute rule's
/// slots and what fills them, backlog drained at connect versus traffic heard live, and which
/// text replies are this phone's.
@Suite("WeatherService answers")
struct WeatherServiceAnswerTests {
  private typealias F = WeatherFixture

  private struct Harness {
    let transport: FakeWeatherTransport
    let clock: WeatherTestClock
    let service: WeatherService
    let events: AsyncStream<WeatherEvent>
  }

  /// The fake radio cannot flood a Request datagram here (spec §7B), so every request in this
  /// suite goes out as the DM of §8.2 and the assertions on `transport.sent` still read the
  /// send they were written for. The channel path has its own section in `WeatherServiceTests`.
  private func makeHarness(answerTimeout: Duration = .seconds(15)) -> Harness {
    let transport = FakeWeatherTransport(channelRequestsSupported: false)
    let clock = WeatherTestClock()
    let service = WeatherService(
      transport: transport,
      store: InMemoryWeatherStateStore(),
      now: { clock.now },
      answerTimeout: answerTimeout,
      stationIndex: { $0 == "KAUS" ? 202 : nil },
      tables: .shared
    )
    return Harness(transport: transport, clock: clock, service: service, events: service.events())
  }

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

  // MARK: - Request flow

  @Test
  func `a request is sent, waits as pending, and settles as answered`() async throws {
    let h = makeHarness()
    let log = LockedValue<[String]>([])
    Task {
      for await event in h.events {
        switch event {
        case let .requestSent(request): log.value.append("sent \(request.request.wireText)")
        case let .requestSettled(request, outcome): log.value.append("settled \(request.request.wireText) \(outcome)")
        default: break
        }
      }
    }
    let pending = try #require(try await h.service.send(.digest, to: F.bot))
    #expect(await h.service.pendingRequests().map(\.id) == [pending.id])
    #expect(await h.transport.sent.map(\.text) == [">d"])

    h.clock.advance(by: 3)
    _ = await h.service.ingest(F.digest(seq: 1, entries: []))
    #expect(await weatherWaitUntil { log.value.count == 2 })
    #expect(log.value == ["sent >d", "settled >d answered"])
    #expect(await h.service.pendingRequests().isEmpty)
  }

  @Test
  func `a second request inside five seconds is refused with the time left`() async throws {
    let h = makeHarness()
    _ = try await h.service.send(.digest, to: F.bot)
    h.clock.advance(by: 3)
    do {
      _ = try await h.service.send(.observations, to: F.bot)
      Issue.record("expected the rate limit")
    } catch let WeatherRequestError.rateLimited(retryAfter) {
      #expect(abs(retryAfter - 2) < 0.001)
    }
    #expect(await h.transport.sent.count == 1)
  }

  // MARK: - Slots

  @Test
  func `an answer served from the channel says what it is as of`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    _ = await h.service.ingest(F.observations(seq: 1, timestampMinutes: F.t0Minutes - 7, stations: [(202, 88), (860, 84)]))
    _ = await h.service.ingest(F.forecast(seq: 2, point: 102, issuedMinutes: F.t0Minutes - 30, bot: 0x0102))
    _ = await h.service.ingest(F.digest(seq: 3, nowMinutes: F.t0Minutes - 2, entries: []))
    h.clock.advance(by: 60)

    #expect(try await h.service.send(.observations, to: F.bot) == nil)
    #expect(try await h.service.send(.forecast(point: 102), to: F.bot) == nil)
    #expect(try await h.service.send(.digest, to: F.bot) == nil)
    #expect(await weatherWaitUntil { settled.value.count == 3 })
    #expect(settled.value.map(\.1) == [
      .alreadyReceived(receivedAt: F.t0, contentAsOf: Date(unixMinutes: F.t0Minutes - 7)),
      .alreadyReceived(receivedAt: F.t0, contentAsOf: Date(unixMinutes: F.t0Minutes - 30)),
      .alreadyReceived(receivedAt: F.t0, contentAsOf: Date(unixMinutes: F.t0Minutes - 2))
    ])
    #expect(await h.transport.sent.isEmpty)
  }

  @Test
  func `a station's slot is as of that station's own report, not the batch's`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    // Revision 5 (spec §6.1): KAUS filed 40 minutes before the newest station in the batch. Its
    // slot must say so; the batch's own slot keeps the batch time.
    _ = await h.service.ingest(F.observations(
      seq: 1, timestampMinutes: F.t0Minutes - 7, stations: [(202, 88), (860, 84)], ages: [40, 0]))
    h.clock.advance(by: 60)

    #expect(try await h.service.send(.observation(station: "KAUS"), to: F.bot) == nil)
    #expect(try await h.service.send(.observations, to: F.bot) == nil)
    #expect(await weatherWaitUntil { settled.value.count == 2 })
    #expect(settled.value.map(\.1) == [
      .alreadyReceived(receivedAt: F.t0, contentAsOf: Date(unixMinutes: F.t0Minutes - 7 - 40)),
      .alreadyReceived(receivedAt: F.t0, contentAsOf: Date(unixMinutes: F.t0Minutes - 7))
    ])
    #expect(await h.transport.sent.isEmpty)
  }

  @Test
  func `a list older than the one held answers nothing, in order or late`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.digest(seq: 10, nowMinutes: F.t0Minutes, entries: []))
    h.clock.advance(by: 6 * 60)

    let older = await h.service.ingest(F.digest(seq: 11, nowMinutes: F.t0Minutes - 30, entries: []))
    #expect(older.contains(.digestIgnoredOlder(builtMinutes: F.t0Minutes - 30)))
    #expect(try await h.service.send(.digest, to: F.bot) != nil)

    h.clock.advance(by: 6 * 60)
    let late = await h.service.ingest(F.digest(seq: 5, nowMinutes: F.t0Minutes - 20, entries: []))
    #expect(late == [.outOfOrder(seq: 5), .digestIgnoredOlder(builtMinutes: F.t0Minutes - 20)])
    #expect(try await h.service.send(.digest, to: F.bot) != nil)
  }

  @Test
  func `a late warning the reducer set aside answers nothing`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.cancel(seq: 10, identity: F.svw42))
    _ = await h.service.ingest(F.warning(seq: 8, identity: F.svw42))
    #expect(await h.service.state(for: F.botID)?.warnings[F.svw42] == nil)
    #expect(try await h.service.send(.warning(identity: "SV.W.EWX.42"), to: F.bot) != nil)
  }

  @Test
  func `a warning from any bot answers a request for that warning`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.warning(seq: 1, identity: F.svw42, bot: 0x0102))
    #expect(try await h.service.send(.warning(identity: "SV.W.EWX.42"), to: F.bot) == nil)
    #expect(try await h.service.send(.warning(identity: "sv.w.ewx.42"), to: F.bot) == nil)
    #expect(try await h.service.send(.warning(identity: "SV.W.EWX.43"), to: F.bot) != nil)
  }

  @Test
  func `a list from the bot answers its warnings requests while nothing is outstanding`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.digest(seq: 1, entries: []))
    #expect(try await h.service.send(.activeWarnings, to: F.bot) == nil)
    #expect(try await h.service.send(.warningsTouching(ugc: "TXC453"), to: F.bot) == nil)
    let other = WeatherBot(publicKey: Data([0x02, 0x01]) + Data(repeating: 0x22, count: 30), name: "WX-SAT", latitude: 29.4, longitude: -98.5, lastAdvert: nil)
    #expect(try await h.service.send(.activeWarnings, to: other) != nil, "another bot's list is not this one's")
  }

  /// The list itself is what shows a warning never arrived; asking again is the repair, and the
  /// rebuilt answer may carry exactly the packet that was lost.
  @Test
  func `warnings requests are sent while the bot's list names a warning this phone lacks`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.digest(seq: 1, entries: [(F.svw43, 30)]))
    _ = await h.service.ingest(F.warning(seq: 2, identity: F.svw42))
    #expect(await h.service.state(for: F.botID)?.missingFromDigest == [F.svw43])
    #expect(try await h.service.send(.warningsTouching(ugc: "TXC453"), to: F.bot) != nil)
  }

  /// Asking for missing warnings one at a time ends in `>d` once the bot has said it has none of
  /// them; that last ask must not wait out the five minutes behind the list it wants replaced.
  @Test
  func `a list request is sent while the bot's list names a warning this phone lacks`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.digest(seq: 1, entries: [(F.svw43, 30)]))
    #expect(await h.service.state(for: F.botID)?.missingFromDigest == [F.svw43])
    #expect(try await h.service.send(.digest, to: F.bot) != nil)
  }

  @Test
  func `only a complete reply this phone asked for answers a text request`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    _ = await h.service.ingest(F.text(seq: 1, subject: .hazardousOutlook, group: 1, index: 0, total: 1, text: "outlook"))
    #expect(try await h.service.send(.hazardousOutlook, to: F.bot) != nil, "somebody else's reply is not an answer")

    _ = await h.service.ingest(F.text(seq: 2, subject: .hazardousOutlook, group: 2, index: 0, total: 1, text: "outlook"))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    h.clock.advance(by: 30)
    #expect(try await h.service.send(.hazardousOutlook, to: F.bot) == nil)
  }

  // MARK: - Coverage

  /// Spec §7A, §8.2: `>cov` asks a bot what it carries. The statement carries no time of its
  /// own — it describes the bot, not an hour — so the five-minute rule runs from receipt and the
  /// answer names nothing it is "as of".
  @Test
  func `a statement answers the request that asked for it, and fills its slot`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    let pending = try #require(try await h.service.send(.coverage, to: F.bot))
    #expect(await h.transport.sent.map(\.text) == [">cov"])

    h.clock.advance(by: 2)
    _ = await h.service.ingest(F.coverage(seq: 1))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.0.id == pending.id)
    #expect(settled.value.first?.1 == .answered)
    #expect(await h.service.state(for: F.botID)?.coverage?.coverage.radiusKilometres == 120)

    h.clock.advance(by: 30)
    #expect(try await h.service.send(.coverage, to: F.bot) == nil)
    #expect(await weatherWaitUntil { settled.value.count == 2 })
    #expect(settled.value.last?.1 == .alreadyReceived(receivedAt: F.t0.addingTimeInterval(2), contentAsOf: nil))
  }

  /// A statement describes whichever bot sent it, so another bot's answer — to this phone or to
  /// anybody else — settles nothing here.
  @Test
  func `another bot's statement is not this bot's`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.coverage(seq: 1, bot: 0x0102))
    #expect(try await h.service.send(.coverage, to: F.bot) != nil)
  }

  @Test
  func `clearing a bot forgets the answers any bot gave`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.forecast(seq: 1, point: 102, bot: 0x0102))
    #expect(try await h.service.send(.forecast(point: 102), to: F.bot) == nil)
    await h.service.clearState(for: F.botID)
    #expect(try await h.service.send(.forecast(point: 102), to: F.bot) != nil)
  }

  // MARK: - Area sweep (spec §7C)

  /// `>wmap` is answered by the sweep's **first** packet — the other seven are already on the
  /// air — and the slot it fills is what stops the next phone spending eight more.
  @Test
  func `the first sweep packet answers the map request and fills its slot`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    let pending = try #require(try await h.service.send(.areaSweep(includesAdvisories: false, states: []), to: F.bot))
    #expect(await h.transport.sent.map(\.text) == [">wmap"])

    h.clock.advance(by: 2)
    _ = await h.service.ingest(F.areaSweep(
      seq: 1, group: 1, index: 0, total: 3, entries: [F.texasSweepEntry]))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.0.id == pending.id)
    #expect(settled.value.first?.1 == .answered)
    // The sweep the tap produced is marked as this phone's, even though it is still arriving.
    #expect(await h.service.state(for: F.botID)?.newestAreaSweep?.request
      == .areaSweep(includesAdvisories: false, states: []))

    // Both scopes share one slot: the narrow sweep is a subset of the wide one, and eight more
    // packets a minute later is exactly what the five-minute rule is for.
    h.clock.advance(by: 30)
    #expect(try await h.service.send(.areaSweep(includesAdvisories: true, states: []), to: F.bot) == nil)
    #expect(await weatherWaitUntil { settled.value.count == 2 })
    #expect(settled.value.last?.1
      == .alreadyReceived(receivedAt: F.t0.addingTimeInterval(2), contentAsOf: Date(unixMinutes: F.t0Minutes)))
  }

  /// Spec §7C: a sweep is cut where the sending bot's own feed runs out, so another bot's is not
  /// this request's answer.
  @Test
  func `another bot's sweep does not answer this bot's map request`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.areaSweep(
      seq: 1, group: 1, index: 0, total: 1, entries: [F.texasSweepEntry], bot: 0x0102))
    #expect(try await h.service.send(.areaSweep(includesAdvisories: false, states: []), to: F.bot) != nil)
  }

  // MARK: - Backlog

  @Test
  func `a backlog message updates state but answers nothing and is not hearing the bot`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.digest(seq: 1, entries: []), isBacklog: true)
    let state = try #require(await h.service.state(for: F.botID))
    #expect(state.digest != nil)
    #expect(state.lastHeardAt == h.clock.now)
    #expect(state.lastLiveHeardAt == nil)
    #expect(try await h.service.send(.digest, to: F.bot) != nil)
  }

  @Test
  func `datagrams delivered while the radio drains its queue are backlog, later ones live`() async throws {
    let h = makeHarness()
    await h.service.startEventMonitoring()
    await h.transport.setDrainingBacklog(true)
    await h.transport.deliver(try F.datagram(F.observations(seq: 1, stations: [(202, 88), (860, 84)])))
    #expect(await weatherWaitUntil { await h.service.state(for: F.botID)?.observations.count == 2 })
    #expect(await h.service.state(for: F.botID)?.lastLiveHeardAt == nil)
    #expect(try await h.service.send(.observations, to: F.bot) != nil, "a drained batch is no answer")

    await h.transport.setDrainingBacklog(false)
    h.clock.advance(by: 10)
    await h.transport.deliver(try F.datagram(F.observations(seq: 2, stations: [(202, 89), (860, 85)])))
    #expect(await weatherWaitUntil { await h.service.state(for: F.botID)?.lastLiveHeardAt == h.clock.now })
    #expect(await weatherWaitUntil { await h.service.pendingRequests().isEmpty })
    #expect(try await h.service.send(.observations, to: F.bot) == nil)
  }

  @Test
  func `a backlog drained after a request does not stop the retry`() async throws {
    let h = makeHarness(answerTimeout: .milliseconds(60))
    let settled = collectSettlements(h.events)
    _ = try await h.service.send(.spaceWeather, to: F.bot)
    h.clock.advance(by: 1)
    _ = await h.service.ingest(F.observations(seq: 1, stations: [(202, 88), (860, 84)]), isBacklog: true)
    // Backlog is not "heard": the resend goes along the route, and the flood follows it.
    #expect(await weatherWaitUntil { await h.transport.sent.count == 3 })
    #expect(await h.transport.sent.map(\.attempt) == [0, 1, 2])
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .timedOut(botWasHeard: false))
  }

  // MARK: - Text ownership

  @Test
  func `a METAR request is settled only by that station's METAR, a TAF only by its TAF`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    _ = try await h.service.send(.metar(station: "KAUS"), to: F.bot)
    _ = await h.service.ingest(F.text(seq: 1, subject: .metarOrTAF, group: 1, index: 0, total: 1,
                                      text: "TAF KAUS 150520Z 1506/1612 17008KT P6SM SCT025"))
    _ = await h.service.ingest(F.text(seq: 2, subject: .metarOrTAF, group: 2, index: 0, total: 1,
                                      text: "METAR KATT 150551Z 16006KT 10SM CLR 29/21 A3001"))
    #expect(await h.service.pendingRequests().count == 1)
    var state = try #require(await h.service.state(for: F.botID))
    #expect(state.texts[1]?.request == nil)
    #expect(state.texts[2]?.request == nil)

    _ = await h.service.ingest(F.text(seq: 3, subject: .metarOrTAF, group: 3, index: 0, total: 1,
                                      text: "METAR KAUS 150551Z 17007KT 10SM FEW250 30/21 A3000"))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    state = try #require(await h.service.state(for: F.botID))
    #expect(state.texts[3]?.request == .metar(station: "KAUS"))

    h.clock.advance(by: 6)
    _ = try await h.service.send(.taf(station: "KAUS"), to: F.bot)
    _ = await h.service.ingest(F.text(seq: 4, subject: .metarOrTAF, group: 4, index: 0, total: 1,
                                      text: "KAUS 150651Z 17007KT 10SM FEW250 30/21 A3000"))
    #expect(await h.service.pendingRequests().count == 1, "a raw METAR is not the TAF")
    _ = await h.service.ingest(F.text(seq: 5, subject: .metarOrTAF, group: 5, index: 0, total: 1,
                                      text: "TAF AMD KAUS 150640Z 1507/1612 17008KT P6SM SCT025"))
    #expect(await weatherWaitUntil { settled.value.count == 2 })
    #expect(await h.service.state(for: F.botID)?.texts[5]?.request == .taf(station: "KAUS"))
  }

  @Test
  func `storm reports for another state neither settle nor become this phone's`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    _ = try await h.service.send(.stormReports(state: "TX"), to: F.bot)
    _ = await h.service.ingest(F.text(seq: 1, subject: .stormReports, group: 1, index: 0, total: 1,
                                      text: "0210 HAIL 3 SW TULSA TULSA OK 1.00 INCH"))
    #expect(await h.service.pendingRequests().count == 1)
    #expect(await h.service.state(for: F.botID)?.texts[1]?.request == nil)
    _ = await h.service.ingest(F.text(seq: 2, subject: .stormReports, group: 2, index: 0, total: 1,
                                      text: "0115 TSTM WND DMG 2 N AUSTIN TRAVIS TX"))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
  }

  /// The kit's own narrative (vectors `text_warning_narrative_chunk0` and `_chunk1`), for a
  /// storm warning over Travis County.
  @Test
  func `a warning narrative is claimed by its event and area, from the bot asked, whatever the chunk order`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    _ = await h.service.ingest(F.warning(seq: 1, identity: F.svw42))
    _ = try await h.service.send(.warningText(identity: "SV.W.EWX.42"), to: F.bot)

    _ = await h.service.ingest(F.text(seq: 2, group: 2, index: 0, total: 1,
                                      text: "FLASH FLOOD WARNING FOR CENTRAL BEXAR COUNTY UNTIL 300 AM CDT."))
    _ = await h.service.ingest(F.text(seq: 3, group: 3, index: 0, total: 1,
                                      text: "SEVERE THUNDERSTORM WARNING FOR NORTHERN KERR COUNTY UNTIL 200 AM CDT."))
    let chunk0 = "SEVERE THUNDERSTORM WARNING FOR NORTHEASTERN HAYS AND SOUTHWESTERN TRAVIS COUNTIES UNTIL 145 AM CDT. At 1257 AM a severe thunderstorm was near Dripping Sprin"
    let chunk1 = "gs, moving east at 40 mph. HAZARD: 60 mph gusts and quarter size hail. SOURCE: Radar indicated."
    _ = await h.service.ingest(F.text(seq: 9, group: 9, index: 0, total: 2, text: chunk0, bot: 0x0102))
    #expect(await h.service.pendingRequests().count == 1, "another bot cannot vouch for this bot's warning")

    _ = await h.service.ingest(F.text(seq: 24, group: 23, index: 1, total: 2, text: chunk1))
    #expect(await h.service.pendingRequests().count == 1, "the second chunk alone names nothing")
    _ = await h.service.ingest(F.text(seq: 23, group: 23, index: 0, total: 2, text: chunk0))
    #expect(await weatherWaitUntil { settled.value.count == 1 })

    let state = try #require(await h.service.state(for: F.botID))
    #expect(state.texts[23]?.request == .warningText(identity: "SV.W.EWX.42"))
    #expect(state.texts[2]?.request == nil)
    #expect(state.texts[3]?.request == nil)
  }
}

/// Spec revision 10: what the three new requests pair with, which of them the five-minute rule
/// applies to, and the channel traffic log.
@Suite("WeatherService revision 10 answers")
struct WeatherServiceRevisionTenTests {
  private typealias F = WeatherFixture

  private struct Harness {
    let transport: FakeWeatherTransport
    let clock: WeatherTestClock
    let service: WeatherService
    let events: AsyncStream<WeatherEvent>
    let traffic: InMemoryWeatherTrafficLogStore
  }

  private func makeHarness(
    channelRequests: Bool = false, logTraffic: Bool = false
  ) -> Harness {
    let transport = FakeWeatherTransport(channelRequestsSupported: channelRequests)
    let clock = WeatherTestClock()
    let traffic = InMemoryWeatherTrafficLogStore()
    let service = WeatherService(
      transport: transport,
      store: InMemoryWeatherStateStore(),
      trafficLogStore: logTraffic ? traffic : nil,
      now: { clock.now },
      stationIndex: { $0 == "KAUS" ? 202 : nil },
      tables: .shared
    )
    return Harness(
      transport: transport, clock: clock, service: service, events: service.events(),
      traffic: traffic)
  }

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

  // MARK: - `>part` (spec revision 10, §1.1)

  /// "It settles as answered when any asked-for index arrives from the bot asked." The other two
  /// packets are still on the air behind it, and a request that only settled on the last of them
  /// would time out every time one of the three was lost again.
  @Test
  func `a parts request settles on any index it asked for`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    _ = await h.service.ingest(F.areaSweep(seq: 1, group: 7, index: 0, total: 3, entries: [F.texasSweepEntry]))
    h.clock.advance(by: 30)
    let pending = try #require(
      try await h.service.send(.parts(group: 7, indexes: [1, 2], of: .areaSweep), to: F.bot))
    #expect(await h.transport.sent.map(\.text) == [">part 7 1,2"])

    // A packet of the same group the request did not name is the bot's ordinary transmission.
    _ = await h.service.ingest(F.areaSweep(seq: 2, group: 7, index: 0, total: 3, entries: [F.texasSweepEntry]))
    #expect(await h.service.pendingRequests().count == 1)

    _ = await h.service.ingest(F.areaSweep(seq: 3, group: 7, index: 2, total: 3, entries: [F.oklahomaSweepEntry]))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.0.id == pending.id)
    #expect(settled.value.first?.1 == .answered)
  }

  /// A `group` byte is one bot's counter; group 7 from another bot is a different answer.
  @Test
  func `another bot's group seven does not answer this bot's parts request`() async throws {
    let h = makeHarness()
    _ = try await h.service.send(.parts(group: 7, indexes: [1], of: .areaSweep), to: F.bot)
    _ = await h.service.ingest(
      F.areaSweep(seq: 1, group: 7, index: 1, total: 3, entries: [F.texasSweepEntry], bot: 0x0102))
    #expect(await h.service.pendingRequests().count == 1)
  }

  /// A text reply's missing chunk is the same ask and the same pairing (spec §8.1, §7C).
  @Test
  func `a parts request is answered by a text chunk of its group`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    _ = try await h.service.send(.parts(group: 23, indexes: [1], of: .text(subject: 0)), to: F.bot)
    #expect(await h.transport.sent.map(\.text) == [">part 23 1"])
    _ = await h.service.ingest(F.text(seq: 1, group: 23, index: 1, total: 2, text: "…moving east."))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .answered)
  }

  /// The five-minute rule must never hold `>part` back: the case it exists for is precisely an
  /// answer received in the last five minutes that arrived with holes in it.
  @Test
  func `a parts request is never refused by the five-minute rule`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.areaSweep(seq: 1, group: 7, index: 0, total: 3, entries: [F.texasSweepEntry]))
    h.clock.advance(by: 30)
    // The ordinary map ask is refused, as it should be: eight packets just went out.
    #expect(try await h.service.send(.areaSweep(includesAdvisories: false, states: []), to: F.bot) == nil)
    h.clock.advance(by: 6)
    #expect(try await h.service.send(.parts(group: 7, indexes: [1, 2], of: .areaSweep), to: F.bot) != nil)
  }

  // MARK: - Scoped sweeps (spec revision 10, §1.2)

  /// A sweep of Texas says nothing about Oklahoma, so the two taps are two answer slots.
  @Test
  func `two state selections are two answer slots and one selection is one`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.areaSweep(
      seq: 1, group: 7, index: 0, total: 1, entries: [F.texasSweepEntry], scope: [F.texasState]))
    h.clock.advance(by: 30)

    // The same selection, whatever order the picker handed it over in.
    #expect(try await h.service.send(.areaSweep(includesAdvisories: false, states: ["TX"]), to: F.bot) == nil)
    h.clock.advance(by: 6)
    #expect(try await h.service.send(.areaSweep(includesAdvisories: true, states: ["tx"]), to: F.bot) == nil,
            "both breadths share one slot, as they always have")
    h.clock.advance(by: 6)
    // A different selection is a different question.
    #expect(try await h.service.send(.areaSweep(includesAdvisories: false, states: ["OK"]), to: F.bot) != nil)
    h.clock.advance(by: 6)
    #expect(try await h.service.send(.areaSweep(includesAdvisories: false, states: []), to: F.bot) != nil,
            "the country is not a state selection either")
  }

  /// A packet of a scoped sweep that is not the one carrying the scope names no states, so it
  /// fills no slot: guessing would put a sweep of Texas in the national one.
  @Test
  func `a scoped packet with no scope entries fills no answer slot`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.areaSweep(
      seq: 1, group: 7, index: 1, total: 2, entries: [F.texasSweepEntry], isScoped: true))
    h.clock.advance(by: 30)
    #expect(try await h.service.send(.areaSweep(includesAdvisories: false, states: []), to: F.bot) != nil)
    h.clock.advance(by: 6)
    #expect(try await h.service.send(.areaSweep(includesAdvisories: false, states: ["TX"]), to: F.bot) != nil)
  }

  /// The tap's own sweep is marked as this phone's, scope and all.
  @Test
  func `a scoped sweep answers the selection that asked for it`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    let request = WeatherRequest.areaSweep(includesAdvisories: false, states: ["OK", "TX"])
    _ = try #require(try await h.service.send(request, to: F.bot))
    #expect(await h.transport.sent.map(\.text) == [">wmap OKTX"])
    _ = await h.service.ingest(F.areaSweep(
      seq: 1, group: 7, index: 0, total: 2, entries: [F.texasSweepEntry],
      scope: [F.texasState, F.oklahomaState]))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(await h.service.state(for: F.botID)?.newestAreaSweep?.request == request)
  }

  // MARK: - `>f <lat>,<lon>` (spec revision 10, §1.3)

  /// The bot picks the point, so the check is distance from what was asked about. A forecast for
  /// a point the bundle does not carry answers it outright — that is the case the ask exists for.
  @Test
  func `a coordinate forecast is answered by an unbundled point or one within eighty kilometres`() async throws {
    let h = makeHarness()
    let settled = collectSettlements(h.events)
    // Santa Fe, whose office had no bundled point at all in version 1 of the bundle.
    _ = try #require(
      try await h.service.send(.forecastAt(latitude: 35.687, longitude: -105.938), to: F.bot))
    #expect(await h.transport.sent.map(\.text) == [">f 35.687,-105.938"])

    // A bundled point on the other side of the country is not it.
    _ = await h.service.ingest(F.forecast(seq: 1, point: 102))
    #expect(await h.service.pendingRequests().count == 1)

    _ = await h.service.ingest(F.forecast(seq: 2, point: 0xFFFF))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .answered)

    // The coordinate asked about becomes the key the answer is filed under.
    let state = try #require(await h.service.state(for: F.botID))
    #expect(state.unbundledForecasts["35.687,-105.938"]?.requestedHere == true)
    #expect(state.unbundledForecasts[WeatherBotState.unbundledAskKey] == nil,
            "it is no longer somebody else's question")
  }

  /// The 80 km the point form already allows, measured from the coordinate rather than from an
  /// index — the bot answers with the nearest point it holds a forecast for.
  @Test
  func `a bundled point near the coordinate answers it and one far away does not`() throws {
    let tables = MeshWXTables.shared
    let point = try #require(tables.nearestPoint(toLat: 30.2672, lon: -97.7431))
    let near = MeshWXForecast(pointIndex: point.index, issuedMinutes: 0, firstPeriod: 0, periods: [])
    #expect(WeatherService.forecast(near, answersLatitude: 30.2672, longitude: -97.7431, tables: tables))
    #expect(!WeatherService.forecast(near, answersLatitude: 40.7128, longitude: -74.0060, tables: tables))
    // `0xFFFF` is the bundle saying it has no point there, which is the whole reason for the ask.
    let unbundled = MeshWXForecast(pointIndex: 0xFFFF, issuedMinutes: 0, firstPeriod: 0, periods: [])
    #expect(WeatherService.forecast(unbundled, answersLatitude: 40.7128, longitude: -74.0060, tables: tables))
  }

  // MARK: - Channel traffic (docs/MESHWX_UI.md §12)

  /// Every datagram on the weather slot: decodable or not, duplicate or not, live or backlog,
  /// somebody else's request or this phone's. That is the whole point of the screen — everywhere
  /// else "nothing arrived" and "eight copies arrived" look identical.
  @Test
  func `the traffic log records every datagram on the weather slot`() async throws {
    let h = makeHarness(channelRequests: true, logTraffic: true)
    await h.service.loadIfNeeded()

    let packet = F.areaSweep(seq: 1, group: 7, index: 0, total: 3, entries: [F.texasSweepEntry])
    _ = await h.service.ingest(try F.datagram(packet))
    // The bot's own resend of an unechoed packet.
    _ = await h.service.ingest(try F.datagram(packet))
    // Somebody else's request, flooded on the channel.
    _ = await h.service.ingest(try F.datagram(F.request(seq: 4, text: ">o KAUS")))
    // Bytes the codec cannot read: a sweep header with no sweep behind it.
    _ = await h.service.ingest(ChannelDatagram(
      channelIndex: 3, pathLength: 2, dataType: MeshWXWire.dataType,
      data: Data([0x11, 0x7A, 0x4C, 0xA0, 0x00]), snr: -3.5))
    // Drained from the radio's queue.
    _ = await h.service.ingest(
      try F.datagram(F.digest(seq: 9, entries: [])), isBacklog: true)
    // And this phone's own request.
    _ = try await h.service.send(.observations, to: F.bot)

    let log = await h.service.trafficLog()
    #expect(log.count == 6, "oldest first, nothing filtered out")
    #expect(log.map(\.direction) == [.received, .received, .received, .received, .received, .sent])
    #expect(log.map(\.isDuplicate) == [false, true, false, false, false, false])
    #expect(log.map(\.isBacklog) == [false, false, false, false, true, false])
    #expect(log[0].type == MeshWXMessageType.areaSweep.rawValue)
    #expect(log[0].botID == F.botID)
    #expect(log[0].snr == 6.5)
    #expect(log[0].pathLength == 0xFF)
    #expect(log[2].type == MeshWXMessageType.request.rawValue)
    // The header read and the body did not, which is the honest row: the four bytes that could be
    // read are shown and nothing else is claimed. `WeatherTrafficSummary` decodes the payload
    // again and calls it undecodable.
    #expect(log[3].type == MeshWXMessageType.areaSweep.rawValue)
    #expect(log[3].seq == 0x11)
    #expect(log[3].length == 5)
    #expect(log[3].hex == "117a4ca000")
    #expect(WeatherTrafficSummary.make(entry: log[3], tables: .shared).title == .undecodable)
    #expect(log[5].channelIndex == 3)
    #expect(log[5].snr == nil, "nothing this phone sent has a signal reading")

    // It persists beside the weather state, and "Clear" empties both.
    #expect(await h.traffic.entries.count == 6)
    await h.service.clearTrafficLog()
    #expect(await h.service.trafficLog().isEmpty)
    #expect(await h.traffic.entries.isEmpty)
  }

  /// The resend of a Request datagram is its own row: the same bytes went on the air twice, and a
  /// screen about airtime has to show both.
  @Test
  func `the resend of a request is a second row`() async throws {
    let transport = FakeWeatherTransport(channelRequestsSupported: true)
    let clock = WeatherTestClock()
    let traffic = InMemoryWeatherTrafficLogStore()
    let service = WeatherService(
      transport: transport, store: InMemoryWeatherStateStore(), trafficLogStore: traffic,
      now: { clock.now }, channelAnswerTimeout: .milliseconds(20), tables: .shared)
    _ = try await service.send(.digest, to: F.bot)
    #expect(await weatherWaitUntil { await transport.channelSent.count == 2 })
    #expect(await weatherWaitUntil { await service.trafficLog().count == 2 })
    let log = await service.trafficLog()
    #expect(log.allSatisfy { $0.direction == .sent })
    #expect(log[0].hex == log[1].hex, "the same bytes, which is what makes it a copy to the bot")
  }

  /// A datagram on another channel is not the weather channel's traffic and never reaches the log.
  @Test
  func `a datagram on a foreign slot is not logged`() async throws {
    let h = makeHarness(logTraffic: true)
    await h.transport.setSecret(Data(repeating: 0x33, count: 16), at: 5)
    _ = await h.service.ingest(try F.datagram(F.digest(seq: 1, entries: []), channelIndex: 5))
    #expect(await h.service.trafficLog().isEmpty)
  }

  /// A ring of three hundred: a window on the channel, not a record of it.
  @Test
  func `the log is a ring of three hundred`() {
    var log: [WeatherTrafficEntry] = []
    for step in 0..<305 {
      log = WeatherTrafficLog.appending(
        WeatherTrafficEntry(
          at: F.t0.addingTimeInterval(Double(step)), direction: .received, channelIndex: 3,
          length: 4, hex: "0\(step % 10)0a0b0c"),
        to: log)
    }
    #expect(WeatherTrafficLog.limit == 300)
    #expect(log.count == 300)
    #expect(log.first?.at == F.t0.addingTimeInterval(5), "the oldest five went")
    #expect(log.last?.at == F.t0.addingTimeInterval(304))
  }
}
