import MC1Services
import SwiftUI

/// What one node contributed, shown when its pin is tapped.
///
/// The signal line is the one that needs care: an average SNR here means "this is how well we
/// hear this node when it is the last hop", and a node we have only ever seen relaying for
/// others has no reading at all — a distinction the legacy tool's guide spelled out and the
/// callout should not blur.
struct TrafficNodeCallout: View {
  let node: TrafficNodeLoad

  private var quality: SNRQuality {
    SNRQuality(snr: node.averageSNR)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(node.name)
        .font(.subheadline.weight(.semibold))
        .lineLimit(2)

      Text(node.publicKey.prefix(3).uppercaseHexString(separator: " "))
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)

      Divider()

      row(
        systemImage: "wave.3.right",
        text: L10n.Tools.Tools.TrafficMap.Callout.packets(node.packetCount),
        tint: .secondary
      )

      if let snr = node.averageSNR {
        row(
          systemImage: "antenna.radiowaves.left.and.right",
          text: L10n.Tools.Tools.TrafficMap.Callout.averageSignal(
            snr.formatted(.number.precision(.fractionLength(1)))
          ),
          tint: quality.color
        )
      } else {
        row(
          systemImage: "antenna.radiowaves.left.and.right.slash",
          text: L10n.Tools.Tools.TrafficMap.Callout.neverHeardDirectly,
          tint: .secondary
        )
      }

      row(
        systemImage: "clock",
        text: node.lastHeard.formatted(.relative(presentation: .numeric)),
        tint: .secondary
      )
    }
    .padding(12)
    .frame(width: 220, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private func row(systemImage: String, text: String, tint: Color) -> some View {
    Label {
      Text(text)
        .font(.subheadline)
        .foregroundStyle(.primary)
    } icon: {
      Image(systemName: systemImage)
        .foregroundStyle(tint)
    }
  }
}
