import Foundation
@testable import MC1Services
import Testing

@Suite("Benchmark history store")
struct BenchmarkHistoryStoreTests {
  private let tower = benchmarkTarget("Tower", prefix: [0x0A])
  private let ridge = benchmarkTarget("Ridge", prefix: [0x0C])
  private let barn = benchmarkTarget("Barn", prefix: [0x1F])
  private let savedAt = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeStore(radioID: UUID) async throws -> (BenchmarkHistoryStore, PersistenceStore) {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let dataStore = PersistenceStore(modelContainer: container)
    return (store(dataStore: dataStore, radioID: radioID, savedAt: savedAt), dataStore)
  }

  /// A second view of the same store, saving at a later instant — one save per store, which
  /// is how a test spells "the user ran the tool again".
  private func store(
    dataStore: any TracePathPersisting,
    radioID: UUID,
    savedAt: Date
  ) -> BenchmarkHistoryStore {
    BenchmarkHistoryStore(dataStore: dataStore, radioID: radioID, now: { savedAt })
  }

  private func result(
    target: BenchmarkTarget,
    probes: [(rtt: Int, snrs: [Double])]
  ) -> BenchmarkTargetResult {
    BenchmarkTargetResult(
      target: target,
      outcomes: probes.enumerated().map { index, probe in
        BenchmarkFixtures.outcome(
          sequence: index + 1,
          durationMs: probe.rtt,
          intermediateSNRs: probe.snrs
        )
      },
      isComplete: true
    )
  }

  // MARK: - Round trip

  @Test
  func `A saved run reads back as one group with one path per target`() async throws {
    let radioID = UUID()
    let (store, _) = try await makeStore(radioID: radioID)

    try await store.save(
      results: [
        result(target: ridge, probes: [(400, [9, 4, 6]), (600, [9, 6, 8])]),
        result(target: barn, probes: [(800, [9, 2, 3])]),
      ],
      testRepeater: tower,
      note: "stock whip antenna",
      traceHashSize: 1
    )

    let groups = try await store.runGroups()
    let group = try #require(groups.first)

    #expect(groups.count == 1)
    #expect(group.note == "stock whip antenna")
    #expect(group.paths.count == 2)
    #expect(group.testRepeaterName == "Tower")
    #expect(Set(group.targetNames) == ["Ridge", "Barn"])
    // (400 + 600) / 2 = 500 for Ridge, 800 for Barn → group mean 650.
    #expect(group.averageRTT == 650)
    #expect(group.averageSuccessRate == 100)
  }

  @Test
  func `Hop SNRs survive the round trip so comparison reads the same legs`() async throws {
    let radioID = UUID()
    let (store, _) = try await makeStore(radioID: radioID)

    try await store.save(
      results: [result(target: ridge, probes: [(400, [9, 4, 6]), (600, [9, 6, 8])])],
      testRepeater: tower,
      note: "before",
      traceHashSize: 1
    )

    let path = try #require(try await store.benchmarkPaths().first)

    #expect(path.runs.count == 2)
    #expect(path.runs.map(\.hopsSNR) == [[9, 4, 6], [9, 6, 8]])
    #expect(BenchmarkScoring.directionalSNR(runs: path.runs, hopIndex: BenchmarkScoring.txHopIndex) == 5)
    #expect(BenchmarkScoring.directionalSNR(runs: path.runs, hopIndex: BenchmarkScoring.rxHopIndex) == 7)
  }

  @Test
  func `The stored path is the probed path, hop-width aware`() async throws {
    let radioID = UUID()
    let (store, _) = try await makeStore(radioID: radioID)

    try await store.save(
      results: [result(target: ridge, probes: [(400, [9, 4, 6])])],
      testRepeater: tower,
      note: "wide",
      traceHashSize: 2
    )

    let path = try #require(try await store.benchmarkPaths().first)

    #expect(path.hashSize == 2)
    #expect(path.pathBytes == Data([0x0A, 0xEE, 0x0C, 0xEE, 0x0A, 0xEE]))
  }

  // MARK: - Filtering and scoping

  @Test
  func `Hand-saved trace paths are never returned as benchmark history`() async throws {
    let radioID = UUID()
    let (store, dataStore) = try await makeStore(radioID: radioID)

    _ = try await dataStore.createSavedTracePath(
      radioID: radioID,
      name: "Tower → Barn",
      pathBytes: Data([0x0A, 0x1F]),
      hashSize: 1,
      initialRun: nil
    )
    try await store.save(
      results: [result(target: ridge, probes: [(400, [9, 4, 6])])],
      testRepeater: tower,
      note: "mine",
      traceHashSize: 1
    )

    let paths = try await store.benchmarkPaths()
    #expect(paths.count == 1)
    #expect(paths.allSatisfy { BenchmarkNaming.isBenchmarkPath($0.name) })
  }

