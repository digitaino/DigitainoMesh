import Charts
import Foundation
import MapperRawLog
import MC1Services
import MeshCore
import SurveyKit
import SwiftUI

/// Every observation of one repeater in one hexagon (docs/SIGNAL_MAPPER_V3.md §8, mockup
/// screen 4): both legs charted over time, then the rows themselves.
///
/// The rows are the ones the card already fetched for this hexagon, filtered to the ones
/// that are *about* this repeater — §1's attribution, applied at capture, is what makes
/// that filter meaningful: a row names a repeater only when our radio really measured that
/// node. Nothing is re-queried, so opening a repeater costs a filter and a chart.
struct SignalMapperRepeaterDetailView: View {
  let item: SignalMapperRepeaterListRow
  /// The hexagon's rows, newest first, exactly as the card holds them.
  let rows: [MapperRawSampleDTO]
  /// The start of the window those rows were fetched over — the subtitle's "since".
  let since: Date

  @Environment(\.dismiss) private var dismiss

  /// How many rows the list draws. The chart reads all of them; the list is a readout, and
  /// a thousand identical flood receptions is a scroll bar, not information. The count line
  /// says how many there are in total, so nothing is hidden by the cap.
  private static let rowLimit = 200

  /// Every hash this repeater is credited under here: its own, plus the narrower path
  /// hashes `MapperCellQueries.canonicalHexIDs(in:now:)` folded into it. Filtering on
  /// `hexID` alone showed a fraction of the evidence the row above was built from —
  /// precisely the rows the 2026-09-05 merge exists to bring together.
  private var creditedHexIDs: Set<String> {
    Set([item.hexID] + item.row.aliasHexIDs)
  }

  private var repeaterRows: [MapperRawSampleDTO] {
    rows.filter { row in row.repeaterHexID.map(creditedHexIDs.contains) ?? false }
  }

  private var title: String {
    item.name ?? item.hexID
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          chart
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        } header: {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(nil)
        }

        // EXTENSION POINT (§7 step 6, Reach): scope's link view for this repeater —
        // "Scope · hears 33 neighbours, 12,169 direct sightings this week" and a row
        // opening `GET /api/nodes/{pubkey}/reach`. It needs the repeater's full public
        // key and a network call, neither of which this step makes.

