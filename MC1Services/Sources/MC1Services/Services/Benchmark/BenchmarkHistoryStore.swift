import Foundation
import os

/// Reads and writes benchmark history.
///
/// A benchmark result is a trace path with runs, so it is persisted through the store's
/// existing `TracePathPersisting` surface rather than a schema of its own: history survives
/// backup/restore and needs no migration. What separates the two is the name — see
/// ``BenchmarkNaming`` — which also carries the save a run is grouped by and the note it is
/// labelled with, because `TracePathRunDTO` has nowhere to put either. The prefix is the
/// isolation: the Trace Path tool filters these rows out of its own list and its
/// path-matching, so a benchmark's numbers only ever change here.
///
/// One saved path per target; one run per probe, in probe order. `hopsSNR` is the
/// intermediate-hop array, which is what ``BenchmarkScoring`` indexes for the TX and RX
/// legs, so a comparison reads history exactly the way a live row reads outcomes.
public actor BenchmarkHistoryStore {
  private let dataStore: any TracePathPersisting
  private let radioID: UUID
  private let now: @Sendable () -> Date
  private let logger = Logger(subsystem: "com.mc1", category: "BenchmarkHistory")

  /// - Parameters:
  ///   - dataStore: The persistence store's saved-trace-path surface.
  ///   - radioID: Scopes every read and write to the connected radio.
  ///   - now: The clock, injected so run timestamps are deterministic in tests.
  public init(
    dataStore: any TracePathPersisting,
    radioID: UUID,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.dataStore = dataStore
    self.radioID = radioID
    self.now = now
  }

  // MARK: - Reading

  /// Every saved path this tool wrote, newest first.
  public func benchmarkPaths() async throws -> [SavedTracePathDTO] {
    try await dataStore.fetchSavedTracePaths(radioID: radioID)
      .filter { BenchmarkNaming.isBenchmarkPath($0.name) }
  }

  /// Benchmark history grouped into runs by save, newest run first.
  public func runGroups() async throws -> [BenchmarkRunGroup] {
    try await BenchmarkComparison.groups(from: benchmarkPaths())
  }

  // MARK: - Writing

  /// Saves one run: a path per target that produced at least one probe.
  ///
  /// Targets with no outcomes are skipped rather than stored empty — a cancelled run should
  /// not leave a row that reads as 0% success. A per-target failure is logged and the rest
  /// of the run still lands, because losing four targets to one bad write helps nobody.
  ///
  /// - Returns: The paths that were created.
  @discardableResult
  public func save(
    results: [BenchmarkTargetResult],
    testRepeater: BenchmarkTarget,
    note: String,
    traceHashSize: Int
  ) async throws -> [SavedTracePathDTO] {
    var saved: [SavedTracePathDTO] = []
    let testHash = testRepeater.pathHash(byteWidth: traceHashSize)
    let savedAt = now()
    // One stamp for the whole save, so this run's targets group together and the next save
    // under the same note (or none) is still a run of its own.
    let runStamp = BenchmarkNaming.runStamp(for: savedAt)

    for result in results where !result.outcomes.isEmpty {
      let targetHash = result.target.pathHash(byteWidth: traceHashSize)
      let name = BenchmarkNaming.pathName(
        note: note,
        runStamp: runStamp,
        testRepeater: testRepeater.name,
        target: result.target.name
      )

      do {
        // The stored path is the one that was probed: out through the test repeater to the
        // target and back, which is what makes a re-run comparable to the original.
        let path = try await dataStore.createSavedTracePath(
          radioID: radioID,
          name: name,
          pathBytes: testHash + targetHash + testHash,
          hashSize: traceHashSize,
          initialRun: nil
        )

        var appended = 0
        for outcome in result.outcomes {
          do {
            try await dataStore.appendTracePathRun(
              pathID: path.id,
              run: run(from: outcome, savedAt: savedAt)
            )
            appended += 1
          } catch {
            logger.error("Failed to save benchmark run: \(error.localizedDescription)")
          }
        }
        // A runless path reads as 100% success and would inflate the group's averages, so a
        // wholly failed append takes its path with it.
        guard appended > 0 else {
          try await dataStore.deleteSavedTracePath(id: path.id)
          continue
        }

        if let stored = try await dataStore.fetchSavedTracePath(id: path.id) {
          saved.append(stored)
        }
      } catch {
        logger.error("Failed to save benchmark path \(name): \(error.localizedDescription)")
      }
    }

    return saved
  }

  /// Deletes every saved path belonging to one run group.
  public func delete(group: BenchmarkRunGroup) async throws {
    for path in group.paths {
      try await dataStore.deleteSavedTracePath(id: path.id)
    }
  }

  // MARK: - Internals

  /// One probe as a persisted run.
  ///
  /// Run dates are spread a second apart from the save instant rather than reusing the
  /// probe's own start time: they are only ever read back in order and as a group date, and
  /// distinct values keep `max(date)` stable for grouping.
  private func run(from outcome: BenchmarkTraceOutcome, savedAt: Date) -> TracePathRunDTO {
    TracePathRunDTO(
      id: outcome.id,
      date: savedAt.addingTimeInterval(Double(outcome.sequence - 1)),
      success: outcome.success,
      roundTripMs: outcome.durationMs,
      hopsSNR: outcome.intermediateSNRs
    )
  }
}
