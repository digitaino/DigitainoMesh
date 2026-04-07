import Foundation
import MC1Services

/// Conversation type discriminator for the unified chat view.
/// Not `@MainActor` — no mutable state. `@State` on the view provides main-actor isolation.
enum ChatConversationType: Sendable {
    case dm(ContactDTO)
    case channel(ChannelDTO)

    // MARK: - Computed Properties

    var navigationTitle: String {
        switch self {
        case .dm(let contact):
            contact.displayName
        case .channel(let channel):
            channel.displayName
        }
    }

    var navigationSubtitle: String {
        switch self {
        case .dm(let contact):
            if contact.isFloodRouted {
                return L10n.Chats.Chats.ConnectionStatus.floodRouting
            } else {
                return L10n.Chats.Chats.ConnectionStatus.direct(contact.pathHopCount)
            }
        case .channel(let channel):
            let base = channelTypeSubtitle(for: channel)
            if let region = channel.regionScope {
                return "\(base) \u{00B7} \(region)"
            }
            return base
        }
    }

    /// Accessibility label for the subtitle, providing a VoiceOver-friendly description
    /// when a region scope is active (the middle dot separator may be read literally).
    var navigationSubtitleAccessibilityLabel: String? {
        switch self {
        case .dm:
            return nil
        case .channel(let channel):
            guard let region = channel.regionScope else { return nil }
            return L10n.Chats.Chats.ChannelInfo.Region.scopedAccessibility(
                channelTypeSubtitle(for: channel), region
            )
        }
    }

    // MARK: - Private Helpers

    private func channelTypeSubtitle(for channel: ChannelDTO) -> String {
        if channel.isPublicChannel {
            L10n.Chats.Chats.Channel.typePublic
        } else if channel.name.hasPrefix("#") {
            L10n.Chats.Chats.ChannelInfo.ChannelType.hashtag
        } else {
            L10n.Chats.Chats.Channel.typePrivate
        }
    }

    var conversationID: UUID {
        switch self {
        case .dm(let contact):
            contact.id
        case .channel(let channel):
            channel.id
        }
    }

    var isPublicStyleChannel: Bool {
        switch self {
        case .dm:
            false
        case .channel(let channel):
            !channel.isEncryptedChannel
        }
    }

    // MARK: - Transforms

    /// Returns a copy with the contact replaced (DM only). Returns self unchanged for channels.
    func replacingContact(_ contact: ContactDTO) -> ChatConversationType {
        guard case .dm = self else { return self }
        return .dm(contact)
    }

    /// Returns a copy with the channel replaced (channel only). Returns self unchanged for DMs.
    func replacingChannel(_ channel: ChannelDTO) -> ChatConversationType {
        guard case .channel = self else { return self }
        return .channel(channel)
    }
}
