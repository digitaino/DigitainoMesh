import MC1Services

/// Determines which message actions are available based on message state.
/// Extracted for testability and reuse across UI components.
struct MessageActionAvailability {
    let canReply: Bool
    let canCopy: Bool
    let canDirectMessage: Bool
    let canSendDM: Bool
    let canSendAgain: Bool
    let canBlockSender: Bool
    let canShowRepeatDetails: Bool
    let canViewPath: Bool
    let canDelete: Bool

    init(message: MessageDTO, senderContact: ContactDTO? = nil) {
        canReply = !message.isOutgoing
        canCopy = true
        canDirectMessage = message.isChannelMessage && !message.isOutgoing && senderContact != nil
        let hasChannelSender = message.isChannelMessage && !message.isOutgoing && message.senderNodeName != nil
        canSendDM = hasChannelSender
        canSendAgain = message.isOutgoing
        canBlockSender = hasChannelSender
        canShowRepeatDetails = message.isOutgoing && message.heardRepeats > 0
        canViewPath = !message.isOutgoing
            && !message.isDirect
            && !(message.pathNodes?.isEmpty ?? true)
        canDelete = true
    }
}
