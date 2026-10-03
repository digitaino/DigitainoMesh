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

  /// Spec revision 13, "State": a newer picture of the same square is another **frame**, kept
  /// beside the one held, newest first. The loop plays them.
  @Test
  func `a newer picture of the same square is another frame`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.radar(seq: 1, wet: [(0, 0, 1)]), to: &state, receivedAt: F.t0)
    let changes = WeatherStateReducer.apply(
      F.radar(seq: 2, takenMinutes: F.t0Minutes + 15, wet: [(0, 0, 3)]),
      to: &state, receivedAt: F.t0.addingTimeInterval(900))
    #expect(changes.contains(.radarStored(tile: F.austinTile, takenMinutes: F.t0Minutes + 15)))
    #expect(state.radarTiles.count == 2)
    #expect(state.radarTiles.map(\.takenMinutes) == [F.t0Minutes + 15, F.t0Minutes], "newest first")
    #expect(state.radarTiles[0].radar.level(row: 0, col: 0) == .heavy)
    #expect(state.radarTiles[1].radar.level(row: 0, col: 0) == .light)
  }

  /// An older picture is no longer nothing (revision 13): a loop's frames arrive oldest first,
  /// and a phone holding the newest asks for exactly these.
  @Test
  func `an older picture of the same square is kept as an older frame`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(
      F.radar(seq: 1, takenMinutes: F.t0Minutes, wet: [(0, 0, 3)]), to: &state, receivedAt: F.t0)
    let changes = WeatherStateReducer.apply(
      F.radar(seq: 2, takenMinutes: F.t0Minutes - 30, wet: [(0, 0, 1)]),
      to: &state, receivedAt: F.t0.addingTimeInterval(5))
    #expect(changes.contains(.radarStored(tile: F.austinTile, takenMinutes: F.t0Minutes - 30)))
    #expect(state.radarTiles.map(\.takenMinutes) == [F.t0Minutes, F.t0Minutes - 30])
    #expect(state.radarTiles[0].radar.level(row: 0, col: 0) == .heavy)
  }

  /// The same `taken` follows revision 11: the same picture again replaces what is held — a
  /// re-send, or a partial picture made whole — and is still one frame.
  @Test
  func `the same minute again replaces its frame and adds none`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.radar(seq: 1, wet: [(0, 0, 1)]), to: &state, receivedAt: F.t0)
    let changes = WeatherStateReducer.apply(
      F.radar(seq: 2, wet: [(0, 0, 2)]), to: &state, receivedAt: F.t0.addingTimeInterval(20))
    #expect(changes.contains(.radarStored(tile: F.austinTile, takenMinutes: F.t0Minutes)))
    #expect(state.radarTiles.count == 1)
    #expect(state.radarTiles[0].radar.level(row: 0, col: 0) == .moderate)
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
    #expect(state.radarTiles.count == 1)
    #expect(state.radarTiles[0].radar.size == MeshWXWire.radarGrid)

    // The other way round it does replace: a coarse picture held, then the fine one of the same
    // minute, is the phone getting lucky the second time.
    var second = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(
      F.radar(seq: 1, isCoarse: true, wet: [(2, 2, 2)]), to: &second, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(
      F.radar(seq: 2, wet: [(4, 4, 2)]), to: &second, receivedAt: F.t0.addingTimeInterval(10))
    #expect(second.radarTiles.count == 1)
    #expect(second.radarTiles[0].radar.size == MeshWXWire.radarGrid)
    // And a newer coarse picture is a frame of its own beside the older fine one: a later
    // minute, which is what a frame is.
    _ = WeatherStateReducer.apply(
      F.radar(seq: 3, takenMinutes: F.t0Minutes + 15, isCoarse: true, wet: [(2, 2, 3)]),
      to: &second, receivedAt: F.t0.addingTimeInterval(900))
    #expect(second.radarTiles.count == 2)
    #expect(second.radarTiles[0].radar.size == MeshWXWire.radarCoarseGrid)
    #expect(second.radarTiles[0].takenMinutes == F.t0Minutes + 15)
    #expect(second.radarTiles[1].radar.size == MeshWXWire.radarGrid)
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

  /// Retention: nothing more than three hours behind the bot's own clock, and forty at most.
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

    // A frame that old arriving now is gone as soon as it came, and says so.
    let changes = WeatherStateReducer.apply(
      F.radar(seq: 3, takenMinutes: F.t0Minutes - 200), to: &state, receivedAt: F.t0)
    #expect(changes.contains(.radarIgnoredOlder(tile: F.austinTile, takenMinutes: F.t0Minutes - 200)))
    #expect(state.radarTiles.count == 1)
  }

  @Test
  func `only forty frames are kept, the oldest picture dropped`() {
    #expect(WeatherBotState.radarTileLimit == 40)
    var state = WeatherBotState(botID: F.botID)
    for step in 0..<45 {
      _ = WeatherStateReducer.apply(
        F.radar(
          seq: UInt8(step + 1), takenMinutes: F.t0Minutes + UInt32(step),
          south: Double(20 + step % 9), west: -99, zoom: 0),
        to: &state, receivedAt: F.t0.addingTimeInterval(Double(step) * 60))
    }
    #expect(state.radarTiles.count == WeatherBotState.radarTileLimit)
    #expect(state.radarTiles.first?.takenMinutes == F.t0Minutes + 44, "newest first")
    #expect(state.radarTiles.last?.takenMinutes == F.t0Minutes + 5)
    // A full list takes no frame older than everything in it.
    let changes = WeatherStateReducer.apply(
      F.radar(seq: 99, takenMinutes: F.t0Minutes + 1), to: &state, receivedAt: F.t0)
    #expect(changes.contains(.radarIgnoredOlder(tile: F.austinTile, takenMinutes: F.t0Minutes + 1)))
  }

  /// A stored state written before revision 13 has whole numbers where the edges are now
  /// `Double` and a small integer where the zoom is now `Int`. It decodes unchanged.
  @Test
  func `a radar tile saved before revision 13 decodes unchanged`() throws {
    let cells = [Int](repeating: 0, count: 256).map(String.init).joined(separator: ",")
    let old = Data("""
      {"tile":{"south":29,"west":-99,"zoom":0},
       "radar":{"takenMinutes":29832458,"south":29,"west":-99,"zoom":0,"product":1,
                "isCoarse":true,"bounds":{"row0":0,"row1":9,"col0":0,"col1":15},"cells":[\(cells)]},
       "receivedAt":780000000,"source":1}
      """.utf8)
    let stored = try JSONDecoder().decode(WeatherStoredRadarTile.self, from: old)
    #expect(stored.tile == F.austinTile)
    #expect(stored.radar.tile == F.austinTile)
    #expect(stored.radar.zoom == 0)
    #expect(stored.radar.south == 29 && stored.radar.west == -99)
    #expect(stored.radar.isCoarse)
    #expect(stored.radar.bounds == MeshWXRadarBounds(row0: 0, row1: 9, col0: 0, col1: 15))
    #expect(stored.takenMinutes == 29_832_458)
    #expect(stored.source == .goesSatellite)
  }

  /// A state saved by the first build of revision 13 may hold a detail frame: zoom −1, half-degree
  /// edges. The detail level was removed the same day (docs/MESHWX_REV13.md §2) and the owner's
  /// phone has such a state, so it must still load: the detail frame is dropped when the state is
  /// read, and every other frame is kept.
  @Test
  func `a detail frame saved by the first revision 13 build is dropped and the rest kept`() throws {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.radar(seq: 1, wet: [(1, 1, 1)]), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(
      F.radar(seq: 2, takenMinutes: F.t0Minutes - 15, south: 28, west: -100, zoom: 2),
      to: &state, receivedAt: F.t0)
    #expect(state.radarTiles.count == 2)

    // That build's frame of Austin's one-degree square, the newest picture held, written exactly
    // as it wrote one: half-degree edges and zoom −1 in both the square and the picture.
    let encoded = try JSONEncoder().encode(state)
    var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var frames = try #require(object["radarTiles"] as? [[String: Any]])
    var detail = try #require(frames.first)
    var radar = try #require(detail["radar"] as? [String: Any])
    detail["tile"] = ["south": 30.5, "west": -97.5, "zoom": -1]
    radar["south"] = 30.5
    radar["west"] = -97.5
    radar["zoom"] = -1
    radar["takenMinutes"] = Int(F.t0Minutes) + 15
    detail["radar"] = radar
    frames.insert(detail, at: 0)
    object["radarTiles"] = frames
    let saved = try JSONSerialization.data(withJSONObject: object)

    // The frame itself still decodes: the edges are `Double` and the zoom `Int` for this.
    let lone = try JSONDecoder().decode(
      WeatherStoredRadarTile.self, from: JSONSerialization.data(withJSONObject: detail))
    #expect(lone.tile == MeshWXRadarTile(south: 30.5, west: -97.5, zoom: -1))
    #expect(!lone.isOnWireLattice)

    let loaded = try JSONDecoder().decode(WeatherBotState.self, from: saved)
    #expect(loaded.radarTiles == state.radarTiles, "the detail frame dropped, both others kept")
    #expect(loaded.radarTiles.allSatisfy { $0.isOnWireLattice })

    // Retention drops one too, before it can set the bot's clock: five hours newer than the rest,
    // it would otherwise have aged both of them out.
    var later = lone
    later.radar.takenMinutes = F.t0Minutes + 300
    #expect(WeatherStateReducer.retainedRadarTiles(state.radarTiles + [later]) == state.radarTiles)
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

  // MARK: - Revision 13: loops through the service

  /// Spec revision 13, §7D.4: a loop lists the pictures held and is settled by the first frame
  /// that comes back; the rest keep landing as frames of their own. A tile received a minute ago
  /// does not hold a loop back — the loop asks for what the phone does not have.
  @Test
  func `a loop goes out listing what is held and the first frame settles it`() async throws {
    let h = makeHarness()
    let settled = settlements(h.events)
    _ = await h.service.ingest(F.radar(seq: 1))
    h.clock.advance(by: 60)
    let held = WeatherRadarLoop.make(
      tile: F.austinTile, tiles: try #require(await h.service.state(for: F.botID)?.radarTiles),
      now: h.clock.now).held
    #expect(held == [F.t0Minutes])
    let loop = WeatherRequest.radarLoop(
      latitude: F.austinLatitude, longitude: F.austinLongitude, zoom: 0, held: held)
    #expect(try await h.service.send(loop, to: F.bot) != nil)
    #expect(await h.transport.sent.map(\.text) == [">radar 30.270,-97.740 loop 0145"])

    h.clock.advance(by: 2)
    _ = await h.service.ingest(F.radar(seq: 2, takenMinutes: F.t0Minutes - 45))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.1 == .answered)
    _ = await h.service.ingest(F.radar(seq: 3, takenMinutes: F.t0Minutes - 30))
    _ = await h.service.ingest(F.radar(seq: 4, takenMinutes: F.t0Minutes - 15))
    #expect(await h.service.state(for: F.botID)?.radarTiles.count == 4)
  }

  /// Everything was left out — held, or sent in the last five minutes — and the bot says so under
  /// `x`, reason 4. The refusal reaches the loop's own button.
  @Test
  func `a refusal under x reaches the loop`() async throws {
    let h = makeHarness()
    let settled = settlements(h.events)
    let loop = WeatherRequest.radarLoop(
      latitude: F.austinLatitude, longitude: F.austinLongitude, zoom: 0, held: [F.t0Minutes])
    _ = try await h.service.send(loop, to: F.bot)
    h.clock.advance(by: 2)
    _ = await h.service.ingest(F.notAvailable(seq: 1, letter: "x", reason: .rateLimited))
    #expect(await weatherWaitUntil { settled.value.count == 1 })
    #expect(settled.value.first?.0.request == loop)
    #expect(settled.value.first?.1 == .notAvailable(.rateLimited))
  }

  /// An older frame off somebody's loop is not "the newest picture the bot has", which is what a
  /// single `>radar` asks for: it fills no five-minute slot.
  @Test
  func `an older frame is not a fresh answer to a single picture`() async throws {
    let h = makeHarness()
    _ = await h.service.ingest(F.radar(seq: 1))
    h.clock.advance(by: 6 * 60)
    _ = await h.service.ingest(F.radar(seq: 2, takenMinutes: F.t0Minutes - 15))
    h.clock.advance(by: 30)
    #expect(try await h.service.send(austinRadar, to: F.bot) != nil)
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
    if case let .radar(tile, _)? = group?.items.first?.subject {
      #expect([0, 2].contains(tile.zoom))
    } else {
      Issue.record("expected a radar subject")
    }

    // And the channel history lists them beside everything else the channel carried.
    let heard = WeatherHeard.make(states: [F.botID: state], now: F.t0)
    #expect(heard.filter { if case .radar = $0.subject { true } else { false } }.count == 2)
  }

  /// Spec revision 13, §3: still one row per square, at its newest picture, with the count of
  /// pictures held; the channel history lists every frame with its own time.
  @Test
  func `a square with several frames is one cached row that counts them`() {
    var state = WeatherBotState(botID: F.botID)
    for (seq, back) in [(1, 30), (2, 15), (3, 0)] {
      _ = WeatherStateReducer.apply(
        F.radar(seq: UInt8(seq), takenMinutes: F.t0Minutes - UInt32(back)),
        to: &state, receivedAt: F.t0.addingTimeInterval(Double(seq)))
    }
    _ = WeatherStateReducer.apply(
      F.radar(seq: 4, south: 28, west: -100, zoom: 2), to: &state, receivedAt: F.t0)
    let cache = WeatherCache.make(states: [F.botID: state], readings: [], alerts: [], tables: .shared)
    let rows = cache.groups.first { $0.group == .radarPictures }?.items ?? []
    #expect(rows.count == 2)
    let austin = rows.first { if case let .radar(tile, _) = $0.subject { tile == F.austinTile } else { false } }
    #expect(austin?.subject == .radar(tile: F.austinTile, frames: 3))
    #expect(austin?.contentAt == Date(unixMinutes: F.t0Minutes), "the newest picture's time")
    let wide = rows.first { $0.id != austin?.id }
    #expect(wide?.subject == .radar(tile: MeshWXRadarTile(south: 28, west: -100, zoom: 2), frames: 1))

    let heard = WeatherHeard.make(states: [F.botID: state], now: F.t0)
    let frames = heard.filter { if case .radar = $0.subject { true } else { false } }
    #expect(frames.count == 4)
    #expect(Set(frames.map(\.id)).count == 4)
  }
}
