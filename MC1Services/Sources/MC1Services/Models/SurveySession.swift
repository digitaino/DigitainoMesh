import Foundation
import SwiftData

/// Dormant model — no UI, no services, no queries.
///
/// Registered in `PersistenceStore.schema` for one reason only: Build 40 (the shipped
/// fork) persisted signal-survey sessions in this table, and Build 40 users update in
/// place onto the same store. Dropping the entity from the schema would make SwiftData's
/// lightweight migration delete the table and every row in it. Keeping the model dormant
/// preserves that data untouched until the redesigned signal mapper (see
/// `docs/MIGRATION_PLAN.md`) is ready to read it.
///
/// Stored property names, types and optionality mirror Build 40's
/// `MC1Services/.../Models/SurveySession.swift` exactly, apart from the
/// `deviceID` → `radioID` rename, which uses the same `@Attribute(originalName:)`
/// mapping every other migrated entity uses (Contact, Message, Channel, Reaction,
/// RxLogEntry, RemoteNodeSession, DiscoveredNode, SavedTracePath, BlockedChannelSender).
/// The values in the column are the legacy BLE device UUIDs, which is exactly what
/// `PersistenceStore.performRadioIDMigration` makes every other child table's radioID
/// mean, so the rows stay joinable to `Device.radioID` with zero rewrites.
///
/// A session groups all survey points recorded during a single wardriving run.
/// Do not add behaviour here; add it alongside the signal mapper when it lands.
@Model
final class SurveySession {
  @Attribute(.unique)
  var id: UUID

  /// The radio this session was recorded on (Build 40 column name: `deviceID`).
  @Attribute(originalName: "deviceID")
  var radioID: UUID

  var startedAt: Date

  var endedAt: Date?

  var name: String?

  /// JSON-encoded `[String: Int]` mapping hex cell keys to probe counts sent.
  /// Used to reconstruct dead zone cells when loading old sessions.
  var probesSentData: Data?

  /// JSON-encoded completion stats computed when the session stopped.
  /// Allows revisiting stats without recomputing from grid cells.
  var completionStatsData: Data?

  init(
    id: UUID = UUID(),
    radioID: UUID,
    startedAt: Date = Date(),
    endedAt: Date? = nil,
    name: String? = nil,
    probesSentData: Data? = nil,
    completionStatsData: Data? = nil
  ) {
    self.id = id
    self.radioID = radioID
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.name = name
    self.probesSentData = probesSentData
    self.completionStatsData = completionStatsData
  }
}
