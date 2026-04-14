import Foundation

/// A channel message waiting to be sent via the queue processor.
struct QueuedChannelMessage {
    let messageID: UUID
    /// When set, the radio TX power is changed to this dBm before sending (one-shot override).
    var overrideRadioDbm: Int8? = nil
}
