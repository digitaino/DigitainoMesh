import MapperRawLog
import MC1Services
import SurveyKit
import SwiftUI

/// One hexagon, read from its rows (docs/SIGNAL_MAPPER_V3.md §3, mockup screens 1–3, row
/// style A).
///
/// A header that names the leg the map is painting and grades it, then one row per repeater
/// this radio heard *directly* here — §1's rule, applied at capture — most recent first,
/// each with the downlink's `now · best · avg` and what that repeater has said about us.
/// Tapping a row opens every observation of it in this hexagon.
///
/// What this card deliberately no longer has, and why: the aggregate table it used to read
/// is retired (§6), so "Best Repeater", the route mix, the probe success rate and the
/// packet split are gone — every one of them was a statistic the aggregate row happened to
/// hold rather than an answer anyone asked for. The repeater chips are gone with them: the
/// list *is* the repeaters, and filtering the whole card to one of them is what the detail
/// sheet does properly.
///
/// Since 2026-09-04 a row can exist with no downlink reading at all — a repeater that
/// answered a probe, or that an echo proves heard us, without our radio ever measuring it.
/// Those rows print what is known and an em dash where a number would be invented; on the
/// Reach layer they are the point of the layer rather than an edge case.
struct SignalMapperCellCard: View {
  /// The hexagon as the map has it — geometry and the all-time fold behind its colour.
  let cell: SignalMapperMapCell
  /// Its rows, once they have been read. Nil while a fetch is in flight.
  let data: SignalMapperCardData?
  /// Which question the map is asking, so the header answers the same one.
  var layer: SignalMapperMapLayer = .heard
  /// True when this is the hexagon the rider is in right now, not one they tapped.
  var isLiveCell = false
  /// True while a ride is open — the only time the scope switch means anything.
  var isRiding = false
  /// Which kind of "nothing" an empty hexagon is, so the card blames the right thing.
  var emptyReason: SignalMapperCardEmptyReason = .nothingHere
  @Binding var scope: SignalMapperCardScope
  /// How tall the scrolling middle may grow once the rider expands it — what the coverage
  /// view has left over after the map's own minimum viewport and the panel's chrome. Zero
  /// until it has measured that, which simply keeps the card at its collapsed size.
  var maxRowsHeight: CGFloat = 0
  /// Reports how tall the rows are actually drawing. The coverage view subtracts it from
  /// the panel it measures to get the panel's fixed chrome, which is how it computes
  /// ``maxRowsHeight`` without anyone having to enumerate the blocks around this card.
  var onRowsHeight: (CGFloat) -> Void = { _ in }
  /// Flips the map's layer. The badge is the switch: the card names the leg, so the card
  /// is where you change it.
  let onFlipLayer: () -> Void
  let onRepeater: (SignalMapperRepeaterListRow) -> Void
  let onClose: () -> Void

  /// Fallback ceiling for the scrolling middle, used until a row has been measured.
  private static let fallbackScrollHeight: CGFloat = 132
  private static let rowSpacing: CGFloat = 8
  /// How many rows fit before the middle starts scrolling while the card is collapsed
  /// (§3: the card is a readout on top of a map, not a list view).
  private static let visibleRows = 3

  @State private var contentHeight: CGFloat = 0
  @State private var rowHeight: CGFloat = 0

