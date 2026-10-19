import Foundation
import os

/// One-shot carry-over of the fork's "Offer Translation" switch into upstream's.
///
/// The fork added `messageTranslationEnabled` (Settings › Messages) on 2026-08-31 to hide the
/// in-bubble Translate control; upstream 1.5 added the same switch as
/// `translationOffersEnabled` (Settings › Language). Two switches for one control is one too
/// many, so the fork's is retired and a user who had turned it off keeps it off.
///
/// Latches like ``LegacyNotificationSwitchMigration``; the retired key is left in place.
public enum TranslationSwitchMigration {
  private static let logger = Logger(subsystem: "com.mc1", category: "TranslationSwitchMigration")

  static let latchKey = "hasMigratedMessageTranslationSwitch"

  /// - Returns: `true` when upstream's switch was written.
  @discardableResult
  public static func run(defaults: UserDefaults = .standard) -> Bool {
    guard !defaults.bool(forKey: latchKey) else { return false }
    defer { defaults.set(true, forKey: latchKey) }

    // Only an explicit "off" carries; an absent key or "on" already matches upstream's default.
    guard defaults.object(forKey: AppStorageKey.messageTranslationEnabled.rawValue) as? Bool == false,
          defaults.object(forKey: AppStorageKey.translationOffersEnabled.rawValue) == nil else { return false }
    defaults.set(false, forKey: AppStorageKey.translationOffersEnabled.rawValue)
    logger.info("Carried 'Offer Translation' off into the Language setting")
    return true
  }
}
