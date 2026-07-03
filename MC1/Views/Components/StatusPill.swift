import SwiftUI

/// A floating, capsule-shaped pill with a consistent drop shadow, used for transient
/// status affordances (sync/connection status, live survey indicator, etc.).
///
/// The `fill` controls the capsule background: `.style(_:)` paints an explicit shape style
/// (e.g. a material or tint) behind the capsule, while `.glass` uses Liquid Glass. Content,
/// padding, and any interactivity (wrapping the pill in a `Button`) are supplied by the caller.
struct StatusPill<Content: View>: View {
    enum Fill {
        case style(AnyShapeStyle)
        case glass
    }

    var fill: Fill
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat
    var shadowRadius: CGFloat = 8
    var shadowY: CGFloat = 4
    @ViewBuilder var content: () -> Content

    var body: some View {
        let padded = content()
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)

        switch fill {
        case .style(let style):
            padded
                .background {
                    Capsule()
                        .fill(style)
                        .shadow(color: .black.opacity(0.15), radius: shadowRadius, y: shadowY)
                }
        case .glass:
            padded
                .liquidGlass(in: .capsule)
                .shadow(color: .black.opacity(0.15), radius: shadowRadius, y: shadowY)
        }
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3).ignoresSafeArea()
        VStack(spacing: 16) {
            StatusPill(fill: .style(AnyShapeStyle(.regularMaterial)),
                       horizontalPadding: 16, verticalPadding: 10) {
                Label("Syncing", systemImage: "arrow.trianglehead.2.clockwise")
            }
            StatusPill(fill: .glass, horizontalPadding: 12, verticalPadding: 7,
                       shadowRadius: 4, shadowY: 2) {
                Label("Recording", systemImage: "dot.radiowaves.left.and.right")
            }
        }
    }
}
