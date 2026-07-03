import SwiftUI

/// A small numeric count badge rendered as a colored capsule (e.g. unread counts).
///
/// When `overflowText` is provided and `count` exceeds `overflowThreshold`, the badge
/// shows the overflow text (e.g. "99+") instead of the raw number. Positioning (such as
/// the `.offset` used when overlaying a circular button) is left to the caller so the
/// badge stays reusable across contexts.
struct CountBadge: View {
    let count: Int
    var color: Color = .blue
    var overflowThreshold: Int = 99
    var overflowText: String?

    var body: some View {
        Text(displayText)
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color, in: .capsule)
    }

    private var displayText: String {
        if let overflowText, count > overflowThreshold {
            return overflowText
        }
        return "\(count)"
    }
}

#Preview {
    HStack(spacing: 16) {
        CountBadge(count: 3)
        CountBadge(count: 42, color: .red)
        CountBadge(count: 150, overflowText: "99+")
    }
    .padding()
}
