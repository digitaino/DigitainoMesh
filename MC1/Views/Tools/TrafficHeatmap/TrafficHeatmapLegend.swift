import MC1Services
import SwiftUI

/// What the map's two visual channels mean, in the corner where they can be checked without
/// leaving the map: size and thickness are how much traffic, colour is how well we hear the
/// node. Collapsed to a single button by default so it never covers the mesh it explains.
struct TrafficHeatmapLegend: View {
  @State private var isExpanded = false

  var body: some View {
    Group {
      if isExpanded {
        expanded
      } else {
        collapsed
      }
    }
    .liquidGlass(in: .rect(cornerRadius: 12))
    .padding(.leading)
    .padding(.bottom, 8)
    .animation(.snappy(duration: 0.2), value: isExpanded)
  }

  private var collapsed: some View {
    Button {
      isExpanded = true
    } label: {
      Image(systemName: "list.bullet.rectangle")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.primary)
        .frame(width: 44, height: 44)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(L10n.Tools.Tools.TrafficMap.Legend.title)
  }

  private var expanded: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        isExpanded = false
      } label: {
        HStack(spacing: 6) {
          Text(L10n.Tools.Tools.TrafficMap.Legend.title)
            .font(.subheadline.weight(.semibold))
          Spacer(minLength: 8)
          Image(systemName: "xmark")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(L10n.Localizable.Common.done)

      Text(L10n.Tools.Tools.TrafficMap.Legend.weight)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Divider()

      Text(L10n.Tools.Tools.TrafficMap.Legend.signal)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      ForEach(SNRQuality.trafficBubbleOrder, id: \.overlayToken) { quality in
        HStack(spacing: 8) {
          Circle()
            .fill(quality.color.opacity(0.55))
            .overlay(Circle().strokeBorder(quality.color, lineWidth: 1))
            .frame(width: 12, height: 12)
          Text(quality.localizedLabel)
            .font(.caption)
        }
        .accessibilityElement(children: .combine)
      }
    }
    .padding(12)
    .frame(maxWidth: 220, alignment: .leading)
    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
  }
}
