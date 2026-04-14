import Foundation

/// A message waiting to be sent, with its target contact captured at enqueue time
struct QueuedMessage {
    let messageID: UUID
    let contactID: UUID
    /// When set, the radio TX power is changed to this dBm before sending (one-shot override).
    var overrideRadioDbm: Int8? = nil
}
