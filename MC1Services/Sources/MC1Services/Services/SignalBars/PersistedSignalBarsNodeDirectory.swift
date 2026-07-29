import Foundation
import os

/// The node pool ``SignalBarsEngine`` resolves repeater hashes against: this radio's saved
/// contacts plus every node it has passively discovered.
///
/// Both sources are handed over untouched — ranking, staleness and hash matching all belong
/// to ``NodeIdentityResolver``, which the engine already owns. This type's only job is to
/// read the two tables and not read them too often: the engine asks on every name-resolution
/// pass, and a busy mesh would otherwise turn each inbound packet into a pair of SwiftData
/// fetches.
///
/// A read failure keeps the previous pool rather than emptying it, so a transient store error
/// blanks no names that were already resolved.
public actor PersistedSignalBarsNodeDirectory: SignalBarsNodeDirectory {
  private let dataStore: any ContactPersisting & DiscoveredNodePersisting
  private let radioID: UUID
  private let cacheLifetime: TimeInterval
  private let now: @Sendable () -> Date
  private let logger = Logger(subsystem: "com.mc1", category: "SignalBarsDirectory")

  private var cached: [AnyResolvableNode] = []
  private var cachedAt: Date?

  /// - Parameters:
  ///   - dataStore: The persistence store holding contacts and discovered nodes.
  ///   - radioID: Scopes both fetches to the connected radio.
  ///   - cacheLifetime: How long a fetched pool is reused before the store is read again.
  ///   - now: The clock, injected so tests do not wait out the cache.
  public init(
    dataStore: any ContactPersisting & DiscoveredNodePersisting,
    radioID: UUID,
    cacheLifetime: TimeInterval = 30,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.dataStore = dataStore
    self.radioID = radioID
    self.cacheLifetime = cacheLifetime
    self.now = now
  }

  public func resolvableNodes() async -> [AnyResolvableNode] {
    let at = now()
    if let cachedAt, at.timeIntervalSince(cachedAt) < cacheLifetime {
      return cached
    }

    do {
      let contacts = try await dataStore.fetchContacts(radioID: radioID)
      let discovered = try await dataStore.fetchDiscoveredNodes(radioID: radioID)
      // Repeaters only: these names label rows in the *repeater* signal table. An
      // unfiltered pool lets a chat contact sharing a leading key byte win a hash
      // collision on advert recency and put a person's name next to a repeater's hex —
      // and it diverges from the repeater-narrowed pools every path view resolves with.
      cached = contacts.filter { $0.type == .repeater }.map(AnyResolvableNode.init)
        + discovered.filter { $0.nodeType == .repeater }.map(AnyResolvableNode.init)
      cachedAt = at
    } catch {
      logger.warning("Node directory read failed: \(error.localizedDescription)")
      // Keep whatever was last read; an empty pool would blank resolved names.
    }
    return cached
  }

  /// Drops the cached pool so the next lookup re-reads the store. Called when contacts or
  /// discovered nodes change and a repeater's name should update without waiting out the TTL.
  public func invalidate() {
    cachedAt = nil
  }
}
