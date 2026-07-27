import MC1Services
import SwiftUI

/// Which leg of a repeater link a glyph describes.
///
/// The two legs are measured separately and routinely differ — antennas and TX power are
/// rarely symmetric — so every signal readout in this feature says which one it means.
enum RepeaterSignalLeg {
  /// How well this radio hears the repeater.
  case rx
  /// How well the repeater hears this radio.
  case tx

  var arrowSystemImage: String {
    switch self {
    case .rx: "arrow.down"
    case .tx: "arrow.up"
    }
  }
}

/// Signal bars for one leg of a link, with a direction arrow tucked into the empty space
/// above the shortest bar — the same shape the firmware draws on its OLED, so a user
/// comparing the two screens sees one design.
///
/// Not upstream's `SignalBars` component: that renders BLE RSSI tiers for the device
/// pickers. This renders LoRa SNR quality for a mesh link and carries the leg arrow. Kept in
/// this feature's folder rather than `Views/Components` because only the signal-bars toolbar
/// and its popover rows draw it.
struct RepeaterSignalGlyph: View {
  let leg: RepeaterSignalLeg
  let quality: SNRQuality
  /// Briefly brightens and enlarges the arrow when a packet moves in this direction.
  var isFlashing = false
  var size: CGFloat = 14

  var body: some View {
    Image(systemName: "cellularbars", variableValue: quality.barLevel)
      .foregroundStyle(quality.color)
      .font(.system(size: size))
      .overlay(alignment: .topLeading) {
        RepeaterSignalArrow(leg: leg, color: quality.color, isFlashing: isFlashing)
          .offset(x: -1, y: -1)
      }
      .accessibilityHidden(true)
  }
}

/// The direction arrow on its own, for the TX states that have no bars to draw.
struct RepeaterSignalArrow: View {
  let leg: RepeaterSignalLeg
  var color: Color = .secondary
  var isFlashing = false

  var body: some View {
    Image(systemName: leg.arrowSystemImage)
      .font(.system(size: 5, weight: .black))
      .foregroundStyle(color)
      .opacity(isFlashing ? 1 : 0.6)
      .scaleEffect(isFlashing ? 1.3 : 1)
      .animation(.easeOut(duration: 0.15), value: isFlashing)
      .accessibilityHidden(true)
  }
}

/// The TX leg in whichever of its four states it is in.
///
/// RX is never substituted for a missing TX measurement: the two legs differ whenever
/// antennas or power differ between the ends, and showing a guess would make an untested
/// link look proven. Unknown draws a question mark, a probe in flight draws a spinner, and a
/// failed probe draws a red cross — matching the firmware's own Signals page.
struct RepeaterTXGlyph: View {
  let state: RepeaterTXState
  var isFlashing = false
  var size: CGFloat = 14

  var body: some View {
    switch state {
    case .unknown:
      pairedWithArrow(color: .secondary) {
        Image(systemName: "questionmark")
          .font(.system(size: size * 0.7, weight: .medium))
          .foregroundStyle(.secondary)
      }
    case .measuring:
      pairedWithArrow(color: .secondary) {
        ProgressView().controlSize(.mini)
      }
    case let .measured(quality):
      RepeaterSignalGlyph(leg: .tx, quality: quality, isFlashing: isFlashing, size: size)
    case .failed:
      pairedWithArrow(color: .red) {
        Image(systemName: "xmark")
          .font(.system(size: size * 0.7, weight: .medium))
          .foregroundStyle(.red)
      }
    }
  }

  private func pairedWithArrow(
    color: Color,
    @ViewBuilder mark: () -> some View
  ) -> some View {
    HStack(spacing: 1) {
      RepeaterSignalArrow(leg: .tx, color: color, isFlashing: isFlashing)
      mark()
    }
    .accessibilityHidden(true)
  }
}

// MARK: - Readouts

/// A signal-to-noise reading in the compact monospaced style the toolbar and rows share.
/// Renders nothing when there is no measurement, so a column collapses rather than showing
/// a placeholder that reads like a value.
struct RepeaterSNRText: View {
  let snr: Double?
  let quality: SNRQuality
  var size: CGFloat = 9

  var body: some View {
    if let snr {
      Text(L10n.Localizable.SignalBars.snrValue(Int(snr.rounded())))
        .font(.system(size: size, weight: .medium, design: .monospaced))
        .foregroundStyle(quality.color)
        .accessibilityHidden(true)
    }
  }
}

// MARK: - Accessibility

extension RepeaterSignal {
  /// One spoken sentence for a repeater row: who it is, how each leg measures, and how long
  /// ago it was heard. Both legs are always named so VoiceOver never leaves it ambiguous
  /// which direction a number describes.
  var accessibilityDescription: String {
    let who = name ?? hexID
    let rx = rxSnr.map { L10n.Localizable.SignalBars.Accessibility.rxLeg(rxQuality.localizedLabel, Int($0.rounded())) }
      ?? L10n.Localizable.SignalBars.Accessibility.rxUnknown
    let tx: String = switch txState {
    case .unknown: L10n.Localizable.SignalBars.Accessibility.txUnknown
    case .measuring: L10n.Localizable.SignalBars.Accessibility.txMeasuring
    case .failed: L10n.Localizable.SignalBars.Accessibility.txFailed
    case let .measured(quality):
      L10n.Localizable.SignalBars.Accessibility.txLeg(
        quality.localizedLabel,
        Int((txSnr ?? 0).rounded())
      )
    }
    return "\(who), \(rx), \(tx)"
  }
}
