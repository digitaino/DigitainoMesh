import MC1Services
import SurveyKit
import SwiftUI

/// The v1 Signal Survey cell card, rebuilt on v2's data.
///
/// The whole story of one hexagon, in place at the bottom of the map: which leg the map is
/// grading, what the cell is worth on it, both link legs with their spread, the strongest
/// repeater *right now*, and the repeaters this radio actually heard — **each of which is a
/// button**. Tapping one re-computes the entire card from that repeater's own observations
/// ("via 0C13"), which is how v1 answered "who exactly is carrying this cell?".
///
/// During a ride the card follows the rider, and offers the ride's own share of the
/// hexagon next to the all-time figures.
///
/// Three rules throughout (field reports 2026-08-30 and 2026-09-03):
///
/// - **The word and the number come from the same statistic.** Every leg is graded on the
///   value it prints. Grading "excellent" off the best and printing the mean next to it is
///   the defect family that produced "400% success".
/// - **A repeater is listed only if this radio heard it directly.** A node that merely sat
///   in a packet's path was measured by somebody else; it is counted, never chipped.
/// - **"Now" means the last ten minutes** (``SignalMapperFreshness/window``). Nothing on
///   the card calls a link current, strongest or two-way on evidence older than that.
struct SignalMapperCellCard: View {
  let cell: SignalMapperCoverageCell
  /// This ride's share of the same hexagon: the difference between the row now and the
  /// row when the run started. Nil when no run is open or the ride has not touched it.
  var sessionCell: SignalMapperCoverageCell?
  /// Which question the map is asking, so the headline answers the same one.
  var layer: SignalMapperMapLayer = .heard
  /// Repeaters this ride is locked onto — badged.
  var focusHexIDs: Set<String> = []
  /// True when this is the hexagon the rider is in right now, not one they tapped.
  var isLiveCell = false
  /// A run is open, so the card offers "This ride" beside "All time".
  var isRunActive = false
  /// The repeater the card is filtered to, if any. A binding because the chips inside
  /// the card set it and the map's selection logic has to be able to clear it.
  @Binding var repeaterFilter: String?
  let onDetails: () -> Void
  var onLockOn: ((SignalMapperCoverageRepeater) -> Void)?
  /// Flips the map between Heard and Reach. The card's leg badge and the nav-bar picker
  /// are one control with two faces, never two sources of truth.
  var onSwitchLayer: (() -> Void)?
  let onClose: () -> Void

  /// Which dataset the figures come from while a run is open.
  enum Scope: Hashable {
    case thisRide
    case allTime
  }

  /// Ceiling for the scrolling middle. Only what is between the header and the footer
  /// can ever scroll, and only when it does not fit.
  private static let maxScrollHeight: CGFloat = 220

  @State private var scope: Scope = .thisRide
  @State private var contentHeight: CGFloat = 0

