import MC1Services
import SurveyKit
import SwiftUI

/// The v1 Signal Survey card, rebuilt for v2's data: tap a hexagon — mid-ride included —
/// and its story appears in place at the bottom of the map, not behind a modal.
///
/// Reads top-to-bottom the way the v1 card did: quality verdict, then the two link legs
/// (▼ what you hear, ▲ what hears you — with the probe success ratio that makes the
/// uplink number trustworthy), a live last-heard clock, and the repeaters behind the
/// numbers — two-way links first, so a lone isolated repeater propping up a green cell
/// is visible for exactly what it is. "Details" opens the full sheet.
struct SignalMapperCellCard: View {
  let cell: SignalMapperCoverageCell
  let onDetails: () -> Void
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      signalRows
      chips
      footerRow
    }
    .padding(12)
    .background(Color(.secondarySystemBackground).opacity(0.96), in: .rect(cornerRadius: 16))
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(cell.quality.localizedLabel)
        .font(.headline)
        .foregroundStyle(cell.quality.color)
      Text(L10n.Tools.Tools.SignalMapper.Detail.packets(cell.packetCount))
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.caption.weight(.bold))
          .foregroundStyle(.secondary)
          .frame(width: 32, height: 32)
          .background(.quaternary.opacity(0.5), in: .circle)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(L10n.Localizable.Common.done)
    }
  }

  // MARK: - Link legs

  private var signalRows: some View {
    HStack(alignment: .top, spacing: 12) {
      // ▼ Downlink — what you hear here.
      legColumn(
        glyph: "arrow.down.left",
        quality: SignalQuality(snr: cell.bestSnr ?? cell.averageSnr),
        primary: snrText(avg: cell.averageSnr, best: cell.bestSnr),
        secondary: cell.averageRssi.map { String(format: "RSSI %.0f dBm", $0) }
      )

      Rectangle()
        .fill(.quaternary)
        .frame(width: 0.5)

      // ▲ Uplink — what hears you here, with the ratio that makes it trustworthy.
      legColumn(
        glyph: "arrow.up.right",
        quality: cell.reachQuality ?? .unknown,
        primary: uplinkPrimary,
        secondary: uplinkSecondary
      )
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private func legColumn(
    glyph: String,
    quality: SignalQuality,
    primary: String,
    secondary: String?
  ) -> some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: "cellularbars", variableValue: Double(quality.rank) / 5.0)
        .font(.title3)
        .foregroundStyle(quality == .unknown ? AnyShapeStyle(.quaternary) : AnyShapeStyle(quality.color))
        .overlay(alignment: .topLeading) {
          Image(systemName: glyph)
            .font(.system(size: 7, weight: .black))
            .foregroundStyle(quality == .unknown ? AnyShapeStyle(.quaternary) : AnyShapeStyle(quality.color))
            .offset(x: -2, y: -2)
        }
      VStack(alignment: .leading, spacing: 1) {
        Text(primary)
          .font(.subheadline.weight(.semibold))
          .monospacedDigit()
        if let secondary {
          Text(secondary)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private func snrText(avg: Double?, best: Double?) -> String {
    switch (avg, best) {
    case let (avg?, best?) where abs(best - avg) >= 0.5:
      String(format: "%.1f dB · ≤ %.0f", avg, best)
    case let (avg?, _):
      String(format: "%.1f dB", avg)
    default:
      L10n.Tools.Tools.SignalMapper.Detail.noPacketsHeard
    }
  }

  private var uplinkPrimary: String {
    if cell.txSnrCount > 0 {
      return snrText(avg: cell.averageTxSnr, best: cell.bestTxSnr)
    }
    if cell.isUnreachedProbed {
      return L10n.Tools.Tools.SignalMapper.Detail.neverHeardBack
    }
    return "–"
  }

  private var uplinkSecondary: String? {
    guard cell.probesSent > 0 else { return nil }
    let replies = cell.activePacketCount
    let percent = Int((Double(replies) / Double(max(1, cell.probesSent)) * 100).rounded())
    return L10n.Tools.Tools.SignalMapper.Card.probeSuccess(replies, cell.probesSent, percent)
  }

  // MARK: - Repeater chips

  /// Two-way links lead (they back the uplink number), heard-only follow. A green cell
  /// carried by one repeater shows exactly one chip — the lone-repeater caveat made
  /// visible instead of argued about.
  @ViewBuilder
  private var chips: some View {
    let twoWay = cell.repeaters.filter { $0.averageTxSnr != nil }
    let heardOnly = cell.repeaters.filter { $0.averageTxSnr == nil }
    if !cell.repeaters.isEmpty {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(twoWay.prefix(6)) { repeater in
            chip(
              name: repeater.name ?? repeater.hexID,
              glyph: "arrow.up.arrow.down",
              value: repeater.averageTxSnr.map { String(format: "▲%.0f", $0) },
              emphasized: true
            )
          }
          ForEach(heardOnly.prefix(6)) { repeater in
            chip(
              name: repeater.name ?? repeater.hexID,
              glyph: "arrow.down.left",
              value: repeater.averageSnr.map { String(format: "▼%.0f", $0) },
              emphasized: false
            )
          }
        }
      }
    }
  }

  private func chip(name: String, glyph: String, value: String?, emphasized: Bool) -> some View {
    HStack(spacing: 4) {
      Image(systemName: glyph)
        .font(.system(size: 9, weight: .bold))
      Text(name)
        .lineLimit(1)
      if let value {
        Text(value)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
    }
    .font(.caption.weight(.medium))
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(
      emphasized ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.5)),
      in: .capsule
    )
    .accessibilityElement(children: .combine)
  }

  // MARK: - Footer

  private var footerRow: some View {
    HStack {
      if let lastSeen = cell.lastSeen {
        // Live clock, the v1 card's `lastHeardRow`: "1s ago" while you stand in it.
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(
            L10n.Tools.Tools.SignalMapper.Card.lastHeard(
              relativeText(from: lastSeen, to: context.date)
            )
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
        }
      }
      Spacer()
      Button(action: onDetails) {
        HStack(spacing: 3) {
          Text(L10n.Tools.Tools.SignalMapper.Detail.title)
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
        }
        .font(.caption.weight(.semibold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(.tint)
    }
  }

  /// Localized abbreviated age ("3 s" / "5 min" / "2 h") — the system formatter, so
  /// the units follow the locale instead of shipping Latin letters inside translated
  /// sentences.
  private static let ageFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.second, .minute, .hour, .day]
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 1
    return formatter
  }()

  private func relativeText(from date: Date, to now: Date) -> String {
    Self.ageFormatter.string(from: max(0, now.timeIntervalSince(date))) ?? ""
  }
}
