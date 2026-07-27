import Foundation
import MC1Services
import OSLog

/// SwiftUI's view of ``RepeaterBenchmarkEngine`` and ``BenchmarkHistoryStore``.
///
/// Actors do not participate in SwiftUI observation, so this holds the engine's latest
/// snapshot in an `@Observable` property and forwards user intents back. Like
/// `RepeaterSignalModel` it is deliberately thin: probe sequencing, scoring, grouping and
/// comparison all live in MC1Services where they are testable without a view. What belongs
/// here is only what a screen owns — the note being typed, the two runs picked for
/// comparison, and the candidate list a picker renders.
///
/// The engine lives on `ServiceContainer`, not here, so a run survives leaving the screen;
/// this model attaches and detaches around that.
@Observable
@MainActor
final class RepeaterBenchmarkModel {
  private static let logger = Logger(subsystem: "com.mc1", category: "RepeaterBenchmark")

  // MARK: - Engine state

  private(set) var snapshot: RepeaterBenchmarkSnapshot = .idle()
  private(set) var isAttached = false

  // MARK: - Screen state

  /// Repeaters the pickers offer.
  private(set) var candidates: [RepeaterCandidate] = []
  /// Saved runs, newest first.
  private(set) var history: [BenchmarkRunGroup] = []
  /// The note this run will be saved under.
  var note = ""
  private(set) var isSaved = false
  /// Notes of the runs picked for comparison; at most two.
  var selectedForComparison: [String] = []
  var errorMessage: String?

  @ObservationIgnored private var engine: RepeaterBenchmarkEngine?
  @ObservationIgnored private var historyStore: BenchmarkHistoryStore?
  @ObservationIgnored private var streamTask: Task<Void, Never>?
  @ObservationIgnored private var traceHashSize = 1

  // MARK: - Binding

  /// Subscribes to `engine`, seeds the current state, and applies the radio's trace geometry.
  ///
  /// Re-attaching is safe: the previous subscription is cancelled first, so a re-fired
  /// `.task` cannot leave two streams writing the same property.
  func attach(
    engine: RepeaterBenchmarkEngine,
    history historyStore: BenchmarkHistoryStore,
    device: DeviceDTO?
  ) async {
    detach()
    self.engine = engine
    self.historyStore = historyStore
    isAttached = true
    traceHashSize = device?.traceHashSize ?? 1

    await engine.configure(
      traceHashSize: traceHashSize,
      traceFlags: device?.pathHashMode ?? 0,
      localNodeName: device?.nodeName ?? ""
    )

    let snapshots = engine.snapshots()
    streamTask = Task { [weak self] in
      for await snapshot in snapshots {
        guard !Task.isCancelled else { break }
        self?.snapshot = snapshot
      }
    }
    snapshot = await engine.currentSnapshot()
    await reloadHistory()
  }

  /// Releases the engine. A run in flight keeps going — the engine outlives this screen.
  func detach() {
    streamTask?.cancel()
    streamTask = nil
    engine = nil
    historyStore = nil
    isAttached = false
    snapshot = .idle()
  }

  // MARK: - Derived state

  var plan: BenchmarkPlan {
    snapshot.plan
  }

  var results: [BenchmarkTargetResult] {
    snapshot.results
  }

  var isRunning: Bool {
    snapshot.isRunning
  }

  var testRepeater: RepeaterCandidate? {
    guard let key = plan.testRepeater?.publicKey else { return nil }
    return candidates.first { $0.publicKey == key }
  }

  /// Everything except the chosen test repeater — nothing benchmarks itself.
  var selectableTargets: [RepeaterCandidate] {
    guard let key = plan.testRepeater?.publicKey else { return candidates }
    return candidates.filter { $0.publicKey != key }
  }

  var selectedTargetKeys: Set<Data> {
    Set(plan.targets.map(\.publicKey))
  }

  var testRepeaterKeys: Set<Data> {
    Set([plan.testRepeater?.publicKey].compactMap(\.self))
  }

