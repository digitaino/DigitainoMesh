import CoreLocation
import Foundation
import MapperRawLog
import MC1Services
import OSLog
import Security
import SurveyKit
import SwiftUI

private let logger = Logger(subsystem: "com.mc1", category: "SignalMapperCoverage")

/// Screen state for the coverage map: what the last read found, whether a load is in
/// flight, and whether passive capture is switched on.
///
/// **Everything on screen is a read of the raw log** (docs/SIGNAL_MAPPER_V3.md §7 step 4).
/// The map reads the per-cell summaries — a fold of rows that are still there, kept because
/// painting two layers cannot scan 90 days of rows per pan (``MapperCellSummary``) — and
/// the card reads the rows themselves through ``MapperCellQueries``. The aggregate
/// `MapperCellObservation` table is still *written* (§7: only the reads move in this step)
/// and nothing here consults it.
///
/// Both builds run off the main actor: folding a few thousand summaries into hexagon
/// geometry, and resolving every repeater hash in a cell against the node pool, are not
/// main-thread work.
@MainActor
@Observable
final class SignalMapperCoverageModel {
  private(set) var snapshot: SignalMapperMapSnapshot = .empty
  private(set) var isLoading = false
  private(set) var didFail = false

  /// The open card's data, or nil when no hexagon is selected (or its rows are still in
  /// flight). Rebuilt when the card's cell or scope changes and on every refresh tick.
  private(set) var card: SignalMapperCardData?

  /// Passively received packets *that were placed* since the open ride started — the
  /// legend's ride line. A count, not a fetch: see
  /// ``MapperRawLogStore/countSamples(kind:since:until:placedOnly:)``.
  ///
  /// Placed-only because the line beside it is a sum over the summaries, and a summary folds
  /// nothing that has no cell. Counting the unplaced rows here put two different populations
  /// under one word, and let a ride that began in a garage report more observations this
  /// ride than all time.
  private(set) var rideObservationCount = 0

  /// Rows of *any* evidence kind since the open ride started, placed or not — the test for
  /// "this ride has captured nothing anywhere", and deliberately not the number above.
  ///
  /// They answer different questions. The legend says how much of what we heard is on the
  /// map; the card's empty state asks whether there is anything to be on the map at all, and
  /// a lock-on ride in a quiet mesh answers that entirely in probe replies and echoes — no
  /// `passiveRx` row for the whole ride, while the hexagon behind the rider lists repeaters.
  /// Placement is not part of that question either: a ride whose fixes are all being refused
  /// has captured plenty, and ``SignalMapperCardEmptyReason/fixesRejected`` is the answer
  /// for it.
  private(set) var rideEvidenceCount = 0

  /// Whether passive capture is running. The same setting the debug panel toggles — both
  /// read and write ``MapperTuningStore``, so neither can drift from the other.
  var isCaptureEnabled = false

  /// The finished session the completion sheet shows, set when a survey ends.
  var surveySummary: SignalMapperProbeEngine.SessionSnapshot?
  /// The run behind ``surveySummary`` — what the completion sheet counts and exports.
  var lastCompletedRunID: UUID?

  private let cardBuilder = SignalMapperCardBuilder()
  private let tuningStore = MapperTuningStore()

  /// Which hexagon the card is reading, and over which window. Held here rather than
  /// passed per call so the refresh tick can rebuild the open card without the view
  /// re-stating what it is showing.
  private var cardTarget: CardTarget?

  private struct CardTarget: Equatable {
    var cell: H3Cell
    var scope: SignalMapperCardScope
  }

  /// The last read of the name pool, with the radio it was read for and when.
  ///
  /// Cached because the card's rebuild rate went from "twice a minute" to "up to once every
  /// 750 ms" when the row-arrival stream landed, and ``resolutionCandidates(appState:)``
  /// pays two unbounded SwiftData fetches — on the same actor the ride's own recorder is
  /// writing rows through. See its TTL for why staleness is affordable here and nowhere
  /// else.
  private var cachedCandidates: (radioID: UUID, nodes: [AnyResolvableNode], readAt: Date)?

