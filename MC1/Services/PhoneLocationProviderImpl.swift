import CoreLocation
import MC1Services

/// Bridges `LocationService`'s cached one-shot fix into the service layer, so
/// message ingestion can stamp receive-time location without the package
/// touching CoreLocation. Passive by contract: reports the cached fix as-is
/// (coordinate + timestamp) and never requests a new one — the consumer
/// judges the fix by age, and ingestion must never trigger a permission
/// prompt or GPS spin-up.
///
/// MainActor-isolated with an async method to allow cross-actor access,
/// mirroring `AppStateProviderImpl`.
@MainActor
final class PhoneLocationProviderImpl: PhoneLocationProvider {
  private let locationService: LocationService

  init(locationService: LocationService) {
    self.locationService = locationService
  }

  nonisolated func currentFix() async -> PhoneLocationFix? {
    await MainActor.run {
      guard let location = locationService.currentLocation else { return nil }
      return PhoneLocationFix(
        latitude: location.coordinate.latitude,
        longitude: location.coordinate.longitude,
        timestamp: location.timestamp
      )
    }
  }
}
