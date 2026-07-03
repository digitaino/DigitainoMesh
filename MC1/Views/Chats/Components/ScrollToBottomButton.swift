import SwiftUI

/// Button to scroll to latest message with unread badge
struct ScrollToBottomButton: View {
    let isVisible: Bool
    let unreadCount: Int
    let onTap: () -> Void

    var body: some View {
        CircularGlassButton(systemImage: "chevron.down", action: onTap) {
            if unreadCount > 0 {
                CountBadge(count: unreadCount, color: .blue,
                           overflowText: L10n.Chats.Chats.ScrollButton.Badge.overflow)
                    .offset(x: 8, y: -8)
            }
        }
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.5)
        .animation(.snappy(duration: 0.2), value: isVisible)
        .accessibilityLabel(L10n.Chats.Chats.ScrollButton.ScrollToBottom.accessibilityLabel)
        .accessibilityValue(unreadCount > 0 ? String(format: NSLocalizedString("chats.unreadMessages.accessibilityValue", tableName: "Chats", comment: ""), locale: .current, unreadCount) : "")
        .accessibilityHidden(!isVisible)
    }
}

#Preview("Visible with unread") {
    ScrollToBottomButton(isVisible: true, unreadCount: 5, onTap: {})
        .padding(50)
}

#Preview("Visible no unread") {
    ScrollToBottomButton(isVisible: true, unreadCount: 0, onTap: {})
        .padding(50)
}

#Preview("Hidden") {
    ScrollToBottomButton(isVisible: false, unreadCount: 3, onTap: {})
        .padding(50)
}
