import CoreLocation
import Foundation
import MC1Services
import OSLog

/// The signal mapper's location layer: a cached one-shot fix, refreshed only when a fresh
/// one would actually say something new (docs/SIGNAL_MAPPER_V2.md §2.2).
///
/// `LocationService` stays exactly what it is — one-shot, when-in-use, hundred-meter
/// accuracy. **No background mode, no `Always` authorization, no plist change.** Everything
/// that makes continuous coverage capture affordable happens here instead:
///
/// - **Serve the cache, never block.** ``latestFix()`` returns whatever is already held and
///   kicks off a refresh in the background. A packet arrives on the RX path and the capture
///   engine has microseconds to decide what to do with it; waiting on GPS would mean either
///   stalling the log or tagging the packet with a fix taken well after it arrived.
/// - **Refresh on movement or age, not on demand.** A stationary phone re-uses one fix
///   indefinitely — which is correct, because it is still in the same cell. A fresh one-shot
///   is spent when the CoreMotion hint says we have moved since the fix was taken, or when
///   the fix has aged past the tuning's `fixMaxAge`. CoreMotion runs on the motion
///   coprocessor and costs nothing next to a GPS fix, which is what makes this trade work.
/// - **Movement invalidates, it does not merely refresh.** Seeing motion is not only a
///   reason to want a newer fix, it is proof the held one is wrong, and the two are not the
///   same thing: a refresh that has not landed yet leaves the *old* fix being served, and
///   nothing about its age or accuracy reveals that the phone walked away from it. So the
///   hint marks the cached fix ``MapperFix/movedSinceCapture`` at the same moment it asks
///   for a new one, and the capture engine drops anything carrying that mark until the
///   replacement arrives (docs/SIGNAL_MAPPER_V2.md §2.2).
/// - **Nothing is queued.** If the refresh has not landed by the time the next packet
///   arrives, the engine drops that observation. A guessed cell is worse than a missing one.
///
/// One thing this layer cannot do is notice movement nobody is classifying. With Motion &
/// Fitness declined the hint is permanently `.stationary` and the mark never fires, which is
/// why the engine's second mechanism — the speed-scaled age budget, read off the fix itself
/// and gated by no permission at all — is not redundant with this one.
///
/// Raw coordinates never leave this layer's callers: the capture engine buckets them to an
/// H3 cell immediately and only the cell is stored (§3.1).
actor MapperFixCache: MapperFixProviding {
  /// Floor between refresh *attempts*, so a burst of packets — or a denied location
  /// permission, where every attempt fails — cannot turn into a stream of requests.
  static let minimumRefreshInterval: TimeInterval = 5

  private let requestFix: @Sendable () async -> MapperFix?
  private let movementHints: any MovementHintProvider
  private let tuning: any MapperTuningProviding
  private let now: @Sendable () -> Date
  private let minimumRefreshInterval: TimeInterval
  private let logger = Logger(subsystem: "com.mc1", category: "MapperFixCache")

  private var cached: MapperFix?
  private var lastAttemptAt: Date?
  private var refreshTask: Task<Void, Never>?

  init(
    requestFix: @escaping @Sendable () async -> MapperFix?,
    movementHints: any MovementHintProvider,
    tuning: any MapperTuningProviding = MapperTuningStore(),
    now: @escaping @Sendable () -> Date = { Date() },
    minimumRefreshInterval: TimeInterval = MapperFixCache.minimumRefreshInterval
  ) {
    self.requestFix = requestFix
    self.movementHints = movementHints
    self.tuning = tuning
    self.now = now
    self.minimumRefreshInterval = minimumRefreshInterval
  }

  /// The production wiring: one-shot fixes from the app's `LocationService`, movement from
  /// the per-connection `MovementHintRelay` that the signal-bars feature already feeds.
  static func live(
    locationService: LocationService,
    movementHints: any MovementHintProvider,
    tuning: any MapperTuningProviding = MapperTuningStore()
  ) -> MapperFixCache {
    MapperFixCache(
      requestFix: { await requestLiveFix(from: locationService, maxAge: tuning.tuning.fixMaxAgeSeconds) },
      movementHints: movementHints,
      tuning: tuning
    )
  }

  // MARK: - MapperFixProviding

  /// The cached fix, and a refresh kicked off if one is warranted. Returns immediately in
  /// every case, including the very first call, when there is nothing to return yet.
  ///
  /// The fix comes back carrying ``MapperFix/movedSinceCapture`` when the movement hint has
  /// fired since it was taken, so the caller can tell "this is where you are" apart from
  /// "this is where you were".
  func latestFix() async -> MapperFix? {
    scheduleRefreshIfNeeded()
    return cached
  }

  /// Drops the cache and any in-flight refresh. Called when capture stops, so a fix from a
  /// previous session cannot tag the first packet of the next one.
  func reset() {
    refreshTask?.cancel()
    refreshTask = nil
    cached = nil
    lastAttemptAt = nil
  }

  // MARK: - Refresh

  private func scheduleRefreshIfNeeded() {
    guard refreshTask == nil else { return }

    let at = now()
    if let lastAttemptAt, at.timeIntervalSince(lastAttemptAt) < minimumRefreshInterval { return }

    // An absent or aged-out fix has to be replaced whatever the phone is doing. A fix that
    // is merely *not new* only gets replaced if we have actually moved, which is the whole
    // reason the movement hint exists — and asking for it costs an actor hop, so it is only
    // asked when the cheap age test has not already decided.
    let expired = cached.map {
      at.timeIntervalSince($0.timestamp) >= tuning.tuning.fixMaxAgeSeconds
    } ?? true

    lastAttemptAt = at
    refreshTask = Task { [weak self] in
      await self?.refresh(force: expired)
    }
  }

  private func refresh(force: Bool) async {
    defer { refreshTask = nil }

    // Asked unconditionally, because the answer is needed for two different decisions: it
    // is the only reason a still-fresh fix gets replaced, *and* it is what invalidates the
    // one currently being served. Skipping the question when the age test has already
    // forced a refresh would leave the old fix looking trustworthy for the seconds the new
    // one takes to arrive.
    let hint = await movementHints.currentMovementHint()
    if hint != .stationary {
      // Whatever the cached fix says, it says it about somewhere the phone has left. The
      // mark stands until a fresh fix replaces the value outright, below.
      cached?.movedSinceCapture = true
    }

    if !force, hint == .stationary { return }
    guard !Task.isCancelled else { return }

    guard let fix = await requestFix() else {
      logger.debug("No location fix available for the mapper")
      return
    }
    // A whole new value, so `movedSinceCapture` starts false again by construction rather
    // than by remembering to clear it.
    cached = fix
  }

  // MARK: - Live location

  /// Turns `LocationService` into a ``MapperFix``.
  ///
  /// Runs on the main actor so `CLLocation` — a reference type owned by the location
  /// manager — never crosses an isolation boundary; only the value type comes back.
  ///
  /// A fix another feature just took (map centering, distance sorting, the region
  /// recommender) is reused when it is still inside the age budget: those requests happen
  /// anyway, and spending a second GPS fix on the same moment would be pure battery cost.
  @MainActor
  private static func requestLiveFix(
    from locationService: LocationService,
    maxAge: TimeInterval
  ) async -> MapperFix? {
    if let existing = locationService.currentLocation,
       Date().timeIntervalSince(existing.timestamp) < maxAge {
      return fix(from: existing)
    }
    // Permission is never prompted from here: capture is a background consumer of a
    // permission the user granted for something visible. Unauthorized simply means the
    // mapper has no fixes, and the engine drops what it cannot place.
    guard locationService.isAuthorized else { return nil }
    guard let location = try? await locationService.requestCurrentLocation() else { return nil }
    return fix(from: location)
  }

  @MainActor
  private static func fix(from location: CLLocation) -> MapperFix {
    MapperFix(
      latitude: location.coordinate.latitude,
      longitude: location.coordinate.longitude,
      horizontalAccuracyMeters: location.horizontalAccuracy,
      // CoreLocation reports a negative speed when it has no valid one.
      speedMetersPerSecond: location.speed >= 0 ? location.speed : nil,
      timestamp: location.timestamp
    )
  }
}
