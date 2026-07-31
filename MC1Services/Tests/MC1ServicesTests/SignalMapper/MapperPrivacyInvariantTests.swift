import Foundation
@testable import MC1Services
import MeshCore
import SurveyKit
import SwiftData
import Testing

/// The privacy rules of docs/SIGNAL_MAPPER_V2.md §3, written as assertions rather than as
/// prose somebody has to remember.
///
/// These are deliberately *structural* tests. Behavioural coverage of the capture engine
/// lives elsewhere; what is checked here is that the shapes themselves cannot express the
/// thing we promised not to store. A behavioural test says "we did not put a coordinate in
/// this time". A structural one says there is no field to put one in — which is the claim
/// the App Store privacy label rests on, and the one that has to survive somebody adding a
/// column in a hurry two years from now.
@Suite("Signal mapper privacy invariants")
struct MapperPrivacyInvariantTests {
  // MARK: - No coordinates anywhere in the stored shape

  /// Names that would be a coordinate under any spelling anyone actually uses. Matched
  /// case-insensitively against every property label reachable from a populated instance.
  private static let coordinateNameFragments = [
    "latitude", "longitude", "coordinate", "location", "geo",
    "lat", "lng", "lon", "position", "gps", "altitude", "bearing", "heading"
  ]

  /// Whether a property label reads as a coordinate.
  ///
  /// Two rules rather than plain substring matching, because substring matching alone
  /// cannot tell `latest` from `lat` — and `latest` is a real, allowed field. Long names are
  /// matched as substrings (`homeLatitude` must fail); the short abbreviations only match as
  /// whole camel-case words, so `lat` catches `lat`, `latDegrees` and `startLat` while
  /// leaving `latest` alone.
  private func readsAsCoordinate(_ label: String) -> Bool {
    let lowered = label.lowercased()
    let words = Self.camelCaseWords(of: label).map { $0.lowercased() }
    for fragment in Self.coordinateNameFragments {
      if fragment.count > 3, lowered.contains(fragment) { return true }
      if words.contains(fragment) { return true }
    }
    return false
  }

  private static func camelCaseWords(of label: String) -> [String] {
    var words: [String] = []
    var current = ""
    for character in label {
      if character.isUppercase, !current.isEmpty {
        words.append(current)
        current = ""
      }
      current.append(character)
    }
    if !current.isEmpty { words.append(current) }
    return words
  }

  /// Every `(label, value)` reachable from a value, walking into nested structs, optionals,
  /// arrays and dictionary values so a coordinate cannot hide one level down.
  private func reachableProperties(of subject: Any, depth: Int = 0) -> [(label: String, value: Any)] {
    guard depth < 6 else { return [] }
    let mirror = Mirror(reflecting: subject)
    var found: [(label: String, value: Any)] = []

    for child in mirror.children {
      let label = child.label ?? ""
      if !label.isEmpty, !label.hasPrefix(".") {
        found.append((label, child.value))
      }
      // Unwrap one level of Optional so `Double?` is walked as `Double`.
      let value: Any = if let unwrapped = Mirror(reflecting: child.value).children.first,
                          Mirror(reflecting: child.value).displayStyle == .optional {
        unwrapped.value
      } else {
        child.value
      }
      found += reachableProperties(of: value, depth: depth + 1)
    }
    return found
  }

  /// A populated DTO — every optional filled, both JSON maps non-empty — so reflection sees
  /// the whole shape rather than the parts a default instance happens to inhabit.
  private func populatedDTO() throws -> MapperCellObservationDTO {
    let cell = try #require(MapperFixtureLocation.cell(MapperFixtureLocation.plaza))
    let heard = Date(timeIntervalSince1970: 1_753_000_000)
    return MapperCellObservationDTO(
      cellRaw: cell.rawValue,
      day: "2025-07-20",
      packetCount: 12,
      activePacketCount: 0,
      passivePacketCount: 12,
      probesSent: 0,
      rxCount: 9,
      txHeardCount: 2,
      ackCount: 1,
      stationaryObservationCount: 4,
      rttMsSum: 1200,
      rttSampleCount: 1,
      snrSum: 48,
      snrCount: 8,
      minSnr: -3,
      maxSnr: 11,
      txSnrSum: 5,
      txSnrCount: 1,
      rssiSum: -640,
      rssiCount: 8,
      floodCount: 7,
      directCount: 5,
      earliest: heard,
      latest: heard.addingTimeInterval(600),
      hopHistogram: [0: 4, 2: 5],
      repeaters: [
        "0C13": MapperRepeaterStats(
          id: "0C13",
          rxPacketCount: 6,
          txPacketCount: 1,
          rxSnrSum: 30,
          rxSnrCount: 5,
          rssiSum: -300,
          rssiCount: 5,
          firstHeard: heard,
          lastHeard: heard.addingTimeInterval(600)
        )
      ]
    )
  }

