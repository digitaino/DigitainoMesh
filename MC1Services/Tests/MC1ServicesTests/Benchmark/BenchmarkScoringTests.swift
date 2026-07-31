import Foundation
@testable import MC1Services
import Testing

@Suite("Benchmark scoring")
struct BenchmarkScoringTests {
  // MARK: - Success rate

  @Test(arguments: [
    (successes: 0, total: 0, expected: 0),
    (successes: 0, total: 5, expected: 0),
    (successes: 1, total: 3, expected: 33),
    (successes: 4, total: 5, expected: 80),
    (successes: 5, total: 5, expected: 100),
  ])
  func `Success rate is whole-percent integer division`(
    testCase: (successes: Int, total: Int, expected: Int)
  ) {
    #expect(
      BenchmarkScoring.successRate(successes: testCase.successes, total: testCase.total)
        == testCase.expected
    )
  }

  @Test
  func `An unrun batch scores zero rather than a perfect hundred`() {
    let result = BenchmarkTargetResult(target: benchmarkTarget("Ridge", prefix: [0x0C]))
    #expect(result.successRate == 0)
    #expect(result.averageRTT == nil)
  }

  // MARK: - Round-trip time

  @Test
  func `Round trips average only the successful probes`() {
    let outcomes = [
      BenchmarkFixtures.outcome(sequence: 1, durationMs: 100, intermediateSNRs: [1, 2, 3]),
      BenchmarkFixtures.outcome(sequence: 2, durationMs: 300, intermediateSNRs: [1, 2, 3]),
      BenchmarkFixtures.outcome(sequence: 3, durationMs: 0, intermediateSNRs: [], failure: .timeout),
    ]

    #expect(BenchmarkScoring.averageRTT(outcomes) == 200)
    #expect(BenchmarkScoring.minRTT(outcomes) == 100)
    #expect(BenchmarkScoring.maxRTT(outcomes) == 300)
  }

  @Test
  func `Round-trip statistics are nil when nothing succeeded`() {
    let outcomes = [
      BenchmarkFixtures.outcome(durationMs: 0, intermediateSNRs: [], failure: .timeout),
      BenchmarkFixtures.outcome(sequence: 2, durationMs: 0, intermediateSNRs: [], failure: .sendFailed),
    ]

    #expect(BenchmarkScoring.averageRTT(outcomes) == nil)
    #expect(BenchmarkScoring.minRTT(outcomes) == nil)
    #expect(BenchmarkScoring.maxRTT(outcomes) == nil)
  }

  // MARK: - Directional SNR

  @Test
  func `TX and RX legs read the second and third intermediate hops`() {
    // Path test → target → test: [test hears us, target hears test (TX), test hears target (RX)]
    let outcomes = [
      BenchmarkFixtures.outcome(sequence: 1, durationMs: 100, intermediateSNRs: [9, 4, 6]),
      BenchmarkFixtures.outcome(sequence: 2, durationMs: 100, intermediateSNRs: [9, 6, 8]),
    ]
    let result = BenchmarkTargetResult(
      target: benchmarkTarget("Ridge", prefix: [0x0C]),
      outcomes: outcomes
    )

    #expect(result.txSNR == 5)
    #expect(result.rxSNR == 7)
  }

  @Test
  func `A truncated path contributes nothing rather than a zero`() {
    let outcomes = [
      BenchmarkFixtures.outcome(sequence: 1, durationMs: 100, intermediateSNRs: [9, 4, 6]),
      // Only two hops came back: the RX leg was never observed on this probe.
      BenchmarkFixtures.outcome(sequence: 2, durationMs: 100, intermediateSNRs: [9, 4]),
    ]

    #expect(BenchmarkScoring.directionalSNR(outcomes, hopIndex: BenchmarkScoring.txHopIndex) == 4)
    #expect(BenchmarkScoring.directionalSNR(outcomes, hopIndex: BenchmarkScoring.rxHopIndex) == 6)
  }

  @Test
  func `Failed probes never contribute signal readings`() {
    let outcomes = [
      BenchmarkFixtures.outcome(sequence: 1, durationMs: 0, intermediateSNRs: [], failure: .timeout),
    ]

    #expect(BenchmarkScoring.directionalSNR(outcomes, hopIndex: BenchmarkScoring.txHopIndex) == nil)
  }

  @Test
  func `Persisted runs score the same way live outcomes do`() {
    let runs = [
      TracePathRunDTO(id: UUID(), date: .now, success: true, roundTripMs: 100, hopsSNR: [9, 4, 6]),
      TracePathRunDTO(id: UUID(), date: .now, success: false, roundTripMs: 0, hopsSNR: []),
      TracePathRunDTO(id: UUID(), date: .now, success: true, roundTripMs: 200, hopsSNR: [9, 6, 8]),
    ]

    #expect(BenchmarkScoring.directionalSNR(runs: runs, hopIndex: BenchmarkScoring.txHopIndex) == 5)
    #expect(BenchmarkScoring.directionalSNR(runs: runs, hopIndex: BenchmarkScoring.rxHopIndex) == 7)
  }
}

