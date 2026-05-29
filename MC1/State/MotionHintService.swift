import Foundation
import os
#if canImport(CoreMotion)
import CoreMotion
#endif

/// Bridges the phone's motion-activity classifier (CoreMotion — runs on the motion
/// coprocessor, near-zero battery, no GPS) to a coarse motion level:
/// `0` stationary · `1` slow (walking/cycling) · `2` fast (running/automotive).
///
/// `AppState` routes the level to the device in viewer mode (via
/// `SYNC_ID_MOTION_HINT`) or to `SignalBarsService` in engine mode, so ping cadence
/// adapts when the radio's own GPS is off/idle. Degrades silently if motion data is
/// unavailable or the user denies Motion & Fitness access.
@MainActor
final class MotionHintService {

    private let logger = Logger(subsystem: "com.mc1", category: "MotionHint")
    private var onLevelChange: ((UInt8) -> Void)?
    private var currentLevel: UInt8 = 0
    private var keepaliveTimer: Timer?

    /// Re-emit interval while moving, comfortably inside the firmware's 60s staleness
    /// window so a steady activity (e.g. continuous walking) keeps the hint fresh.
    private let keepaliveInterval: TimeInterval = 45

#if canImport(CoreMotion) && os(iOS)
    private let activityManager = CMMotionActivityManager()
#endif

    /// Begin classifying motion. `onLevelChange` is called on the main actor whenever
    /// the level changes, plus periodically while moving (keepalive).
    func start(onLevelChange: @escaping (UInt8) -> Void) {
        self.onLevelChange = onLevelChange
        currentLevel = 0
#if canImport(CoreMotion) && os(iOS)
        guard CMMotionActivityManager.isActivityAvailable() else {
            logger.info("Motion activity unavailable on this device; motion hint disabled")
            return
        }
        activityManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity, let level = MotionHintService.level(from: activity) else { return }
            Task { @MainActor [weak self] in self?.emit(level) }
        }
        logger.info("MotionHintService started")
#else
        logger.info("CoreMotion unavailable on this platform; motion hint disabled")
#endif
    }

    func stop() {
#if canImport(CoreMotion) && os(iOS)
        activityManager.stopActivityUpdates()
#endif
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        onLevelChange = nil
        currentLevel = 0
        logger.info("MotionHintService stopped")
    }

#if canImport(CoreMotion) && os(iOS)
    /// Map a CoreMotion activity to a level, or `nil` to ignore it
    /// (low-confidence or unknown — keep the current level to avoid flapping).
    private static func level(from activity: CMMotionActivity) -> UInt8? {
        guard activity.confidence != .low else { return nil }
        if activity.stationary { return 0 }
        if activity.automotive || activity.running { return 2 }
        if activity.walking || activity.cycling { return 1 }
        return nil
    }
#endif

    private func emit(_ level: UInt8) {
        let changed = (level != currentLevel)
        currentLevel = level
        if changed {
            logger.debug("motion level → \(level)")
            onLevelChange?(level)
        }
        // Keepalive while moving; cancel it once stationary.
        if level > 0 {
            if keepaliveTimer == nil {
                keepaliveTimer = Timer.scheduledTimer(withTimeInterval: keepaliveInterval, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.currentLevel > 0 else { return }
                        self.onLevelChange?(self.currentLevel)
                    }
                }
            }
        } else {
            keepaliveTimer?.invalidate()
            keepaliveTimer = nil
        }
    }
}
