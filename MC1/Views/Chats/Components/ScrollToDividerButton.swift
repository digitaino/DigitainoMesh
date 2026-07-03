import SwiftUI

/// Button to scroll to the new messages divider
struct ScrollToDividerButton: View {
    let onTap: () -> Void

    var body: some View {
        CircularGlassButton(systemImage: "chevron.up", action: onTap)
            .accessibilityLabel(L10n.Chats.Chats.ScrollButton.ScrollToDivider.accessibilityLabel)
            .accessibilityHint(L10n.Chats.Chats.ScrollButton.ScrollToDivider.accessibilityHint)
    }
}

#Preview {
    ScrollToDividerButton(onTap: {})
        .padding(50)
}
