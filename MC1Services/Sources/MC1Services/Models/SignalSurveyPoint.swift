import Foundation
import MeshCore
import SwiftData

/// SwiftData model for GPS-tagged signal survey data points.
/// Each record pairs a received RF packet with the user's GPS location at reception time.
@Model
public final class SignalSurveyPoint {
    @Attribute(.unique)
    public var id: UUID

    public var deviceID: UUID
    public var surveySessionID: UUID
    public var timestamp: Date

    // GPS
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?
    public var horizontalAccuracy: Double
    public var speed: Double?

    // RF Signal
    public var snr: Double?
    public var rssi: Int?

    // Packet metadata
    public var routeType: Int
    public var payloadType: Int
    public var pathLength: Int

    // Deduplication
    public var packetHash: String

    public init(
        id: UUID = UUID(),
        deviceID: UUID,
        surveySessionID: UUID,
        timestamp: Date = Date(),
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        horizontalAccuracy: Double,
        speed: Double? = nil,
        snr: Double? = nil,
        rssi: Int? = nil,
        routeType: Int,
        payloadType: Int,
        pathLength: Int,
        packetHash: String
    ) {
        self.id = id
        self.deviceID = deviceID
        self.surveySessionID = surveySessionID
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.snr = snr
        self.rssi = rssi
        self.routeType = routeType
        self.payloadType = payloadType
        self.pathLength = pathLength
        self.packetHash = packetHash
    }
}

// MARK: - DTO

/// Sendable DTO for cross-actor transfer of SignalSurveyPoint data.
public struct SignalSurveyPointDTO: Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let deviceID: UUID
    public let surveySessionID: UUID
    public let timestamp: Date
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?
    public let horizontalAccuracy: Double
    public let speed: Double?
    public let snr: Double?
    public let rssi: Int?
    public let routeType: RouteType
    public let payloadType: PayloadType
    public let pathLength: UInt8
    public let packetHash: String

    /// Initialize from SwiftData model.
    public init(from model: SignalSurveyPoint) {
        self.id = model.id
        self.deviceID = model.deviceID
        self.surveySessionID = model.surveySessionID
        self.timestamp = model.timestamp
        self.latitude = model.latitude
        self.longitude = model.longitude
        self.altitude = model.altitude
        self.horizontalAccuracy = model.horizontalAccuracy
        self.speed = model.speed
        self.snr = model.snr
        self.rssi = model.rssi
        self.routeType = RouteType(rawValue: UInt8(model.routeType)) ?? .flood
        self.payloadType = PayloadType(rawValue: UInt8(model.payloadType)) ?? .unknown
        self.pathLength = UInt8(model.pathLength)
        self.packetHash = model.packetHash
    }

    public init(
        id: UUID = UUID(),
        deviceID: UUID,
        surveySessionID: UUID,
        timestamp: Date = Date(),
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        horizontalAccuracy: Double,
        speed: Double? = nil,
        snr: Double? = nil,
        rssi: Int? = nil,
        routeType: RouteType,
        payloadType: PayloadType,
        pathLength: UInt8,
        packetHash: String
    ) {
        self.id = id
        self.deviceID = deviceID
        self.surveySessionID = surveySessionID
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.snr = snr
        self.rssi = rssi
        self.routeType = routeType
        self.payloadType = payloadType
        self.pathLength = pathLength
        self.packetHash = packetHash
    }

    // MARK: - Computed Properties

    /// Classified signal quality based on SNR thresholds.
    public var snrQuality: SNRQuality { SNRQuality(snr: snr) }
}
