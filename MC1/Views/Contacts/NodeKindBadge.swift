import SwiftUI

/// Capsule badge for labeling node types (room, discovered, etc.)
struct NodeKindBadge: View {
    let text: String
    let color: Color

    var body: some View {
        CapsuleBadge(tint: color) {
            Text(text)
                .font(.caption2.weight(.medium))
        }
    }
}
