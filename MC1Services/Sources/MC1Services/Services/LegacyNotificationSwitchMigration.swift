import Foundation
import os

/// One-shot translation of Build 40's global notifications kill-switch into v2's
/// per-category toggles.
///
/// Build 40 gated *every* notification post behind a single `notificationsEnabled`
/// `UserDefaults` bool (`NotificationService`, Build 40). v2 has no global switch — it
/// reads the per-category `notify*` keys in `AppStorageKey`, each defaulting to
/// `AppStorageKey.defaultNotificationEnabled` (true). So a Build 40 user who had turned
/// notifications off would silently get every category switched back on by the in-place
/// update. This migration carries their choice across.
///
/// Runs at app launch (not radio connect — the preference has nothing to do with a radio,
/// and a user who never connects still deserves the silence they asked for), and latches on
/// a `UserDefaults` flag the same way `performRadioIDMigration` /
/// `performChannelFloodScopeMigration` / `hasMigratedContactFavorites` do, so a later
/// deliberate re-enable in v2's Settings is never stomped by a second run.
///
/// The legacy key is left in place: it costs nothing, and deleting it would make the
/// migration unrepeatable if the latch ever had to be reset.
public enum LegacyNotificationSwitchMigration {
  private static let logger = Logger(subsystem: "com.mc1", category: "LegacyNotificationSwitchMigration")

  /// Latch flag. Not an `AppStorageKey` case — migration flags are internal bookkeeping,
  /// matching `hasPopulatedRadioIDs` and `hasMigratedContactFavorites`.
  static let latchKey = "hasMigratedLegacyNotificationsSwitch"

  /// Build 40's global switch, written as a bare literal by its `NotificationService`.
  static let legacyGlobalKey = "notificationsEnabled"

  /// Per-category keys the global switch used to gate. Sound and badge are deliberately
  /// absent: they shape a notification that is already being posted rather than deciding
  /// whether to post one, so a global "off" says nothing about them.
  /// Computed rather than a stored `static let`: `AppStorageKey` is not `Sendable`, so a
  /// stored global of it trips the strict-concurrency check.
  static var targetKeys: [AppStorageKey] {
    [
      .notifyContactMessages,
      .notifyChannelMessages,
      .notifyRoomMessages,
      .notifyNewContacts,
      .notifyReactions,
      .notifyLowBattery
    ]
  }

  /// Fans `notificationsEnabled == false` out to every per-category toggle, once.
  ///
  /// No-op when the latch is already set, when the legacy key was never written (a
  /// fresh v2 install, or a Build 40 user who never touched the switch), or when it
  /// was left at `true` — in which case v2's defaults already agree with it. The latch
  /// is set in all of those cases too: the question is asked once per install, never again.
  ///
  /// - Returns: `true` when the per-category keys were actually written.
  @discardableResult
  public static func run(defaults: UserDefaults = .standard) -> Bool {
    guard !defaults.bool(forKey: latchKey) else { return false }

    // `object(forKey:)` rather than `bool(forKey:)` so an absent key is distinguishable
    // from an explicit `false`; a missing key must not silence anything.
    let legacyValue = defaults.object(forKey: legacyGlobalKey) as? Bool
    let shouldSilence = legacyValue == false

    if shouldSilence {
      for key in targetKeys {
        defaults.set(false, forKey: key.rawValue)
      }
      logger.info("Legacy global notifications switch was off; disabled \(targetKeys.count) per-category toggles")
    }

    defaults.set(true, forKey: latchKey)
    return shouldSilence
  }

  /// Resets the latch (for testing only).
  static func resetLatch(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: latchKey)
  }
}
