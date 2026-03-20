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

    public init(
        id: UUID = UUID(),
        deviceID: UUID,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        name: String? = nil,
        probesSentData: Data? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.name = name
        self.probesSentData = probesSentData
    }
}

// MARK: - DTO

/// Sendable DTO for cross-actor transfer of SurveySession data.
public struct SurveySessionDTO: Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let deviceID: UUID
    public let startedAt: Date
    public var endedAt: Date?
    public var name: String?
    /// Probe counts per hex cell key. Used to reconstruct dead zone cells.
    public var probesSentPerCell: [String: Int]?

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
    }

    public init(
        id: UUID = UUID(),
        deviceID: UUID,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        name: String? = nil,
        probesSentPerCell: [String: Int]? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.name = name
        self.probesSentPerCell = probesSentPerCell
    }

    // MARK: - Computed Properties

    /// Duration of the session (or time since start if still active).
    public var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// Whether the session is still active.
    public var isActive: Bool { endedAt == nil }
}
