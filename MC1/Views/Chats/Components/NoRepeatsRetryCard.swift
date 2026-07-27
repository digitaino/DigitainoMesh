import MC1Services
import SwiftUI

/// Inline offer to resend a channel message that no repeater was heard relaying.
///
/// Sits under the bubble as a sibling, so it never changes the bubble's own geometry —
/// the row grows downward when the card appears and shrinks back when it retires.
///
/// Two actions, matching legacy: resend unchanged, or resend one power rung higher. The
/// escalated button is present only when `prompt.nextPowerLabel` is set (adaptive power on
/// and a higher rung reachable), so the card never offers a step the radio cannot take.
struct NoRepeatsRetryCard: View {
  let prompt: NoRepeatsRetryPrompt
  var onResendSamePower: (() -> Void)?
  var onResendAtNextPower: (() -> Void)?

  @Environment(\.appTheme) private var theme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      Text(L10n.Chats.Chats.Message.NoRepeats.title)
        .font(.caption2)
        .foregroundStyle(.secondary)

      // Accessibility sizes stack the buttons so neither label truncates.
      let buttons = Group {
        Button {
          onResendSamePower?()
        } label: {
          Label(
            L10n.Chats.Chats.Message.NoRepeats.sendAgain,
            systemImage: "arrow.clockwise"
          )
          .font(.caption2.weight(.medium))
        }
        .tint(theme.accentColor)

        if let nextPowerLabel = prompt.nextPowerLabel {
          Button {
            onResendAtNextPower?()
          } label: {
            Label(
              L10n.Chats.Chats.Message.NoRepeats.sendAtPower(nextPowerLabel),
              systemImage: "bolt.fill"
            )
            .font(.caption2.weight(.medium))
          }
          .tint(.orange)
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)

      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .trailing, spacing: 6) { buttons }
      } else {
        HStack(spacing: 8) { buttons }
      }
    }
    .padding(.top, 4)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L10n.Chats.Chats.Message.NoRepeats.accessibilityLabel)
  }
}

#Preview("With escalation") {
  NoRepeatsRetryCard(prompt: NoRepeatsRetryPrompt(nextPowerLabel: "500mW"))
    .padding()
}

#Preview("At max power") {
  NoRepeatsRetryCard(prompt: NoRepeatsRetryPrompt())
    .padding()
    .preferredColorScheme(.dark)
}
