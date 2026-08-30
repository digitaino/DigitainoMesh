import SurveyKit
import SwiftUI

/// What the coverage map's two visual channels mean, in the corner where they can be
/// checked without leaving the map: colour is how well the mesh reaches a cell, solidity is
/// how much was observed there. Collapsed to a single button by default so it never covers
/// the coverage it explains.
///
/// Same shape and same idiom as ``TrafficHeatmapLegend`` — a tool's legend should not be a
/// new invention every time — with the quality scale swapped for SurveyKit's six-step one.
struct SignalMapperLegend: View {
  /// Which layer the map is showing; the Reach layer adds its "probed, never heard" row.
  var layer: SignalMapperMapLayer = .heard
  /// One-line coverage totals, shown at the top of the expanded card — the old floating
  /// summary pill's content, demoted here so the top of the map stays clear.
  var summary: String?

  @State private var isExpanded = false
  @State private var bodyHeight: CGFloat = 0

  var body: some View {
    Group {
      if isExpanded {
        expanded
      } else {
        collapsed
      }
    }
    .mapperHUDSurface(in: .rect(cornerRadius: 16))
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
    .accessibilityLabel(L10n.Tools.Tools.SignalMapper.Legend.title)
  }

  /// Title row pinned, body scrolling under a ceiling: unbounded, this grew past the top
  /// of the screen at large Dynamic Type and carried its own close button off with it,
  /// and tapping outside selects a hexagon rather than dismissing (UI review P1-8).
  private var expanded: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        isExpanded = false
      } label: {
        HStack(spacing: 6) {
          Text(L10n.Tools.Tools.SignalMapper.Legend.title)
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

      ScrollView {
        expandedBody
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(height: min(bodyHeight, 300))
    }
    .padding(12)
    .frame(maxWidth: 220, alignment: .leading)
    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
  }

  private var expandedBody: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let summary {
        Text(summary)
          .font(.caption.weight(.medium))
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
        Divider()
      }

      Text(L10n.Tools.Tools.SignalMapper.Legend.density)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Divider()

      Text(
        layer == .heard
          ? L10n.Tools.Tools.SignalMapper.Legend.signal
          : L10n.Tools.Tools.SignalMapper.Legend.reachSignal
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      ForEach(SignalQuality.coverageOrder, id: \.overlayToken) { quality in
        HStack(spacing: 8) {
          RoundedRectangle(cornerRadius: 2)
            .fill(quality.color.opacity(0.55))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(quality.color, lineWidth: 1))
            .frame(width: 12, height: 12)
          Text(quality.localizedLabel)
            .font(.caption)
        }
        .accessibilityElement(children: .combine)
      }

      if layer == .reach {
        HStack(spacing: 8) {
          RoundedRectangle(cornerRadius: 2)
            .fill(Color.gray.opacity(0.45))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.gray, lineWidth: 1))
            .frame(width: 12, height: 12)
          Text(L10n.Tools.Tools.SignalMapper.Legend.noReach)
            .font(.caption)
        }
        .accessibilityElement(children: .combine)
      }

      Divider()

      // The legend is where someone comes to ask why the map looks the way it does, which
      // makes it the right place to explain the blank patch around home before they read it
      // as a bug. Also stated under the capture toggle, for the people who never open this.
      Text(L10n.Tools.Tools.SignalMapper.anchorNote)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
