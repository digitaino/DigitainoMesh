import MC1Services
import SurveyKit
import SwiftUI

/// The v1 Signal Survey cell card, rebuilt on v2's data.
///
/// The whole story of one hexagon, in place at the bottom of the map: what the cell is
/// worth, both link legs with their spread, the numbers that qualify them, and the
/// repeaters behind them — **each of which is a button**. Tapping one re-computes the
/// entire card from that repeater's own observations ("via 0C13"), which is how v1
/// answered "who exactly is carrying this cell?" and is the piece the first three v2
/// passes were missing (field report, 2026-08-30).
///
/// During a ride the card follows the rider: no tap needed, the hexagon you are standing
/// in is on screen with its numbers moving.
///
/// **One rule throughout: the word and the number come from the same statistic.** Every
/// leg is graded on its *best* reading and prints that same best reading, with the mean
/// and the spread underneath as context. Grading "excellent" off the best and then
/// printing the mean next to it is the defect family that produced "400% success".
struct SignalMapperCellCard: View {
  let cell: SignalMapperCoverageCell
  /// Which question the map is asking, so the headline answers the same one.
  var layer: SignalMapperMapLayer = .heard
  /// Repeaters this ride is locked onto — badged, and listed first.
  var focusHexIDs: Set<String> = []
  /// True when this is the hexagon the rider is in right now, not one they tapped.
  var isLiveCell = false
  /// The repeater the card is filtered to, if any. A binding because the chips inside
  /// the card set it and the map's selection logic has to be able to clear it.
  @Binding var repeaterFilter: String?
  let onDetails: () -> Void
  var onLockOn: ((SignalMapperCoverageRepeater) -> Void)?
  let onClose: () -> Void

