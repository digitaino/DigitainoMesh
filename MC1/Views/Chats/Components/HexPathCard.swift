import SwiftUI

/// Inline card shown below a message bubble when a hex path chain is detected in the text.
/// Tapping opens a map sheet to visualize the path.
struct HexPathCard: View {
    let hexPath: HexPath
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.blue)
                    .font(.body)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Path Map")
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
        .accessibilityLabel("Show path map, \(summaryText)")
        .accessibilityHint("Opens a map showing the path")
    }

    private var summaryText: String {
        let hopWord = hexPath.hopCount == 1 ? "hop" : "hops"
        return "\(hexPath.hopCount) \(hopWord): \(hexPath.hexIDs.joined(separator: ", "))"
    }
}
