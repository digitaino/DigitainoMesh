import SwiftUI

/// Badge fronting a run of duplicate message copies (mesh retries of one
/// logical send). Collapsed it sits on the run's newest copy showing the run
/// size; expanded it sits on the oldest. Tapping toggles the run.
struct DuplicateCountBadge: View {
  let count: Int
  let isExpanded: Bool
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 3) {
        Image(systemName: isExpanded ? "chevron.up" : "square.on.square")
          .font(.system(size: 9, weight: .semibold))
        Text(L10n.Chats.Chats.Message.Duplicates.badge(count))
          .font(.system(.caption2, design: .monospaced, weight: .medium))
      }
      .foregroundStyle(.secondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(.fill.tertiary, in: .capsule)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(L10n.Chats.Chats.Message.Duplicates.accessibilityLabel(count))
    .accessibilityHint(
      isExpanded
        ? L10n.Chats.Chats.Message.Duplicates.collapse
        : L10n.Chats.Chats.Message.Duplicates.expand
    )
  }
}
