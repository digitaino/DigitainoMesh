import Foundation
@testable import MC1Services
import Testing

@Suite("Legacy global notifications switch migration")
struct LegacyNotificationSwitchMigrationTests {
  /// Fresh, isolated defaults domain per test; the migration writes real keys.
  private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suiteName = "test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    try body(defaults)
  }

  private func enabled(_ key: AppStorageKey, in defaults: UserDefaults) -> Bool? {
    defaults.object(forKey: key.rawValue) as? Bool
  }

  // MARK: - Fan-out

  @Test
  func `Legacy switch set to false disables every per-category toggle`() throws {
    try withDefaults { defaults in
      defaults.set(false, forKey: LegacyNotificationSwitchMigration.legacyGlobalKey)

      #expect(LegacyNotificationSwitchMigration.run(defaults: defaults))

      for key in LegacyNotificationSwitchMigration.targetKeys {
        #expect(enabled(key, in: defaults) == false, "\(key.rawValue) should have been switched off")
      }
    }
  }

  @Test
  func `Fan-out covers exactly the post-or-not toggles, not sound or badge`() throws {
    try withDefaults { defaults in
      defaults.set(false, forKey: LegacyNotificationSwitchMigration.legacyGlobalKey)

      LegacyNotificationSwitchMigration.run(defaults: defaults)

      // Sound and badge shape an already-posted notification, so a global "off"
      // says nothing about them: they must stay unwritten (i.e. at their defaults).
      #expect(enabled(.notificationSoundEnabled, in: defaults) == nil)
      #expect(enabled(.notificationBadgeEnabled, in: defaults) == nil)
    }
  }

  // MARK: - No-ops

  @Test
  func `Absent legacy key silences nothing`() throws {
    try withDefaults { defaults in
      #expect(LegacyNotificationSwitchMigration.run(defaults: defaults) == false)

      for key in LegacyNotificationSwitchMigration.targetKeys {
        #expect(enabled(key, in: defaults) == nil, "\(key.rawValue) must be left at its v2 default")
      }
    }
  }

  @Test
  func `Legacy switch left on silences nothing`() throws {
    try withDefaults { defaults in
      defaults.set(true, forKey: LegacyNotificationSwitchMigration.legacyGlobalKey)

      #expect(LegacyNotificationSwitchMigration.run(defaults: defaults) == false)

      for key in LegacyNotificationSwitchMigration.targetKeys {
        #expect(enabled(key, in: defaults) == nil)
      }
    }
  }

  // MARK: - Latch

  @Test
  func `Latch is set even when nothing was migrated`() throws {
    try withDefaults { defaults in
      LegacyNotificationSwitchMigration.run(defaults: defaults)

      #expect(defaults.bool(forKey: LegacyNotificationSwitchMigration.latchKey))
    }
  }

  @Test
  func `A later re-enable in v2 survives a second run`() throws {
    try withDefaults { defaults in
      defaults.set(false, forKey: LegacyNotificationSwitchMigration.legacyGlobalKey)
      LegacyNotificationSwitchMigration.run(defaults: defaults)

      // User turns one category back on in v2's Settings, legacy key still false.
      defaults.set(true, forKey: AppStorageKey.notifyContactMessages.rawValue)

      #expect(LegacyNotificationSwitchMigration.run(defaults: defaults) == false)
      #expect(enabled(.notifyContactMessages, in: defaults) == true)
    }
  }

  @Test
  func `Resetting the latch makes the migration runnable again`() throws {
    try withDefaults { defaults in
      defaults.set(false, forKey: LegacyNotificationSwitchMigration.legacyGlobalKey)
      LegacyNotificationSwitchMigration.run(defaults: defaults)
      defaults.set(true, forKey: AppStorageKey.notifyContactMessages.rawValue)

      LegacyNotificationSwitchMigration.resetLatch(defaults: defaults)

      #expect(LegacyNotificationSwitchMigration.run(defaults: defaults))
      #expect(enabled(.notifyContactMessages, in: defaults) == false)
    }
  }

  @Test
  func `Legacy key is left in place so the migration stays repeatable`() throws {
    try withDefaults { defaults in
      defaults.set(false, forKey: LegacyNotificationSwitchMigration.legacyGlobalKey)

      LegacyNotificationSwitchMigration.run(defaults: defaults)

      #expect(defaults.object(forKey: LegacyNotificationSwitchMigration.legacyGlobalKey) as? Bool == false)
    }
  }
}
