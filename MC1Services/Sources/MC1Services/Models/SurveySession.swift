import Foundation
import SwiftData

/// SwiftData model for signal survey sessions.
/// A session groups all survey points recorded during a single wardriving run.
@Model
public final class SurveySession {
    @Attribute(.unique)
    public var id: UUID

    public var deviceID: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var name: String?

    /// JSON-encoded `[String: Int]` mapping hex cell keys to probe counts sent.
    /// Used to reconstruct dead zone cells when loading old sessions.
    public var probesSentData: Data?

    /// JSON-encoded `SurveyCompletionStatsDTO` computed when the session stopped.
    /// Allows revisiting stats without recomputing from grid cells.
    public var completionStatsData: Data?

    public init(
        id: UUID = UUID(),
        deviceID: UUID,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        name: String? = nil,
        probesSentData: Data? = nil,
        completionStatsData: Data? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.name = name
        self.probesSentData = probesSentData
        self.completionStatsData = completionStatsData
    }
}

// MARK: - Completion Stats DTO

/// Codable snapshot of survey completion stats for persistence.
/// Flattens tuple fields from the ViewModel's `SurveyCompletionStats` into simple optionals.
public struct SurveyCompletionStatsDTO: Codable, Sendable, Equatable, Hashable {
    public let duration: TimeInterval
    public let totalPackets: Int
    public let totalCells: Int
    public let connectedCells: Int
    public let meshReachCells: Int
    public let heardOnlyCells: Int
    public let deadZoneCells: Int
    public let totalUniqueRepeaters: Int
    public let bestCoverageRepeaterHexID: String?
    public let bestCoverageRepeaterPacketCount: Int?
    public let bestConnectedRepeaterHexID: String?
    public let bestConnectedRepeaterCellCount: Int?
    public let communityNewCells: Int?
    public let communityUpdatedCells: Int?
    public let communityOldestUpdatedAge: TimeInterval?

    public init(
        duration: TimeInterval,
        totalPackets: Int,
        totalCells: Int,
        connectedCells: Int,
        meshReachCells: Int,
        heardOnlyCells: Int,
        deadZoneCells: Int,
        totalUniqueRepeaters: Int,
        bestCoverageRepeaterHexID: String? = nil,
        bestCoverageRepeaterPacketCount: Int? = nil,
        bestConnectedRepeaterHexID: String? = nil,
        bestConnectedRepeaterCellCount: Int? = nil,
        communityNewCells: Int? = nil,
        communityUpdatedCells: Int? = nil,
        communityOldestUpdatedAge: TimeInterval? = nil
    ) {
        self.duration = duration
        self.totalPackets = totalPackets
        self.totalCells = totalCells
        self.connectedCells = connectedCells
        self.meshReachCells = meshReachCells
        self.heardOnlyCells = heardOnlyCells
        self.deadZoneCells = deadZoneCells
        self.totalUniqueRepeaters = totalUniqueRepeaters
        self.bestCoverageRepeaterHexID = bestCoverageRepeaterHexID
        self.bestCoverageRepeaterPacketCount = bestCoverageRepeaterPacketCount
        self.bestConnectedRepeaterHexID = bestConnectedRepeaterHexID
        self.bestConnectedRepeaterCellCount = bestConnectedRepeaterCellCount
        self.communityNewCells = communityNewCells
        self.communityUpdatedCells = communityUpdatedCells
        self.communityOldestUpdatedAge = communityOldestUpdatedAge
    }
}

// MARK: - Session DTO

/// Sendable DTO for cross-actor transfer of SurveySession data.
public struct SurveySessionDTO: Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let deviceID: UUID
    public let startedAt: Date
    public var endedAt: Date?
    public var name: String?
    /// Probe counts per hex cell key. Used to reconstruct dead zone cells.
    public var probesSentPerCell: [String: Int]?
    /// Completion stats saved when the session stopped. Nil for old sessions.
    public var completionStats: SurveyCompletionStatsDTO?

    /// Initialize from SwiftData model.
    public init(from model: SurveySession) {
        self.id = model.id
        self.deviceID = model.deviceID
        self.startedAt = model.startedAt
        self.endedAt = model.endedAt
        self.name = model.name
        if let data = model.probesSentData {
            self.probesSentPerCell = try? JSONDecoder().decode([String: Int].self, from: data)
        }
        if let data = model.completionStatsData {
            self.completionStats = try? JSONDecoder().decode(SurveyCompletionStatsDTO.self, from: data)
        }
    }

    public init(
        id: UUID = UUID(),
        deviceID: UUID,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        name: String? = nil,
        probesSentPerCell: [String: Int]? = nil,
        completionStats: SurveyCompletionStatsDTO? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.name = name
        self.probesSentPerCell = probesSentPerCell
        self.completionStats = completionStats
    }

    // MARK: - Computed Properties

    /// Duration of the session (or time since start if still active).
    public var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// Whether the session is still active.
    public var isActive: Bool { endedAt == nil }
}
