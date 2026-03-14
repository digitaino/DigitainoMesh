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

    public init(
        id: UUID = UUID(),
        deviceID: UUID,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        name: String? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.name = name
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

    /// Initialize from SwiftData model.
    public init(from model: SurveySession) {
        self.id = model.id
        self.deviceID = model.deviceID
        self.startedAt = model.startedAt
        self.endedAt = model.endedAt
        self.name = model.name
    }

    public init(
        id: UUID = UUID(),
        deviceID: UUID,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        name: String? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.name = name
    }

    // MARK: - Computed Properties

    /// Duration of the session (or time since start if still active).
    public var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// Whether the session is still active.
    public var isActive: Bool { endedAt == nil }
}