// MARK: - Naming

@Suite("Benchmark path naming")
struct BenchmarkNamingTests {
  @Test
  func `A note round-trips through the stored name`() throws {
    let name = BenchmarkNaming.pathName(
      note: "stock whip antenna",
      testRepeater: "Tower",
      target: "Ridge"
    )
    let parsed = try #require(BenchmarkNaming.components(from: name))

    #expect(parsed.note == "stock whip antenna")
    #expect(parsed.testRepeater == "Tower")
    #expect(parsed.target == "Ridge")
  }

  @Test
  func `An empty note parses back as empty`() throws {
    let name = BenchmarkNaming.pathName(note: "  ", testRepeater: "Tower", target: "Ridge")
    let parsed = try #require(BenchmarkNaming.components(from: name))

    #expect(parsed.note.isEmpty)
    #expect(parsed.target == "Ridge")
  }

  @Test
  func `A note containing the delimiter cannot break parsing`() throws {
    let name = BenchmarkNaming.pathName(
      note: "yagi · 8 dBi",
      testRepeater: "Tower",
      target: "Ridge"
    )
    let parsed = try #require(BenchmarkNaming.components(from: name))

    #expect(parsed.testRepeater == "Tower")
    #expect(parsed.target == "Ridge")
    #expect(!parsed.note.contains(BenchmarkNaming.noteSeparator))
  }

  @Test
  func `Legacy names without a note still parse`() throws {
    let parsed = try #require(BenchmarkNaming.components(from: "[Benchmark] Tower → Ridge"))

    #expect(parsed.note.isEmpty)
    #expect(parsed.runStamp == nil)
    #expect(parsed.testRepeater == "Tower")
    #expect(parsed.target == "Ridge")
  }

  @Test
  func `A run stamp round-trips alongside the note`() throws {
    let stamp = BenchmarkNaming.runStamp(for: Date(timeIntervalSince1970: 1_700_000_000))
    let name = BenchmarkNaming.pathName(
      note: "yagi",
      runStamp: stamp,
      testRepeater: "Tower",
      target: "Ridge"
    )
    let parsed = try #require(BenchmarkNaming.components(from: name))

    #expect(parsed.note == "yagi")
    #expect(parsed.runStamp == stamp)
    #expect(parsed.groupKey == stamp)
    #expect(parsed.testRepeater == "Tower")
    #expect(parsed.target == "Ridge")
  }

  @Test
  func `A stamp keeps two noteless saves apart`() throws {
    let earlier = BenchmarkNaming.runStamp(for: Date(timeIntervalSince1970: 1_700_000_000))
    let later = BenchmarkNaming.runStamp(for: Date(timeIntervalSince1970: 1_700_000_600))
    let names = [earlier, later].map {
      BenchmarkNaming.pathName(note: "", runStamp: $0, testRepeater: "Tower", target: "Ridge")
    }
    let parsed = try names.map { try #require(BenchmarkNaming.components(from: $0)) }

    let allNoteless = parsed.allSatisfy(\.note.isEmpty)
    #expect(allNoteless)
    #expect(parsed.allSatisfy { $0.target == "Ridge" })
    #expect(parsed[0].groupKey != parsed[1].groupKey)
  }

  @Test
  func `A stampless name groups by its note, as it always did`() throws {
    let parsed = try #require(
      BenchmarkNaming.components(from: "[Benchmark] stock whip · Tower → Ridge")
    )

    #expect(parsed.runStamp == nil)
    #expect(parsed.groupKey == "stock whip")
  }

  @Test
  func `Hand-saved trace paths are not benchmark paths`() {
    #expect(BenchmarkNaming.components(from: "Tower → Barn → Ridge") == nil)
    #expect(!BenchmarkNaming.isBenchmarkPath("Tower → Ridge"))
  }
}