  /// Ceiling for the card's own height. Beyond it the content scrolls rather than
  /// growing past the top of the screen, which is what large Dynamic Type did to the
  /// first draft of this layout.
  private static let maxHeight: CGFloat = 300

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 7) {
        header
        if filtered != nil {
          filterBar
        }
        signalRows
        detailRows
        repeaterSections
        footerRow
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(maxHeight: Self.maxHeight)
    .background(Color(.secondarySystemBackground).opacity(0.96), in: .rect(cornerRadius: 16))
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
  }

  /// The repeater the card is currently filtered to.
  private var filtered: SignalMapperCoverageRepeater? {
    guard let repeaterFilter else { return nil }
    return cell.repeaters.first { $0.hexID == repeaterFilter }
  }

  /// Probed from here, and nobody ever reported hearing us — v1's dead-zone state, which
  /// only means anything while the map is asking the reach question.
  private var isNoResponse: Bool {
    layer == .reach && filtered == nil && cell.isUnreachedProbed
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if isNoResponse {
        Image(systemName: "antenna.radiowaves.left.and.right.slash")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      } else if isLiveCell {
        Image(systemName: "location.fill")
          .font(.caption2)
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
      }

      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 6) {
          if isLiveCell {
            Text(L10n.Tools.Tools.SignalMapper.Card.myCell)
              .font(.subheadline.weight(.semibold))
          }
          Text(
            isNoResponse
              ? L10n.Tools.Tools.SignalMapper.Card.noResponse
              : headlineQuality.localizedLabel
          )
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(isNoResponse ? AnyShapeStyle(.secondary) : AnyShapeStyle(headlineQuality.color))
        }
        Text(
          isNoResponse
            ? L10n.Tools.Tools.SignalMapper.Card.noResponseDetail
            : L10n.Tools.Tools.SignalMapper.Card.packetsReceived(displayPacketCount)
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .contentTransition(.numericText())
      }

      Spacer()

      Button(action: onClose) {
        Image(systemName: "xmark.circle.fill")
          .font(.title3)
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.secondary)
          .frame(width: 44, height: 44)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(L10n.Localizable.Common.done)
    }
    // The 44 pt close target would otherwise push the whole header row taller than the
    // two lines of text beside it.
    .frame(minHeight: 44)
  }

  /// The headline grades the leg the map is currently painting, so the card and the
  /// hexagon under it never disagree about what the colour meant.
  private var headlineQuality: SignalQuality {
    if let filtered {
      return layer == .reach
        ? SignalQuality(snr: filtered.bestTxSnr)
        : SignalQuality(snr: filtered.bestSnr)
    }
    return layer == .reach ? (cell.reachQuality ?? .unknown) : cell.quality
  }

  private var displayPacketCount: Int {
    filtered?.packetCount ?? cell.packetCount
  }

  // MARK: - Filter bar

  /// "via <repeater>" — with the two things worth doing to a repeater you just singled
  /// out: watch it for the rest of the ride, or go back to the whole cell.
  private var filterBar: some View {
    HStack(spacing: 4) {
      Image(systemName: "line.3.horizontal.decrease.circle.fill")
        .font(.caption2)
      Text(L10n.Tools.Tools.SignalMapper.Card.via(filtered?.name ?? repeaterFilter ?? ""))
        .font(.caption)
        .lineLimit(1)

      Spacer(minLength: 8)

      if let filtered, let onLockOn, !focusHexIDs.contains(filtered.hexID) {
        Button {
          onLockOn(filtered)
        } label: {
          Label(L10n.Tools.Tools.SignalMapper.Focus.apply, systemImage: "scope")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
      }

      Button {
        withAnimation(.snappy(duration: 0.2)) { repeaterFilter = nil }
      } label: {
        Text(L10n.Tools.Tools.SignalMapper.Card.clear)
          .font(.caption2.weight(.semibold))
          .padding(.horizontal, 10)
          .frame(minHeight: 44)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
    }
    .foregroundStyle(.tint)
  }

  // MARK: - The two legs

  private var signalRows: some View {
    HStack(alignment: .top, spacing: 0) {
      signalColumn(
        label: L10n.Tools.Tools.SignalMapper.Card.rxSignal,
        arrow: "arrow.down",
        leg: rxLeg,
        unknownReason: rxLeg.best == nil ? L10n.Tools.Tools.SignalMapper.Detail.noPacketsHeard : nil
      )

      Divider()
        .frame(width: 0.5)

      signalColumn(
        label: L10n.Tools.Tools.SignalMapper.Card.txSignal,
        arrow: "arrow.up",
        leg: txLeg,
        unknownReason: txUnknownReason
      )
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  /// One link direction, already reduced to the numbers the column prints. `best` is both
  /// the graded and the printed value; `average` and the range are context.
  private struct Leg {
    var best: Double?
    var average: Double?
    var low: Double?
    var high: Double?
    var rssi: Double?

    var quality: SignalQuality {
      SignalQuality(snr: best)
    }
  }

  /// A filtered leg never falls back to the cell's own numbers — mixing one repeater's
  /// label with every repeater's data is exactly what v1 refused to do.
  private var rxLeg: Leg {
    if let filtered {
      return Leg(
        best: filtered.bestSnr ?? filtered.averageSnr,
        average: filtered.averageSnr,
        low: filtered.worstSnr,
        high: filtered.bestSnr,
        rssi: filtered.averageRssi
      )
    }
    return Leg(
      best: cell.bestSnr ?? cell.averageSnr,
      average: cell.averageSnr,
      low: cell.worstSnr,
      high: cell.bestSnr,
      rssi: cell.averageRssi
    )
  }

  private var txLeg: Leg {
    if let filtered {
      return Leg(
        best: filtered.bestTxSnr ?? filtered.averageTxSnr,
        average: filtered.averageTxSnr,
        low: filtered.worstTxSnr,
        high: filtered.bestTxSnr,
        rssi: nil
      )
    }
    return Leg(
      best: cell.bestTxSnr ?? cell.averageTxSnr,
      average: cell.averageTxSnr,
      low: nil,
      high: nil,
      rssi: nil
    )
  }

  /// Why the uplink column is blank — v1's `unknownReason`, which is the difference
  /// between "we have no data" and "we asked and nobody answered".
  private var txUnknownReason: String? {
    guard txLeg.best == nil else { return nil }
    if filtered != nil {
      return L10n.Tools.Tools.SignalMapper.Card.heardOnlyReason
    }
    if cell.isUnreachedProbed {
      return L10n.Tools.Tools.SignalMapper.Detail.neverHeardBack
    }
    return L10n.Tools.Tools.SignalMapper.Card.waitingUplink
  }

  /// Bars on the left, stacked numbers on the right — fills the width, saves the height
  /// (v1's `signalColumn`, which is why two legs fit on one line of a phone).
  private func signalColumn(
    label: String,
    arrow: String,
    leg: Leg,
    unknownReason: String?
  ) -> some View {
    let quality = leg.quality
    return HStack(alignment: .top, spacing: 6) {
      Image(systemName: "cellularbars", variableValue: Double(quality.rank) / 5.0)
        .font(.system(size: 22))
        .foregroundStyle(quality == .unknown ? AnyShapeStyle(.quaternary) : AnyShapeStyle(quality.color))
        .overlay(alignment: .topLeading) {
          if quality != .unknown {
            Image(systemName: arrow)
              .font(.system(size: 6, weight: .black))
              .foregroundStyle(quality.color)
              .offset(x: -1, y: -1)
          }
        }

      VStack(alignment: .leading, spacing: 1) {
        Text(label)
          .font(.system(size: 9, weight: .medium, design: .default))
          .foregroundStyle(.secondary)

        if let best = leg.best {
          HStack(spacing: 3) {
            Text(quality.localizedLabel)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(quality.color)
            Text(Self.decibels(best, places: 1))
              .font(.system(.caption2, design: .monospaced))
              .foregroundStyle(.primary)
              .contentTransition(.numericText())
          }
          if let context = contextLine(leg) {
            Text(context)
              .font(.system(size: 9, design: .monospaced))
              .foregroundStyle(.secondary)
          }
          if let range = rangeLine(leg) {
            Text(range)
              .font(.system(size: 9, design: .monospaced))
              .foregroundStyle(.secondary)
          }
        } else if let unknownReason {
          Text(unknownReason)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text(verbatim: "—")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  /// The mean and the RSSI, under the best reading that the word grades — so "Excellent
  /// 11" and "avg 4.2" are visibly two different facts instead of one contradiction.
  private func contextLine(_ leg: Leg) -> String? {
    var parts: [String] = []
    if let average = leg.average, let best = leg.best, abs(best - average) >= 0.5 {
      parts.append(L10n.Tools.Tools.SignalMapper.Card.average(Self.decibels(average, places: 1)))
    }
    if let rssi = leg.rssi {
      parts.append(String(format: "RSSI %.0f dBm", rssi.rounded() == 0 ? 0 : rssi))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func rangeLine(_ leg: Leg) -> String? {
    guard let low = leg.low, let high = leg.high, high - low >= 0.5 else { return nil }
    return "\(Self.decibels(low))–\(Self.decibels(high))"
  }

  // MARK: - Detail rows

  @ViewBuilder
  private var detailRows: some View {
    VStack(spacing: 2) {
      if let filtered {
        detailRow(
          label: L10n.Tools.Tools.SignalMapper.Card.packetSplit,
          value: L10n.Tools.Tools.SignalMapper.Card.packetSplitValue(
            filtered.rxPacketCount, filtered.txPacketCount
          )
        )
        lastHeardRow(filtered.lastHeard)
      } else {
        if let best = bestRepeater, let snr = best.bestSnr ?? best.averageSnr {
          detailRow(
            label: L10n.Tools.Tools.SignalMapper.Card.bestRepeater,
            value: Self.decibels(snr, places: 1) + " dB (\(best.name ?? best.hexID))",
            valueColor: SignalQuality(snr: snr).color
          )
        }
        if let lastSeen = cell.lastSeen {
          lastHeardRow(lastSeen)
        }
        if cell.directCount + cell.floodCount > 0 {
          detailRow(
            label: L10n.Tools.Tools.SignalMapper.Detail.routeMix,
            value: L10n.Tools.Tools.SignalMapper.Detail.routeSplit(cell.directCount, cell.floodCount)
          )
        }
        if let rtt = cell.averageProbeRttMs {
          detailRow(
            label: L10n.Tools.Tools.SignalMapper.Detail.probeRoundTrip,
            value: L10n.Tools.Tools.SignalMapper.Detail.milliseconds(Int(rtt.rounded()))
          )
        }
      }
      // A cell property, not a per-repeater one: it stays put when a chip is picked.
      probeSuccessRow
    }
  }

  private var bestRepeater: SignalMapperCoverageRepeater? {
    cell.repeaters
      .filter { $0.averageSnr != nil }
      .max { ($0.bestSnr ?? $0.averageSnr ?? -100) < ($1.bestSnr ?? $1.averageSnr ?? -100) }
  }

  /// Probes answered over probes sent, with the reply packets those answers were worth
  /// on the same line rather than as a second, contradictory-looking row. Replies as the
  /// numerator is what produced "400%": one discover is answered by every repeater in
  /// range (field report, 2026-08-30).
  @ViewBuilder
  private var probeSuccessRow: some View {
    if let rate = cell.probeSuccessRate {
      let percent = Int((rate * 100).rounded())
      detailRow(
        label: L10n.Tools.Tools.SignalMapper.Card.probeSuccessLabel,
        value: L10n.Tools.Tools.SignalMapper.Card.probeSuccessValue(
          percent,
          min(cell.probesAnswered, cell.probesSent),
          cell.probesSent,
          cell.activePacketCount
        ),
        valueColor: percent >= 75 ? .green : percent >= 40 ? .yellow : .red
      )
    }
  }

  private func detailRow(label: String, value: String, valueColor: Color = .primary) -> some View {
    HStack {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(valueColor)
        .contentTransition(.numericText())
    }
  }

  /// The live clock: "12s ago" while you stand in the cell, ticking.
  private func lastHeardRow(_ date: Date) -> some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      detailRow(
        label: L10n.Tools.Tools.SignalMapper.Card.lastHeardLabel,
        value: L10n.Tools.Tools.SignalMapper.Card.ago(Self.age(from: date, to: context.date))
      )
    }
  }

  // MARK: - Repeaters

  /// Every repeater in the cell, as buttons, split by whether the link is two-way.
  /// Two-way first and strongest-uplink first inside it: "who is actually carrying this
  /// cell" is a question about the best link, not the chattiest one.
  @ViewBuilder
  private var repeaterSections: some View {
    if !cell.repeaters.isEmpty {
      Divider()
      VStack(alignment: .leading, spacing: 5) {
        let twoWay = orderedTwoWay(cell.repeaters.filter { $0.averageTxSnr != nil })
        let heardOnly = orderedHeard(cell.repeaters.filter { $0.averageTxSnr == nil })
        if !twoWay.isEmpty {
          repeaterRow(
            label: L10n.Tools.Tools.SignalMapper.Card.connected,
            icon: "arrow.left.arrow.right",
            iconColor: .green,
            repeaters: twoWay
          )
        }
        if !heardOnly.isEmpty {
          repeaterRow(
            label: L10n.Tools.Tools.SignalMapper.Card.heardOnly,
            icon: "ear",
            iconColor: .secondary,
            repeaters: heardOnly
          )
        }
      }
    }
  }

  /// Locked-on repeaters lead every group — during a range test they are what the rider
  /// is looking for.
  private func orderedTwoWay(
    _ repeaters: [SignalMapperCoverageRepeater]
  ) -> [SignalMapperCoverageRepeater] {
    repeaters.sorted { lhs, rhs in
      let lhsFocus = focusHexIDs.contains(lhs.hexID)
      let rhsFocus = focusHexIDs.contains(rhs.hexID)
      if lhsFocus != rhsFocus { return lhsFocus }
      let lhsTx = lhs.bestTxSnr ?? lhs.averageTxSnr ?? -100
      let rhsTx = rhs.bestTxSnr ?? rhs.averageTxSnr ?? -100
      if lhsTx != rhsTx { return lhsTx > rhsTx }
      return lhs.hexID < rhs.hexID
    }
  }

  private func orderedHeard(
    _ repeaters: [SignalMapperCoverageRepeater]
  ) -> [SignalMapperCoverageRepeater] {
    repeaters.sorted { lhs, rhs in
      let lhsFocus = focusHexIDs.contains(lhs.hexID)
      let rhsFocus = focusHexIDs.contains(rhs.hexID)
      if lhsFocus != rhsFocus { return lhsFocus }
      let lhsRx = lhs.bestSnr ?? lhs.averageSnr ?? -100
      let rhsRx = rhs.bestSnr ?? rhs.averageSnr ?? -100
      if lhsRx != rhsRx { return lhsRx > rhsRx }
      return lhs.hexID < rhs.hexID
    }
  }

  private func repeaterRow(
    label: String,
    icon: String,
    iconColor: Color,
    repeaters: [SignalMapperCoverageRepeater]
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Label {
        Text(label)
          .font(.caption2)
      } icon: {
        Image(systemName: icon)
          .font(.caption2)
          .foregroundStyle(iconColor)
      }
      .foregroundStyle(.secondary)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(repeaters) { repeater in
            chip(for: repeater)
          }
        }
      }
    }
  }

  private func chip(for repeater: SignalMapperCoverageRepeater) -> some View {
    let isFiltered = repeaterFilter == repeater.hexID
    let isFocused = focusHexIDs.contains(repeater.hexID)
    return Button {
      withAnimation(.snappy(duration: 0.2)) {
        repeaterFilter = isFiltered ? nil : repeater.hexID
      }
    } label: {
      HStack(spacing: 4) {
        if isFocused {
          Image(systemName: "scope")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.tint)
        }
        // An unresolved hash goes monospaced: 0/O and 1/l have to stay apart.
        Text(repeater.name ?? repeater.hexID)
          .font(repeater.name == nil ? .system(.caption, design: .monospaced) : .caption)
          .lineLimit(1)
        if repeater.isAmbiguous {
          Image(systemName: "questionmark.circle")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
        }
        if let tx = repeater.bestTxSnr ?? repeater.averageTxSnr {
          Text("▲" + Self.decibels(tx))
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.primary)
        }
        if let rx = repeater.bestSnr ?? repeater.averageSnr {
          Text("▼" + Self.decibels(rx))
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 10)
      .frame(minHeight: 44)
      .background(isFiltered ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary.opacity(0.6)))
      .clipShape(.capsule)
      .overlay {
        Capsule().strokeBorder(isFiltered ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1)
      }
      .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(chipAccessibilityLabel(repeater))
    .accessibilityHint(L10n.Tools.Tools.SignalMapper.Card.chipHint)
    .accessibilityAddTraits(isFiltered ? [.isSelected] : [])
  }

  private func chipAccessibilityLabel(_ repeater: SignalMapperCoverageRepeater) -> String {
    var parts = [repeater.name ?? repeater.hexID]
    if repeater.isAmbiguous {
      parts.append(L10n.Tools.Tools.SignalMapper.Detail.ambiguousName)
    }
    if let tx = repeater.bestTxSnr ?? repeater.averageTxSnr {
      parts.append(L10n.Tools.Tools.SignalMapper.Focus.uplinkAccessibility(Int(tx.rounded())))
    }
    if let rx = repeater.bestSnr ?? repeater.averageSnr {
      parts.append(L10n.Tools.Tools.SignalMapper.Card.downlinkAccessibility(Int(rx.rounded())))
    }
    return parts.joined(separator: ", ")
  }

  // MARK: - Footer

  private var footerRow: some View {
    Button(action: onDetails) {
      HStack(spacing: 4) {
        Image(systemName: "list.bullet")
          .font(.caption2)
        Text(L10n.Tools.Tools.SignalMapper.Detail.title)
          .font(.caption)
        Spacer()
        Image(systemName: "chevron.right")
          .font(.caption2)
      }
      .frame(minHeight: 44)
      .foregroundStyle(.tint)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
  }

  // MARK: - Formatting

  /// Decibels without the `-0` that `%f` produces for anything just below zero. Readings
  /// carry a decimal (v1's `%.1f`); chips and ranges round, because they trade precision
  /// for the width to fit more of them on one line.
  private static func decibels(_ value: Double, places: Int = 0) -> String {
    let scale = pow(10.0, Double(places))
    let rounded = (value * scale).rounded() / scale
    return String(format: "%.\(places)f", rounded == 0 ? 0 : rounded)
  }

  /// Localized abbreviated age ("12 s", "5 min") — the system formatter, so the units
  /// follow the locale instead of shipping Latin letters inside translated sentences.
  private static let ageFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.second, .minute, .hour, .day]
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 1
    return formatter
  }()

  private static func age(from date: Date, to now: Date) -> String {
    ageFormatter.string(from: max(0, now.timeIntervalSince(date))) ?? ""
  }
}
