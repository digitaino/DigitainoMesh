import Foundation
import MC1Services
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.mc1", category: "SignalMapperCoverage")

/// Screen state for the coverage map: what the last build found, whether a load is in
/// flight, and whether passive capture is switched on.
///
/// All the arithmetic lives in ``SignalMapperCoverageBuilder``; this is the thin part —
/// fetch, hand off, publish. Building runs off the main actor because merging a season of
/// cell-days and resolving every repeater hash against the node pool is not main-thread
/// work.
@MainActor
@Observable
final class SignalMapperCoverageModel {
  private(set) var snapshot: SignalMapperCoverageSnapshot = .empty
  private(set) var isLoading = false
  private(set) var didFail = false

  /// Whether passive capture is running. The same setting the debug panel toggles — both
  /// read and write ``MapperTuningStore``, so neither can drift from the other.
  var isCaptureEnabled = false

  /// Live counters of the running survey session, polled while one is active.
  private(set) var surveySnapshot: SignalMapperProbeEngine.SessionSnapshot?

  /// The finished session the completion sheet shows, set when a survey ends.
  var surveySummary: SignalMapperProbeEngine.SessionSnapshot?

  private var surveyPollTask: Task<Void, Never>?

  private let builder = SignalMapperCoverageBuilder()
  private let tuningStore = MapperTuningStore()

  var hasCoverage: Bool {
    !snapshot.isEmpty
  }

  var isSurveying: Bool {
    surveySnapshot != nil
  }

  // MARK: - Survey session

  /// Starts a survey session and begins mirroring its counters into ``surveySnapshot``.
  func startSurvey(appState: AppState) async {
    guard await appState.startSignalMapperSurvey() else { return }
    surveySnapshot = await appState.signalMapperProbeEngine?.snapshot()

    surveyPollTask?.cancel()
    surveyPollTask = Task { [weak self] in
      var ticks = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self, !Task.isCancelled else { return }
        guard let probe = appState.signalMapperProbeEngine else {
          // The session died underneath us — a disconnect, or a capture re-wire. There
          // is no summary worth a sheet in that case; just stop showing a HUD.
          self.surveySnapshot = nil
          self.surveyPollTask = nil
          return
        }
        self.surveySnapshot = await probe.snapshot()

        // The walk should paint the map as it happens, not on session end: re-read the
        // store on a slow cadence so freshly probed cells surface behind the HUD.
        ticks += 1
        if ticks.isMultiple(of: 10) {
          await self.load(dataStore: appState.services?.dataStore, radioID: appState.currentRadioID)
        }
      }
    }
  }

  /// Ends the session, hands its counters to the completion sheet, and refreshes the map
  /// so the cells it just filled are on screen behind the sheet.
  func stopSurvey(appState: AppState) async {
    surveyPollTask?.cancel()
    surveyPollTask = nil
    let summary = await appState.stopSignalMapperSurvey()
    surveySnapshot = nil
    surveySummary = summary
    await load(dataStore: appState.services?.dataStore, radioID: appState.currentRadioID)
  }

  /// One probe cycle for the cell the user is standing in, HUD refreshed right after so
  /// the spent budget is visible immediately.
  func spotCheck(appState: AppState) async {
    guard let probe = appState.signalMapperProbeEngine else { return }
    await probe.spotCheck()
    surveySnapshot = await probe.snapshot()
  }

  // MARK: - Capture

  /// Reads the stored capture flag. Called on appear so a change made in the debug panel
  /// is reflected here.
  func loadCaptureSetting() {
    isCaptureEnabled = tuningStore.isCaptureEnabled
  }

  /// Persists the flag and restarts (or tears down) the engine so it takes effect now.
  func setCaptureEnabled(_ enabled: Bool, appState: AppState) {
    tuningStore.setCaptureEnabled(enabled)
    isCaptureEnabled = enabled
    appState.applySignalMapperCaptureSetting()
  }

  // MARK: - Loading

  /// Rebuilds the map from every stored cell-day.
  ///
  /// The store is not radio-scoped — coverage is a property of where the phone was, not of
  /// which radio was paired — so this reads without a radio ID and works while
  /// disconnected. The *candidate pool* for repeater names is radio-scoped, and simply
  /// comes back empty when there is no radio, which leaves repeaters showing as hashes.
  func load(dataStore: PersistenceStore?, radioID: UUID?) async {
    guard let dataStore else {
      snapshot = .empty
      return
    }

    isLoading = true
    didFail = false
    defer { isLoading = false }

    do {
      let rows = try await dataStore.fetchMapperCellObservations()
      var candidates: [AnyResolvableNode] = []
      if let radioID {
        let contacts = try await dataStore.fetchContacts(radioID: radioID)
        let discovered = try await dataStore.fetchDiscoveredNodes(radioID: radioID)
        candidates = contacts.map(AnyResolvableNode.init) + discovered.map(AnyResolvableNode.init)
      }

      let builder = builder
      let now = Date()
      let pool = candidates
      snapshot = await Task.detached(priority: .userInitiated) {
        builder.build(rows: rows, candidates: pool, now: now)
      }.value
    } catch {
      logger.error("Coverage build failed: \(error.localizedDescription, privacy: .public)")
      didFail = true
      snapshot = .empty
    }
  }

  /// Drops every captured cell. The user-facing half of the debug panel's reset.
  func deleteAll(dataStore: PersistenceStore?, radioID: UUID?) async {
    guard let dataStore else { return }
    do {
      try await dataStore.deleteAllMapperCellObservations()
    } catch {
      logger.error("Coverage delete failed: \(error.localizedDescription, privacy: .public)")
      didFail = true
    }
    await load(dataStore: dataStore, radioID: radioID)
  }
}
