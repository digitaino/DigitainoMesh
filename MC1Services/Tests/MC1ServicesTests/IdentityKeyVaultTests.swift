import Foundation
@testable import MC1Services
import os
import Testing

/// docs/RADIO_SWAP.md R5: the phone keeps each node's key so a new radio can be set up as it.
@Suite("Identity key vault")
struct IdentityKeyVaultTests {
  /// Memory instead of the Keychain, which the macOS test host cannot use.
  private final class MemoryStorage: IdentityKeyStorage, @unchecked Sendable {
    private let items = OSAllocatedUnfairLock(initialState: [String: (label: String, data: Data)]())

    func write(account: String, label: String, data: Data) throws {
      items.withLock { $0[account] = (label, data) }
    }

    func read(account: String) throws -> Data? {
      items.withLock { $0[account]?.data }
    }

    func list() throws -> [(account: String, label: String)] {
      items.withLock { $0.map { ($0.key, $0.value.label) } }
    }

    func delete(account: String) throws {
      items.withLock { _ = $0.removeValue(forKey: account) }
    }

    func deleteAll() throws {
      items.withLock { $0.removeAll() }
    }
  }

  private static func generate() async throws -> (privateKey: Data, publicKey: Data) {
    let identity = try await KeyGenerationService.generateIdentity(hexPrefix: nil)
    return (identity.expandedPrivateKey, identity.publicKey)
  }

  @Test
  func `A saved key comes back under its node's public key and name`() async throws {
    let vault = IdentityKeyVault(storage: MemoryStorage())
    let node = try await Self.generate()

    try await vault.save(privateKey: node.privateKey, publicKey: node.publicKey, nodeName: "Digitaino")

    #expect(try await vault.privateKey(for: node.publicKey) == node.privateKey)
    #expect(try await vault.savedIdentities() == [SavedIdentity(publicKey: node.publicKey, nodeName: "Digitaino")])
  }

  @Test
  func `Saving again under the same key replaces the name, not adds a second entry`() async throws {
    let vault = IdentityKeyVault(storage: MemoryStorage())
    let node = try await Self.generate()

    try await vault.save(privateKey: node.privateKey, publicKey: node.publicKey, nodeName: "Old")
    try await vault.save(privateKey: node.privateKey, publicKey: node.publicKey, nodeName: "Digitaino")

    #expect(try await vault.savedIdentities().map(\.nodeName) == ["Digitaino"])
  }

  @Test
  func `A key that is not a valid expanded private key is refused`() async throws {
    let vault = IdentityKeyVault(storage: MemoryStorage())

    await #expect(throws: IdentityKeyVaultError.self) {
      try await vault.save(
        privateKey: Data(repeating: 0xFF, count: 64),
        publicKey: Data(repeating: 0x01, count: 32),
        nodeName: "Bad"
      )
    }
    #expect(try await vault.savedIdentities().isEmpty)
  }

  @Test
  func `Forgetting removes one node, forgetting all removes every node`() async throws {
    let vault = IdentityKeyVault(storage: MemoryStorage())
    let first = try await Self.generate()
    let second = try await Self.generate()
    try await vault.save(privateKey: first.privateKey, publicKey: first.publicKey, nodeName: "First")
    try await vault.save(privateKey: second.privateKey, publicKey: second.publicKey, nodeName: "Second")

    try await vault.forget(publicKey: first.publicKey)
    #expect(try await vault.privateKey(for: first.publicKey) == nil)
    #expect(try await vault.savedIdentities().map(\.nodeName) == ["Second"])

    try await vault.forgetAll()
    #expect(try await vault.savedIdentities().isEmpty)
  }

  @Test
  func `Keeping keys is on unless the user turned it off`() throws {
    let name = "IdentityKeyVaultTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }

    #expect(IdentityKeyVault.isEnabled(defaults: defaults))
    defaults.set(false, forKey: AppStorageKey.keepNodeKeysOnPhone.rawValue)
    #expect(!IdentityKeyVault.isEnabled(defaults: defaults))
  }
}