  @Test
  func `The name test itself catches coordinates and spares the fields we do keep`() {
    // A guard on the guard: a matcher that never fires would make every assertion below
    // vacuous, and one that fires too eagerly would fail on `latest`.
    #expect(readsAsCoordinate("latitude"))
    #expect(readsAsCoordinate("longitude"))
    #expect(readsAsCoordinate("lat"))
    #expect(readsAsCoordinate("lon"))
    #expect(readsAsCoordinate("lng"))
    #expect(readsAsCoordinate("startLat"))
    #expect(readsAsCoordinate("homeLatitude"))
    #expect(readsAsCoordinate("coordinate"))
    #expect(readsAsCoordinate("lastKnownPosition"))
    #expect(readsAsCoordinate("gps"))

    #expect(!readsAsCoordinate("latest"))
    #expect(!readsAsCoordinate("earliest"))
    #expect(!readsAsCoordinate("day"))
    #expect(!readsAsCoordinate("cellRaw"))
    #expect(!readsAsCoordinate("packetCount"))
  }

  @Test
  func `No field reachable from a stored observation DTO is named like a coordinate`() throws {
    let offenders = try reachableProperties(of: populatedDTO())
      .map(\.label)
      .filter(readsAsCoordinate)

    #expect(offenders.isEmpty, "coordinate-shaped fields on MapperCellObservationDTO: \(offenders)")
  }

  @Test
  func `No stored property on the SwiftData model is named like a coordinate`() async throws {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)
    try await store.upsertMapperCellObservations([populatedDTO()])

