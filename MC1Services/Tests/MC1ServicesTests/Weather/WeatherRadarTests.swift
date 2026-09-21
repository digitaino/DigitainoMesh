import Foundation
@testable import MC1Services
import MeshCore
import MeshWX
import Testing

/// Radar (spec revision 11, §7D) through the non-drawing layers: what the reducer keeps, what
/// settles a `>radar`, what the five-minute rule counts as an answer, and what the channel
/// traffic row says a tile was.
@Suite("WeatherRadar state and pairing")
struct WeatherRadarTests {
  private typealias F = WeatherFixture

  // MARK: - The reducer

  @Test
  func `a tile is stored under the square of earth it covers`() {
    var state = WeatherBotState(botID: F.botID)
    let changes = WeatherStateReducer.apply(
      F.radar(seq: 1, wet: [(10, 10, 2)]), to: &state, receivedAt: F.t0)
    #expect(changes.contains(.radarStored(tile: F.austinTile, takenMinutes: F.t0Minutes)))
    #expect(state.radarTiles.count == 1)
    let stored = state.radarTiles[0]
    #expect(stored.tile == F.austinTile)
    #expect(stored.takenMinutes == F.t0Minutes)
    #expect(stored.receivedAt == F.t0)
    #expect(stored.source == .goesSatellite)
    #expect(stored.radar.level(row: 10, col: 10) == .moderate)
  }

