import Foundation
import SwiftData

extension PersistenceStore {

    // MARK: - Survey Sessions

    /// Creates a new survey session.
    public func createSurveySession(deviceID: UUID, name: String? = nil) throws -> SurveySessionDTO {
        let session = SurveySession(deviceID: deviceID, name: name)
        modelContext.insert(session)
        try modelContext.save()
        return SurveySessionDTO(from: session)
    }

    /// Ends the active survey session by setting its endedAt timestamp.
    public func endSurveySession(id: UUID) throws {
        let targetID = id
        var descriptor = FetchDescriptor<SurveySession>(
            predicate: #Predicate { $0.id == targetID }
        )
        descriptor.fetchLimit = 1
        guard let session = try modelContext.fetch(descriptor).first else { return }
        session.endedAt = Date()
        try modelContext.save()
    }

    /// Updates the name of a survey session.
    public func updateSurveySessionName(id: UUID, name: String) throws {
        let targetID = id
        var descriptor = FetchDescriptor<SurveySession>(
            predicate: #Predicate { $0.id == targetID }
        )
        descriptor.fetchLimit = 1
        guard let session = try modelContext.fetch(descriptor).first else { return }
        session.name = name
        try modelContext.save()
    }

    /// Fetches all survey sessions for a device, ordered by most recent first.
    public func fetchSurveySessions(deviceID: UUID) throws -> [SurveySessionDTO] {
        let targetDeviceID = deviceID
        let descriptor = FetchDescriptor<SurveySession>(
            predicate: #Predicate { $0.deviceID == targetDeviceID },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map { SurveySessionDTO(from: $0) }
    }

    /// Deletes a survey session and all its associated survey points.
    public func deleteSurveySession(id: UUID) throws {
        let targetSessionID = id
        let pointDescriptor = FetchDescriptor<SignalSurveyPoint>(
            predicate: #Predicate { $0.surveySessionID == targetSessionID }
        )
        let points = try modelContext.fetch(pointDescriptor)
        for point in points {
            modelContext.delete(point)
        }

        let targetID = id
        var sessionDescriptor = FetchDescriptor<SurveySession>(
            predicate: #Predicate { $0.id == targetID }
        )
        sessionDescriptor.fetchLimit = 1
        if let session = try modelContext.fetch(sessionDescriptor).first {
            modelContext.delete(session)
        }
        try modelContext.save()
    }

    /// Closes all orphaned survey sessions (those with no endedAt) for a device.
    /// Called on startup to clean up sessions that were never properly stopped.
    public func closeOrphanedSessions(deviceID: UUID) throws -> Int {
        let targetDeviceID = deviceID
        let descriptor = FetchDescriptor<SurveySession>(
            predicate: #Predicate { $0.deviceID == targetDeviceID && $0.endedAt == nil }
        )
        let orphans = try modelContext.fetch(descriptor)
        guard !orphans.isEmpty else { return 0 }

        let now = Date()
        for session in orphans {
            session.endedAt = now
        }
        try modelContext.save()
        return orphans.count
    }

    // MARK: - Survey Points

    /// Saves a new signal survey point.
    public func saveSurveyPoint(_ dto: SignalSurveyPointDTO) throws {
        let point = SignalSurveyPoint(
            id: dto.id,
            deviceID: dto.deviceID,
            surveySessionID: dto.surveySessionID,
            timestamp: dto.timestamp,
            latitude: dto.latitude,
            longitude: dto.longitude,
            altitude: dto.altitude,
            horizontalAccuracy: dto.horizontalAccuracy,
            speed: dto.speed,
            snr: dto.snr,
            rssi: dto.rssi,
            routeType: Int(dto.routeType.rawValue),
            payloadType: Int(dto.payloadType.rawValue),
            pathLength: Int(dto.pathLength),
            packetHash: dto.packetHash,
            fromContactName: dto.fromContactName,
            pathNodeHexIDs: dto.pathNodeHexIDs.isEmpty ? nil : dto.pathNodeHexIDs.joined(separator: ",")
        )
        modelContext.insert(point)
        try modelContext.save()
    }

    /// Fetches all survey points for a session, ordered by timestamp.
    public func fetchSurveyPoints(sessionID: UUID) throws -> [SignalSurveyPointDTO] {
        let targetSessionID = sessionID
        let descriptor = FetchDescriptor<SignalSurveyPoint>(
            predicate: #Predicate { $0.surveySessionID == targetSessionID },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map { SignalSurveyPointDTO(from: $0) }
    }

    /// Fetches all survey points for a device across all sessions, ordered by timestamp.
    public func fetchSurveyPoints(deviceID: UUID) throws -> [SignalSurveyPointDTO] {
        let targetDeviceID = deviceID
        let descriptor = FetchDescriptor<SignalSurveyPoint>(
            predicate: #Predicate { $0.deviceID == targetDeviceID },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map { SignalSurveyPointDTO(from: $0) }
    }

    /// Returns the count of survey points in a session.
    public func countSurveyPoints(sessionID: UUID) throws -> Int {
        let targetSessionID = sessionID
        let descriptor = FetchDescriptor<SignalSurveyPoint>(
            predicate: #Predicate { $0.surveySessionID == targetSessionID }
        )
        return try modelContext.fetchCount(descriptor)
    }

    /// Checks if a packet hash already exists in a session (deduplication).
    public func surveyPointExists(sessionID: UUID, packetHash: String) throws -> Bool {
        let targetSessionID = sessionID
        let targetHash = packetHash
        var descriptor = FetchDescriptor<SignalSurveyPoint>(
            predicate: #Predicate {
                $0.surveySessionID == targetSessionID &&
                $0.packetHash == targetHash
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetchCount(descriptor) > 0
    }
}
