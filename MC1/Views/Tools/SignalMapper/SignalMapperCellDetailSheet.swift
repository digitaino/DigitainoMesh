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

  /// The sheet is the one place the whole list lives — the card shows only the repeaters
  /// this radio heard directly and folds the rest into a count that lands here.
  private static let repeaterLimit = 40

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        summarySection
        directionSection
        uplinkSection
        signalSection
        if !heardDirectly.isEmpty {
          repeaterSection
        }
        if !indirect.isEmpty {
          indirectSection
        }
      }
      .navigationTitle(L10n.Tools.Tools.SignalMapper.Detail.title)
      .navigationBarTitleDisplayMode(.inline)
      // Every sibling sheet on this screen has an explicit dismissal; a drag indicator
      // on its own made this the odd one out (UI review P2-15).
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) { dismiss() }
        }
      }
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

  /// The active-survey half of the ledger (M3.5): what probing from this cell proved.
  @ViewBuilder
  private var uplinkSection: some View {
    if cell.probesSent > 0 || cell.txSnrCount > 0 {
      Section(L10n.Tools.Tools.SignalMapper.Detail.uplink) {
        row(
          systemImage: "dot.radiowaves.left.and.right",
          title: L10n.Tools.Tools.SignalMapper.Detail.probesSent,
          value: cell.probesSent.formatted()
        )
        row(
          systemImage: "arrow.turn.up.left",
          title: L10n.Tools.Tools.SignalMapper.Detail.probeReplies,
          value: cell.activePacketCount.formatted()
        )
        if let txSnr = cell.averageTxSnr {
          row(
            systemImage: "arrow.up.right.circle",
            title: L10n.Tools.Tools.SignalMapper.Detail.averageTxSnr,
            value: decibels(txSnr)
          )
        } else if cell.isUnreachedProbed {
          row(
            systemImage: "speaker.slash",
            title: L10n.Tools.Tools.SignalMapper.Detail.averageTxSnr,
            value: L10n.Tools.Tools.SignalMapper.Detail.neverHeardBack
          )
        }
        if let rtt = cell.averageProbeRttMs {
          row(
            systemImage: "timer",
            title: L10n.Tools.Tools.SignalMapper.Detail.probeRoundTrip,
            value: L10n.Tools.Tools.SignalMapper.Detail.milliseconds(Int(rtt.rounded()))
          )
        }
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

  /// Repeaters this radio heard directly here — the last hop of a packet's path, the only
  /// link the packet measured. Most recently heard first.
  private var heardDirectly: [SignalMapperCoverageRepeater] {
    cell.repeaters
      .filter(\.wasHeardDirectly)
      .sorted { lhs, rhs in
        let lhsHeard = lhs.lastDirectHeard ?? .distantPast
        let rhsHeard = rhs.lastDirectHeard ?? .distantPast
        if lhsHeard != rhsHeard { return lhsHeard > rhsHeard }
        return lhs.hexID < rhs.hexID
      }
  }

  /// Everything else: upstream relays somebody else measured, and repeaters that reported
  /// hearing us over a path this radio never heard them on. Real evidence of reach, no
  /// signal of our own to show for it.
  private var indirect: [SignalMapperCoverageRepeater] {
    cell.repeaters
      .filter { !$0.wasHeardDirectly }
      .sorted { lhs, rhs in
        let lhsCount = lhs.packetCount + lhs.relayCount
        let rhsCount = rhs.packetCount + rhs.relayCount
        if lhsCount != rhsCount { return lhsCount > rhsCount }
        return lhs.hexID < rhs.hexID
      }
  }

  private var repeaterSection: some View {
    Section(L10n.Tools.Tools.SignalMapper.Detail.repeaters) {
      ForEach(heardDirectly.prefix(Self.repeaterLimit)) { repeater in
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
            if let snr = repeater.lastRxSnr ?? repeater.averageSnr {
              Text("▼" + decibels(snr))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if let tx = repeater.bestTxSnr ?? repeater.averageTxSnr {
              Text("▲" + decibels(tx))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if let rssi = repeater.averageRssi {
              Text("\(Int(rssi.rounded())) dBm")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if let heard = repeater.lastDirectHeard {
              Text(L10n.Tools.Tools.SignalMapper.Detail.lastHeardDirectly(Self.age(from: heard)))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
          }
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  private var indirectSection: some View {
    Section {
      ForEach(indirect.prefix(Self.repeaterLimit)) { repeater in
        HStack(spacing: 6) {
          VStack(alignment: .leading, spacing: 2) {
            Text(repeater.name ?? repeater.hexID)
              .font(.subheadline.weight(.medium))
              .lineLimit(1)
            Text(repeater.hexID)
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
          }
          if repeater.isAmbiguous {
            Image(systemName: "questionmark.circle")
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityLabel(L10n.Tools.Tools.SignalMapper.Detail.ambiguousName)
          }
          Spacer(minLength: 8)
          Text(L10n.Tools.Tools.SignalMapper.Detail.packets(repeater.packetCount + repeater.relayCount))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }
    } header: {
      Text(L10n.Tools.Tools.SignalMapper.Detail.indirectRepeaters)
    } footer: {
      Text(L10n.Tools.Tools.SignalMapper.Detail.indirectFooter)
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

  private static let ageFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.second, .minute, .hour, .day]
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 1
    return formatter
  }()

  /// A static age: the sheet is a value copy re-resolved on every snapshot, not a clock.
  private static func age(from date: Date) -> String {
    ageFormatter.string(from: max(0, Date().timeIntervalSince(date))) ?? ""
  }
}
