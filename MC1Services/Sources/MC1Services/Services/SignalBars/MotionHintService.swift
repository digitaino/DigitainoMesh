import Foundation
import MeshCore
import os

/// Tells the radio how fast the phone is moving, so its own ping cadence can adapt without
/// turning on GPS.
///
/// The firmware keeps a movement level with a ~60-second staleness window: a moving radio
/// probes its neighbours more often, and the hint lapses back to stationary if nothing
/// refreshes it. That shapes the two rules here:
///
/// - **Only on change.** A repeated reading of the same level is not written, so a phone
///   sitting on a desk costs no radio traffic at all.
/// - **Keepalive while moving.** A non-stationary level is re-pushed every
///   ``refreshInterval`` (comfortably inside the firmware's window) so a steady activity —
///   an hour of walking — does not lapse back to stationary halfway through.
///
/// Writes are gated on ``SyncRegistryProbe`` advertising ``SyncID/motionHint``, so nothing is
/// ever sent to a radio that would just reject it. A rejection anyway (slot advertised but
/// refused) latches this service inert for the connection, matching ``NotifSyncService``.
///
/// The wire payload is `[version, level]` with version `1` and level 0/1/2 for
/// stationary/walking/driving — ``MovementHint``'s own raw values.
public actor MotionHintService {
  /// Payload version byte the firmware expects.
  static let wireVersion: UInt8 = 1

  private let session: any SyncRegistrySessionOps
  private let registry: SyncRegistryProbe
  private let refreshInterval: TimeInterval
  private let now: @Sendable () -> Date
  private let logger = Logger(subsystem: "com.mc1", category: "MotionHint")

  private var lastPushed: MovementHint?
  private var lastPushAt: Date?
  private var isRejected = false

  /// - Parameters:
  ///   - session: The radio's configuration ops, which own the sync registry writes.
  ///   - registry: The capability probe gating whether the slot exists at all.
  ///   - refreshInterval: How often a non-stationary level is re-pushed. Must stay inside
  ///     the firmware's staleness window.
  ///   - now: The clock, injected so tests do not wait out the keepalive.
  public init(
    session: any SyncRegistrySessionOps,
    registry: SyncRegistryProbe,
    refreshInterval: TimeInterval = 45,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.session = session
    self.registry = registry
    self.refreshInterval = refreshInterval
    self.now = now
  }

  /// Pushes a movement level to the radio when it is worth pushing.
  ///
  /// - Returns: `true` when a write actually went out, `false` when the level was redundant,
  ///   the slot is unavailable, or the write failed.
  @discardableResult
  public func push(_ hint: MovementHint) async -> Bool {
    guard !isRejected else { return false }
    guard await registry.supportsSlot(.motionHint) else { return false }

    let at = now()
    guard shouldPush(hint, at: at) else { return false }

    do {
      try await session.setSync(.motionHint, payload: Data([Self.wireVersion, hint.rawValue]))
      lastPushed = hint
      lastPushAt = at
      logger.debug("Pushed motion hint level \(hint.rawValue)")
      return true
    } catch let error as MeshCoreError where isRejection(error) {
      isRejected = true
      logger.info("Device rejected the motion-hint slot; motion hints disabled for this connection")
      return false
    } catch {
      // Transient: leave `lastPushed` alone so the next reading retries.
      logger.warning("Motion hint push failed: \(error.localizedDescription)")
      return false
    }
  }

  /// Forgets what was last sent, so the next reading is pushed even if the level is unchanged.
  /// Used when the radio's view of the hint may have been lost (a reconnect on the same
  /// container, a firmware reboot).
  public func reset() {
    lastPushed = nil
    lastPushAt = nil
  }

  // MARK: - Helpers

  private func shouldPush(_ hint: MovementHint, at: Date) -> Bool {
    guard let lastPushed else { return true }
    if hint != lastPushed { return true }
    // Same level: only the keepalive justifies a write, and only while moving.
    guard hint != .stationary, let lastPushAt else { return false }
    return at.timeIntervalSince(lastPushAt) >= refreshInterval
  }

  private func isRejection(_ error: MeshCoreError) -> Bool {
    error.deviceErrorCode == .unsupportedCommand
  }
}