        // Omitted entirely rather than shown empty: a repeater can now be listed on the card
        // on the strength of an echo whose first hop it was, and no row in this hexagon is
        // *about* it — an "Observations here" header over nothing would read as a bug
        // (2026-09-04). The chart above already says what is known.
        if !repeaterRows.isEmpty {
          Section {
            ForEach(Array(repeaterRows.prefix(Self.rowLimit).enumerated()), id: \.offset) { _, row in
              observationRow(row)
            }
            if repeaterRows.count > Self.rowLimit {
              Text(L10n.Tools.Tools.SignalMapper.Detail.allRows(repeaterRows.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } header: {
            Text(L10n.Tools.Tools.SignalMapper.Detail.observationsHere)
          }
        }
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  private var subtitle: String {
    L10n.Tools.Tools.SignalMapper.Detail.inThisHexagon(
      item.row.rxCount,
      Self.dayFormatter.string(from: Self.evidenceStart(
        in: repeaterRows,
        window: since,
        lastEvidenceAt: item.row.lastEvidenceAt
      ))
    )
  }

  /// The date the subtitle's "since" prints: the later of the fetch window's lower bound and
  /// the oldest evidence we actually hold, so the sentence stays true when the window reaches
  /// further back than the evidence does.
  ///
  /// The fallback is the row's own `lastEvidenceAt`, not `since`. Since 2026-09-04 a
  /// repeater can be listed on the strength of an echo whose *first hop* it was, with no row
  /// in this hexagon naming it — `repeaterRows` is then empty, and under All time `since` is
  /// `.distantPast`, which the day template renders as "1 Jan" (or "31 Dec" west of UTC) and
  /// reads as a date this year. `lastEvidenceAt` is non-optional and is precisely when the
  /// echo that put this repeater on the card landed. Under a ride scope every fetched row
  /// has `lastEvidenceAt >= session.startedAt`, so `max` keeps that case unchanged.
  static func evidenceStart(
    in rows: [MapperRawSampleDTO],
    window since: Date,
    lastEvidenceAt: Date
  ) -> Date {
    max(since, rows.map(\.timestamp).min() ?? lastEvidenceAt)
  }

  // MARK: - Chart

  /// Both legs on one time axis: the downlink as a line (we measure it continuously) and
  /// the uplink as points (a repeater only reports a number when it answers a probe, so
  /// joining them with a line would draw a link that was never sampled in between).
  @ViewBuilder
  private var chart: some View {
    let downlink = SignalMapperChartPoint.series(repeaterRows.sorted { $0.timestamp < $1.timestamp }) {
      $0.rxSnr
    }
    let uplink = SignalMapperChartPoint.series(repeaterRows.sorted { $0.timestamp < $1.timestamp }) {
      $0.txSnr
    }
    if downlink.isEmpty, uplink.isEmpty {
      Text(L10n.Tools.Tools.SignalMapper.Detail.noPacketsHeard)
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 12) {
          legendSwatch(color: .green, title: L10n.Tools.Tools.SignalMapper.Detail.youHearIt)
          legendSwatch(color: .orange, title: L10n.Tools.Tools.SignalMapper.Detail.itHearsYou)
        }
        Chart {
          ForEach(downlink) { point in
            LineMark(
              x: .value(L10n.Tools.Tools.SignalMapper.Detail.observationsHere, point.at),
              y: .value(L10n.Tools.Tools.SignalMapper.Detail.youHearIt, point.snr)
            )
            .foregroundStyle(Color.green)
            .interpolationMethod(.monotone)
          }
          ForEach(uplink) { point in
            PointMark(
              x: .value(L10n.Tools.Tools.SignalMapper.Detail.observationsHere, point.at),
              y: .value(L10n.Tools.Tools.SignalMapper.Detail.itHearsYou, point.snr)
            )
            .foregroundStyle(Color.orange)
            .symbolSize(40)
          }
        }
        .chartLegend(.hidden)
        .frame(height: 140)
      }
    }
  }

  private func legendSwatch(color: Color, title: String) -> some View {
    HStack(spacing: 5) {
      RoundedRectangle(cornerRadius: 2)
        .fill(color)
        .frame(width: 10, height: 10)
      Text(title)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: - Rows

  private func observationRow(_ row: MapperRawSampleDTO) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(Self.describe(row))
        .font(.caption)
        .foregroundStyle(.primary)
      Spacer(minLength: 8)
      Text(Self.measurements(row))
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
    }
    .accessibilityElement(children: .combine)
  }

  /// "09:24:41 · flood · 2 hops" — the time, what the packet was, and how far it had come.
  static func describe(_ row: MapperRawSampleDTO) -> String {
    var parts = [timeFormatter.string(from: row.timestamp), kindPhrase(row)]
    if let hops = row.hopCount {
      parts.append(L10n.Tools.Tools.SignalMapper.Detail.hops(hops))
    }
    return parts.joined(separator: " · ")
  }

  /// What the row *is*, in the vocabulary §1 uses. Passive receptions are named by the
  /// packet rather than by the kind, because "flood" and "advert" are the distinctions that
  /// decide what the reading means — an advert with no path is the sender itself, a flood's
  /// last hop is the relay we heard.
  static func kindPhrase(_ row: MapperRawSampleDTO) -> String {
    switch row.kind {
    case .passiveRx:
      let payload = row.payloadTypeRaw.flatMap(UInt8.init(exactly:)).flatMap(PayloadType.init(rawValue:))
      if payload == .advert {
        return L10n.Tools.Tools.SignalMapper.Detail.Kind.advert
      }
      guard let route = row.routeTypeRaw.flatMap(UInt8.init(exactly:)).flatMap(RouteType.init(rawValue:))
      else {
        return L10n.Tools.Tools.SignalMapper.Detail.Kind.heard
      }
      return route.isFlood
        ? L10n.Tools.Tools.SignalMapper.Detail.Kind.flood
        : L10n.Tools.Tools.SignalMapper.Detail.Kind.direct
    case .txHeard:
      return L10n.Tools.Tools.SignalMapper.Detail.Kind.echo
    case .probeTraceReply:
      return L10n.Tools.Tools.SignalMapper.Detail.Kind.traceReply
    case .probeDiscoverResponse:
      return L10n.Tools.Tools.SignalMapper.Detail.Kind.discoverReply
    case .probeAttempt:
      return L10n.Tools.Tools.SignalMapper.Detail.Kind.probeSent
    case .probeLost, .probeAbandoned:
      return L10n.Tools.Tools.SignalMapper.Detail.Kind.probeLost
    case .sent:
      return L10n.Tools.Tools.SignalMapper.Detail.Kind.sent
    case .ackResolved:
      return L10n.Tools.Tools.SignalMapper.Detail.Kind.delivered
    case .observerSighting:
      return L10n.Tools.Tools.SignalMapper.Detail.Kind.observer
    default:
      return L10n.Tools.Tools.SignalMapper.Detail.Kind.heard
    }
  }

  /// "↓ 12.5 dB · −72 dBm", "↑ 13 dB · ↓ 12.0". The uplink leads when the row carries one,
  /// because a row that says how well they heard *us* is the rarer fact.
  static func measurements(_ row: MapperRawSampleDTO) -> String {
    var parts: [String] = []
    if let txSnr = row.txSnr {
      parts.append("↑ " + SignalMapperCellCard.decibels(txSnr, places: 1) + " dB")
    }
    if let rxSnr = row.rxSnr {
      let value = SignalMapperCellCard.decibels(rxSnr, places: 1)
      parts.append(parts.isEmpty ? "↓ \(value) dB" : "↓ \(value)")
    }
    if let rssi = row.rssi {
      parts.append("\(rssi) dBm")
    }
    return parts.isEmpty ? "—" : parts.joined(separator: " · ")
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("d MMM")
    return formatter
  }()
}

/// What a tap on a card row opens: the repeater, and the hexagon's rows *as they were when
/// it was tapped*.
///
/// Frozen deliberately. The card refreshes every 20 s and follows the rider across hexagon
/// boundaries; a sheet that re-read the card's current rows would keep its title and quietly
/// swap in a different hexagon's observations underneath it.
struct SignalMapperRepeaterDetailRequest: Identifiable, Equatable {
  let item: SignalMapperRepeaterListRow
  let rows: [MapperRawSampleDTO]
  let since: Date

  var id: String {
    item.hexID
  }
}

/// One point on the repeater chart.
///
/// Identity is the row's position in the series rather than its timestamp: two receptions
/// can share a second, and a `ForEach` whose ids collide drops marks silently.
struct SignalMapperChartPoint: Identifiable, Hashable {
  let id: Int
  let at: Date
  let snr: Double

  /// Keeps only the rows that carry the leg being charted, numbering what survives.
  static func series(
    _ rows: [MapperRawSampleDTO],
    value: (MapperRawSampleDTO) -> Double?
  ) -> [SignalMapperChartPoint] {
    rows.compactMap { row in value(row).map { (row.timestamp, $0) } }
      .enumerated()
      .map { SignalMapperChartPoint(id: $0.offset, at: $0.element.0, snr: $0.element.1) }
  }
}

// MARK: - Preview

#if DEBUG
  #Preview("Repeater detail") {
    if let data = SignalMapperPreviewFixtures.cardData, let item = data.repeaters.first {
      SignalMapperRepeaterDetailView(item: item, rows: data.rows, since: data.since)
    }
  }
#endif
