import Foundation
import SwiftData

/// Dormant model — no UI, no services, no queries.
///
/// Registered in `PersistenceStore.schema` purely to preserve Build 40 user data across
/// the in-place update to v2; see `SurveySession` for the full rationale. Each row pairs a
/// received RF packet with the user's GPS location at reception time — the raw material the
/// redesigned signal mapper will need, and unrecoverable if the table is dropped.
///
/// Stored property names, types and optionality mirror Build 40's
/// `MC1Services/.../Models/SignalSurveyPoint.swift` exactly, apart from the
/// `deviceID` → `radioID` rename via `@Attribute(originalName:)`, matching every other
/// migrated entity. `surveySessionID` is deliberately a plain UUID rather than a SwiftData
/// relationship: Build 40 stored it that way (there is no relationship between these two
/// entities to replicate), and changing it to a relationship would rewrite the table.
///
/// Do not add behaviour here; add it alongside the signal mapper when it lands.
@Model
final class SignalSurveyPoint {
  @Attribute(.unique)
  var id: UUID

  /// The radio this point was recorded on (Build 40 column name: `deviceID`).
  @Attribute(originalName: "deviceID")
  var radioID: UUID

  /// `SurveySession.id` this point belongs to. Scalar foreign key, not a relationship.
  var surveySessionID: UUID

  var timestamp: Date

  // GPS
  var latitude: Double
  var longitude: Double
  var altitude: Double?
  var horizontalAccuracy: Double
  var speed: Double?

  // RF Signal
  var snr: Double?
  var txSnr: Double?
  var rssi: Int?

  // Packet metadata
  var routeType: Int
  var payloadType: Int
  var pathLength: Int

  /// Deduplication
  var packetHash: String

  /// Sender identification
  var fromContactName: String?

  /// Relay path — comma-separated hex IDs of repeaters in the path
  var pathNodeHexIDs: String?

  /// Active/passive classification — true when this point was collected during active probing
  var isActiveProbe: Bool = false

  init(
    id: UUID = UUID(),
    radioID: UUID,
    surveySessionID: UUID,
    timestamp: Date = Date(),
    latitude: Double,
    longitude: Double,
    altitude: Double? = nil,
    horizontalAccuracy: Double,
    speed: Double? = nil,
    snr: Double? = nil,
    txSnr: Double? = nil,
    rssi: Int? = nil,
    routeType: Int,
    payloadType: Int,
    pathLength: Int,
    packetHash: String,
    fromContactName: String? = nil,
    pathNodeHexIDs: String? = nil,
    isActiveProbe: Bool = false
  ) {
    self.id = id
    self.radioID = radioID
    self.surveySessionID = surveySessionID
    self.timestamp = timestamp
    self.latitude = latitude
    self.longitude = longitude
    self.altitude = altitude
    self.horizontalAccuracy = horizontalAccuracy
    self.speed = speed
    self.snr = snr
    self.txSnr = txSnr
    self.rssi = rssi
    self.routeType = routeType
    self.payloadType = payloadType
    self.pathLength = pathLength
    self.packetHash = packetHash
    self.fromContactName = fromContactName
    self.pathNodeHexIDs = pathNodeHexIDs
    self.isActiveProbe = isActiveProbe
  }
}
