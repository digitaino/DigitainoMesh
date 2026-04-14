import SwiftUI
import MC1Services

/// Input bar for chat conversations, configured per conversation type.
struct ChatConversationInputBar: View {
    let conversationType: ChatConversationType
    @Binding var composingText: String
    @FocusState.Binding var isFocused: Bool
    let nodeNameByteCount: Int
    let onSend: (String, Int8?) async -> Void
    let onWillSend: () -> Void

    var body: some View {
        switch conversationType {
        case .dm:
            ChatInputBar(
                text: $composingText,
                isFocused: $isFocused,
                placeholder: L10n.Chats.Chats.Input.Placeholder.directMessage,
                maxBytes: ProtocolLimits.maxDirectMessageLength,
                isEncrypted: true
            ) { text, powerOverride in
                onWillSend()
                Task { await onSend(text, powerOverride) }
            }

        case .channel(let channel):
            let maxBytes = ProtocolLimits.maxChannelMessageLength(
                nodeNameByteCount: nodeNameByteCount
            )
            ChatInputBar(
                text: $composingText,
                isFocused: $isFocused,
                placeholder: conversationType.isPublicStyleChannel
                    ? L10n.Chats.Chats.Channel.typePublic
                    : L10n.Chats.Chats.Channel.typePrivate,
                maxBytes: maxBytes,
                isEncrypted: channel.isEncryptedChannel
            ) { text, powerOverride in
                onWillSend()
                Task { await onSend(text, powerOverride) }
            }
        }
    }
}
