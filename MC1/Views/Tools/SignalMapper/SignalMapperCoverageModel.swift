import CoreLocation
import Foundation
import MC1Services
import OSLog
import Security
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

  /// The open run's own share of ``snapshot``, built from the same rows in the same pass —
  /// so the card can never show ride figures with no all-time cell behind them. `.empty`
  /// whenever no run is open.
  private(set) var sessionSnapshot: SignalMapperCoverageSnapshot = .empty
  /// Which hexagons the open run has touched, and which of those it mapped for the first
  /// time. `.empty` whenever no run is open.
  private(set) var sessionScope: SignalMapperSessionScope = .empty

  /// Whether passive capture is running. The same setting the debug panel toggles — both
  /// read and write ``MapperTuningStore``, so neither can drift from the other.
  var isCaptureEnabled = false

  /// The finished session the completion sheet shows, set when a survey ends.
  var surveySummary: SignalMapperProbeEngine.SessionSnapshot?
  /// The run behind ``surveySummary`` — what the completion sheet exports.
  var lastCompletedRunID: UUID?

  private let builder = SignalMapperCoverageBuilder()
  private let tuningStore = MapperTuningStore()
  /// Bumped on entry to every load; only the newest one is allowed to publish.
  private var loadGeneration = 0

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
    // The first paint of the ride comes off the same read the baseline was taken from, so
    // the ride starts at zero on screen rather than inheriting the last idle build.
    await refresh(appState: appState)
  }

  /// Mirrors the current engine generation's snapshot stream into the run object, and
  /// keeps the map repainting on a slow cadence. Called from the view's
  /// `.task(id: engineGeneration)`, so a rewire re-subscribes to the *new* engine's
  /// stream instead of parking on a finished one forever (M3.5 review C4c).
  func attachSurveyStream(appState: AppState) async {
    guard let session = appState.signalMapperRideSession else { return }

    if session.repeaterDirectory.isEmpty {
      session.repeaterDirectory = await loadRepeaterDirectory(appState: appState)
    }

    guard let probe = appState.signalMapperProbeEngine else { return }
    let stream = await probe.snapshots()
    for await snapshot in stream {
      guard !Task.isCancelled else { return }
      session.liveSnapshot = snapshot
      foldMaxRange(snapshot: snapshot, session: session, appState: appState)
    }
  }

  /// Keeps the on-screen snapshot honest for as long as the view is up.
  ///
  /// Passive capture folds packets whether or not a survey is running, and the store
  /// flushes every 30 s, so a screen that loads once shows a cell card whose "Last Heard"
  /// drifts minutes behind the repeater list in the radio pill (field report, 2026-08-30).
  /// Riding gets the tighter cadence because the card is following the rider; idle gets a
  /// slower one because nothing on screen is moving.
  func autoRefresh(appState: AppState) async {
    while !Task.isCancelled {
      let riding = appState.signalMapperRideSession != nil
      try? await Task.sleep(for: .seconds(riding ? 20 : 45))
      guard !Task.isCancelled else { return }
      await refresh(appState: appState)
    }
  }

  /// Builds the hexID → (name, position) lookup the auto "hearing now" blocks resolve
  /// against, at the device's path-hash width — the same derivation the picker uses.
  private func loadRepeaterDirectory(
    appState: AppState
  ) async -> [String: SignalMapperRideSession.FocusMeta] {
    guard let dataStore = appState.services?.dataStore,
          let radioID = appState.currentRadioID else { return [:] }
    let width = min(3, Int(appState.connectedDevice?.pathHashMode ?? 0) + 1)
    var directory: [String: SignalMapperRideSession.FocusMeta] = [:]
    if let contacts = try? await dataStore.fetchContacts(radioID: radioID) {
      for contact in contacts where contact.type == .repeater {
        guard let id = NodeHexID(data: contact.publicKey.prefix(width)) else { continue }
        directory[id.hex] = SignalMapperRideSession.FocusMeta(
          name: contact.name,
          latitude: contact.hasLocation ? contact.latitude : nil,
          longitude: contact.hasLocation ? contact.longitude : nil
        )
      }
    }
    if let discovered = try? await dataStore.fetchDiscoveredNodes(radioID: radioID) {
      for node in discovered where node.nodeType == .repeater {
        guard let id = NodeHexID(data: node.publicKey.prefix(width)),
              directory[id.hex] == nil else { continue }
        directory[id.hex] = SignalMapperRideSession.FocusMeta(
          name: node.name,
          latitude: node.hasLocation ? node.latitude : nil,
          longitude: node.hasLocation ? node.longitude : nil
        )
      }
    }
    return directory
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
    let runID = appState.signalMapperRideSession?.runID
    let summary = await appState.stopSignalMapperSurvey()
    surveySummary = summary
    lastCompletedRunID = runID
    // The run is over and its flush has landed, so this reads back the whole ride — and
    // with no session open it clears the ride layers, leaving the all-time map behind.
    await refresh(appState: appState)
  }

  /// One probe cycle for the cell the user is standing in. The snapshot stream carries
  /// the spent budget to the HUD.
  func spotCheck(appState: AppState) async {
    guard let probe = appState.signalMapperProbeEngine else { return }
    await probe.spotCheck()
  }

  // MARK: - Manual transmissions

  /// One zero-hop discover, on demand.
  func manualDiscover(appState: AppState) async -> Bool {
    guard let probe = appState.signalMapperProbeEngine else { return false }
    return await probe.manualDiscover()
  }

  /// One directed trace at a chosen repeater, on demand.
  func manualTrace(appState: AppState, target: MapperProbeTarget) async -> Bool {
    guard let probe = appState.signalMapperProbeEngine else { return false }
    return await probe.manualTrace(to: target)
  }

  /// Sends a real flood-routed packet: a short message on a private channel.
  ///
  /// This is the one transmission the mapper makes that the whole mesh relays, which is
  /// why the automatic engine will never make it (`floodsPerTierCell = 0`, Rafael
  /// 2026-08-26) and why this is a button with a channel picker in front of it. Its value
  /// is the echo: repeaters rebroadcasting your own packet is the uplink evidence no
  /// amount of listening can produce, and passive capture already folds those echoes as
  /// `txHeard` for the cell you sent from.
  ///
  /// A public-channel send would put survey noise in front of every stranger on the mesh,
  /// so the picker offers private channels only, and this refuses index 0 outright.
  func sendFloodProbe(appState: AppState, channelIndex: UInt8, text: String) async -> Bool {
    guard channelIndex != 0,
          let messageService = appState.services?.messageService,
          let radioID = appState.currentRadioID else { return false }
    do {
      _ = try await messageService.sendChannelMessage(
        text: text,
        channelIndex: channelIndex,
        radioID: radioID
      )
      return true
    } catch {
      logger.error("Survey flood probe failed: \(error.localizedDescription)")
      return false
    }
  }

  /// The private channels a flood probe may be sent on. Never the public channel.
  func floodChannels(appState: AppState) async -> [ChannelDTO] {
    guard let dataStore = appState.services?.dataStore,
          let radioID = appState.currentRadioID,
          let channels = try? await dataStore.fetchChannels(radioID: radioID) else { return [] }
    return channels.filter { !$0.isPublicChannel }
  }

  /// Creates a dedicated encrypted survey channel on the first free slot, with a random
  /// secret — v1's `createSurveyChannel`. Nobody else has the key, so flood probes on it
  /// traverse the mesh (which is the point) without being readable by anyone (which is
  /// what "so we don't bother anyone" asks for).
  func createSurveyChannel(appState: AppState, name: String) async -> UInt8? {
    guard let channelService = appState.services?.channelService,
          let radioID = appState.currentRadioID,
          let device = appState.connectedDevice,
          // Slot 0 is the public channel, so a radio reporting one channel (or none) has
          // nowhere to put a private one — inventing slot 1 there would write past what
          // the device advertises.
          device.maxChannels > 1 else { return nil }
    let existing = await floodChannels(appState: appState)
    let used = Set(existing.map(\.index))
    guard let slot = (UInt8(1)..<device.maxChannels).first(where: { !used.contains($0) })
    else { return nil }

    var bytes = [UInt8](repeating: 0, count: 16)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      return nil
    }
    do {
      try await channelService.setChannelWithSecret(
        radioID: radioID,
        index: slot,
        name: name,
        secret: Data(bytes)
      )
      return slot
    } catch {
      logger.error("Survey channel creation failed: \(error.localizedDescription)")
      return nil
    }
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
  /// The one call every screen makes: reads the store, folds in whatever the capture engine
  /// still holds unflushed, and rebuilds the all-time map — plus the ride's own map when a
  /// run is open, against that run's baseline.
  func refresh(appState: AppState) async {
    await load(
      dataStore: appState.services?.dataStore,
      radioID: appState.currentRadioID,
      baseline: appState.signalMapperRideSession?.baseline,
      pending: await appState.signalMapperEngine?.pendingObservations() ?? []
    )
  }

  /// - Parameters:
  ///   - baseline: the open run's reference rows, or nil when nothing is running — which
  ///     resets the two session values, since a map with no run has no ride on it.
  ///   - pending: cell-days the engine has folded but not yet written. Merged over the
  ///     stored rows so both maps see the current minute of capture rather than trailing
  ///     the flush interval.
  func load(
    dataStore: PersistenceStore?,
    radioID: UUID?,
    baseline: SignalMapperSessionBaseline? = nil,
    pending: [MapperCellObservationDTO] = []
  ) async {
    guard let dataStore else {
      snapshot = .empty
      sessionSnapshot = .empty
      sessionScope = .empty
      return
    }

    // Loads overlap: the auto-refresh ticker, a pull, a run starting and the completion
    // sheet all call in, and a slow build used to be free to publish over a newer one.
    loadGeneration += 1
    let generation = loadGeneration
    isLoading = true
    didFail = false
    defer { if generation == loadGeneration { isLoading = false } }

    do {
      let stored = try await dataStore.fetchMapperCellObservations()
      let rows = Self.folded(stored: stored, pending: pending)
      var candidates: [AnyResolvableNode] = []
      if let radioID {
        let contacts = try await dataStore.fetchContacts(radioID: radioID)
        let discovered = try await dataStore.fetchDiscoveredNodes(radioID: radioID)
        candidates = contacts.map(AnyResolvableNode.init) + discovered.map(AnyResolvableNode.init)
      }

      let builder = builder
      let now = Date()
      let pool = candidates
      let result = await Task.detached(priority: .userInitiated) { () -> BuildResult in
        var result = BuildResult(allTime: builder.build(rows: rows, candidates: pool, now: now))
        if let baseline {
          let ride = builder.buildSession(
            rows: rows,
            baseline: baseline,
            candidates: pool,
            now: now
          )
          result.session = ride.snapshot
          result.scope = ride.scope
        }
        return result
      }.value

      guard generation == loadGeneration else { return }
      snapshot = result.allTime
      sessionSnapshot = result.session ?? .empty
      sessionScope = result.scope ?? .empty
    } catch {
      logger.error("Coverage build failed: \(error.localizedDescription, privacy: .public)")
      guard generation == loadGeneration else { return }
      didFail = true
      snapshot = .empty
      sessionSnapshot = .empty
      sessionScope = .empty
    }
  }

  /// One build's worth of output, so the detached build publishes all of it or none of it.
  private struct BuildResult: Sendable {
    var allTime: SignalMapperCoverageSnapshot
    var session: SignalMapperCoverageSnapshot?
    var scope: SignalMapperSessionScope?
  }

  /// Stored rows with the engine's unflushed aggregates folded on top, by `(cell, day)` —
  /// the same fold the store's upsert performs, so the merged view is what the next flush
  /// will make true.
  private static func folded(
    stored: [MapperCellObservationDTO],
    pending: [MapperCellObservationDTO]
  ) -> [MapperCellObservationDTO] {
    guard !pending.isEmpty else { return stored }

    var byKey: [SignalMapperSessionBaseline.Key: MapperCellObservationDTO] = [:]
    var order: [SignalMapperSessionBaseline.Key] = []
    for row in stored + pending {
      let key = SignalMapperSessionBaseline.Key(cellRaw: row.cellRaw, day: row.day)
      if let existing = byKey[key] {
        byKey[key] = existing.merged(with: row)
      } else {
        byKey[key] = row
        order.append(key)
      }
    }
    return order.compactMap { byKey[$0] }
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