  @Test
  func `History is scoped to the radio it was measured on`() async throws {
    let radioID = UUID()
    let (store, dataStore) = try await makeStore(radioID: radioID)

    _ = try await dataStore.createSavedTracePath(
      radioID: UUID(),
      name: BenchmarkNaming.pathName(note: "elsewhere", testRepeater: "Other", target: "Far"),
      pathBytes: Data([0x01]),
      hashSize: 1,
      initialRun: nil
    )
    try await store.save(
      results: [result(target: ridge, probes: [(400, [9, 4, 6])])],
      testRepeater: tower,
      note: "here",
      traceHashSize: 1
    )

    let groups = try await store.runGroups()
    #expect(groups.map(\.note) == ["here"])
  }

  @Test
  func `Two saves without a note are two runs, not one merged group`() async throws {
    let radioID = UUID()
    let (first, dataStore) = try await makeStore(radioID: radioID)
    let second = store(
      dataStore: dataStore,
      radioID: radioID,
      savedAt: savedAt.addingTimeInterval(600)
    )

    try await first.save(
      results: [result(target: ridge, probes: [(400, [9, 4, 6])])],
      testRepeater: tower,
      note: "",
      traceHashSize: 1
    )
    try await second.save(
      results: [result(target: ridge, probes: [(900, [9, 1, 2])])],
      testRepeater: tower,
      note: "",
      traceHashSize: 1
    )

    let groups = try await first.runGroups()
    let allNoteless = groups.allSatisfy(\.note.isEmpty)
    #expect(groups.count == 2)
    #expect(allNoteless)
    #expect(groups.allSatisfy { $0.paths.count == 1 })
    // Newest first, and each group's average is its own run's.
    #expect(groups.map(\.averageRTT) == [900, 400])
  }

  @Test
  func `Deleting one noteless run leaves the other's measurements alone`() async throws {
    let radioID = UUID()
    let (first, dataStore) = try await makeStore(radioID: radioID)
    let second = store(
      dataStore: dataStore,
      radioID: radioID,
      savedAt: savedAt.addingTimeInterval(600)
    )

    try await first.save(
      results: [result(target: ridge, probes: [(400, [9, 4, 6])])],
      testRepeater: tower,
      note: "",
      traceHashSize: 1
    )
    try await second.save(
      results: [result(target: ridge, probes: [(900, [9, 1, 2])])],
      testRepeater: tower,
      note: "",
      traceHashSize: 1
    )

    let newest = try #require(try await first.runGroups().first)
    try await first.delete(group: newest)

    let remaining = try await first.runGroups()
    #expect(remaining.count == 1)
    #expect(remaining.first?.averageRTT == 400)
  }

  @Test
  func `A run saved before stamps existed still parses and displays`() async throws {
    let radioID = UUID()
    let (store, dataStore) = try await makeStore(radioID: radioID)

    _ = try await dataStore.createSavedTracePath(
      radioID: radioID,
      name: "[Benchmark] stock whip · Tower → Ridge",
      pathBytes: Data([0x0A, 0x0C, 0x0A]),
      hashSize: 1,
      initialRun: TracePathRunDTO(
        id: UUID(),
        date: savedAt,
        success: true,
        roundTripMs: 500,
        hopsSNR: [9, 4, 6]
      )
    )

    let group = try #require(try await store.runGroups().first)
    #expect(group.note == "stock whip")
    #expect(group.targetNames == ["Ridge"])
    #expect(group.averageRTT == 500)
  }

  @Test
  func `A target with no probes is not stored as a zero-percent row`() async throws {
    let radioID = UUID()
    let (store, _) = try await makeStore(radioID: radioID)

    try await store.save(
      results: [
        result(target: ridge, probes: [(400, [9, 4, 6])]),
        BenchmarkTargetResult(target: barn),
      ],
      testRepeater: tower,
      note: "cancelled early",
      traceHashSize: 1
    )

    let paths = try await store.benchmarkPaths()
    #expect(paths.count == 1)
    #expect(BenchmarkNaming.components(from: paths[0].name)?.target == "Ridge")
  }

  @Test
  func `A path whose runs all failed to write is not left behind`() async throws {
    let radioID = UUID()
    let dataStore = FailingAppendTracePathStore()
    let historyStore = store(dataStore: dataStore, radioID: radioID, savedAt: savedAt)

    let saved = try await historyStore.save(
      results: [result(target: ridge, probes: [(400, [9, 4, 6])])],
      testRepeater: tower,
      note: "doomed",
      traceHashSize: 1
    )

    // A runless path reads as 100% success and would inflate the group's averages.
    #expect(saved.isEmpty)
    #expect(await dataStore.paths.isEmpty)
  }

  // MARK: - Deletion

  @Test
  func `Deleting a group removes every path it holds`() async throws {
    let radioID = UUID()
    let (store, _) = try await makeStore(radioID: radioID)

    try await store.save(
      results: [
        result(target: ridge, probes: [(400, [9, 4, 6])]),
        result(target: barn, probes: [(800, [9, 2, 3])]),
      ],
      testRepeater: tower,
      note: "scrap this",
      traceHashSize: 1
    )
    let group = try #require(try await store.runGroups().first)
    try await store.delete(group: group)

    #expect(try await store.runGroups().isEmpty)
  }
}