  /// One picture per square, and the same or a newer `taken` replaces it. Same as well as newer
  /// because the bot re-sends a packet nothing echoed, and because the second copy may carry more
  /// than the first.
  @Test
  func `a newer picture of the same square replaces the one held`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.radar(seq: 1, wet: [(0, 0, 1)]), to: &state, receivedAt: F.t0)
    let changes = WeatherStateReducer.apply(
      F.radar(seq: 2, takenMinutes: F.t0Minutes + 15, wet: [(0, 0, 3)]),
      to: &state, receivedAt: F.t0.addingTimeInterval(900))
    #expect(changes.contains(.radarStored(tile: F.austinTile, takenMinutes: F.t0Minutes + 15)))
    #expect(state.radarTiles.count == 1)
    #expect(state.radarTiles[0].takenMinutes == F.t0Minutes + 15)
    #expect(state.radarTiles[0].radar.level(row: 0, col: 0) == .heavy)
  }

  /// A backlog drained from the radio's queue at connect must not repaint a live picture with one
  /// from an hour ago.
  @Test
  func `an older picture of the same square changes nothing`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(
      F.radar(seq: 1, takenMinutes: F.t0Minutes, wet: [(0, 0, 3)]), to: &state, receivedAt: F.t0)
    let changes = WeatherStateReducer.apply(
      F.radar(seq: 2, takenMinutes: F.t0Minutes - 30, wet: [(0, 0, 1)]),
      to: &state, receivedAt: F.t0.addingTimeInterval(5))
    #expect(changes.contains(.radarIgnoredOlder(tile: F.austinTile, takenMinutes: F.t0Minutes - 30)))
    #expect(state.radarTiles.count == 1)
    #expect(state.radarTiles[0].takenMinutes == F.t0Minutes)
    #expect(state.radarTiles[0].radar.level(row: 0, col: 0) == .heavy)
  }

  /// The bot cuts a tile coarse only when the fine one will not fit, so a phone that already has
  /// the fine picture of that minute keeps it: they are the same storm, and one of them is
  /// strictly more of it.
  @Test
  func `a coarse picture never replaces a fine one of the same minute`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.radar(seq: 1, wet: [(4, 4, 2)]), to: &state, receivedAt: F.t0)
    let changes = WeatherStateReducer.apply(
      F.radar(seq: 2, isCoarse: true, wet: [(2, 2, 2)]),
      to: &state, receivedAt: F.t0.addingTimeInterval(10))
    #expect(changes.contains(.radarIgnoredOlder(tile: F.austinTile, takenMinutes: F.t0Minutes)))
    #expect(state.radarTiles[0].radar.size == MeshWXWire.radarGrid)

    // The other way round it does replace: a coarse picture held, then the fine one of the same
    // minute, is the phone getting lucky the second time.
    var second = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(
      F.radar(seq: 1, isCoarse: true, wet: [(2, 2, 2)]), to: &second, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(
      F.radar(seq: 2, wet: [(4, 4, 2)]), to: &second, receivedAt: F.t0.addingTimeInterval(10))
    #expect(second.radarTiles[0].radar.size == MeshWXWire.radarGrid)
    // And a newer coarse picture replaces an older fine one: it is a later minute, which is what
    // the rule is about.
    _ = WeatherStateReducer.apply(
      F.radar(seq: 3, takenMinutes: F.t0Minutes + 15, isCoarse: true, wet: [(2, 2, 3)]),
      to: &second, receivedAt: F.t0.addingTimeInterval(900))
    #expect(second.radarTiles[0].radar.size == MeshWXWire.radarCoarseGrid)
    #expect(second.radarTiles[0].takenMinutes == F.t0Minutes + 15)
  }

  /// A different zoom over the same centre is a different square and gets a row of its own, which
  /// is what lets the radar screen say what it holds for each width.
  @Test
  func `each width is a square of its own`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.radar(seq: 1), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(
      F.radar(seq: 2, south: 28, west: -100, zoom: 2), to: &state, receivedAt: F.t0)
    #expect(state.radarTiles.count == 2)
    #expect(Set(state.radarTiles.map(\.tile.zoom)) == [0, 2])
  }

  /// Retention: nothing more than three hours behind the bot's own clock, and twelve at most.
  /// "The bot's clock" is the newest `taken` this bot has sent, which is the only clock of the
  /// bot's a radar packet carries.
  @Test
  func `tiles older than three hours on the bot's clock are dropped`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(
      F.radar(seq: 1, takenMinutes: F.t0Minutes - 200, south: 24, west: -100, zoom: 1),
      to: &state, receivedAt: F.t0)
    #expect(state.radarTiles.count == 1, "nothing to measure it against yet")
    _ = WeatherStateReducer.apply(
      F.radar(seq: 2, takenMinutes: F.t0Minutes), to: &state, receivedAt: F.t0)
    #expect(state.radarTiles.map(\.tile) == [F.austinTile], "200 minutes is past the three hours")
  }

  @Test
  func `only twelve tiles are kept, the oldest picture dropped`() {
    var state = WeatherBotState(botID: F.botID)
    for step in 0..<15 {
      _ = WeatherStateReducer.apply(
        F.radar(
          seq: UInt8(step + 1), takenMinutes: F.t0Minutes + UInt32(step),
          south: Int8(20 + step), west: -99, zoom: 0),
        to: &state, receivedAt: F.t0.addingTimeInterval(Double(step) * 60))
    }
    #expect(state.radarTiles.count == WeatherBotState.radarTileLimit)
    #expect(state.radarTiles.first?.takenMinutes == F.t0Minutes + 14, "newest first")
    #expect(state.radarTiles.last?.takenMinutes == F.t0Minutes + 3)
  }

  /// A file written before revision 11 holds no tiles, which is exactly right: nobody had asked
  /// for one. It must decode rather than take the whole state file down with it.
  @Test
  func `a state file written before radar decodes as holding none`() throws {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.radar(seq: 1, wet: [(1, 1, 1)]), to: &state, receivedAt: F.t0)
    let encoded = try JSONEncoder().encode(state)
    var object = try #require(
      try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["radarTiles"] != nil)
    object.removeValue(forKey: "radarTiles")
    let old = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder().decode(WeatherBotState.self, from: old).radarTiles.isEmpty)
    // And the whole value round-trips, cells and bounds included.
    #expect(try JSONDecoder().decode(WeatherBotState.self, from: encoded) == state)
  }

  // MARK: - Through the service

  private struct Harness {
    let transport: FakeWeatherTransport
    let clock: WeatherTestClock
    let service: WeatherService
    let events: AsyncStream<WeatherEvent>
  }

  private func makeHarness() -> Harness {
    let transport = FakeWeatherTransport(channelRequestsSupported: false)
    let clock = WeatherTestClock()
    let service = WeatherService(
      transport: transport,
      store: InMemoryWeatherStateStore(),
      now: { clock.now },
      answerTimeout: .seconds(15),
      stationIndex: { _ in nil },
      tables: .shared
    )
    return Harness(transport: transport, clock: clock, service: service, events: service.events())
  }

  private func settlements(
    _ events: AsyncStream<WeatherEvent>
  ) -> LockedValue<[(WeatherPendingRequest, WeatherRequestOutcome)]> {
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

  private var austinRadar: WeatherRequest {
    .radar(latitude: F.austinLatitude, longitude: F.austinLongitude, zoom: 0)
  }

  @Test
  func `a tile for the square asked about settles the request`() async throws {
    let h = makeHarness()
    let settled = settlements(h.events)
    _ = try await h.service.send(austinRadar, to: F.bot)
    #expect(await h.transport.sent.map(\.text) == [">radar 30.270,-97.740"])

    h.clock.advance(by: 2)
    _ = await h.service.ingest(F.radar(seq: 1, wet: [(20, 20, 1)]))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .answered)
    #expect(await h.service.pendingRequests().isEmpty)
    #expect(await h.service.state(for: F.botID)?.radarTiles.count == 1)
  }

  /// The lattice is fixed so that a tile is a tile: another bot's answer to somebody else's
  /// `>radar` over the same square is a picture of the same storm from the same mosaic.
  @Test
  func `another bot's tile of the same square settles it too`() async throws {
    let h = makeHarness()
    let settled = settlements(h.events)
    _ = try await h.service.send(austinRadar, to: F.bot)
    h.clock.advance(by: 2)
    _ = await h.service.ingest(F.radar(seq: 9, bot: 0x1234))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .answered)
  }

  /// A tile of a different square is somebody else's question and settles nothing — which is the
  /// whole reason the request knows its own tile before the answer comes.
  @Test
  func `a tile of another square settles nothing`() async throws {
    let h = makeHarness()
    let settled = settlements(h.events)
    _ = try await h.service.send(austinRadar, to: F.bot)
    h.clock.advance(by: 2)
    _ = await h.service.ingest(F.radar(seq: 1, south: 32, west: -98))
    #expect(await h.service.pendingRequests().count == 1)
    #expect(settled.value.isEmpty)
    // The wider tile over the same place is a different square as well.
    _ = await h.service.ingest(F.radar(seq: 2, south: 28, west: -100, zoom: 2))
    #expect(await h.service.pendingRequests().count == 1)
  }

  /// Spec revision 11, §7D: the refusal comes back under `x`, and it has to reach the `>radar`
  /// button rather than a `>rain` one.
  @Test
  func `a refusal under x settles the radar request and not the rain one`() async throws {
    let h = makeHarness()
    let settled = settlements(h.events)
    _ = try await h.service.send(austinRadar, to: F.bot)
    h.clock.advance(by: 2)
    _ = await h.service.ingest(F.notAvailable(seq: 1, letter: "r", reason: .noData))
    #expect(await h.service.pendingRequests().count == 1, "that is `>rain`")
    _ = await h.service.ingest(F.notAvailable(seq: 2, letter: "x", reason: .unsupported))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .notAvailable(.unsupported))
  }

  /// The three refusals the screen says different things for (spec revision 11, §3), each
  /// reaching the button as its own reason.
  @Test
  func `the radar refusal reasons arrive distinctly`() async throws {
    for (reason, expected) in [
      (MeshWXNotAvailableReason.noData, WeatherRadarRefusal.noPicture),
      (.unsupported, .unsupported),
      (.rateLimited, .sentRecently),
      (.unknownLocation, .unknownPlace)
    ] {
      let h = makeHarness()
      let settled = settlements(h.events)
      _ = try await h.service.send(austinRadar, to: F.bot)
      h.clock.advance(by: 2)
      _ = await h.service.ingest(F.notAvailable(seq: 1, letter: "x", reason: reason))
      #expect(await weatherWaitUntil { settled.value.count == 1 })
      guard case let .notAvailable(got)? = settled.value.first?.1 else {
        Issue.record("expected a refusal for \(reason)")
        return
      }
      #expect(WeatherRadarRefusal(reason: got) == expected)
    }
  }

  /// The five-minute rule, keyed by the tile and by no bot: pictures are made about every fifteen
  /// minutes, so asking again a minute later spends a packet on a refusal.
  @Test
  func `a tile received in the last five minutes is not asked for again`() async throws {
    let h = makeHarness()
    let settled = settlements(h.events)
    _ = await h.service.ingest(F.radar(seq: 1))
    h.clock.advance(by: 60)
    #expect(try await h.service.send(austinRadar, to: F.bot) == nil)
    #expect(await h.transport.sent.isEmpty)
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    guard case let .alreadyReceived(_, contentAsOf)? = settled.value.first?.1 else {
      Issue.record("expected the five-minute rule")
      return
    }
    #expect(contentAsOf == Date(unixMinutes: F.t0Minutes), "the time printed on the picture")

    // Past the window it goes out again — and a tile of another square was never in the way.
    h.clock.advance(by: 5 * 60)
    #expect(try await h.service.send(austinRadar, to: F.bot) != nil)
  }

  @Test
  func `a tile drained from the radio's queue fills no slot`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.radar(seq: 1), isBacklog: true)
    h.clock.advance(by: 60)
    // Backlog says nothing about what the bot would answer now, so the ask still goes out.
    #expect(try await h.service.send(austinRadar, to: F.bot) != nil)
    #expect(await h.service.state(for: F.botID)?.radarTiles.count == 1, "it is still a picture")
  }

  /// A copy of a packet already applied changes nothing and settles nothing, exactly as every
  /// other type's does (spec §2.3).
  @Test
  func `a duplicate tile is a duplicate`() async throws {
    let h = makeHarness()
    let message = F.radar(seq: 1, wet: [(3, 3, 1)])
    _ = await h.service.ingest(message)
    let changes = await h.service.ingest(message)
    #expect(changes.contains(.duplicate(seq: 1)))
    #expect(await h.service.state(for: F.botID)?.radarTiles.count == 1)
  }

  /// End to end over the radio, so the bytes are what the decoder sees rather than a value the
  /// test built: a 131-byte tile on the weather slot lands as a held picture.
  @Test
  func `a tile arriving as a datagram is decoded and held`() async throws {
    let h = makeHarness()
    let datagram = try F.datagram(F.radar(seq: 1, wet: [(16, 16, 3), (16, 17, 3)]))
    let changes = try #require(await h.service.ingest(datagram))
    #expect(changes.contains(.radarStored(tile: F.austinTile, takenMinutes: F.t0Minutes)))
    let stored = try #require(await h.service.state(for: F.botID)?.radarTiles.first)
    #expect(stored.radar.wetCellCount == 2)
    #expect(stored.source == .goesSatellite)
  }

  // MARK: - The channel traffic row

  @Test
  func `a traffic row says which square went past and how much of it is wet`() throws {
    let payload = try MeshWXEncoder.encode(F.radar(seq: 1, wet: [(0, 0, 1), (0, 1, 2), (9, 9, 3)]))
    let entry = WeatherTrafficEntry.received(
      payload, channelIndex: 3, dataType: MeshWXWire.dataType, snr: 6.5, pathLength: 0xFF,
      at: F.t0, isBacklog: false, isDuplicate: false)
    let summary = WeatherTrafficSummary.make(entry: entry, tables: .shared)
    #expect(summary.title == .radar)
    #expect(summary.detail == [.tile(south: 29, west: -99, zoom: 0), .wetCells(3)])
  }

  /// The refusal row carries `x`, so a reader can tell which of the two `r` requests it answers.
  @Test
  func `a radar refusal row carries the letter x`() throws {
    let payload = try MeshWXEncoder.encode(
      F.notAvailable(seq: 1, letter: "x", reason: .rateLimited))
    let entry = WeatherTrafficEntry.received(
      payload, channelIndex: 3, dataType: MeshWXWire.dataType, snr: nil, pathLength: nil,
      at: F.t0, isBacklog: false, isDuplicate: false)
    #expect(WeatherTrafficSummary.make(entry: entry, tables: .shared).title
      == .notAvailable(letter: "x"))
  }

  // MARK: - The cached screen

  @Test
  func `held tiles are listed as their own cache group`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.radar(seq: 1, wet: [(1, 1, 1)]), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(
      F.radar(seq: 2, south: 28, west: -100, zoom: 2), to: &state, receivedAt: F.t0)
    let cache = WeatherCache.make(
      states: [F.botID: state], readings: [], alerts: [], tables: .shared)
    let group = cache.groups.first { $0.group == .radarPictures }
    #expect(group?.count == 2)
    #expect(group?.items.allSatisfy { $0.destination == nil } == true)
    if case let .radar(tile)? = group?.items.first?.subject {
      #expect([0, 2].contains(tile.zoom))
    } else {
      Issue.record("expected a radar subject")
    }

    // And the channel history lists them beside everything else the channel carried.
    let heard = WeatherHeard.make(states: [F.botID: state], now: F.t0)
    #expect(heard.filter { if case .radar = $0.subject { true } else { false } }.count == 2)
  }
}
