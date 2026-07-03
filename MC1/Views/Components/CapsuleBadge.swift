import SwiftUI

/// A compact capsule badge that applies consistent padding and a capsule background to
/// arbitrary content (text and/or icons).
///
/// Use `init(tint:)` for the common translucent tinted style (foreground tinted with the
/// given color, background the same color at `fillOpacity`), or `init(foreground:background:)`
/// for custom chrome such as a material fill.
struct CapsuleBadge<Content: View>: View {
    private let foreground: AnyShapeStyle
    private let background: AnyShapeStyle
    private let horizontalPadding: CGFloat
    private let verticalPadding: CGFloat
    @ViewBuilder private let content: () -> Content

    /// Translucent tinted style: foreground tinted with `tint`, background `tint` at `fillOpacity`.
    init(
        tint: Color,
        fillOpacity: Double = 0.15,
        horizontalPadding: CGFloat = 6,
        verticalPadding: CGFloat = 2,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.foreground = AnyShapeStyle(tint)
        self.background = AnyShapeStyle(tint.opacity(fillOpacity))
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.content = content
    }

    /// Custom style with explicit foreground and background shape styles.
    init(
        foreground: some ShapeStyle,
        background: some ShapeStyle,
        horizontalPadding: CGFloat = 6,
        verticalPadding: CGFloat = 2,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.foreground = AnyShapeStyle(foreground)
        self.background = AnyShapeStyle(background)
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.content = content
    }

    var body: some View {
        content()
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(background, in: .capsule)
    }
}

#Preview {
    VStack(spacing: 12) {
        CapsuleBadge(tint: .blue) {
            Text("Room").font(.caption2.weight(.medium))
        }
        CapsuleBadge(tint: .green) {
            HStack(spacing: 3) {
                Image(systemName: "bolt")
                Text("200mW")
            }
            .font(.caption2)
        }
        CapsuleBadge(foreground: .secondary, background: .fill.tertiary,
                     horizontalPadding: 7, verticalPadding: 3) {
            HStack(spacing: 3) {
                Image(systemName: "square.on.square")
                Text("×3")
            }
            .font(.caption2)
        }
    }
    .padding()
}
