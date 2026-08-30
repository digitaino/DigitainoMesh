import CoreLocation
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

  /// The finished session the completion sheet shows, set when a survey ends.
  var surveySummary: SignalMapperProbeEngine.SessionSnapshot?
  /// The run behind ``surveySummary`` — what the completion sheet exports.
  var lastCompletedRunID: UUID?

  private var reloadTask: Task<Void, Never>?

  private let builder = SignalMapperCoverageBuilder()
  private let tuningStore = MapperTuningStore()

  var hasCoverage: Bool {
    !snapshot.isEmpty
  }

  // MARK: - Survey session

  /// Starts a survey run. The HUD is driven by ``attachSurveyStream(appState:)``, which
  /// the view re-invokes per engine generation — the run, not this model, is the thing
  /// that survives a BLE rewire. The lock-on selection rides in from the start-flow
  /// picker so the first probe cycle already has its focus targets (review S1).
  func startSurvey(
    appState: AppState,
    focusTargets: [MapperProbeTarget] = [],
    focusMeta: [NodeHexID: SignalMapperRideSession.FocusMeta] = [:]
  ) async {
    guard await appState.startSignalMapperSurvey(focusTargets: focusTargets) else { return }
    appState.signalMapperRideSession?.focusMeta = focusMeta
  }

  /// Mirrors the current engine generation's snapshot stream into the run object, and
  /// keeps the map repainting on a slow cadence. Called from the view's
  /// `.task(id: engineGeneration)`, so a rewire re-subscribes to the *new* engine's
  /// stream instead of parking on a finished one forever (M3.5 review C4c).
  func attachSurveyStream(appState: AppState) async {
    guard let session = appState.signalMapperRideSession else {
      reloadTask?.cancel()
      reloadTask = nil
      return
    }

    if reloadTask == nil {
      // The ride should paint the map as it happens — but a full store rebuild every
      // 10 s grows monotonically all ride and cooks the phone (review 5b). 60 s.
      reloadTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
          guard let self, !Task.isCancelled else { return }
          await self.load(dataStore: appState.services?.dataStore, radioID: appState.currentRadioID)
        }
      }
    }

    guard let probe = appState.signalMapperProbeEngine else { return }
    let stream = await probe.snapshots()
    for await snapshot in stream {
      guard !Task.isCancelled else { return }
      session.liveSnapshot = snapshot
      foldMaxRange(snapshot: snapshot, session: session, appState: appState)
    }
  }

  /// The ride's actual answer, computed where positions live: each fresh reply's distance
  /// from the current fix to the target's advertised position, folded into the run max.
  private func foldMaxRange(
    snapshot: SignalMapperProbeEngine.SessionSnapshot,
    session: SignalMapperRideSession,
    appState: AppState
  ) {
    guard let here = appState.locationService.currentLocation else { return }
    for focus in snapshot.focusStates {
      guard let reply = focus.lastReplyAt, Date().timeIntervalSince(reply) < 10,
            let meta = session.focusMeta[focus.id],
            let latitude = meta.latitude, let longitude = meta.longitude else { continue }
      let distance = here.distance(from: CLLocation(latitude: latitude, longitude: longitude))
      if distance > (session.maxReplyDistanceMeters[focus.id] ?? 0) {
        session.maxReplyDistanceMeters[focus.id] = distance
      }
    }
  }

  /// Ends the run, hands its cumulative counters to the completion sheet, and refreshes
  /// the map so the cells it just filled are on screen behind the sheet.
  func stopSurvey(appState: AppState) async {
    reloadTask?.cancel()
    reloadTask = nil
    let runID = appState.signalMapperRideSession?.runID
    let summary = await appState.stopSignalMapperSurvey()
    surveySummary = summary
    lastCompletedRunID = runID
    await load(dataStore: appState.services?.dataStore, radioID: appState.currentRadioID)
  }

  /// One probe cycle for the cell the user is standing in. The snapshot stream carries
  /// the spent budget to the HUD.
  func spotCheck(appState: AppState) async {
    guard let probe = appState.signalMapperProbeEngine else { return }
    await probe.spotCheck()
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
