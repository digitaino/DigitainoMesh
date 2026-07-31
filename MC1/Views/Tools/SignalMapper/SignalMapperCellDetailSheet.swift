import MC1Services
import SwiftUI

/// What one cell holds, shown when its hexagon is tapped.
///
/// Three things need care here, and all three are distinctions the data actually makes:
///
/// - **Direction is not decoration.** "Packets received" and "our packets heard back" prove
///   opposite halves of a link, and a cell strong in one and empty in the other is telling
///   you something. They get their own rows, never a merged total.
/// - **An average SNR means "when the mesh reached us here"**. A cell proved only by
///   acknowledgements has none, and says so rather than showing a zero.
/// - **A repeater's name is resolved or it is absent.** The hash is always shown; the name
///   only when the identity resolver produced one, marked when it was a best guess between
///   several nodes answering to the same hash.
struct SignalMapperCellDetailSheet: View {
  let cell: SignalMapperCoverageCell

  /// Enough to name the busiest neighbours without turning the sheet into a list screen.
  private static let repeaterLimit = 5

  var body: some View {
    NavigationStack {
      List {
        summarySection
        directionSection
        signalSection
        if !cell.repeaters.isEmpty {
          repeaterSection
        }
      }
      .navigationTitle(L10n.Tools.Tools.SignalMapper.Detail.title)
      .navigationBarTitleDisplayMode(.inline)
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  // MARK: - Sections

  private var summarySection: some View {
    Section {
      LabeledContent(L10n.Tools.Tools.SignalMapper.Detail.quality) {
        Label {
          Text(cell.quality.localizedLabel)
        } icon: {
          Image(systemName: "hexagon.fill")
            .foregroundStyle(cell.quality.color)
        }
      }
      LabeledContent(
        L10n.Tools.Tools.SignalMapper.Detail.observations,
        value: cell.observationCount.formatted()
      )
      LabeledContent(
        L10n.Tools.Tools.SignalMapper.Detail.days,
        value: L10n.Tools.Tools.SignalMapper.Detail.dayRange(cell.firstDay, cell.lastDay)
      )
    } footer: {
      Text(L10n.Tools.Tools.SignalMapper.Detail.cellFooter(cell.cell.stringValue))
        .font(.caption2.monospaced())
    }
  }

  private var directionSection: some View {
    Section(L10n.Tools.Tools.SignalMapper.Detail.direction) {
      row(
        systemImage: "arrow.down.left",
        title: L10n.Tools.Tools.SignalMapper.Detail.received,
        value: cell.rxCount.formatted()
      )
      row(
        systemImage: "arrow.up.right",
        title: L10n.Tools.Tools.SignalMapper.Detail.txHeard,
        value: cell.txHeardCount.formatted()
      )
      row(
        systemImage: "checkmark.circle",
        title: L10n.Tools.Tools.SignalMapper.Detail.acknowledged,
        value: cell.ackCount.formatted()
      )
      if let rtt = cell.averageRttMs {
        row(
          systemImage: "timer",
          title: L10n.Tools.Tools.SignalMapper.Detail.roundTrip,
          value: L10n.Tools.Tools.SignalMapper.Detail.milliseconds(Int(rtt.rounded()))
        )
      }
    }
  }

  private var signalSection: some View {
    Section(L10n.Tools.Tools.SignalMapper.Detail.signal) {
      if let snr = cell.averageSnr {
        row(
          systemImage: "antenna.radiowaves.left.and.right",
          title: L10n.Tools.Tools.SignalMapper.Detail.averageSnr,
          value: decibels(snr)
        )
        if let best = cell.bestSnr, let worst = cell.worstSnr, best != worst {
          row(
            systemImage: "arrow.up.arrow.down",
            title: L10n.Tools.Tools.SignalMapper.Detail.snrRange,
            value: "\(decibels(worst)) – \(decibels(best))"
          )
        }
      } else {
        row(
          systemImage: "antenna.radiowaves.left.and.right.slash",
          title: L10n.Tools.Tools.SignalMapper.Detail.averageSnr,
          value: L10n.Tools.Tools.SignalMapper.Detail.noPacketsHeard
        )
      }

      if let rssi = cell.averageRssi {
        row(
          systemImage: "waveform",
          title: L10n.Tools.Tools.SignalMapper.Detail.averageRssi,
          value: "\(Int(rssi.rounded())) dBm"
        )
      }

      if cell.packetCount > 0 {
        row(
          systemImage: "arrow.triangle.branch",
          title: L10n.Tools.Tools.SignalMapper.Detail.routeMix,
          value: L10n.Tools.Tools.SignalMapper.Detail.routeSplit(cell.directCount, cell.floodCount)
        )
      }
    }
  }

  private var repeaterSection: some View {
    Section(L10n.Tools.Tools.SignalMapper.Detail.repeaters) {
      ForEach(cell.repeaters.prefix(Self.repeaterLimit)) { repeater in
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(repeater.name ?? repeater.hexID)
              .font(.subheadline.weight(.medium))
              .lineLimit(1)
            if repeater.isAmbiguous {
              Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.Tools.Tools.SignalMapper.Detail.ambiguousName)
            }
            Spacer(minLength: 8)
            Text(L10n.Tools.Tools.SignalMapper.Detail.packets(repeater.packetCount))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          HStack(spacing: 8) {
            Text(repeater.hexID)
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
            if let snr = repeater.averageSnr {
              Text(decibels(snr))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  // MARK: - Rows

  private func row(systemImage: String, title: String, value: String) -> some View {
    LabeledContent {
      Text(value)
    } label: {
      Label(title, systemImage: systemImage)
    }
  }

  private func decibels(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1))) + " dB"
  }
}
