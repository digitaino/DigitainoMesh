import Foundation

/// A message waiting to be sent, with its target contact captured at enqueue time
struct QueuedMessage {
    let messageID: UUID
    let contactID: UUID
}