  var canRun: Bool {
    plan.isRunnable && !isRunning
  }

  var canSave: Bool {
    snapshot.hasResults && !isRunning && !isSaved
  }

  /// The two runs picked for comparison, older first so deltas read "before → after".
  var comparisonPair: (BenchmarkRunGroup, BenchmarkRunGroup)? {
    let picked = history.filter { selectedForComparison.contains($0.note) }
    guard picked.count == 2 else { return nil }
    let sorted = picked.sorted { $0.date < $1.date }
    return (sorted[0], sorted[1])
  }

  // MARK: - Candidates

  func reloadCandidates(
    dataStore: PersistenceStore?,
    radioID: UUID?,
    signals: RepeaterSignalModel,
    pathHashMode: UInt8
  ) async {
    candidates = await RepeaterCandidateSource.load(
      dataStore: dataStore,
      radioID: radioID,
      signals: signals,
      pathHashMode: pathHashMode
    )
  }

  // MARK: - Plan intents

  func setTestRepeater(_ candidate: RepeaterCandidate) async {
    await engine?.setTestRepeater(candidate.benchmarkTarget)
    isSaved = false
  }

  func toggleTarget(_ candidate: RepeaterCandidate) async {
    await engine?.toggleTarget(candidate.benchmarkTarget)
    isSaved = false
  }

  /// Selects every target the radio is currently hearing — the set worth measuring first.
  func selectHeardTargets() async {
    await engine?.setTargets(selectableTargets.filter(\.isHeard).map(\.benchmarkTarget))
    isSaved = false
  }

  func setTracesPerTarget(_ count: Int) async {
    await engine?.setTracesPerTarget(count)
  }

  // MARK: - Run intents

  func run() async {
    isSaved = false
    await engine?.run()
  }

  func cancel() async {
    await engine?.cancel()
  }

  // MARK: - History

  func reloadHistory() async {
    guard let historyStore else { return }
    do {
      history = try await historyStore.runGroups()
      selectedForComparison.removeAll { note in !history.contains { $0.note == note } }
    } catch {
      Self.logger.error("Benchmark history read failed: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
    }
  }

  func saveResults() async {
    guard let historyStore, let testRepeater = plan.testRepeater else { return }
    do {
      try await historyStore.save(
        results: results,
        testRepeater: testRepeater,
        note: note,
        traceHashSize: traceHashSize
      )
      isSaved = true
      note = ""
      await reloadHistory()
    } catch {
      Self.logger.error("Benchmark save failed: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
    }
  }

  func delete(group: BenchmarkRunGroup) async {
    guard let historyStore else { return }
    do {
      try await historyStore.delete(group: group)
      await reloadHistory()
    } catch {
      Self.logger.error("Benchmark delete failed: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
    }
  }

  /// Loads a saved run's test repeater and targets back into the plan, so a change can be
  /// measured against exactly the same set.
  func loadPlan(from group: BenchmarkRunGroup) async {
    guard let engine else { return }
    let names = Set(group.targetNames)
    if let testName = group.testRepeaterName,
       let test = candidates.first(where: { $0.displayName == testName }) {
      await engine.setTestRepeater(test.benchmarkTarget)
    }
    await engine.setTargets(
      candidates.filter { names.contains($0.displayName) }.map(\.benchmarkTarget)
    )
    await engine.clearResults()
    isSaved = false
    note = ""
  }

  /// Picks a run for comparison, keeping at most two and dropping the oldest pick first.
  func toggleComparison(_ group: BenchmarkRunGroup) {
    if let index = selectedForComparison.firstIndex(of: group.note) {
      selectedForComparison.remove(at: index)
    } else {
      selectedForComparison.append(group.note)
      if selectedForComparison.count > 2 {
        selectedForComparison.removeFirst()
      }
    }
  }

  func isSelectedForComparison(_ group: BenchmarkRunGroup) -> Bool {
    selectedForComparison.contains(group.note)
  }
}
