import Foundation
import os
import SwiftData

extension PersistenceStore {
  private static let migrationLogger = Logger(subsystem: "com.mc1", category: "RadioIDMigration")
  private static let migrationKey = "hasPopulatedRadioIDs"

  /// One-time migration: populate radioID on all Devices, then backfill
  /// deduplicationKey on outgoing Messages with nil keys.
  ///
  /// Children's radioID column already contains the old BLE UUID (`device.id`)
  /// via the `@Attribute(originalName: "deviceID")` rename, so the device simply
  /// adopts its own id as the radioID and every child row is reachable with zero
  /// rewrites. (An earlier revision minted a fresh UUID per device and rewrote
  /// every child table to match — on multi-year stores that materialized hundreds
  /// of thousands of rows through the model context in one transaction, which
  /// never finished inside a launch the user was willing to wait through, and the
  /// single atomic save meant an interrupted run left nothing behind. Equality of
  /// `radioID` and the legacy `id` is harmless: the field's purpose is stability
  /// against future BLE re-pairs, which the separate column provides regardless
  /// of its initial value.)
  public func performRadioIDMigration(defaults: UserDefaults = .standard) throws {
    Self.migrationLogger.info("radioID migration: entered")
    guard !defaults.bool(forKey: Self.migrationKey) else {
      Self.migrationLogger.info("radioID migration: already complete, skipping")
      return
    }

    // Step 1: each device adopts its legacy id as its radioID.
    let devices = try modelContext.fetch(FetchDescriptor<Device>())

    let lastDeviceIDString = defaults.string(forKey: PersistenceKeys.lastConnectedDeviceID)
    let lastDeviceID = lastDeviceIDString.flatMap(UUID.init)
    var mappedRadioID: UUID?

    for device in devices {
      device.radioID = device.id
      if device.id == lastDeviceID {
        mappedRadioID = device.id
      }
    }
    try modelContext.save()

    // Step 2: Backfill deduplicationKey on outgoing messages with nil keys.
    // Only outgoing (directionRawValue == 1); incoming messages get keys during re-sync.
    // Chunked with a save per batch: processed rows stop matching the predicate, so an
    // interrupted launch resumes where it left off instead of starting over.
    let outgoingDirection = MessageDirection.outgoing.rawValue
    let nilKeyPredicate = #Predicate<Message> { message in
      message.deduplicationKey == nil && message.directionRawValue == outgoingDirection
    }
    var backfilled = 0
    while true {
      var descriptor = FetchDescriptor(predicate: nilKeyPredicate)
      descriptor.fetchLimit = 500
      let batch = try modelContext.fetch(descriptor)
      guard !batch.isEmpty else { break }

      for message in batch {
        message.deduplicationKey = DeduplicationKey.contentBased(
          contactID: message.contactID,
          channelIndex: message.channelIndex,
          senderNodeName: message.senderNodeName,
          timestamp: message.timestamp,
          content: message.text
        )
      }
      try modelContext.save()
      backfilled += batch.count
    }

    if let mappedRadioID {
      defaults.set(mappedRadioID.uuidString, forKey: PersistenceKeys.lastConnectedRadioID)
    } else if lastDeviceID != nil {
      Self.migrationLogger.warning("lastConnectedDeviceID did not match any stored device; lastConnectedRadioID not backfilled")
    }

    defaults.set(true, forKey: Self.migrationKey)

