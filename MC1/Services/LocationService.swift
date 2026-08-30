import CoreLocation
import OSLog

enum LocationServiceError: Error, LocalizedError {
  case notAuthorized(CLAuthorizationStatus)
  case requestInProgress
  case permissionTimeout
  case locationTimeout
  case requestFailed(String)

  var errorDescription: String? {
    switch self {
    case let .notAuthorized(status):
      switch status {
      case .notDetermined:
        "Location permission is required to update your node's location."
      case .denied, .restricted:
        "Location permission is denied. Enable it in Settings to update your node's location."
      default:
        "Location permission is not available."
      }
    case .requestInProgress:
      "A location request is already in progress."
    case .permissionTimeout:
      "Timed out while waiting for location permission."
    case .locationTimeout:
      "Timed out while requesting location."
    case let .requestFailed(message):
      "Location request failed: \(message)"
    }
  }
}

/// App-wide location service for managing location permissions and access.
/// Used by MapView, LineOfSightView, ContactsListView, and other location-dependent features.
@Observable
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
  // MARK: - Properties

  private let logger = Logger(subsystem: "com.mc1", category: "LocationService")
  private let locationManager: CLLocationManager

  private var requestContinuation: CheckedContinuation<CLLocation, Error>?
  private var locationTimeoutTask: Task<Void, Never>?

  private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Error>?
  private var permissionTimeoutTask: Task<Void, Never>?

  /// Current authorization status
  private(set) var authorizationStatus: CLAuthorizationStatus

  /// Current device location (nil if unavailable or not yet determined)
  private(set) var currentLocation: CLLocation?

  /// Whether a location request is in progress
  private(set) var isRequestingLocation = false

  /// Whether the continuous ride-survey stream is running (``startContinuousUpdates()``).
  private(set) var isContinuousActive = false
  private var savedDesiredAccuracy: CLLocationAccuracy?

  /// Whether location services are authorized for use
  var isAuthorized: Bool {
    authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
  }

  /// Whether permission has been determined (not .notDetermined)
  var hasRequestedPermission: Bool {
    authorizationStatus != .notDetermined
  }

  /// Whether location is denied or restricted
  var isLocationDenied: Bool {
    authorizationStatus == .denied || authorizationStatus == .restricted
  }

  // MARK: - Initialization

  override init() {
    locationManager = CLLocationManager()
    authorizationStatus = locationManager.authorizationStatus
    super.init()
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  // MARK: - Public Methods

  /// Request location permission if not already determined.
  /// Call this when a location-dependent feature is accessed.
  func requestPermissionIfNeeded() {
    guard authorizationStatus == .notDetermined else {
      let raw = authorizationStatus.rawValue
      logger.debug("Location permission already determined: \(String(describing: raw))")
      return
    }

    logger.info("Requesting location permission")
    locationManager.requestWhenInUseAuthorization()
  }

  /// Whether the app currently receives full-accuracy fixes. With Precise Location off,
  /// CoreLocation degrades to ~1–3 km accuracy and the signal mapper's 50 m gate rejects
  /// every sample — a silent total loss the ride pre-flight must surface.
  var isPreciseLocationAuthorized: Bool {
    locationManager.accuracyAuthorization == .fullAccuracy
  }

  /// Asks for temporary full accuracy under the given plist purpose key (project.yml's
  /// `NSLocationTemporaryUsageDescriptionDictionary`). No-op when already precise.
  func requestTemporaryFullAccuracy(purposeKey: String) async {
    guard !isPreciseLocationAuthorized else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      locationManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: purposeKey) { _ in
        continuation.resume()
      }
    }
  }

  /// Starts the continuous ride-survey stream: best accuracy, every fix delivered.
  ///
  /// `kCLDistanceFilterNone` is deliberate — a distance filter starves a stopped rider of
  /// callbacks, and the mapper's fix gate then rejects on age alone even though the
  /// position never changed (M3.5 review M2). While the stream runs, one-shot requests
  /// are served from it (see ``requestCurrentLocation(timeout:)``) — mixing
  /// `requestLocation()` with `startUpdatingLocation()` is unsupported by CoreLocation.
  /// The previous `desiredAccuracy` is restored on stop so the rest of the app keeps its
  /// battery-friendly hundred-meter default.
  func startContinuousUpdates() {
    guard isAuthorized else {
      requestPermissionIfNeeded()
      return
    }
    guard !isContinuousActive else { return }
    isContinuousActive = true
    savedDesiredAccuracy = locationManager.desiredAccuracy
    locationManager.desiredAccuracy = kCLLocationAccuracyBest
    locationManager.distanceFilter = kCLDistanceFilterNone
    locationManager.startUpdatingLocation()
    logger.info("Continuous location updates started")
  }

  /// Stops the continuous stream and restores the one-shot configuration.
  func stopContinuousUpdates() {
    guard isContinuousActive else { return }
    isContinuousActive = false
    locationManager.stopUpdatingLocation()
    if let saved = savedDesiredAccuracy {
      locationManager.desiredAccuracy = saved
      savedDesiredAccuracy = nil
    }
    logger.info("Continuous location updates stopped")
  }

  /// Request a one-shot location update.
  /// Call this when you need the current location (e.g., for distance sorting).
  func requestLocation() {
    guard isAuthorized else {
      logger.debug("Cannot request location: not authorized")
      requestPermissionIfNeeded()
      return
    }

    guard !isRequestingLocation else {
      logger.debug("Location request already in progress")
      return
    }

    guard !isContinuousActive else {
      // The stream keeps `currentLocation` fresh every second; issuing a one-shot
      // alongside `startUpdatingLocation()` is unsupported.
      return
    }

    logger.info("Requesting one-shot location update")
    isRequestingLocation = true
    locationManager.requestLocation()
  }

  /// Request current location asynchronously with timeout.
  /// Handles permission prompting if needed.
  func requestCurrentLocation(timeout: Duration = .seconds(10)) async throws -> CLLocation {
    guard requestContinuation == nil, authorizationContinuation == nil else {
      throw LocationServiceError.requestInProgress
    }

    if !isAuthorized {
      if authorizationStatus == .notDetermined {
        requestPermissionIfNeeded()
        _ = try await waitForAuthorizationDecision(timeout: .seconds(30))
      }

      guard isAuthorized else {
        throw LocationServiceError.notAuthorized(authorizationStatus)
      }
    }

    if isContinuousActive {
      // Served from the stream: return the freshest streamed fix, or park the
      // continuation for the next delegate callback — never a competing one-shot.
      if let current = currentLocation, Date().timeIntervalSince(current.timestamp) < 5 {
        return current
      }
    }

    isRequestingLocation = true

    return try await withCheckedThrowingContinuation { continuation in
      requestContinuation = continuation
      if !isContinuousActive {
        locationManager.requestLocation()
      }

      locationTimeoutTask?.cancel()
      locationTimeoutTask = Task { @MainActor [weak self] in
        do {
          try await Task.sleep(for: timeout)
        } catch {
          return
        }
        guard let self, let continuation = requestContinuation else { return }

        requestContinuation = nil
        isRequestingLocation = false
        continuation.resume(throwing: LocationServiceError.locationTimeout)
      }
    }
  }

  // MARK: - Private Methods

  private func waitForAuthorizationDecision(timeout: Duration) async throws -> CLAuthorizationStatus {
    guard authorizationStatus == .notDetermined else { return authorizationStatus }
    guard authorizationContinuation == nil else {
      throw LocationServiceError.requestInProgress
    }

    return try await withCheckedThrowingContinuation { continuation in
      authorizationContinuation = continuation

      permissionTimeoutTask?.cancel()
      permissionTimeoutTask = Task { @MainActor [weak self] in
        do {
          try await Task.sleep(for: timeout)
        } catch {
          return
        }
        guard let self, let continuation = authorizationContinuation else { return }

        authorizationContinuation = nil
        continuation.resume(throwing: LocationServiceError.permissionTimeout)
      }
    }
  }

  // MARK: - CLLocationManagerDelegate

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    Task { @MainActor in
      self.authorizationStatus = status
      self.logger.info("Location authorization changed: \(String(describing: status.rawValue))")

      if status != .notDetermined, let authorizationContinuation = self.authorizationContinuation {
        self.authorizationContinuation = nil
        self.permissionTimeoutTask?.cancel()
        self.permissionTimeoutTask = nil
        authorizationContinuation.resume(returning: status)
      }

      if status == .denied || status == .restricted {
        if let continuation = self.requestContinuation {
          self.requestContinuation = nil
          self.locationTimeoutTask?.cancel()
          self.locationTimeoutTask = nil
          self.isRequestingLocation = false
          continuation.resume(throwing: LocationServiceError.notAuthorized(status))
        }
      }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last else { return }
    Task { @MainActor in
      self.currentLocation = location
      self.isRequestingLocation = false
      // `privacy: .private` because OSLog treats interpolated numerics as public by
      // default, which would put full-precision coordinates in the unified log store for
      // anyone with a sysdiagnose. Signal-mapper capture makes this fire far more often
      // than the occasional map-centering request it was written for.
      self.logger.info(
        "Location updated: \(location.coordinate.latitude, privacy: .private), \(location.coordinate.longitude, privacy: .private)"
      )

      self.locationTimeoutTask?.cancel()
      self.locationTimeoutTask = nil

      if let continuation = self.requestContinuation {
        self.requestContinuation = nil
        continuation.resume(returning: location)
      }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    Task { @MainActor in
      self.isRequestingLocation = false
      self.logger.error("Location request failed: \(error.localizedDescription)")

      self.locationTimeoutTask?.cancel()
      self.locationTimeoutTask = nil

      if let continuation = self.requestContinuation {
        self.requestContinuation = nil
        continuation.resume(throwing: LocationServiceError.requestFailed(error.localizedDescription))
      }
    }
  }
}