  /// Read only to decide whether the header's best-link readout is drawn — see ``header``.
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  /// Whether the rider has asked for the taller list, remembered across hexagons, rides and
  /// launches: "we need to be able to see more information at the same time" is a standing
  /// preference, not a per-card one (Rafael, 2026-09-05). Collapsed remains the default —
  /// the card sits on a map that is also the thing being read.
  @AppStorage(AppStorageKey.signalMapperCardExpanded.rawValue)
  private var isExpanded = AppStorageKey.defaultSignalMapperCardExpanded

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      // The header is pinned: it is the first thing to read and the only route back to the
      // other layer, so it may never be the part that scrolls out of sight.
      header
      scrollingMiddle
      // EXTENSION POINT (§7 step 6, Reach): the per-hexagon reach line —
      // "Reach · 6 observers heard packets sent here · farthest 18 km   (Look up)" —
      // belongs here, below the rows and pinned like the header. It needs
      // `MapperCellQueries.reach(in:sightings:)` over `sent` rows plus a CoreScope
      // lookup on tap, neither of which exists yet.
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
  /// P0-1). The ceiling is a whole number of measured rows either way, so the cut always
  /// lands between rows however large the type is.
  private var scrollingMiddle: some View {
    let height = min(contentHeight, scrollCeiling)
    return ScrollView {
      rowsBody
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }
    .scrollBounceBehavior(.basedOnSize)
    .defaultScrollAnchor(.top)
    .frame(height: height)
    // Reported rather than measured by the parent, because the parent needs precisely this
    // number — the panel's height minus this is its fixed chrome — and measuring the card
    // from outside would hand it back the chrome and the rows added together.
    .onChange(of: height, initial: true) { _, new in onRowsHeight(new) }
  }

  private var scrollCeiling: CGFloat {
    guard isExpanded, rowHeight > 0, maxRowsHeight > 0 else { return collapsedCeiling }
    // Whole rows only: the ceiling is what fits in the room the map can spare, rounded
    // down to a row boundary so an expanded card never ends mid-row either.
    let fitting = Int(((maxRowsHeight + Self.rowSpacing) / (rowHeight + Self.rowSpacing)).rounded(.down))
    return max(collapsedCeiling, ceiling(rows: max(Self.visibleRows, fitting)))
  }

  /// Three rows, as the card has always been. Expanding never goes *below* this: a hexagon
  /// on a short screen still lists what it used to.
  private var collapsedCeiling: CGFloat {
    guard rowHeight > 0 else { return Self.fallbackScrollHeight }
    return ceiling(rows: Self.visibleRows)
  }

  private func ceiling(rows count: Int) -> CGFloat {
    rowHeight * CGFloat(count) + Self.rowSpacing * CGFloat(count - 1)
  }

  @ViewBuilder
  private var rowsBody: some View {
    if let data {
      if data.repeaters.isEmpty {
        Text(Self.emptyText(
          reason: emptyReason,
          scope: data.scope,
          heardCount: data.headline.heardCount
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
      } else {
        // One clock for the whole list rather than one per row, and a five-second tick
        // rather than a one-second one: these ages are minutes-scale, and a card that
        // invalidates at 1 Hz for an hour of riding is the thermal defect UI review S3
        // was about. The header's own age still ticks every second.
        TimelineView(.periodic(from: .now, by: 5)) { context in
          LazyVStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(Array(data.repeaters.enumerated()), id: \.element.id) { index, item in
              repeaterRow(item, now: context.date, measured: index == 0)
            }
          }
        }
      }
    } else {
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
  }

  /// One short line saying which kind of nothing this is.
  ///
  /// "Nothing heard here this ride" is true of a hexagon the ride simply has not reached
  /// into, and a lie about a ride that is capturing nothing anywhere or whose positions are
  /// all being refused — the two states that actually produced the empty card in the field
  /// (2026-09-04). The card blames the hexagon only when the hexagon is what is empty.
  ///
  /// And it may not blame the hexagon for being empty while the header beside it counts
  /// packets. A hexagon whose rows are all direct-routed, or 0-hop and not adverts, credits
  /// no repeater under §1 and lists nothing — but "12 heard" is pinned above the empty line
  /// and is the true number, so the line says what the list is missing instead of denying
  /// the count. Keyed on `heardCount` rather than on the layer: "nothing heard here" is
  /// just as false on Reach.
  ///
  /// Static and parameterised so the four sentences can be pinned by a test without
  /// standing up a view.
  static func emptyText(
    reason: SignalMapperCardEmptyReason,
    scope: SignalMapperCardScope,
    heardCount: Int
  ) -> String {
    switch reason {
    case .fixesRejected:
      L10n.Tools.Tools.SignalMapper.Card.fixesRejected
    case .noFixYet:
      L10n.Tools.Tools.SignalMapper.Card.noFixYet
    case .nothingYet:
      L10n.Tools.Tools.SignalMapper.Card.nothingYet
    case .nothingHere:
      if heardCount > 0 {
        L10n.Tools.Tools.SignalMapper.Card.noneAttributable(heardCount)
      } else if scope == .ride {
        L10n.Tools.Tools.SignalMapper.Card.nothingThisRide
      } else {
        L10n.Tools.Tools.SignalMapper.Detail.noPacketsHeard
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    // One clock for everything the header decides: which link is best and whether it is
    // stale have to be answered against the same instant, or a redraw could grade one row
    // and name another.
    let now = Date()
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          legBadge
          Text(verdict)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isNoResponse ? AnyShapeStyle(.secondary) : AnyShapeStyle(verdictColor))
        }
        subtitle
      }

      Spacer(minLength: 0)

      // Gone entirely at accessibility sizes rather than shrunk or wrapped. Every part of
      // this row is at its floor already — two 44 pt targets, a badge, a graded word — so
      // the readout is what turns a two-line header into a four-line one, and the rows
      // below print the same two numbers for the same repeater at that size.
      if !dynamicTypeSize.isAccessibilitySize,
         let best = Self.bestLink(in: data?.repeaters ?? [], now: now) {
        bestLinkReadout(best, now: now)
      }

      expandButton

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
    // text beside it.
    .frame(minHeight: 44)
  }

  /// Collapsed ⇄ expanded, beside the close button because that is where the card's own
  /// controls live. Always drawn, even on a hexagon with two rows: a control that comes and
  /// goes with the data would move the close button under the rider's thumb mid-ride.
  private var expandButton: some View {
    Button {
      withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
    } label: {
      Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 44, height: 44)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      isExpanded
        ? L10n.Tools.Tools.SignalMapper.Card.collapse
        : L10n.Tools.Tools.SignalMapper.Card.expand
    )
  }