  /// How many of a cell's rows the card will hold. A dense hexagon over 90 days can exceed
  /// this; the query sorts newest first, so what is dropped is the oldest end, and the
  /// card's own numbers stay the recent truth rather than a truncated average of history.
  private static let cardRowLimit = 5000

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
      // The capture engine's fix-drop counters have no stream of their own, and this loop is
      // the ride's own heartbeat (the probe engine yields every tick, fix or no fix), so the
      // health sample rides along with it rather than paying for a second timer.
      if let capture = appState.signalMapperEngine {
        let captureSnapshot = await capture.snapshot()
        session.noteCaptureSnapshot(captureSnapshot)
      }
    }
  }

  /// Repaints the card the moment rows land, instead of whenever the timer next comes round.
  ///
  /// The timer below is the belt; this is the braces, and it is what the 2026-09-04 field
  /// report actually needed: rows were being written throughout a 28-minute ride while the
  /// card under the HUD said "Nothing heard here this ride", because nothing but a 20 s
  /// sleep ever asked the store again.
  ///
  /// Coalesced by sleeping *after* a signal and acting once the sleep ends: the store's
  /// stream buffers only the newest signal, so a burst of a hundred rows costs one card
  /// rebuild per 750 ms rather than a hundred detached builds. The map's own rebuild is
  /// rarer still — it re-reads every summary in the store, which is not something to do at
  /// walking pace.
  func observeRowArrivals(appState: AppState) async {
    guard let store = await appState.resolveMapperRawLogStore() else { return }
    var lastMapRebuildAt = Date.distantPast
    for await _ in await store.rowArrivals() {
      guard !Task.isCancelled else { return }
      try? await Task.sleep(for: .milliseconds(Self.cardCoalesceMilliseconds))
      guard !Task.isCancelled else { return }

      await reloadCard(appState: appState, store: store)
      guard Date().timeIntervalSince(lastMapRebuildAt) >= Self.mapCoalesceSeconds else { continue }
      lastMapRebuildAt = Date()
      await reloadMap(appState: appState, store: store)
    }
  }

  /// How long a burst of arrivals is allowed to keep collapsing into one card rebuild.
  private static let cardCoalesceMilliseconds = 750
  /// The same for the map, which re-reads every cell summary and is not worth doing often.
  private static let mapCoalesceSeconds: TimeInterval = 5

  /// Keeps the on-screen numbers honest for as long as the view is up.
  ///
  /// Passive capture keeps writing rows whether or not a survey is running, and the
  /// recorder flushes on its own deadline, so a screen that loads once shows a card whose
  /// ages drift minutes behind the repeater list in the radio pill (field report,
  /// 2026-08-30). Riding gets the tighter cadence because the card is following the rider;
  /// idle gets a slower one because nothing on screen is moving.
  ///
  /// Loads *first* and sleeps after. The inherited order slept before its first read, so a
  /// screen opened mid-ride showed whatever it was built with for a whole period — and with
  /// the row-arrival stream carrying the fast path now, this loop's job is the things no row
  /// arrival announces: ages ticking over, and rows another process flushed.
  func autoRefresh(appState: AppState) async {
    while !Task.isCancelled {
      let riding = appState.signalMapperRideSession != nil
      // The view's own on-appear load runs from a `.task` declared just above this one and
      // claims `isLoading` synchronously, so the first iteration stands aside rather than
      // firing a second identical fetch at it.
      if !isLoading {
        await load(appState: appState)
      }
      guard !Task.isCancelled else { return }
      try? await Task.sleep(for: .seconds(riding ? 10 : 45))
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

  /// Ends the run, hands its identity to the completion sheet, and refreshes the map so
  /// the cells it just filled are on screen behind the sheet.
  func stopSurvey(appState: AppState) async {
    let runID = appState.signalMapperRideSession?.runID
    let summary = await appState.stopSignalMapperSurvey()
    surveySummary = summary
    lastCompletedRunID = runID
    await load(appState: appState)
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
  /// amount of listening can produce, and capture folds those echoes as `txHeard` rows for
  /// the cell you sent from.
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

  /// Rebuilds the map from the raw log's per-cell summaries, and the open card with it.
  ///
  /// The store is not radio-scoped — coverage is a property of where the phone was, not of
  /// which radio was paired — so this reads without a radio ID and works while
  /// disconnected. The *candidate pool* for repeater names is radio-scoped, and simply
  /// comes back empty when there is no radio, which leaves repeaters showing as hashes.
  func load(appState: AppState) async {
    // Claimed before the first suspension, not after the store resolves: `autoRefresh`
    // stands aside on this flag, and a flag set two awaits deep would still be false when
    // it looked.
    isLoading = true
    defer { isLoading = false }

    guard let store = await appState.resolveMapperRawLogStore() else {
      snapshot = .empty
      card = nil
      return
    }

    await reloadMap(appState: appState, store: store)
    await reloadCard(appState: appState, store: store)
  }

  /// The map half of ``load(appState:)``, on its own so the row-arrival stream can rebuild
  /// the card often and the map rarely.
  private func reloadMap(appState: AppState, store: MapperRawLogStore) async {
    do {
      let summaries = try await store.fetchCellSummaries()
      snapshot = await Task.detached(priority: .userInitiated) {
        SignalMapperSnapshotBuilder.build(summaries: summaries)
      }.value
      didFail = false
    } catch {
      logger.error("Coverage read failed: \(error.localizedDescription, privacy: .public)")
      didFail = true
      snapshot = .empty
    }

    if let startedAt = appState.signalMapperRideSession?.startedAt {
      rideObservationCount = await (try? store.countSamples(
        kind: .passiveRx,
        since: startedAt,
        until: .distantFuture,
        placedOnly: true
      )) ?? 0
      rideEvidenceCount = await (try? store.countSamples(
        matching: MapperSampleFilter(since: startedAt, kinds: Self.rideEvidenceKinds)
      )) ?? 0
    } else {
      rideObservationCount = 0
      rideEvidenceCount = 0
    }
  }

  /// What counts as "the ride captured something": everything the radio brought in, and
  /// nothing the app merely emitted.
  ///
  /// `probeAttempt` and `sent` are excluded on purpose — a ride that has transmitted into a
  /// dead mesh and heard nothing back really has captured nothing yet, and counting our own
  /// transmissions would answer the rider's question with our own noise.
  private static let rideEvidenceKinds: Set<MapperRawSampleKind> = [
    .passiveRx, .probeTraceReply, .probeDiscoverResponse, .txHeard
  ]

  /// Points the card at a hexagon (or nowhere), and reads its rows.
  ///
  /// Called from a `.task(id:)` on the displayed cell and the scope, so switching hexagons
  /// or flipping This ride / All time cancels the fetch in flight rather than racing it.
  func setCardTarget(
    cell: H3Cell?,
    scope: SignalMapperCardScope,
    appState: AppState
  ) async {
    guard let cell else {
      cardTarget = nil
      card = nil
      return
    }
    let target = CardTarget(cell: cell, scope: scope)
    guard cardTarget != target else { return }
    cardTarget = target
    // Cleared rather than left stale: the previous hexagon's repeaters under this
    // hexagon's header is the one thing the card must never show.
    card = nil
    guard let store = await appState.resolveMapperRawLogStore() else { return }
    await reloadCard(appState: appState, store: store)
  }

  /// Re-reads whatever the card is pointed at. Silent when it is pointed at nothing.
  private func reloadCard(appState: AppState, store: MapperRawLogStore) async {
    guard let target = cardTarget else {
      card = nil
      return
    }
    let since = cardWindowStart(scope: target.scope, appState: appState)
    let now = Date()
    guard let rows = try? await store.fetchSamples(
      cellRaw: target.cell.rawValue,
      since: since,
      until: .distantFuture,
      limit: Self.cardRowLimit
    ) else { return }

    let candidates = await resolutionCandidates(appState: appState)
    let builder = cardBuilder
    let built = await Task.detached(priority: .userInitiated) {
      builder.build(
        cell: target.cell,
        scope: target.scope,
        since: since,
        rows: rows,
        candidates: candidates,
        now: now
      )
    }.value
    // The target can have moved while the rows were in flight (a rider crossing a
    // boundary); a card for a hexagon nobody is looking at any more is dropped.
    guard cardTarget == target else { return }
    card = built
  }

  /// The `since` of the card's fetch — which *is* §3's ride filter, and nothing more.
  private func cardWindowStart(scope: SignalMapperCardScope, appState: AppState) -> Date {
    guard scope == .ride, let session = appState.signalMapperRideSession else {
      return .distantPast
    }
    return session.startedAt
  }

  /// The pool repeater hashes resolve names against: contacts and discovered nodes alike.
  ///
  /// Held for ``candidatePoolTTLSeconds`` between reads. This pool answers "what is this
  /// repeater called", and the answer changes when a contact is saved or an advert names a
  /// new node — a minutes-scale event, where the card behind it now rebuilds within a
  /// second of every batch of rows. A pool up to half a minute old costs a just-discovered
  /// repeater its name for that long; re-reading it per rebuild costs every ride two
  /// unbounded fetches a second, queued behind the recorder's own writes.
  ///
  /// Keyed by radio, so a rewire to a different node never serves the previous one's names.
  private func resolutionCandidates(appState: AppState) async -> [AnyResolvableNode] {
    guard let dataStore = appState.services?.dataStore,
          let radioID = appState.currentRadioID else { return [] }
    if let cached = cachedCandidates,
       cached.radioID == radioID,
       Date().timeIntervalSince(cached.readAt) < Self.candidatePoolTTLSeconds {
      return cached.nodes
    }
    let contacts = await (try? dataStore.fetchContacts(radioID: radioID)) ?? []
    let discovered = await (try? dataStore.fetchDiscoveredNodes(radioID: radioID)) ?? []
    let nodes = contacts.map(AnyResolvableNode.init) + discovered.map(AnyResolvableNode.init)
    cachedCandidates = (radioID: radioID, nodes: nodes, readAt: Date())
    return nodes
  }

  /// Inside the idle refresh period and twice the riding one, so a name learned mid-ride
  /// appears within a couple of card rebuilds rather than at the end of the run.
  private static let candidatePoolTTLSeconds: TimeInterval = 20

  /// Drops everything the map is drawn from. The user-facing half of the debug panel's
  /// reset — and since the map now reads the raw log, "delete captured coverage" has to
  /// take the rows with it, or the button would clear a table nothing on screen reads.
  func deleteAll(appState: AppState) async {
    if let store = await appState.resolveMapperRawLogStore() {
      do {
        try await store.deleteAll()
      } catch {
        logger.error("Raw log delete failed: \(error.localizedDescription, privacy: .public)")
        didFail = true
      }
    }
    // The aggregate table is still written (§7 step 4 moves the reads only), so it is
    // cleared too — leaving it behind would keep a copy of the coverage the user just
    // asked to be rid of.
    if let dataStore = appState.services?.dataStore {
      do {
        try await dataStore.deleteAllMapperCellObservations()
      } catch {
        logger.error("Coverage delete failed: \(error.localizedDescription, privacy: .public)")
        didFail = true
      }
    }
    cardTarget = nil
    card = nil
    await load(appState: appState)
  }
}
