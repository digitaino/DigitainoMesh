import MC1Services
import SwiftUI

/// Shared repeater row for picker lists. Used by both BenchmarkView and SignalSurvey
/// focused mode. Displays star, name, optional badge, hex ID, timestamp, and selection state.
struct RepeaterPickerRow: View {
    let contact: ContactDTO
    let isSelected: Bool
    var selectionColor: Color = .accentColor
    var badge: String? = nil
    var badgeColor: Color = .green

    var body: some View {
        HStack {
            if contact.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
            VStack(alignment: .leading) {
                HStack(spacing: 4) {
                    Text(contact.resolvableName)
                    if let badge {
                        Text(badge)
                            .font(.caption2.bold())
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(badgeColor.opacity(0.2))
                            .foregroundStyle(badgeColor)
                            .clipShape(.capsule)
                    }
                }
                HStack(spacing: 6) {
                    Text(contact.publicKey.prefix(3).map { String(format: "%02X", $0) }.joined())
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if contact.lastModified > 0 {
                        RelativeTimestampText(timestamp: contact.lastModified)
                    }
                }
            }
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? selectionColor : .secondary)
        }
    }
}
