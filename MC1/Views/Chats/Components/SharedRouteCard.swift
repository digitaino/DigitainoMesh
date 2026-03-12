import SwiftUI

/// Inline card shown below a message bubble when shared route info is detected in the text.
/// Tapping opens a map sheet to visualize the shared route.
struct SharedRouteCard: View {
    let sharedRoute: SharedRoute
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "map")
                    .foregroundStyle(.blue)
                    .font(.body)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Shared Route")
                        .font(.subheadline)
                        .bold()
                        .foregroundStyle(.primary)

                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Show shared route, \(summaryText)")
        .accessibilityHint("Opens a map showing the shared route")
    }

    private var summaryText: String {
        let hopWord = sharedRoute.hopCount == 1 ? "hop" : "hops"
        var text = "\(sharedRoute.hopCount) \(hopWord) via \(sharedRoute.hexIDs.joined(separator: ", "))"
        if let distance = sharedRoute.distanceText {
            text += " · \(distance)"
        }
        return text
    }
}
