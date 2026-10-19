import Foundation
import MC1Services
import OSLog

#if canImport(CoreMotion)
  import CoreMotion
#endif

/// Whether motion activity is available to us, and whether asking for it would prompt.
///
/// Kept as its own enum so CoreMotion's types stay behind ``MovementHintMonitor`` and callers
/// can reason about the prompt without importing the framework.
enum MovementHintAuthorization {
  /// Asking would show the Motion & Fitness prompt.
  case notDetermined
  /// Already granted; starting updates prompts nothing.
  case authorized
  /// Refused or restricted. Starting updates would deliver nothing.
  case denied
  /// No motion coprocessor, or not an iOS device.
  case unavailable

  /// Whether starting updates could produce data — either now or after a prompt.
  var canDeliverUpdates: Bool {
    self == .notDetermined || self == .authorized
  }
}

/// Classifies how the phone is moving, so signal probing speeds up when links are changing
/// and stays quiet when they are not.
///
/// CoreMotion's activity classifier runs on the motion coprocessor: no GPS, near-zero
/// battery, and it works with the screen off. That is the whole reason this exists rather
/// than deriving movement from `LocationService`.
///
/// ## Permission
///
/// Motion & Fitness is requested by the first `startActivityUpdates` call, so starting this
/// *is* the act of prompting. Connecting a radio must never be enough to trigger that: the
/// hint only shortens a probe interval, which is nowhere near proportionate to a permission
/// dialog thrown over whatever the user was doing — including, on an auto-reconnect, the
/// launch screen. ``authorization`` lets a caller tell "already granted, start freely" from
/// "starting would prompt, so wait until the user opens the feature". A denial is not an error
/// state: updates simply never arrive and the level stays `.stationary`, which is the cadence
/// a parked radio wants anyway.
///
/// ## Readings, not edges
///
/// The callback receives *readings*, not change events: the level on every change, plus a
/// periodic repeat of the current level while moving. The firmware's motion hint lapses after
/// about a minute, so a steady hour of walking has to keep being restated. Both consumers
/// (`MovementHintRelay` and `MotionHintService`) already de-duplicate, so a repeated reading
/// costs nothing when it is not needed.
@MainActor
final class MovementHintMonitor {
  /// How often the current level is restated while moving. Comfortably inside the firmware's
  /// ~60s staleness window.
  static let keepaliveInterval: TimeInterval = 45

  private let logger = Logger(subsystem: "com.mc1", category: "MovementHint")
  private let keepaliveInterval: TimeInterval

  /// The latest classified level. `.stationary` until CoreMotion says otherwise.
  private(set) var level: MovementHint = .stationary

  /// Whether updates are currently being delivered.
  private(set) var isRunning = false

  private var onReading: ((MovementHint) -> Void)?
  private var keepaliveTask: Task<Void, Never>?

  #if canImport(CoreMotion) && os(iOS)
    private let activityManager = CMMotionActivityManager()
  #endif

  init(keepaliveInterval: TimeInterval = MovementHintMonitor.keepaliveInterval) {
    self.keepaliveInterval = keepaliveInterval
  }

  /// Whether motion data is available, and whether asking for it would prompt.
  nonisolated static var authorization: MovementHintAuthorization {
    #if canImport(CoreMotion) && os(iOS)
      guard CMMotionActivityManager.isActivityAvailable() else { return .unavailable }
      return switch CMMotionActivityManager.authorizationStatus() {
      case .notDetermined: .notDetermined
      case .authorized: .authorized
      case .denied, .restricted: .denied
      @unknown default: .denied
      }
    #else
      return .unavailable
    #endif
  }

  /// Begins classifying motion.
  ///
  /// - Parameter onReading: Called on the main actor with the starting level, then with
  ///   every changed level and with periodic restatements while moving.
  func start(onReading: @escaping (MovementHint) -> Void) {
    stop()
    self.onReading = onReading
    isRunning = true
    level = .stationary
    onReading(.stationary)

    #if canImport(CoreMotion) && os(iOS)
      guard CMMotionActivityManager.isActivityAvailable() else {
        logger.info("Motion activity unavailable on this device; movement hint stays stationary")
        return
      }
      activityManager.startActivityUpdates(to: .main) { [weak self] activity in
        guard let activity, let level = Self.level(from: activity) else { return }
        MainActor.assumeIsolated {
          self?.emit(level)
        }
      }
      logger.info("Movement hint monitor started")
    #else
      logger.info("CoreMotion unavailable on this platform; movement hint stays stationary")
    #endif
  }

  /// Stops classifying and reports `.stationary` one last time, so nothing downstream keeps
  /// probing at a fast cadence after the source goes away.
  func stop() {
    guard isRunning || onReading != nil else { return }

    #if canImport(CoreMotion) && os(iOS)
      activityManager.stopActivityUpdates()
    #endif
    stopKeepalive()

    let notify = onReading
    onReading = nil
    isRunning = false
    let wasMoving = level != .stationary
    level = .stationary
    if wasMoving {
      notify?(.stationary)
    }
    logger.info("Movement hint monitor stopped")
  }

  // MARK: - Classification

  /// Maps one activity sample to a level, or `nil` to ignore it.
  ///
  /// Low-confidence and unclassifiable samples are ignored rather than folded into
  /// `.stationary`: CoreMotion emits them constantly at activity boundaries, and treating
  /// them as a reading would flap the level — and therefore the radio write — every few
  /// seconds. Running and driving both land on `.fast` because the firmware's cadence ladder
  /// has only three rungs; walking and cycling share `.slow` for the same reason.
  ///
  /// Taken as plain flags rather than a `CMMotionActivity` because that class cannot be
  /// constructed with chosen values, which would leave the mapping untestable.
  nonisolated static func level(
    stationary: Bool,
    walking: Bool,
    cycling: Bool,
    running: Bool,
    automotive: Bool,
    isLowConfidence: Bool
  ) -> MovementHint? {
    guard !isLowConfidence else { return nil }
    if stationary { return .stationary }
    if automotive || running { return .fast }
    if walking || cycling { return .slow }
    return nil
  }

  #if canImport(CoreMotion) && os(iOS)
    nonisolated static func level(from activity: CMMotionActivity) -> MovementHint? {
      level(
        stationary: activity.stationary,
        walking: activity.walking,
        cycling: activity.cycling,
        running: activity.running,
        automotive: activity.automotive,
        isLowConfidence: activity.confidence == .low
      )
    }
  #endif

  private func emit(_ level: MovementHint) {
    guard level != self.level else { return }
    self.level = level
    logger.debug("Movement level → \(level.rawValue)")
    onReading?(level)

    if level == .stationary {
      stopKeepalive()
    } else {
      startKeepaliveIfNeeded()
    }
  }

  // MARK: - Keepalive

  private func startKeepaliveIfNeeded() {
    guard keepaliveTask == nil else { return }
    let interval = keepaliveInterval
    keepaliveTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled, let self, level != .stationary else { return }
        onReading?(level)
      }
    }
  }

  private func stopKeepalive() {
    keepaliveTask?.cancel()
    keepaliveTask = nil
  }
}
