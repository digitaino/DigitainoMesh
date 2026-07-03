import SwiftUI

/// Button to scroll to unread mentions
struct ScrollToMentionButton: View {
    let unreadMentionCount: Int
    let onTap: () -> Void

    var body: some View {
        CircularGlassButton(systemImage: "at", action: onTap) {
            if unreadMentionCount > 0 {
                CountBadge(count: unreadMentionCount, color: .red,
                           overflowText: L10n.Chats.Chats.ScrollButton.Badge.overflow)
                    .offset(x: 8, y: -8)
            }
        }
        .accessibilityLabel(L10n.Chats.Chats.ScrollButton.ScrollToMention.accessibilityLabel)
        .accessibilityValue(L10n.Chats.Chats.ScrollButton.ScrollToMention.accessibilityValue(unreadMentionCount))
        .accessibilityHint(L10n.Chats.Chats.ScrollButton.ScrollToMention.accessibilityHint)
    }
}

#Preview("With multiple") {
    ScrollToMentionButton(unreadMentionCount: 5, onTap: {})
        .padding(50)
}

#Preview("With one") {
    ScrollToMentionButton(unreadMentionCount: 1, onTap: {})
        .padding(50)
}
