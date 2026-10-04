import Foundation
import Security

/// A node this iPhone remembers the key of, offered when a new radio can be set up as it.
public struct SavedIdentity: Sendable, Equatable, Identifiable {
  public let publicKey: Data
  public let nodeName: String

  public var id: Data {
    publicKey
  }

  public init(publicKey: Data, nodeName: String) {
    self.publicKey = publicKey
    self.nodeName = nodeName
  }
}

public enum IdentityKeyVaultError: Error, Sendable {
  case invalidKey
  case keychain(OSStatus)
}

/// Where the vault keeps its items: the Keychain in the app, memory in tests.
protocol IdentityKeyStorage: Sendable {
  func write(account: String, label: String, data: Data) throws
  func read(account: String) throws -> Data?
  func list() throws -> [(account: String, label: String)]
  func delete(account: String) throws
  func deleteAll() throws
}

/// Keeps each node's private key on this iPhone (docs/RADIO_SWAP.md, rule R5), so a new or
/// reflashed radio can be set up as that node without the old radio present. The app already
/// reads the key on every connect, for DM decryption; this keeps a copy.
///
/// Items are device-only and readable after first unlock: never synced to iCloud, never
/// restored onto another device, and never in the app's own `.mc1backup` files, which hold no
/// Keychain items. The app never shows or exports a saved key; it only writes it to a radio.
public actor IdentityKeyVault {
  public static let shared = IdentityKeyVault(storage: KeychainIdentityKeyStorage())

  private let storage: any IdentityKeyStorage

  init(storage: any IdentityKeyStorage) {
    self.storage = storage
  }

  /// Whether the user lets this iPhone keep node keys (Settings › Advanced › Identity). On by
  /// default: owner decision 1 of docs/RADIO_SWAP.md §5.
  public nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: AppStorageKey.keepNodeKeysOnPhone.rawValue) as? Bool
      ?? AppStorageKey.defaultKeepNodeKeysOnPhone
  }

  public func save(privateKey: Data, publicKey: Data, nodeName: String) throws {
    do {
      try KeyGenerationService.validateExpandedKey(privateKey)
    } catch {
      throw IdentityKeyVaultError.invalidKey
    }
    guard publicKey.count == ProtocolLimits.publicKeySize else { throw IdentityKeyVaultError.invalidKey }
    try storage.write(account: publicKey.uppercaseHexString(), label: nodeName, data: privateKey)
  }

  public func privateKey(for publicKey: Data) throws -> Data? {
    try storage.read(account: publicKey.uppercaseHexString())
  }

  public func savedIdentities() throws -> [SavedIdentity] {
    try storage.list().compactMap { item in
      Data(hexString: item.account).map { SavedIdentity(publicKey: $0, nodeName: item.label) }
    }
  }

  public func forget(publicKey: Data) throws {
    try storage.delete(account: publicKey.uppercaseHexString())
  }

  public func forgetAll() throws {
    try storage.deleteAll()
  }
}

/// Generic-password items under one service, keyed by the node's public key in hex, labelled
/// with its name so the list can be read without touching the keys themselves.
struct KeychainIdentityKeyStorage: IdentityKeyStorage {
  private let service = "com.digitaino.mesh.node-identity-keys"

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrSynchronizable as String: false
    ]
  }

  func write(account: String, label: String, data: Data) throws {
    var match = baseQuery
    match[kSecAttrAccount as String] = account
    SecItemDelete(match as CFDictionary)

    var add = match
    add[kSecAttrLabel as String] = label
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { throw IdentityKeyVaultError.keychain(status) }
  }

  func read(account: String) throws -> Data? {
    var query = baseQuery
    query[kSecAttrAccount as String] = account
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw IdentityKeyVaultError.keychain(status) }
    return result as? Data
  }

  func list() throws -> [(account: String, label: String)] {
    var query = baseQuery
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else { throw IdentityKeyVaultError.keychain(status) }
    let items = result as? [[String: Any]] ?? []
    return items.compactMap { item in
      guard let account = item[kSecAttrAccount as String] as? String else { return nil }
      return (account, item[kSecAttrLabel as String] as? String ?? "")
    }
  }

  func delete(account: String) throws {
    var query = baseQuery
    query[kSecAttrAccount as String] = account
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw IdentityKeyVaultError.keychain(status)
    }
  }

  func deleteAll() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw IdentityKeyVaultError.keychain(status)
    }
  }
}
