import MC1Services
import SwiftUI

/// One repeater in the signal table: who it is, both legs of its link, and how fresh the
/// measurement is.
///
/// Fixed column widths rather than a flexible layout: the value of this list is scanning
/// down a column to compare repeaters, which only works if the columns line up.
struct RepeaterSignalRow: View {
  @Environment(\.appTheme) private var theme

  let repeater: RepeaterSignal
  var isWatched = false

  private enum Column {
    static let identity: CGFloat = 84
    static let leg: CGFloat = 36
    static let age: CGFloat = 52
  }

  var body: some View {
    HStack(spacing: 4) {
      identity
        .frame(width: Column.identity, alignment: .leading)

      RepeaterSignalGlyph(leg: .rx, quality: repeater.rxQuality, size: 13)
        .frame(width: Column.leg)

      RepeaterTXGlyph(state: repeater.txState, size: 13)
        .frame(width: Column.leg)

      freshness
        .frame(width: Column.age, alignment: .trailing)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(watchHighlight)
    .contentShape(.rect)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  // MARK: - Identity

  /// The resolved name when there is one, with the hash below it — the hash is what the
  /// firmware's OLED shows and what a path readout carries, so it stays visible even when a
  /// friendlier name is available.
  private var identity: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let name = repeater.name {
        HStack(spacing: 3) {
          watchMarker
          Text(name)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
        }
        Text(repeater.hexID)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.secondary)
      } else {
        HStack(spacing: 3) {
          watchMarker
          Text(repeater.hexID)
            .font(.system(.caption, design: .monospaced).weight(.medium))
        }
      }
    }
  }

  @ViewBuilder
  private var watchMarker: some View {
    if isWatched {
      Image(systemName: "binoculars.fill")
        .font(.system(size: 9))
        .foregroundStyle(theme.accentColor)
    }
  }

  // MARK: - Freshness

  /// When the repeater was last heard, with the last round-trip time beneath it when one has
  /// been measured — a link can be recent and still slow, and the two answer different
  /// questions.
  private var freshness: some View {
    VStack(alignment: .trailing, spacing: 0) {
      Text(repeater.lastHeard, style: .relative)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
      if let rttMs = repeater.rttMs {
        Text(L10n.Localizable.SignalBars.rttValue(rttMs))
          .font(.system(size: 9, design: .monospaced))
          .foregroundStyle(.quaternary)
          .lineLimit(1)
      }
    }
  }

  // MARK: - Watch highlight

  @ViewBuilder
  private var watchHighlight: some View {
    if isWatched {
      RoundedRectangle(cornerRadius: 6)
        .fill(theme.accentColor.opacity(0.12))
        .padding(.horizontal, 6)
    }
  }

  private var accessibilityLabel: String {
    let base = repeater.accessibilityDescription
    guard isWatched else { return base }
    return "\(base), \(L10n.Localizable.SignalBars.Accessibility.watched)"
  }
}
