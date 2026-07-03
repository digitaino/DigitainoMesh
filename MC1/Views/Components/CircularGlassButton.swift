import SwiftUI

/// A circular, Liquid Glass–styled icon button used for floating affordances such as
/// the chat scroll-to-bottom / mention / divider buttons.
///
/// Centralizes the 44×44 hit target, plain button style, circular content shape, and
/// interactive Liquid Glass background so individual affordances only specify their
/// icon, optional badge, and accessibility semantics.
struct CircularGlassButton<Badge: View>: View {
    let systemImage: String
    let action: () -> Void
    @ViewBuilder var badge: () -> Badge

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.bold())
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .contentShape(.circle)
        .liquidGlassInteractive(in: .circle)
        .overlay(alignment: .topTrailing) {
            badge()
        }
    }
}

extension CircularGlassButton where Badge == EmptyView {
    init(systemImage: String, action: @escaping () -> Void) {
        self.init(systemImage: systemImage, action: action, badge: { EmptyView() })
    }
}

#Preview {
    VStack(spacing: 24) {
        CircularGlassButton(systemImage: "chevron.up", action: {})
        CircularGlassButton(systemImage: "chevron.down", action: {}) {
            CountBadge(count: 5, color: .blue)
                .offset(x: 8, y: -8)
        }
    }
    .padding(50)
}
