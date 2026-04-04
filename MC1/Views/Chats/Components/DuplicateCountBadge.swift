import SwiftUI

/// Badge showing the count of collapsed duplicate messages.
/// Tapping toggles between collapsed and expanded states.
struct DuplicateCountBadge: View {
    let count: Int
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 3) {
                Image(systemName: isExpanded ? "chevron.up" : "square.on.square")
                    .font(.system(size: 9, weight: .semibold))
                Text("\u{00D7}\(count)")
                    .font(.system(.caption2, design: .monospaced, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.fill.tertiary, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) duplicate messages")
        .accessibilityHint("Tap to \(isExpanded ? "collapse" : "expand") duplicate messages")
    }
}
