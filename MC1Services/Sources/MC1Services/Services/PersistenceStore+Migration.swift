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

    // Persisted before step 2 rather than after it: the mapping is already known here, and
    // a throw inside the batch loop would otherwise leave the conversation list without a
    // last-connected radio for one launch.
    if let mappedRadioID {
      defaults.set(mappedRadioID.uuidString, forKey: PersistenceKeys.lastConnectedRadioID)
    } else if lastDeviceID != nil {
      Self.migrationLogger.warning("lastConnectedDeviceID did not match any stored device; lastConnectedRadioID not backfilled")
    }

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

  // MARK: - Message sortDate normalization migration

  /// Both legacy flags. The backfill (rows persisted before the `sortDate` column existed,
  /// which come up with the `Date.distantPast` schema default) and the reset (an interim
  /// build derived `sortDate` from the sender's send time, burying just-synced backlog deep
  /// in scrollback) assign the same value, so a store owing either one owes exactly one
  /// rewrite and completing it satisfies both. The keys are kept separate so already-migrated
  /// stores from both eras stay migrated.
  private static let sortDateMigrationKeys = ["hasBackfilledMessageSortDate", "hasResetMessageSortDate"]
  private static let sortDateMigrationLogger = Logger(
    subsystem: "com.mc1",
    category: "SortDateNormalizationMigration"
  )

  /// One-time normalization: set every message's `sortDate` to its `createdAt` so date-header
  /// grouping preserves the rows' current display order and block-at-reconnect ordering starts
  /// from a clean receive-time baseline; subsequent syncs derive a fresh drain anchor per batch.
  /// Runs once at launch before any sync, so every row present is a pre-feature row.
  ///
  /// Chunked with a save per batch: normalized rows stop matching the predicate, so an
  /// interrupted launch resumes where it left off instead of discarding the whole rewrite.
  public func performSortDateNormalizationMigration(defaults: UserDefaults = .standard) throws {
    guard Self.sortDateMigrationKeys.contains(where: { !defaults.bool(forKey: $0) }) else { return }

    let skewedPredicate = #Predicate<Message> { message in
      message.sortDate != message.createdAt
    }
    // Normalized rows dropping out of the predicate is what advances the loop, so bound it by
    // the table size: every row needs at most one rewrite, and a stored Date that somehow did
    // not compare equal after its save must not spin the launch path forever.
    let rowBudget = try modelContext.fetchCount(FetchDescriptor<Message>())
    var normalized = 0
    while normalized < rowBudget {
      var descriptor = FetchDescriptor(predicate: skewedPredicate)
      descriptor.fetchLimit = 500
      let batch = try modelContext.fetch(descriptor)
      guard !batch.isEmpty else { break }

      for message in batch {
        message.sortDate = message.createdAt
      }
      try modelContext.save()
      normalized += batch.count
    }

    for key in Self.sortDateMigrationKeys {
      defaults.set(true, forKey: key)
    }

    Self.sortDateMigrationLogger.info(
      "sortDate normalization complete: \(normalized) messages normalized to createdAt"
    )
  }

  /// Resets the migration flags (for testing only).
  public func resetSortDateNormalizationMigrationFlags(defaults: UserDefaults = .standard) {
    for key in Self.sortDateMigrationKeys {
      defaults.removeObject(forKey: key)
    }
  }
}
