import CoreLocation
import Foundation
import MC1Services

/// The one fix provider the mapper engines are wired with, for the whole app lifetime.
///
/// Engines take their `MapperFixProviding` at init and never re-read it, and they are
/// built at **two** sites (the ambient stack in `wireSignalMapper`, the session-scoped
/// stack in `startSignalMapperSurvey`) — so a provider swapped at only one site would
/// miss the default configuration entirely (M3.5 review M1: capture-off is the default
/// path). The router is constructed once on AppState and injected at both; what changes
/// at runtime is its *routing*:
///
/// - **Live mode** (a ride run is active): fixes come straight off `LocationService`'s
///   continuous stream. Each is ~1 s old with real speed and course, so
///   `movedSinceCapture` is false by construction — the flag exists for a cached fix the
///   phone walked away from, and a streamed fix has no such gap. No cache fallback in
///   this mode: if the stream has nothing, the honest answer is nil, not a cached fix
///   whose movement flag would reject it anyway.
/// - **Cached mode** (everything else): delegates to the per-connection
///   `MapperFixCache`, exactly the pre-M3.5 behaviour.
actor MapperFixRouter: MapperFixProviding {
  private let locationService: LocationService
  private var liveMode = false
  private var fallback: (any MapperFixProviding)?

  init(locationService: LocationService) {
    self.locationService = locationService
  }

  /// Swaps the cached-mode delegate — called by the wiring whenever a new
  /// `MapperFixCache` is built for a connection (nil on teardown).
  func setFallback(_ provider: (any MapperFixProviding)?) {
    fallback = provider
  }

  /// Flips between the live stream and the cache. The caller is responsible for
  /// starting/stopping `LocationService.startContinuousUpdates()` alongside.
  func setLiveMode(_ on: Bool) {
    liveMode = on
  }

  func latestFix() async -> MapperFix? {
    if liveMode {
      return await liveFix()
    }
    return await fallback?.latestFix()
  }

  private func liveFix() async -> MapperFix? {
    await MainActor.run {
      guard let location = locationService.currentLocation else { return nil }
      return MapperFix(
        latitude: location.coordinate.latitude,
        longitude: location.coordinate.longitude,
        horizontalAccuracyMeters: location.horizontalAccuracy,
        speedMetersPerSecond: location.speed >= 0 ? location.speed : nil,
        courseDegrees: location.course >= 0 ? location.course : nil,
        timestamp: location.timestamp,
        movedSinceCapture: false
      )
    }
  }
}