    Self.migrationLogger.info("radioID migration complete: \(devices.count) devices, \(backfilled) dedup keys backfilled")
  }

  /// Resets the migration flag (for testing only).
  public func resetRadioIDMigrationFlag(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: Self.migrationKey)
  }

  // MARK: - Channel flood scope corrective migration

  private static let floodScopeMigrationKey = "hasMigratedChannelFloodScope"
  private static let floodScopeMigrationLogger = Logger(
    subsystem: "com.mc1",
    category: "ChannelFloodScopeMigration"
  )

  /// One-time migration: pre-existing rows were persisted before the flood-scope mode
  /// column existed and all come up with the default `.inherit` value, even when they
  /// had a per-channel `regionScope` override. Promote those to `.specific` so the
  /// user's prior choice keeps working. Rows whose `regionScope` was nil keep
  /// `.inherit` — corrective semantics, so the device default applies.
  public func performChannelFloodScopeMigration(defaults: UserDefaults = .standard) throws {
    guard !defaults.bool(forKey: Self.floodScopeMigrationKey) else { return }

    let inheritRaw = ChannelFloodScopeStorage.Mode.inherit.rawValue
    let specificRaw = ChannelFloodScopeStorage.Mode.specific.rawValue

    let predicate = #Predicate<Channel> { channel in
      channel.regionScope != nil && channel.floodScopeModeRawValue == inheritRaw
    }
    let channels = try modelContext.fetch(FetchDescriptor(predicate: predicate))
    for channel in channels {
      channel.floodScopeModeRawValue = specificRaw
    }
    try modelContext.save()

    defaults.set(true, forKey: Self.floodScopeMigrationKey)

    Self.floodScopeMigrationLogger.info(
      "channel flood-scope migration complete: \(channels.count) rows promoted to .specific"
    )
  }

  /// Resets the migration flag (for testing only).
  public func resetChannelFloodScopeMigrationFlag(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: Self.floodScopeMigrationKey)
  }

  // MARK: - Repeater unread-count corrective migration

  private static let repeaterUnreadMigrationKey = "hasMigratedRepeaterUnreadCounts"
  private static let repeaterUnreadMigrationLogger = Logger(
    subsystem: "com.mc1",
    category: "RepeaterUnreadMigration"
  )

  /// One-time migration: prior versions counted unread on repeater-type contacts and
  /// repeater-role node sessions toward the OS badge, even though those records are
  /// filtered out of the chats list and so unreachable to the user. Zero out any
  /// accumulated counters so the badge drops to a sane number on first launch after
  /// upgrading. The predicate fix in `getTotalUnreadCounts` prevents new accumulation
  /// from inflating the badge; this sweep clears the historical residue.
  public func performRepeaterUnreadCountMigration(defaults: UserDefaults = .standard) throws {
    guard !defaults.bool(forKey: Self.repeaterUnreadMigrationKey) else { return }

    let repeaterContactRaw = ContactType.repeater.rawValue
    let contactPredicate = #Predicate<Contact> { contact in
      contact.typeRawValue == repeaterContactRaw &&
        (contact.unreadCount > 0 || contact.unreadMentionCount > 0)
    }
    let contacts = try modelContext.fetch(FetchDescriptor(predicate: contactPredicate))
    for contact in contacts {
      contact.unreadCount = 0
      contact.unreadMentionCount = 0
    }

    let repeaterRoleRaw = RemoteNodeRole.repeater.rawValue
    let sessionPredicate = #Predicate<RemoteNodeSession> { session in
      session.roleRawValue == repeaterRoleRaw && session.unreadCount > 0
    }
    let sessions = try modelContext.fetch(FetchDescriptor(predicate: sessionPredicate))
    for session in sessions {
      session.unreadCount = 0
    }

    try modelContext.save()

    defaults.set(true, forKey: Self.repeaterUnreadMigrationKey)

    Self.repeaterUnreadMigrationLogger.info(
      "repeater unread migration complete: \(contacts.count) contacts, \(sessions.count) sessions cleared"
    )
  }

  /// Resets the migration flag (for testing only).
  public func resetRepeaterUnreadMigrationFlag(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: Self.repeaterUnreadMigrationKey)
  }

  // MARK: - Message sortDate normalization

  /// Normalizes every message's `sortDate` to its `createdAt`, guarded by a one-time flag.
  /// Shared by the backfill and reset migrations, which differ only in which flag gates
  /// them and what they log. Returns the row count, or `nil` when the flag was already set
  /// and the migration was skipped.
  private func normalizeMessageSortDates(flagKey: String, defaults: UserDefaults) throws -> Int? {
    guard !defaults.bool(forKey: flagKey) else { return nil }

    let messages = try modelContext.fetch(FetchDescriptor<Message>())
    for message in messages {
      message.sortDate = message.createdAt
    }
    try modelContext.save()

    defaults.set(true, forKey: flagKey)
    return messages.count
  }

  // MARK: - Message sortDate backfill migration

  private static let sortDateBackfillMigrationKey = "hasBackfilledMessageSortDate"
  private static let sortDateBackfillMigrationLogger = Logger(
    subsystem: "com.mc1",
    category: "SortDateBackfillMigration"
  )

  /// One-time backfill: pre-existing rows were persisted before the `sortDate`
  /// column existed and come up with the `Date.distantPast` schema default.
  /// Set `sortDate` to `createdAt` on every row so the date-header grouping
  /// preserves their current display order. This runs once at launch before
  /// any sync, so every row present is a pre-feature row.
  public func performSortDateBackfillMigration(defaults: UserDefaults = .standard) throws {
    guard let count = try normalizeMessageSortDates(flagKey: Self.sortDateBackfillMigrationKey, defaults: defaults) else { return }

    Self.sortDateBackfillMigrationLogger.info(
      "sortDate backfill complete: \(count) messages backfilled"
    )
  }

  /// Resets the migration flag (for testing only).
  public func resetSortDateBackfillMigrationFlag(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: Self.sortDateBackfillMigrationKey)
  }

  // MARK: - Message sortDate reset migration

  private static let sortDateResetMigrationKey = "hasResetMessageSortDate"
  private static let sortDateResetMigrationLogger = Logger(
    subsystem: "com.mc1",
    category: "SortDateResetMigration"
  )

  /// One-time reset: an interim build derived `sortDate` from the sender's send time,
  /// which buried just-synced backlog deep in scrollback. The original backfill
  /// (`performSortDateBackfillMigration`) already ran on those installs, so its flag is
  /// set and it can no longer touch the rows. Re-normalize every row's `sortDate` to
  /// `createdAt` so block-at-reconnect ordering starts from a clean receive-time baseline;
  /// subsequent syncs derive a fresh drain anchor per batch. Runs once at launch before
  /// any sync, so every row present is a pre-feature row.
  public func performSortDateResetMigration(defaults: UserDefaults = .standard) throws {
    guard let count = try normalizeMessageSortDates(flagKey: Self.sortDateResetMigrationKey, defaults: defaults) else { return }

    Self.sortDateResetMigrationLogger.info(
      "sortDate reset complete: \(count) messages re-normalized to createdAt"
    )
  }

  /// Resets the migration flag (for testing only).
  public func resetSortDateResetMigrationFlag(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: Self.sortDateResetMigrationKey)
  }
}
