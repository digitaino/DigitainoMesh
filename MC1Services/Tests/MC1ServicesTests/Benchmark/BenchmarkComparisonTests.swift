import Foundation
@testable import MC1Services
import Testing

@Suite("Benchmark comparison")
struct BenchmarkComparisonTests {
  private let earlier = Date(timeIntervalSince1970: 1_700_000_000)
  private let later = Date(timeIntervalSince1970: 1_700_003_600)

  // MARK: - Grouping

  @Test
  func `Pre-stamp paths group by the note they were saved under, newest run first`() throws {
    let paths = [
      BenchmarkFixtures.savedPath(
        note: "stock whip",
        target: "Ridge",
        createdDate: earlier,
        runs: [(rtt: 400, snrs: [9, 4, 6], success: true)]
      ),
      BenchmarkFixtures.savedPath(
        note: "stock whip",
        target: "Barn",
        createdDate: earlier,
        runs: [(rtt: 600, snrs: [9, 2, 3], success: true)]
      ),
      BenchmarkFixtures.savedPath(
        note: "yagi",
        target: "Ridge",
        createdDate: later,
        runs: [(rtt: 300, snrs: [9, 8, 9], success: true)]
      ),
    ]

    let groups = BenchmarkComparison.groups(from: paths)

    #expect(groups.count == 2)
    #expect(groups.first?.note == "yagi")
    let stock = try #require(groups.first { $0.note == "stock whip" })
    #expect(stock.paths.count == 2)
    #expect(stock.averageRTT == 500)
    #expect(stock.averageSuccessRate == 100)
    #expect(stock.testRepeaterName == "Tower")
    #expect(Set(stock.targetNames) == ["Ridge", "Barn"])
  }

  @Test
  func `Two noteless saves group separately, keyed by their stamps`() {
    let paths = [
      BenchmarkFixtures.savedPath(
        note: "",
        runStamp: BenchmarkNaming.runStamp(for: earlier),
        target: "Ridge",
        createdDate: earlier,
        runs: [(rtt: 400, snrs: [9, 4, 6], success: true)]
      ),
      BenchmarkFixtures.savedPath(
        note: "",
        runStamp: BenchmarkNaming.runStamp(for: later),
        target: "Ridge",
        createdDate: later,
        runs: [(rtt: 900, snrs: [9, 1, 2], success: true)]
      ),
    ]

    let groups = BenchmarkComparison.groups(from: paths)

    let allNoteless = groups.allSatisfy(\.note.isEmpty)
    #expect(groups.count == 2)
    #expect(allNoteless)
    #expect(groups.map(\.averageRTT) == [900, 400])
    // Both rows are the same target, so a merged group would have hidden the older one.
    #expect(groups.allSatisfy { $0.paths.count == 1 })
    #expect(Set(groups.map(\.id)).count == 2)
  }

  @Test
  func `Hand-saved trace paths are excluded from history groups`() {
    let handSaved = SavedTracePathDTO(
      id: UUID(),
      radioID: UUID(),
      name: "Tower → Barn",
      pathBytes: Data([0x01]),
      createdDate: earlier,
      runs: []
    )

    #expect(BenchmarkComparison.groups(from: [handSaved]).isEmpty)
  }

  // MARK: - Deltas

  @Test
  func `Every delta is B minus A across matched targets`() throws {
    let groupA = try #require(BenchmarkComparison.groups(from: [
      BenchmarkFixtures.savedPath(
        note: "stock whip",
        target: "Ridge",
        createdDate: earlier,
        runs: [(rtt: 500, snrs: [9, 4, 6], success: true)]
      ),
    ]).first)
    let groupB = try #require(BenchmarkComparison.groups(from: [
      BenchmarkFixtures.savedPath(
        note: "yagi",
        target: "Ridge",
        createdDate: later,
        runs: [(rtt: 400, snrs: [9, 7, 9], success: true)]
      ),
    ]).first)

    let rows = BenchmarkComparison.rows(groupA: groupA, groupB: groupB)
    let row = try #require(rows.first)

    #expect(rows.count == 1)
    #expect(row.targetName == "Ridge")
    #expect(row.rttDelta == -100)
    #expect(row.txDelta == 3)
    #expect(row.rxDelta == 3)
    #expect(row.successRateDelta == 0)
  }

  @Test
  func `A target present in only one run keeps a blank column and no delta`() throws {
    let groupA = try #require(BenchmarkComparison.groups(from: [
      BenchmarkFixtures.savedPath(
        note: "before",
        target: "Ridge",
        createdDate: earlier,
        runs: [(rtt: 500, snrs: [9, 4, 6], success: true)]
      ),
      BenchmarkFixtures.savedPath(
        note: "before",
        target: "Barn",
        createdDate: earlier,
        runs: [(rtt: 700, snrs: [9, 1, 2], success: true)]
      ),
    ]).first)
    let groupB = try #require(BenchmarkComparison.groups(from: [
      BenchmarkFixtures.savedPath(
        note: "after",
        target: "Ridge",
        createdDate: later,
        runs: [(rtt: 450, snrs: [9, 5, 7], success: true)]
      ),
    ]).first)

    let rows = BenchmarkComparison.rows(groupA: groupA, groupB: groupB)
    let barn = try #require(rows.first { $0.targetName == "Barn" })

    #expect(rows.map(\.targetName) == ["Barn", "Ridge"])
    #expect(barn.rttA == 700)
    #expect(barn.rttB == nil)
    #expect(barn.rttDelta == nil)
  }

  @Test
  func `Summary averages only the rows that have both sides`() throws {
    let groupA = try #require(BenchmarkComparison.groups(from: [
      BenchmarkFixtures.savedPath(
        note: "before",
        target: "Ridge",
        createdDate: earlier,
        runs: [(rtt: 500, snrs: [9, 4, 6], success: true)]
      ),
      BenchmarkFixtures.savedPath(
        note: "before",
        target: "Barn",
        createdDate: earlier,
        runs: [(rtt: 700, snrs: [9, 2, 2], success: true)]
      ),
    ]).first)
    let groupB = try #require(BenchmarkComparison.groups(from: [
      BenchmarkFixtures.savedPath(
        note: "after",
        target: "Ridge",
        createdDate: later,
        runs: [(rtt: 400, snrs: [9, 8, 10], success: true)]
      ),
      BenchmarkFixtures.savedPath(
        note: "after",
        target: "Barn",
        createdDate: later,
        runs: [(rtt: 500, snrs: [9, 4, 6], success: true)]
      ),
    ]).first)

    let summary = BenchmarkComparison.summary(
      rows: BenchmarkComparison.rows(groupA: groupA, groupB: groupB)
    )

    #expect(summary.rttDelta == -150)
    #expect(summary.txSNRDelta == 3)
    #expect(summary.rxSNRDelta == 4)
    #expect(!summary.isEmpty)
  }

  @Test(arguments: [
    (delta: -1.0, lowerIsBetter: true, improved: true),
    (delta: 1.0, lowerIsBetter: true, improved: false),
    (delta: 1.0, lowerIsBetter: false, improved: true),
    (delta: -1.0, lowerIsBetter: false, improved: false),
    (delta: 0.0, lowerIsBetter: true, improved: false),
  ])
  func `Improvement direction depends on the metric`(
    testCase: (delta: Double, lowerIsBetter: Bool, improved: Bool)
  ) {
    #expect(
      BenchmarkComparison.isImprovement(
        delta: testCase.delta,
        lowerIsBetter: testCase.lowerIsBetter
      ) == testCase.improved
    )
  }
}
