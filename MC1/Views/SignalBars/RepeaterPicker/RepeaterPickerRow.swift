import MC1Services
import SwiftUI

/// One repeater in a picker: who it is, whether the radio can hear it right now, and
/// whether it is chosen.
///
/// The hash is shown on its own line rather than folded into the name, because it is the
/// identity the rest of this feature works in — the toolbar table, the trace hops and the
/// firmware's own OLED all label repeaters by hash, and a picker that only showed names
/// would not let a user match what they are looking at.
struct RepeaterPickerRow: View {
  @Environment(\.appTheme) private var theme

  let candidate: RepeaterCandidate
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 12) {
      NodeAvatar(publicKey: candidate.publicKey, role: .repeater, size: 36)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          if candidate.isFavorite {
            Image(systemName: "star.fill")
              .font(.caption2)
              .foregroundStyle(.yellow)
          }
          Text(candidate.displayName)
            .font(.body.weight(.medium))
            .lineLimit(1)
        }

        HStack(spacing: 6) {
          if candidate.hasResolvedName {
            Text(candidate.hexID.hex)
              .font(.caption.monospaced())
              .foregroundStyle(.tertiary)
          }
          if let lastSeen = candidate.lastSeen {
            RelativeTimestampText(date: lastSeen)
          }
        }
      }

      Spacer(minLength: 0)

      if candidate.isHeard {
        RepeaterSignalGlyph(leg: .rx, quality: candidate.rxQuality, size: 13)
      }

      if isSelected {
        Image(systemName: "checkmark")
          .font(.body.weight(.semibold))
          .foregroundStyle(theme.accentColor)
      }
    }
    .padding(.vertical, 4)
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}
