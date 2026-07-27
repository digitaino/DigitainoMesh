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
    let saved = savedAt
    let store = BenchmarkHistoryStore(
      dataStore: dataStore,
      radioID: radioID,
      now: { saved }
    )
    return (store, dataStore)
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
