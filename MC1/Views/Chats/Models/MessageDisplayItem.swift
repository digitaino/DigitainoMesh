import Foundation
import MC1Services

/// State of link preview loading for a message
enum PreviewLoadState: Sendable, Hashable {
    case idle           // Not yet requested (URL detected but fetch not started)
    case loading        // Fetch in progress
    case loaded         // Preview data available in loadedPreview
    case noPreview      // Fetch completed, no preview available
    case disabled       // User has previews disabled
    case malwareWarning // URL flagged as suspicious by malware domain filter
}

/// Pre-computed display properties for message cells.
/// Stores message ID reference only (not full DTO) to avoid memory overhead.
struct MessageDisplayItem: Identifiable, Hashable, Sendable {
    let messageID: UUID
    let showTimestamp: Bool
    let showDirectionGap: Bool
    let showSenderName: Bool  // false for continuation messages in a group
    let showNewMessagesDivider: Bool
    let detectedURL: URL?
    let isImageURL: Bool

    // Forwarded properties from message (lightweight copies)
    let isOutgoing: Bool
    let status: MessageStatus
    let containsSelfMention: Bool
    let mentionSeen: Bool
    let heardRepeats: Int
    let retryAttempt: Int
    let maxRetryAttempts: Int
    let reactionSummary: String?

    // Shared route detected in message text (e.g., "RX via ...")
    let detectedSharedRoute: SharedRoute?

    // Hex path chain detected in message text (e.g., "A3 7F 42 B5")
    let detectedHexPath: HexPath?

    // Preview state (owned by ViewModel, not view)
    let previewState: PreviewLoadState
    let loadedPreview: LinkPreviewDataDTO?

    // Search match highlight
    let isSearchMatch: Bool

    var id: UUID { messageID }
}
