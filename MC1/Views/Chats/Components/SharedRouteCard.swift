import MC1Services
import SwiftUI

/// Inline card shown below an incoming bubble whose text contains a shared
/// route ("RX via ..."). A quick tap opens the path map for the embedded
/// route; the tap yields to the bubble's long-press like the other content
/// cards, so a sustained press anywhere still opens the actions sheet.
struct SharedRouteCard: View {
  let sharedRoute: SharedRoute
  let onTap: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "map")
        .font(.body)
        .foregroundStyle(.tint)

      VStack(alignment: .leading, spacing: 2) {
        Text(L10n.Chats.Chats.SharedRoute.Card.title)
          .font(.subheadline)
          .bold()
        Text(summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 0)

      Image(systemName: "chevron.right")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(10)
    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: RichPreviewMetrics.cornerRadius))
    .contentShape(.rect(cornerRadius: RichPreviewMetrics.cornerRadius))
    .tapYieldingToLongPress { onTap() }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(L10n.Chats.Chats.SharedRoute.Card.accessibilityLabel(summary))
    .accessibilityHint(L10n.Chats.Chats.SharedRoute.Card.accessibilityHint)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { onTap() }
  }

  var summary: String {
    let ids = sharedRoute.hexIDs.joined(separator: ", ")
    var text = sharedRoute.hopCount == 1
      ? L10n.Chats.Chats.SharedRoute.Card.summaryOneHop(ids)
      : L10n.Chats.Chats.SharedRoute.Card.summary(sharedRoute.hopCount, ids)
    if let distance = sharedRoute.distanceText {
      text += " · \(distance)"
    }
    return text
  }
}
