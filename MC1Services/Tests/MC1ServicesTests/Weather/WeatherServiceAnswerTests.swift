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
