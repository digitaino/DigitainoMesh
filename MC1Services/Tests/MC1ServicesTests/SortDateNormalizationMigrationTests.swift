import Foundation
@testable import MC1Services
import SwiftData
import Testing

@Suite("Message sortDate normalization migration", .serialized)
struct SortDateNormalizationMigrationTests {
  /// The legacy per-era flag keys, spelled out here because the migration must keep honoring
  /// both: stores that ran the original backfill and stores that ran the send-time reset are
  /// already migrated and must not be rewritten again.
  private static let backfillFlagKey = "hasBackfilledMessageSortDate"
  private static let resetFlagKey = "hasResetMessageSortDate"

  private func createTestStore() async throws -> PersistenceStore {
    let container = try PersistenceStore.createContainer(inMemory: true)
    return PersistenceStore(modelContainer: container)
  }

  @Test
  func `Pre-existing rows get sortDate normalized to createdAt`() async throws {
    let suiteName = "test.\(UUID().uuidString)"
    // UserDefaults is thread-safe but not marked Sendable, so reusing this value
    // across the performSortDateNormalizationMigration actor boundary needs the isolation opt-out.
    nonisolated(unsafe) let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }

    let store = try await createTestStore()
    let radioID = UUID()

    let firstCreatedAt = Date(timeIntervalSince1970: 1_704_067_200)
    try await store.insertMessageWithSortDate(
      id: UUID(),
      radioID: radioID,
      text: "Hello",
      createdAt: firstCreatedAt,
      sortDate: .distantPast
    )

    let secondCreatedAt = Date(timeIntervalSince1970: 1_704_070_800)
    try await store.insertMessageWithSortDate(
      id: UUID(),
      radioID: radioID,
      text: "World",
      createdAt: secondCreatedAt,
      sortDate: .distantPast
    )

    try await store.performSortDateNormalizationMigration(defaults: defaults)

    let messages = try await store.fetchAllMessages()
    #expect(messages.count == 2)
    for message in messages {
      #expect(message.sortDate == message.createdAt)
    }
  }

  @Test
  func `A send-time sortDate is re-normalized even after the legacy backfill flag was set`() async throws {
    let suiteName = "test.\(UUID().uuidString)"
    nonisolated(unsafe) let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }

    // A row buried by the interim send-time sort: createdAt is the drain time, but sortDate
    // was written far in the past from the sender's clock. The original backfill already ran
    // on this install, so only the second flag can still let the pass through.
    defaults.set(true, forKey: Self.backfillFlagKey)

    let store = try await createTestStore()
    let messageID = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_704_067_200)
    try await store.insertMessageWithSortDate(
      id: messageID,
      radioID: UUID(),
      text: "Buried backlog",
      createdAt: createdAt,
      sortDate: Date(timeIntervalSince1970: 1_700_000_000)
    )

    try await store.performSortDateNormalizationMigration(defaults: defaults)

    #expect(try await store.fetchMessage(id: messageID)?.sortDate == createdAt)
  }

  @Test
  func `One pass satisfies both legacy flags, so neither era re-runs`() async throws {
    let suiteName = "test.\(UUID().uuidString)"
    nonisolated(unsafe) let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }

    let store = try await createTestStore()
    try await store.performSortDateNormalizationMigration(defaults: defaults)

    #expect(defaults.bool(forKey: Self.backfillFlagKey))
    #expect(defaults.bool(forKey: Self.resetFlagKey))
  }

  @Test
  func `Migration is idempotent — second run is a no-op`() async throws {
    let suiteName = "test.\(UUID().uuidString)"
    nonisolated(unsafe) let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }

    let store = try await createTestStore()
    let messageID = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_704_067_200)
    try await store.insertMessageWithSortDate(
      id: messageID,
      radioID: UUID(),
      text: "Hello",
      createdAt: createdAt,
      sortDate: .distantPast
    )

    try await store.performSortDateNormalizationMigration(defaults: defaults)
    #expect(try await store.fetchMessage(id: messageID)?.sortDate == createdAt)

    // Re-skew the row after the first run. A second call with the flags set must not touch
    // it — otherwise the normalization would rewrite the table every launch.
    try await store.setMessageSortDate(id: messageID, sortDate: .distantPast)
    try await store.performSortDateNormalizationMigration(defaults: defaults)

    #expect(try await store.fetchMessage(id: messageID)?.sortDate == .distantPast, "second run must be a no-op")
  }

  @Test
  func `Normalization spans more rows than one batch`() async throws {
    let suiteName = "test.\(UUID().uuidString)"
    nonisolated(unsafe) let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }

    let store = try await createTestStore()
    let radioID = UUID()
    // One full batch plus a remainder, so a pass that stopped after its first fetch would
    // leave rows skewed.
    let rowCount = 600
    for offset in 0..<rowCount {
      try await store.insertMessageWithSortDate(
        id: UUID(),
        radioID: radioID,
        text: "Message \(offset)",
        createdAt: Date(timeIntervalSince1970: 1_704_067_200 + Double(offset)),
        sortDate: .distantPast
      )
    }

    try await store.performSortDateNormalizationMigration(defaults: defaults)

    let messages = try await store.fetchAllMessages()
    #expect(messages.count == rowCount)
    #expect(messages.allSatisfy { $0.sortDate == $0.createdAt })
  }
}