    // Asked of the schema rather than of an instance: a `@Model` class reflects its backing
    // store, and the schema is the definitive list of what is actually written to disk.
    let entity = try #require(
      PersistenceStore.schema.entities.first { $0.name == "MapperCellObservation" }
    )
    let offenders = entity.properties.map(\.name).filter(readsAsCoordinate)

    #expect(offenders.isEmpty, "coordinate-shaped columns on MapperCellObservation: \(offenders)")
  }

  @Test
  func `No number on a row captured at a known place is that place's coordinate`() async throws {
    // The belt to the name test's braces: a column called `alpha`/`beta` holding 37.77 and
    // -122.41 would pass every name check and still be a location. So this one runs a real
    // capture at a known coordinate and then hunts the resulting row for that coordinate,
    // whatever it might be called.
    //
    // Names alone would not catch it, and a hand-built fixture would not either — the value
    // has to have gone *through* the engine to prove the engine did not keep it.
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)
    let source = ScriptedRxEntrySource()
    let plaza = MapperFixtureLocation.plaza

    let engine = SignalMapperCaptureEngine(
      source: source,
      store: store,
      fixProvider: StubMapperFixProvider(mapperFix(plaza, at: clock.now)),
      tuningProvider: StaticMapperTuningProvider(
        MapperTuning(flushIntervalSeconds: 3600, flushEntryCount: 10000)
      ),
      anchorSeedProvider: StaticMapperAnchorSeedProvider(),
      now: clock.provider
    )

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now, snr: 6, rssi: -80))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()
    await engine.stop()

    let row = try #require(try await store.fetchMapperCellObservations().first)
    let doubles = reachableProperties(of: row).compactMap { $0.value as? Double }
    #expect(!doubles.isEmpty, "reflection found no numbers at all, which would make this vacuous")

    // 0.01° is roughly a kilometer — far coarser than the res-9 cell the row legitimately
    // holds, so this cannot be satisfied by a rounded-off coordinate either.
    #expect(!doubles.contains { abs($0 - plaza.latitude) < 0.01 })
    #expect(!doubles.contains { abs($0 - plaza.longitude) < 0.01 })
    // swiftformat:disable:next preferKeyPath
    #expect(doubles.allSatisfy { $0.isFinite }) // `allSatisfy(\.isFinite)` breaks the #expect macro

    // The JSON columns too, since reflection over the decoded DTO would not see a stray
    // number that only exists in the serialized form.
    let json = String(decoding: MapperCellObservationDTO.encode(repeaters: row.repeaters), as: UTF8.self)
      + String(decoding: MapperCellObservationDTO.encode(hopHistogram: row.hopHistogram), as: UTF8.self)
    #expect(!json.contains("37.77"))
    #expect(!json.contains("-122.41"))
  }

  @Test
  func `The H3 cell a row stores is coarse enough to be the whole location claim`() throws {
    let dto = try populatedDTO()
    let cell = try #require(dto.cell)

    // Res 9 by construction, and the row carries the cell index only — the coordinate that
    // produced it was bucketed inside the engine and never left it (§3.1).
    #expect(cell.resolution == SurveyGrid.baseResolution)
    #expect(SurveyGrid.averageEdgeMeters(resolution: cell.resolution) > 100)
  }

  // MARK: - Message identity never reaches a cell

  @Test
  func `A heard repeat carrying a message ID leaves no trace of it in the stored row`() async throws {
    // `HeardRepeatEvent` carries the `messageID` of *our own* message — the event has to, to
    // correlate the echo — and the row it produces is a claim about radio coverage that must
    // not identify which message proved it. Currently true by discipline; this is the test
    // that keeps it true.
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)
    let source = ScriptedRxEntrySource()
    let txHeard = ScriptedTxHeardSource()
    let messageID = UUID()

    let engine = SignalMapperCaptureEngine(
      source: source,
      txHeardSource: txHeard,
      store: store,
      fixProvider: StubMapperFixProvider(mapperFix(at: clock.now)),
      tuningProvider: StaticMapperTuningProvider(
        MapperTuning(flushIntervalSeconds: 3600, flushEntryCount: 10000)
      ),
      anchorSeedProvider: StaticMapperAnchorSeedProvider(),
      now: clock.provider
    )

    await engine.start()
    txHeard.send(mapperHeardRepeat(messageID: messageID, receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()
    await engine.stop()

    let row = try #require(try await store.fetchMapperCellObservations().first)
    #expect(row.txHeardCount == 1)

    // Every string anywhere in the row, checked against the ID in both of the forms it
    // could plausibly be written in.
    let strings = reachableProperties(of: row).compactMap { $0.value as? String }
    let uppercased = messageID.uuidString
    let lowercased = uppercased.lowercased()
    #expect(!strings.contains { $0.localizedCaseInsensitiveContains(uppercased) })
    #expect(!strings.contains { $0.contains(lowercased) })

    // And the row as it actually sits on disk, JSON columns included, in case the ID were
    // hiding somewhere reflection over the DTO does not reach.
    let encoded = MapperCellObservationDTO.encode(repeaters: row.repeaters)
    let json = String(decoding: encoded, as: UTF8.self)
    #expect(!json.localizedCaseInsensitiveContains(uppercased))
    #expect(!json.isEmpty, "the repeater column must be non-empty for this check to mean anything")
  }

  @Test
  func `A repeater on a stored row is a short path hash, never a pubkey`() async throws {
    // `SurveySample.RepeaterSighting.id` used to be documented as "full 64-char pubkey when
    // known"; the mapper only ever writes the short prefix a packet's path carries, and a
    // 64-char identity in a cell observation would be a precise claim about which node was
    // near a person.
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)
    let source = ScriptedRxEntrySource()

    let engine = SignalMapperCaptureEngine(
      source: source,
      store: store,
      fixProvider: StubMapperFixProvider(mapperFix(at: clock.now)),
      tuningProvider: StaticMapperTuningProvider(
        MapperTuning(flushIntervalSeconds: 3600, flushEntryCount: 10000)
      ),
      anchorSeedProvider: StaticMapperAnchorSeedProvider(),
      now: clock.provider
    )

    await engine.start()
    source.send(mapperRxEntry(
      payload: Data([0x01]),
      receivedAt: clock.now,
      hashSize: 1,
      pathNodes: [0x42, 0x0C]
    ))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()
    await engine.stop()

    let row = try #require(try await store.fetchMapperCellObservations().first)
    #expect(!row.repeaters.isEmpty)
    for id in row.repeaters.keys {
      #expect(id.count <= 12, "repeater identity '\(id)' is longer than a path-hash prefix")
    }
  }

  // MARK: - The wire is not reachable by accident

  @Test
  func `The stored observation types expose no serialization of their own`() throws {
    // `MapperCellObservationDTO` and `MapperRepeaterStats` are deliberately not `Codable`,
    // so `JSONEncoder().encode(rows)` does not compile and M2 has to write a wire type on
    // purpose. That is a compile-time property and cannot be asserted at runtime directly —
    // what *is* checkable is that the only codec is the private column one, and that it
    // round-trips.
    let dto: Any = try populatedDTO()
    #expect(!(dto is any Encodable))
    #expect(!(dto is any Decodable))

    let stats: Any = try #require(try populatedDTO().repeaters.values.first)
    #expect(!(stats is any Encodable))
    #expect(!(stats is any Decodable))
  }

  @Test
  func `The private column codec still round-trips the repeater map`() throws {
    let original = try populatedDTO().repeaters
    let decoded = MapperCellObservationDTO.decodeRepeaters(
      MapperCellObservationDTO.encode(repeaters: original)
    )

    #expect(decoded == original)
  }
}
