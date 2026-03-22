import Foundation

/// Lightweight search result for global message search.
/// Contains only the fields needed for display in search results,
/// avoiding the overhead of transferring full `MessageDTO` (30+ fields).
public struct MessageSearchResult: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    public let contactID: UUID?
    public let channelIndex: UInt8?
    public let deviceID: UUID
    public let senderNodeName: String?
    public let directionRawValue: Int

    public var isOutgoing: Bool { directionRawValue == MessageDirection.outgoing.rawValue }

    public init(
        id: UUID,
        text: String,
        createdAt: Date,
        contactID: UUID?,
        channelIndex: UInt8?,
        deviceID: UUID,
        senderNodeName: String?,
        directionRawValue: Int
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.contactID = contactID
        self.channelIndex = channelIndex
        self.deviceID = deviceID
        self.senderNodeName = senderNodeName
        self.directionRawValue = directionRawValue
    }
}