  var body: some View {
    // One clock for every age on the card and for the freshness rule itself: a chip that
    // was current a second ago goes grey the second it is not.
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let now = context.date
      VStack(alignment: .leading, spacing: 7) {
        // Header and footer are pinned. The headline is the first thing to read and the
        // footer is the only route to the detail sheet; neither may be the part that
        // scrolls out of sight (field report, 2026-08-30, and UI review P1-5).
        header(now: now)
        if isRunActive {
          scopePicker
        }
        scrollingMiddle(now: now)
        footerRow
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
  }

  /// `ScrollView` is greedy along its axis: given a concrete proposal it returns the
  /// proposal, so a plain `.frame(maxHeight:)` renders every card at exactly that height
  /// — a short card as a slab of dead space, a tall one clipped mid-row with the next
  /// control flush against it. Measuring the content and taking the *minimum* is the
  /// pattern `HeardRepeatsMapView` already uses for the same configuration (UI review
  /// P0-1).
  private func scrollingMiddle(now: Date) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 7) {
        if showsRide, sessionCell == nil {
          nothingThisRide
        } else {
          if filtered != nil {
            filterBar
          }
          signalRows
          detailRows(now: now)
          repeaterSections(now: now)
        }
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }
    .scrollBounceBehavior(.basedOnSize)
    .defaultScrollAnchor(.top)
    .frame(height: min(contentHeight, Self.maxScrollHeight))
  }

  // MARK: - Which data

  private var showsRide: Bool {
    isRunActive && scope == .thisRide
  }

  /// The cell every figure below reads from: the ride's residual or the all-time merge.
  private var displayed: SignalMapperCoverageCell {
    showsRide ? (sessionCell ?? cell) : cell
  }

  /// The repeater the card is currently filtered to, in the displayed dataset.
  private var filtered: SignalMapperCoverageRepeater? {
    guard let repeaterFilter else { return nil }
    return displayed.repeaters.first { $0.hexID == repeaterFilter }
  }

  /// Display names that more than one repeater in this cell answers to.
  ///
  /// The builder collapses one node's several hash widths into one row, so what is left
  /// is the genuine case: two distinct hashes whose best-guess resolution is the same
  /// node. A name that cannot tell two rows apart has to carry the hash that can.
  private var collidingNames: Set<String> {
    var seen: Set<String> = []
    var collisions: Set<String> = []
    for repeater in displayed.repeaters {
      guard let name = repeater.name else { continue }
      if !seen.insert(name).inserted { collisions.insert(name) }
    }
    return collisions
  }

  private func label(for repeater: SignalMapperCoverageRepeater) -> String {
    guard let name = repeater.name else { return repeater.hexID }
    return collidingNames.contains(name) ? "\(name) \(repeater.hexID)" : name
  }

  /// Probed from here, and nobody ever reported hearing us — v1's dead-zone state, which
  /// only means anything while the map is asking the reach question.
  private var isNoResponse: Bool {
    layer == .reach && filtered == nil && displayed.isUnreachedProbed
  }

  // MARK: - Header

  private func header(now: Date) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if isNoResponse {
        Image(systemName: "antenna.radiowaves.left.and.right.slash")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          legBadge
          Text(
            isNoResponse
              ? L10n.Tools.Tools.SignalMapper.Card.noResponse
              : headlineQuality.localizedLabel
          )
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(isNoResponse ? AnyShapeStyle(.secondary) : AnyShapeStyle(headlineQuality.color))
          .lineLimit(1)
        }
        Text(subtitle(now: now))
          .font(.caption)
          .foregroundStyle(.secondary)
          .contentTransition(.numericText())
          .lineLimit(1)
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

  /// Which leg the headline is grading, in words, and the switch to the other one. The
  /// one thing the first three cards never said out loud (Rafael, 2026-09-03).
  private var legBadge: some View {
    Button {
      onSwitchLayer?()
    } label: {
      Label {
        Text(legLabel)
      } icon: {
        Image(systemName: layer == .reach ? "arrow.up" : "arrow.down")
      }
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(.tint.opacity(0.15), in: .capsule)
      .foregroundStyle(.tint)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(onSwitchLayer == nil)
    .accessibilityLabel(legLabel)
    .accessibilityHint(L10n.Tools.Tools.SignalMapper.Card.legBadgeHint)
  }

  private var legLabel: String {
    layer == .reach
      ? L10n.Tools.Tools.SignalMapper.Card.txSignal
      : L10n.Tools.Tools.SignalMapper.Card.rxSignal
  }

  /// The headline grades the leg the map is currently painting, from the same value the
  /// matching column prints — never the best on one and the mean on the other.
  private var headlineQuality: SignalQuality {
    (layer == .reach ? txLeg : rxLeg).quality
  }

  /// Volume on the graded leg, and when this radio last heard a repeater here directly.
  /// "My Cell" rides along as a location marker rather than a headline word.
  private func subtitle(now: Date) -> String {
    var parts: [String] = []
    if isLiveCell {
      parts.append(L10n.Tools.Tools.SignalMapper.Card.myCell)
    }
    if showsRide {
      parts.append(L10n.Tools.Tools.SignalMapper.Card.thisRide)
    }
    if isNoResponse {
      parts.append(L10n.Tools.Tools.SignalMapper.Card.noResponseDetail)
    } else if layer == .reach {
      let readings = filtered?.txPacketCount ?? displayed.txSnrCount
      parts.append(L10n.Tools.Tools.SignalMapper.Card.txReadings(readings))
    } else {
      let received = filtered?.rxPacketCount ?? displayed.rxCount
      parts.append(L10n.Tools.Tools.SignalMapper.Card.packetsReceived(received))
    }
    if let heard = lastDirectHearing {
      parts.append(L10n.Tools.Tools.SignalMapper.Card.heardAgo(Self.age(from: heard, to: now)))
    }
    return parts.joined(separator: " · ")
  }

  /// The freshest direct hearing in the displayed dataset: the filtered repeater's, else
  /// the newest across every repeater this radio heard. Never our own transmissions, and
  /// never a relay somebody else measured.
  private var lastDirectHearing: Date? {
    if let filtered { return filtered.lastDirectHeard }
    return displayed.repeaters.compactMap(\.lastDirectHeard).max()
  }

  // MARK: - Scope

  private var scopePicker: some View {
    Picker(selection: $scope) {
      Text(L10n.Tools.Tools.SignalMapper.Card.thisRide).tag(Scope.thisRide)
      Text(L10n.Tools.Tools.SignalMapper.Card.allTime).tag(Scope.allTime)
    } label: {
      Text(L10n.Tools.Tools.SignalMapper.Card.thisRide)
    }
    .pickerStyle(.segmented)
    .controlSize(.small)
    .onChange(of: scope) { _, _ in
      // A repeater picked in one dataset may not exist in the other.
      repeaterFilter = nil
    }
  }

  private var nothingThisRide: some View {
    Text(L10n.Tools.Tools.SignalMapper.Card.nothingThisRide)
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 6)
  }

  // MARK: - Filter bar

  /// "via <repeater>" — with the two things worth doing to a repeater you just singled
  /// out: watch it for the rest of the ride, or go back to the whole cell.
  private var filterBar: some View {
    HStack(spacing: 4) {
      Image(systemName: "line.3.horizontal.decrease.circle.fill")
        .font(.caption2)
      Text(L10n.Tools.Tools.SignalMapper.Card.via(filtered.map(label(for:)) ?? repeaterFilter ?? ""))
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
        isActive: layer == .heard,
        unknownReason: rxLeg.graded == nil ? L10n.Tools.Tools.SignalMapper.Detail.noPacketsHeard : nil
      )

      Divider()
        .frame(width: 0.5)

      signalColumn(
        label: L10n.Tools.Tools.SignalMapper.Card.txSignal,
        arrow: "arrow.up",
        leg: txLeg,
        isActive: layer == .reach,
        unknownReason: txUnknownReason
      )
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  /// One link direction, already reduced to the numbers the column prints. `graded` is
  /// both the graded and the printed value: the best reading where one exists, else the
  /// mean — a ride's residual has no best, because maxima do not subtract, and says so
  /// with the "avg" tag instead of grading the mean and calling it the best.
  private struct Leg {
    var best: Double?
    var average: Double?
    var low: Double?
    var high: Double?

    var graded: Double? {
      best ?? average
    }

    var isAverage: Bool {
      best == nil && average != nil
    }

    var quality: SignalQuality {
      SignalQuality(snr: graded)
    }
  }

  /// A filtered leg never falls back to the cell's own numbers — mixing one repeater's
  /// label with every repeater's data is exactly what v1 refused to do.
  private var rxLeg: Leg {
    if let filtered {
      return Leg(
        best: filtered.bestSnr,
        average: filtered.averageSnr,
        low: filtered.worstSnr,
        high: filtered.bestSnr
      )
    }
    return Leg(
      best: displayed.bestSnr,
      average: displayed.averageSnr,
      low: displayed.worstSnr,
      high: displayed.bestSnr
    )
  }

  private var txLeg: Leg {
    if let filtered {
      return Leg(
        best: filtered.bestTxSnr,
        average: filtered.averageTxSnr,
        low: filtered.worstTxSnr,
        high: filtered.bestTxSnr
      )
    }
    return Leg(
      best: displayed.bestTxSnr,
      average: displayed.averageTxSnr,
      low: nil,
      high: nil
    )
  }

  /// Why the uplink column is blank — v1's `unknownReason`, which is the difference
  /// between "we have no data" and "we asked and nobody answered".
  private var txUnknownReason: String? {
    guard txLeg.graded == nil else { return nil }
    if filtered != nil {
      return L10n.Tools.Tools.SignalMapper.Card.heardOnlyReason
    }
    if displayed.isUnreachedProbed {
      return L10n.Tools.Tools.SignalMapper.Detail.neverHeardBack
    }
    return L10n.Tools.Tools.SignalMapper.Card.waitingUplink
  }

  /// Bars on the left, stacked numbers on the right — fills the width, saves the height
  /// (v1's `signalColumn`, which is why two legs fit on one line of a phone). The column
  /// the map is not painting steps back so the graded one reads as the graded one.
  private func signalColumn(
    label: String,
    arrow: String,
    leg: Leg,
    isActive: Bool,
    unknownReason: String?
  ) -> some View {
    let quality = leg.quality
    return HStack(alignment: .top, spacing: 6) {
      Image(systemName: "cellularbars", variableValue: Double(quality.rank) / 5.0)
        .font(.system(size: 22))
        .foregroundStyle(quality == .unknown ? AnyShapeStyle(.quaternary) : AnyShapeStyle(quality.color))

      VStack(alignment: .leading, spacing: 1) {
        Label {
          Text(label)
        } icon: {
          Image(systemName: arrow)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

        if let graded = leg.graded {
          HStack(spacing: 3) {
            Text(quality.localizedLabel)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(quality.color)
            Text(Self.decibels(graded, places: 1))
              .font(.system(.caption2, design: .monospaced))
              .foregroundStyle(.primary)
              .contentTransition(.numericText())
            if leg.isAverage {
              Text(L10n.Tools.Tools.SignalMapper.Card.averageTag)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          if let context = contextLine(leg) {
            Text(context)
              .font(.system(.caption2, design: .monospaced))
              .foregroundStyle(.secondary)
          }
        } else if let unknownReason {
          Text(unknownReason)
            .font(.caption2)
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
    .opacity(isActive ? 1 : 0.6)
    .accessibilityElement(children: .combine)
  }

  /// The mean and the spread, on one line under the best reading the word grades — so
  /// "Excellent 11" and "avg 4.2" are visibly two different facts instead of one
  /// contradiction.
  private func contextLine(_ leg: Leg) -> String? {
    var parts: [String] = []
    if let average = leg.average, let best = leg.best, abs(best - average) >= 0.5 {
      parts.append(L10n.Tools.Tools.SignalMapper.Card.average(Self.decibels(average, places: 1)))
    }
    if let low = leg.low, let high = leg.high, high - low >= 0.5 {
      parts.append("\(Self.decibels(low))–\(Self.decibels(high))")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  // MARK: - Detail rows

  private func detailRows(now: Date) -> some View {
    VStack(spacing: 2) {
      if let filtered {
        detailRow(
          label: L10n.Tools.Tools.SignalMapper.Card.packetSplit,
          value: L10n.Tools.Tools.SignalMapper.Card.packetSplitValue(
            filtered.rxPacketCount, filtered.txPacketCount
          )
        )
      } else if let strongest = strongestNow(at: now), let snr = strongest.lastRxSnr,
                let heard = strongest.lastDirectHeard {
        detailRow(
          label: L10n.Tools.Tools.SignalMapper.Card.strongestNow,
          value: [
            Self.decibels(snr, places: 1) + " dB",
            label(for: strongest),
            Self.age(from: heard, to: now)
          ].joined(separator: " · "),
          valueColor: SignalQuality(snr: snr).color
        )
      }
      // A cell property, not a per-repeater one: it stays put when a chip is picked.
      probeSuccessRow
    }
  }

  /// The repeater carrying this hexagon *right now*: the strongest of the last direct
  /// readings inside the freshness window. Not the best reading ever — one lucky packet
  /// from a distant node weeks ago is exactly what the old "Best Repeater" rewarded.
  ///
  /// The order is total and every step is a statistic the reader can check: the latest
  /// reading to the nearest decibel (LoRa saturates around +13 dB, so nearby repeaters
  /// tie there constantly), then RSSI, which still has range at the SNR ceiling, then how
  /// much direct evidence backs it, then who was heard most recently, then the hash.
  private func strongestNow(at now: Date) -> SignalMapperCoverageRepeater? {
    displayed.repeaters
      .filter { $0.isDirectCurrent(at: now) && $0.lastRxSnr != nil }
      .max { lhs, rhs in
        let lhsBucket = (lhs.lastRxSnr ?? -100).rounded()
        let rhsBucket = (rhs.lastRxSnr ?? -100).rounded()
        if lhsBucket != rhsBucket { return lhsBucket < rhsBucket }
        let lhsRssi = lhs.averageRssi ?? -200
        let rhsRssi = rhs.averageRssi ?? -200
        if lhsRssi != rhsRssi { return lhsRssi < rhsRssi }
        if lhs.directReadingCount != rhs.directReadingCount {
          return lhs.directReadingCount < rhs.directReadingCount
        }
        let lhsHeard = lhs.lastDirectHeard ?? .distantPast
        let rhsHeard = rhs.lastDirectHeard ?? .distantPast
        if lhsHeard != rhsHeard { return lhsHeard < rhsHeard }
        return lhs.hexID > rhs.hexID
      }
  }

  /// Probes answered over probes sent. Reply packets are not the numerator: one discover
  /// is answered by every repeater in range, which is what produced "400%" (field report,
  /// 2026-08-30). The reply count lives in the detail sheet.
  @ViewBuilder
  private var probeSuccessRow: some View {
    if let rate = displayed.probeSuccessRate {
      let percent = Int((rate * 100).rounded())
      detailRow(
        label: L10n.Tools.Tools.SignalMapper.Card.probeSuccessLabel,
        value: L10n.Tools.Tools.SignalMapper.Card.probeSuccessValue(
          percent,
          min(displayed.probesAnswered, displayed.probesSent),
          displayed.probesSent
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
        .lineLimit(1)
        .contentTransition(.numericText())
    }
  }

  // MARK: - Repeaters

  /// The repeaters this radio heard directly in the hexagon, as buttons: the ones with
  /// both legs current first, then the rest, **most recently heard first** inside each
  /// row — the left end is where the eye lands, so it holds what is happening now
  /// (Rafael, 2026-08-30). Nodes that only sat in a packet's path, or only reported
  /// hearing us without ever being heard, are one small count that opens the detail
  /// sheet (Rafael, 2026-09-03).
  @ViewBuilder
  private func repeaterSections(now: Date) -> some View {
    let direct = displayed.repeaters.filter(\.wasHeardDirectly)
    let indirectCount = displayed.repeaters.count - direct.count
    if !direct.isEmpty || indirectCount > 0 {
      Divider()
      VStack(alignment: .leading, spacing: 5) {
        let twoWay = byRecency(direct.filter { $0.link(at: now) == .twoWay })
        let heard = byRecency(direct.filter { $0.link(at: now) != .twoWay })
        if !twoWay.isEmpty {
          repeaterRow(
            label: L10n.Tools.Tools.SignalMapper.Card.connected,
            icon: "arrow.left.arrow.right",
            iconColor: .green,
            repeaters: twoWay,
            now: now,
            indirectCount: heard.isEmpty ? indirectCount : 0
          )
        }
        if !heard.isEmpty || twoWay.isEmpty {
          repeaterRow(
            label: L10n.Tools.Tools.SignalMapper.Card.heardOnly,
            icon: "ear",
            iconColor: .secondary,
            repeaters: heard,
            now: now,
            indirectCount: indirectCount
          )
        }
      }
    }
  }

  private func byRecency(
    _ repeaters: [SignalMapperCoverageRepeater]
  ) -> [SignalMapperCoverageRepeater] {
    repeaters.sorted { lhs, rhs in
      let lhsHeard = lhs.lastDirectHeard ?? .distantPast
      let rhsHeard = rhs.lastDirectHeard ?? .distantPast
      if lhsHeard != rhsHeard { return lhsHeard > rhsHeard }
      return lhs.hexID < rhs.hexID
    }
  }

  private func repeaterRow(
    label: String,
    icon: String,
    iconColor: Color,
    repeaters: [SignalMapperCoverageRepeater],
    now: Date,
    indirectCount: Int
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
            chip(for: repeater, now: now)
          }
          if indirectCount > 0 {
            indirectPill(indirectCount)
          }
        }
      }
    }
  }

  private func chip(for repeater: SignalMapperCoverageRepeater, now: Date) -> some View {
    let isFiltered = repeaterFilter == repeater.hexID
    let isFocused = focusHexIDs.contains(repeater.hexID)
    let isStale = repeater.isStale(at: now)
    return Button {
      withAnimation(.snappy(duration: 0.2)) {
        repeaterFilter = isFiltered ? nil : repeater.hexID
      }
    } label: {
      HStack(spacing: 4) {
        if isFocused {
          Image(systemName: "scope")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.tint)
        }
        // An unresolved hash goes monospaced: 0/O and 1/l have to stay apart.
        Text(label(for: repeater))
          .font(repeater.name == nil ? .system(.caption, design: .monospaced) : .caption)
          .lineLimit(1)
        if repeater.isAmbiguous {
          Image(systemName: "questionmark.circle")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
        }
        if let tx = repeater.bestTxSnr ?? repeater.averageTxSnr {
          Text("▲" + Self.decibels(tx))
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.primary)
        }
        if let rx = repeater.lastRxSnr ?? repeater.bestSnr ?? repeater.averageSnr {
          Text("▼" + Self.decibels(rx))
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        if let heard = repeater.lastDirectHeard {
          Text(Self.age(from: heard, to: now))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .contentTransition(.numericText())
        }
      }
      .padding(.horizontal, 10)
      // 36 pt rather than 44: two rows of 44 pt chips cost more of the map than the
      // 8 pt buys back, and a capsule in a horizontal row is the one control class
      // Apple itself ships below the full target (filter chips, ~34 pt).
      .padding(.vertical, 8)
      .background(isFiltered ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary.opacity(0.6)))
      .clipShape(.capsule)
      .overlay {
        Capsule().strokeBorder(isFiltered ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1)
      }
      // Past the freshness window the chip steps back: still there, still tappable, no
      // longer claiming to be current.
      .opacity(isStale ? 0.5 : 1)
      // 36 pt pill, 44 pt target: the visual stays dense enough for two groups of chips,
      // and the touch area still clears the guideline in the one configuration where a
      // mis-tap is most likely — nested scroll views over a pannable map (UI review
      // P2-14).
      .padding(.vertical, 4)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(chipAccessibilityLabel(repeater, now: now))
    .accessibilityHint(L10n.Tools.Tools.SignalMapper.Card.chipHint)
    .accessibilityAddTraits(isFiltered ? [.isSelected] : [])
  }

  /// "+9 indirect": the honest count of everything that is not a chip.
  private func indirectPill(_ count: Int) -> some View {
    Button(action: onDetails) {
      Text(L10n.Tools.Tools.SignalMapper.Card.indirectCount(count))
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay {
          Capsule().strokeBorder(.quaternary, lineWidth: 1)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityHint(L10n.Tools.Tools.SignalMapper.Card.indirectHint)
  }

  private func chipAccessibilityLabel(_ repeater: SignalMapperCoverageRepeater, now: Date) -> String {
    var parts = [label(for: repeater)]
    if repeater.isAmbiguous {
      parts.append(L10n.Tools.Tools.SignalMapper.Detail.ambiguousName)
    }
    if let tx = repeater.bestTxSnr ?? repeater.averageTxSnr {
      parts.append(L10n.Tools.Tools.SignalMapper.Focus.uplinkAccessibility(Int(tx.rounded())))
    }
    if let rx = repeater.lastRxSnr ?? repeater.bestSnr ?? repeater.averageSnr {
      parts.append(L10n.Tools.Tools.SignalMapper.Card.downlinkAccessibility(Int(rx.rounded())))
    }
    if let heard = repeater.lastDirectHeard {
      parts.append(L10n.Tools.Tools.SignalMapper.Card.heardAgo(Self.age(from: heard, to: now)))
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