  // MARK: - Best link

  /// The nav-bar radio pill, per hexagon.
  ///
  /// The pill is hidden while a ride runs because this card was meant to replace it — and
  /// until 2026-09-05 it did not: the rider lost the one readout that says, at a glance, how
  /// the link they are on is doing right now (Rafael, on the ride: "what I want to see in
  /// the signal mapper list is what we see in the signal pill but specific for the cell we
  /// are in"). The pill's two columns — RX bars over the number, TX bars over the number —
  /// so it is read the same way without relearning anything.
  ///
  /// Graded on SurveyKit's six-step ``SignalQuality``, not the pill's four-step
  /// ``SNRQuality``: everything else on this card and on the map under it uses the six-step
  /// scale, and mixing them here would let the header's bars disagree with the row's.
  ///
  /// **Two things the pill carries that this does not.** The adaptive-power step, because
  /// the ride strip already shows it. And the repeater's hash: the pill prints it because a
  /// nav-bar cluster has no other way to say who it means, whereas here the same repeater is
  /// named in full a few points below and a tap opens its detail — so the hash was the one
  /// part of the cluster that could go without losing information, and this header has three
  /// other things competing for the same row.
  ///
  /// Fixed-size and prioritised: when the row runs short the verdict word truncates and the
  /// numbers do not, because the numbers are the whole reason the readout is here.
  private func bestLinkReadout(_ item: SignalMapperRepeaterListRow, now: Date) -> some View {
    Button {
      onRepeater(item)
    } label: {
      // Tight on purpose: this shares a row with the verdict, the chevron and the close
      // button, and every point it takes is a point the verdict line has to give up.
      HStack(spacing: 4) {
        legColumn(
          glyph: RepeaterSignalGlyph(leg: .rx, coverage: SignalQuality(snr: item.row.rxLatest), size: 12),
          readout: snrReadout(item.row.rxLatest)
        )
        legColumn(glyph: uplinkLegGlyph(item, now: now), readout: uplinkLegReadout(item, now: now))
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .fixedSize(horizontal: true, vertical: false)
    .layoutPriority(1)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(L10n.Tools.Tools.SignalMapper.Card.bestLink)
    .accessibilityValue(Self.bestLinkDescription(for: item, now: now))
    .accessibilityHint(L10n.Tools.Tools.SignalMapper.Card.rowHint)
  }

  /// The pill's own column: bars, and the number under them.
  private func legColumn(glyph: some View, readout: some View) -> some View {
    VStack(spacing: 0) {
      glyph
      readout
    }
  }

  /// Nothing at all when there is no measurement, exactly as `RepeaterSNRText` does it: a
  /// column that collapses says less than a placeholder that reads like a value.
  @ViewBuilder
  private func snrReadout(_ snr: Double?) -> some View {
    if let snr {
      Text(L10n.Localizable.SignalBars.snrValue(Int(snr.rounded())))
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(SignalQuality(snr: snr).color)
    }
  }

  /// §1's three uplink states as one glyph: bars for a reported number, empty bars for a
  /// link an echo proves without measuring (the "heard you" state — it hears us, at an
  /// unknown strength), and the app's `↑?` for a repeater nothing here says can hear us.
  @ViewBuilder
  private func uplinkLegGlyph(_ item: SignalMapperRepeaterListRow, now: Date) -> some View {
    switch item.row.link(at: now) {
    case let .hearsYou(snr, _):
      RepeaterSignalGlyph(leg: .tx, coverage: SignalQuality(snr: snr), size: 12)
    case .heardYou:
      RepeaterSignalGlyph(leg: .tx, coverage: .unknown, size: 12)
    case .none:
      RepeaterTXGlyph(state: .unknown, size: 12)
    }
  }

  @ViewBuilder
  private func uplinkLegReadout(_ item: SignalMapperRepeaterListRow, now: Date) -> some View {
    if case let .hearsYou(snr, _) = item.row.link(at: now) {
      snrReadout(snr)
    }
  }

  /// Which link the header speaks for: the strongest thing we can hear here *now*.
  ///
  /// Strongest by `rxLatest` rather than by `rxBest`, because this is the pill's question —
  /// what is the radio on right now — and a repeater's best-ever reading in a hexagon is
  /// the row's job to print. Stale rows (§1's ten minutes) are considered only when nothing
  /// fresh has a reading: the header would otherwise go blank on a hexagon whose evidence is
  /// all older than ten minutes, which is a place, not an error.
  nonisolated static func bestLink(
    in repeaters: [SignalMapperRepeaterListRow],
    now: Date
  ) -> SignalMapperRepeaterListRow? {
    let fresh = repeaters.filter { !$0.row.isStale(at: now) }
    // The first pass is gated on the age of the *reading it prints*, not on the row's
    // freshness: `isStale` measures the newest evidence of any kind, and a probe reply
    // keeps a repeater "fresh" for as long as it keeps answering, so a row whose last
    // downlink measurement is two hours old would otherwise win on that old number and
    // the header would grade a link the radio is not on (review, 2026-09-05).
    let freshlyHeard = repeaters.filter { item in
      guard let heardAt = item.row.lastHeardAt else { return false }
      return now.timeIntervalSince(heardAt) <= MapperCellQueries.freshnessWindow
    }
    if let strongest = strongestHeard(in: freshlyHeard) { return strongest }
    if let strongest = strongestHeard(in: repeaters) { return strongest }
    // Nothing was ever measured here — every row is a reply or an echo. The newest of them
    // is still the link this hexagon is running on, and its uplink is worth printing.
    return fresh.first ?? repeaters.first
  }

  private nonisolated static func strongestHeard(
    in repeaters: [SignalMapperRepeaterListRow]
  ) -> SignalMapperRepeaterListRow? {
    repeaters
      .filter { $0.row.rxLatest != nil }
      .max { lhs, rhs in
        let left = lhs.row.rxLatest ?? 0
        let right = rhs.row.rxLatest ?? 0
        if left != right { return left < right }
        if lhs.row.lastEvidenceAt != rhs.row.lastEvidenceAt {
          return lhs.row.lastEvidenceAt < rhs.row.lastEvidenceAt
        }
        // Ties land on the same hexagon-ascending order the list itself uses, so the header
        // names the row a rider would find at the top of it.
        return lhs.hexID > rhs.hexID
      }
  }

  /// One spoken sentence in `RepeaterSignal.accessibilityDescription`'s shape — who, then
  /// each leg named explicitly — so the header and the signal-bars screen sound alike.
  nonisolated static func bestLinkDescription(
    for item: SignalMapperRepeaterListRow,
    now: Date
  ) -> String {
    let who = item.name ?? item.hexID
    let rx = item.row.rxLatest.map {
      L10n.Localizable.SignalBars.Accessibility.rxLeg(SignalQuality(snr: $0).localizedLabel, Int($0.rounded()))
    } ?? L10n.Localizable.SignalBars.Accessibility.rxUnknown
    let tx: String = switch item.row.link(at: now) {
    case let .hearsYou(snr, _):
      L10n.Localizable.SignalBars.Accessibility.txLeg(SignalQuality(snr: snr).localizedLabel, Int(snr.rounded()))
    case .heardYou:
      L10n.Tools.Tools.SignalMapper.Card.heardYou
    case .none:
      L10n.Localizable.SignalBars.Accessibility.txUnknown
    }
    return "\(who), \(rx), \(tx)"
  }

  /// "↓ I hear them" / "↑ They hear me": the card names the leg the map is painting, and
  /// tapping it swaps them. Tinted per leg, matching the layer's own colour language.
  private var legBadge: some View {
    Button(action: onFlipLayer) {
      // The arrow is a direction glyph, not a word: composed here rather than baked into
      // the string, so a translator is never asked to preserve "↓" in the middle of a
      // sentence and a right-to-left locale can mirror the layout around it.
      HStack(spacing: 3) {
        Text(verbatim: layer == .heard ? "↓" : "↑")
        Text(layerName)
      }
      .font(.caption2.weight(.bold))
      .foregroundStyle(layerTint)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(layerTint.opacity(0.18), in: .capsule)
      .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(L10n.Tools.Tools.SignalMapper.Layer.title)
    .accessibilityValue(layerName)
  }

  private var layerName: String {
    layer == .heard
      ? L10n.Tools.Tools.SignalMapper.Layer.heard
      : L10n.Tools.Tools.SignalMapper.Layer.reach
  }

  private var layerTint: Color {
    layer == .heard ? .accentColor : .orange
  }

  private var subtitle: some View {
    HStack(spacing: 5) {
      if isLiveCell {
        Text(L10n.Tools.Tools.SignalMapper.Card.myCell)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if isRiding {
        if isLiveCell { separator }
        scopeSwitch
      }
      if let counts = countsText {
        if isLiveCell || isRiding { separator }
        Text(counts)
          .font(.caption)
          .foregroundStyle(.secondary)
          .contentTransition(.numericText())
      }
    }
    .lineLimit(1)
  }

  private var separator: some View {
    Text(verbatim: "·")
      .font(.caption)
      .foregroundStyle(.tertiary)
  }

  /// "1,048 heard · last 8 s ago" on the Hear layer, "13 readings of you · last 8 s ago" on
  /// Reach — the same sentence about whichever leg is on screen. Nil until the rows land,
  /// because the map's all-time fold is the wrong number to show under a "This ride" chip.
  private var countsText: String? {
    guard let headline = data?.headline else { return nil }
    if isNoResponse {
      return L10n.Tools.Tools.SignalMapper.Card.noResponseDetail
    }
    let count = layer == .heard
      ? L10n.Tools.Tools.SignalMapper.Card.heardCount(headline.heardCount)
      : L10n.Tools.Tools.SignalMapper.Card.readingsOfYou(headline.txReadings)
    guard let latest = latestAt else { return count }
    return count + " · " + agePhrase(since: latest)
  }

  /// The clock the header's age runs on: one second, one `Text`.
  private func agePhrase(since date: Date) -> String {
    L10n.Tools.Tools.SignalMapper.Card.lastHeardAgo(Self.age(from: date, to: Date()))
  }

  /// When the leg on screen last had something to say.
  private var latestAt: Date? {
    guard let data else { return nil }
    return layer == .heard
      ? data.headline.rxLatestAt
      : data.repeaters.compactMap { $0.uplink?.latestAt }.max()
  }

  /// This ride | All time. Ride is the default while riding (§3): the question on a ride is
  /// what is happening now, and the hexagon's whole history is one tap away.
  private var scopeSwitch: some View {
    HStack(spacing: 0) {
      scopeSegment(.ride, title: L10n.Tools.Tools.SignalMapper.Card.thisRide)
      scopeSegment(.allTime, title: L10n.Tools.Tools.SignalMapper.Card.allTime)
    }
    .background(.quaternary.opacity(0.5), in: .capsule)
  }

  private func scopeSegment(_ value: SignalMapperCardScope, title: String) -> some View {
    let isOn = scope == value
    return Button {
      withAnimation(.snappy(duration: 0.2)) { scope = value }
    } label: {
      Text(title)
        .font(.caption2.weight(isOn ? .semibold : .regular))
        .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isOn ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.clear), in: .capsule)
        .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isOn ? [.isSelected] : [])
  }

  /// Probed from here, and nobody ever reported hearing us — v1's dead-zone state, which
  /// only means anything while the map is asking the reach question.
  private var isNoResponse: Bool {
    guard layer == .reach, let headline = data?.headline else { return false }
    return headline.isUnreachedProbed
  }

  /// The header grades the leg the map is currently painting, so the card and the hexagon
  /// under it never disagree about what the colour meant.
  private var headlineQuality: SignalQuality {
    guard let headline = data?.headline else { return .unknown }
    return SignalQuality(snr: layer == .heard ? headline.rxBest : headline.txBest)
  }

  /// Blank until the rows land: grading a hexagon "Unknown" for the half-second before its
  /// own numbers arrive says something false about the place rather than about the fetch.
  private var verdict: String {
    guard data != nil else { return "" }
    if isNoResponse { return L10n.Tools.Tools.SignalMapper.Card.noResponse }
    return headlineQuality.localizedLabel
  }

  private var verdictColor: Color {
    headlineQuality.color
  }

  // MARK: - Rows

  /// Row style A (§10): name and age on the first line, the numbers on the second.
  ///
  /// A repeater the radio has not heard for longer than §1's "now" steps back to 55%
  /// rather than disappearing — the age is printed beside it, and hiding a quiet repeater
  /// would turn "we have not heard it lately" into "it is not there".
  private func repeaterRow(
    _ item: SignalMapperRepeaterListRow,
    now: Date,
    measured: Bool
  ) -> some View {
    Button {
      onRepeater(item)
    } label: {
      HStack(spacing: 8) {
        qualityRail(item)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 4) {
            // An unresolved hash goes monospaced: 0/O and 1/l have to stay apart.
            Text(label(for: item))
              .font(item.name == nil ? .system(.subheadline, design: .monospaced) : .subheadline)
              .foregroundStyle(.primary)
              .lineLimit(1)
            if item.isAmbiguous {
              Image(systemName: "questionmark.circle")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.Tools.Tools.SignalMapper.Detail.ambiguousName)
            }
            Spacer(minLength: 8)
            // The newest evidence of any kind, not the newest downlink reading: a repeater
            // known only from a reply thirty seconds ago is thirty seconds old, and printing
            // the age of a measurement that never happened is not an option.
            Text(Self.age(from: item.row.lastEvidenceAt, to: now))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            leadLine(item, now: now)
            Spacer(minLength: 4)
            trailLine(item, now: now)
          }
        }
      }
      .opacity(item.row.isStale(at: now) ? 0.55 : 1)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityHint(L10n.Tools.Tools.SignalMapper.Card.rowHint)
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
      guard measured, height > 0 else { return }
      rowHeight = height
    }
  }

  /// The Hear layer leads with what we hear; the Reach layer leads with what they report
  /// (mockup screen 2). Same row, the legs swapped.
  @ViewBuilder
  private func leadLine(_ item: SignalMapperRepeaterListRow, now: Date) -> some View {
    switch layer {
    case .heard:
      // A repeater with no downlink reading at all is listed here for what it says about
      // *us* — a reply or an echo put it in the list. Printing `0 now · 0 best · 0 avg`
      // would be a measurement we never made.
      leg(downlinkGlyph(item)) {
        if let latest = item.row.rxLatest, let best = item.row.rxBest, let average = item.row.rxAverage {
          Text(L10n.Tools.Tools.SignalMapper.Card.rxLine(
            Self.decibels(latest, places: 1),
            Self.decibels(best, places: 1),
            Self.decibels(average, places: 1)
          ))
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.primary)
          .lineLimit(1)
        } else {
          Text(L10n.Tools.Tools.SignalMapper.Card.noDirectReading)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    case .reach:
      leg(uplinkGlyph(item)) {
        if let uplink = item.uplink {
          Text(L10n.Tools.Tools.SignalMapper.Card.txLine(
            Self.decibels(uplink.latest, places: 1),
            Self.decibels(uplink.best, places: 1),
            Self.decibels(uplink.average, places: 1)
          ))
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.orange)
          .lineLimit(1)
        } else {
          uplinkStateText(item, now: now)
        }
      }
    }
  }

  @ViewBuilder
  private func trailLine(_ item: SignalMapperRepeaterListRow, now: Date) -> some View {
    switch layer {
    case .heard:
      leg(uplinkGlyph(item)) {
        uplinkStateText(item, now: now)
      }
    case .reach:
      // The Reach layer used to guarantee a downlink figure in the trail. A repeater that
      // hears us and that we have never measured is now a first-class citizen of this
      // layer — it is precisely the asymmetry the layer exists to show — so the trail
      // carries an em dash rather than a number nobody read.
      leg(downlinkGlyph(item)) {
        if let latest = item.row.rxLatest {
          Text(verbatim: Self.decibels(latest, places: 1))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
          Text(verbatim: "—")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
    }
  }

  /// One leg of the link: its bars, then what it says.
  ///
  /// The glyph replaces the leading `↓`/`↑` the sentences used to carry (§10's wording is
  /// otherwise untouched). It says the same thing about direction and adds the one thing the
  /// numbers were failing to convey at a glance — how strong that is — for the cost of the
  /// two characters it removed, which matters on a row that already prints two legs
  /// (Rafael, 2026-09-04: "a better way to visualize the different signal levels").
  private func leg(_ glyph: some View, @ViewBuilder line: () -> some View) -> some View {
    HStack(spacing: 3) {
      glyph
      line()
    }
  }

  /// How strong this repeater is *here* on each leg, on the scale the map paints the
  /// hexagons with (SurveyKit's six steps, not the four-step single-packet scale) — so a
  /// row's bars can never contradict the colour of the hexagon it is inside.
  ///
  /// Graded on `best`, the same number the hexagon is coloured from, even though the
  /// sentence beside it leads with `now`.
  nonisolated static func downlinkQuality(for item: SignalMapperRepeaterListRow) -> SignalQuality {
    SignalQuality(snr: item.row.rxBest)
  }

  /// Nil means no repeater has ever reported a number for us here. Never the downlink's
  /// value: the two legs differ whenever the antennas or the power do, and substituting one
  /// for the other would make an untested link look proven (`RepeaterTXGlyph`'s rule).
  nonisolated static func uplinkQuality(for item: SignalMapperRepeaterListRow) -> SignalQuality? {
    item.uplink.map { SignalQuality(snr: $0.best) }
  }

  /// What the rail grades: whichever leg the map is currently asking about.
  nonisolated static func railQuality(
    for item: SignalMapperRepeaterListRow,
    layer: SignalMapperMapLayer
  ) -> SignalQuality {
    switch layer {
    case .heard: downlinkQuality(for: item)
    case .reach: uplinkQuality(for: item) ?? .unknown
    }
  }

  /// A hairline of the row's own colour down its leading edge, so strength is scannable down
  /// the list rather than only readable row by row. It takes the row's height, so it costs
  /// nothing at any Dynamic Type size, and it lives inside the button's label so a stale row
  /// dims its rail with everything else.
  private func qualityRail(_ item: SignalMapperRepeaterListRow) -> some View {
    Capsule(style: .continuous)
      .fill(Self.railQuality(for: item, layer: layer).color)
      .frame(width: 3)
      .accessibilityHidden(true)
  }

  private func downlinkGlyph(_ item: SignalMapperRepeaterListRow) -> some View {
    RepeaterSignalGlyph(leg: .rx, coverage: Self.downlinkQuality(for: item), size: 13)
  }

  /// The uplink's bars, or the app's "not measured" mark — a repeater proved to hear us only
  /// by an echo draws `↑?`, exactly as the signal-bars row does for a link never probed.
  @ViewBuilder
  private func uplinkGlyph(_ item: SignalMapperRepeaterListRow) -> some View {
    if let quality = Self.uplinkQuality(for: item) {
      RepeaterSignalGlyph(leg: .tx, coverage: quality, size: 13)
    } else {
      RepeaterTXGlyph(state: .unknown, size: 13)
    }
  }

  /// §1's three uplink states, in the approved wording (§10): a reported number, an echo
  /// with no number, or nothing — which is "nothing here says it can hear us", not "it
  /// cannot".
  @ViewBuilder
  private func uplinkStateText(_ item: SignalMapperRepeaterListRow, now: Date) -> some View {
    switch item.row.link(at: now) {
    case let .hearsYou(snr, _):
      Text(L10n.Tools.Tools.SignalMapper.Card.hearsYou(Self.decibels(snr)))
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.orange)
        .lineLimit(1)
    case .heardYou:
      Text(L10n.Tools.Tools.SignalMapper.Card.heardYou)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    case .none:
      Text(verbatim: "—")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }

  /// Display names that more than one repeater in this cell answers to.
  ///
  /// A cell routinely holds several distinct path hashes whose best-guess resolution is
  /// the same node, which renders as "Digitaino Chestnut" three times with three different
  /// SNRs and reads like a bug (field report, 2026-08-30). It isn't one — but a name that
  /// cannot tell two rows apart has to carry the hash that can.
  private var collidingNames: Set<String> {
    var seen: Set<String> = []
    var collisions: Set<String> = []
    for item in data?.repeaters ?? [] {
      guard let name = item.name else { continue }
      if !seen.insert(name).inserted { collisions.insert(name) }
    }
    return collisions
  }

  private func label(for item: SignalMapperRepeaterListRow) -> String {
    guard let name = item.name else { return item.hexID }
    return collidingNames.contains(name) ? "\(name) \(item.hexID)" : name
  }

  // MARK: - Formatting

  /// Decibels without the `-0` that `%f` produces for anything just below zero.
  static func decibels(_ value: Double, places: Int = 0) -> String {
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

  static func age(from date: Date, to now: Date) -> String {
    ageFormatter.string(from: max(0, now.timeIntervalSince(date))) ?? ""
  }
}

// MARK: - Preview

#if DEBUG
  #Preview("Cell card") {
    SignalMapperCellCardPreviewHost(expanded: false)
  }

  // The three 2026-09-05 decisions in one screenshot: the fixture's `0C`/`0C13` pair merged
  // into one row, the list grown past its three, and the best-link readout in the header.
  #Preview("Cell card, expanded") {
    SignalMapperCellCardPreviewHost(expanded: true)
  }

  /// Fixture rows through the real builder, so the preview exercises the same arithmetic the
  /// card ships with rather than a hand-written display model.
  private struct SignalMapperCellCardPreviewHost: View {
    @State private var scope: SignalMapperCardScope = .allTime
    @State private var layer: SignalMapperMapLayer = .heard

    /// The card reads its own expansion from `@AppStorage`, so a preview that wants to show
    /// the expanded state has to write the key the card reads. Confined to previews, which
    /// run against the simulator's own defaults.
    init(expanded: Bool) {
      UserDefaults.standard.set(expanded, forKey: AppStorageKey.signalMapperCardExpanded.rawValue)
    }

    var body: some View {
      VStack {
        Spacer()
        if let cell = SignalMapperPreviewFixtures.cell {
          SignalMapperCellCard(
            cell: cell,
            data: SignalMapperPreviewFixtures.cardData,
            layer: layer,
            isLiveCell: true,
            isRiding: true,
            scope: $scope,
            // What the coverage view would hand it on a phone-sized map: room for the whole
            // fixture list, which is what "expanded" has to be able to show.
            maxRowsHeight: 400,
            onFlipLayer: { layer = layer == .heard ? .reach : .heard },
            onRepeater: { _ in },
            onClose: {}
          )
          .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
          .padding()
        }
      }
      .background(Color(.systemBackground))
    }
  }
#endif
