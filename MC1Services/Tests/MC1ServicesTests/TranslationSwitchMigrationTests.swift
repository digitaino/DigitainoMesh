import Foundation
@testable import MC1Services
import Testing

@Suite("Translation switch migration")
struct TranslationSwitchMigrationTests {
  private static func makeDefaults() throws -> (UserDefaults, String) {
    let name = "TranslationSwitchMigrationTests.\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: name)), name)
  }

  @Test
  func `An Offer Translation switched off carries into the Language setting, once`() throws {
    let (defaults, name) = try Self.makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(false, forKey: AppStorageKey.messageTranslationEnabled.rawValue)

    #expect(TranslationSwitchMigration.run(defaults: defaults))
    #expect(defaults.object(forKey: AppStorageKey.translationOffersEnabled.rawValue) as? Bool == false)

    // A later re-enable in Settings is never stomped by a second run.
    defaults.set(true, forKey: AppStorageKey.translationOffersEnabled.rawValue)
    #expect(!TranslationSwitchMigration.run(defaults: defaults))
    #expect(defaults.bool(forKey: AppStorageKey.translationOffersEnabled.rawValue))
  }

  @Test
  func `An untouched or switched-on Offer Translation writes nothing`() throws {
    let (defaults, name) = try Self.makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }

    #expect(!TranslationSwitchMigration.run(defaults: defaults))
    #expect(defaults.object(forKey: AppStorageKey.translationOffersEnabled.rawValue) == nil)
  }

  @Test
  func `A Language setting already chosen wins`() throws {
    let (defaults, name) = try Self.makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(false, forKey: AppStorageKey.messageTranslationEnabled.rawValue)
    defaults.set(true, forKey: AppStorageKey.translationOffersEnabled.rawValue)

    #expect(!TranslationSwitchMigration.run(defaults: defaults))
    #expect(defaults.bool(forKey: AppStorageKey.translationOffersEnabled.rawValue))
  }
}
