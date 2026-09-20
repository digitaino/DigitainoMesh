import MC1Services
import MeshCore
import MeshWX
import SwiftUI

/// Everything that went past on `#meshwx`, as a chat (docs/MESHWX_UI.md §12, §3.1 U-40).
///
/// The owner's sixth ask, 20 September: *a way to see all the GRP_DATA traffic on a channel like
/// we do a chat.* So it reads like one: oldest at the top, what the radios sent on the left under
/// their names, what this phone sent on the right, and it opens at the newest and follows new
/// arrivals unless somebody has scrolled up to read.
///
/// **It is the wire, not the model.** Every datagram that reached the weather slot is here —
/// decodable or not, duplicate or not, live or drained from the radio's queue — which is the whole
/// reason the screen exists: everywhere else in the app, "nothing arrived" and "eight packets
/// arrived and every one of them was a copy" look exactly the same.
///
/// Nothing here spends airtime. There is no ask on this screen at all.
struct WeatherTrafficView: View {
  @Environment(\.appTheme) private var theme

  /// The page this was opened from, for the radios it names (docs/MESHWX_UI.md §13).
  let screen: WeatherPageScreen

  @State private var isConfirmingClear = false
  /// The bottom of the list is on screen, so new arrivals should scroll to. Cleared the moment
  /// somebody scrolls up: a timeline that yanked itself downwards while being read would be
  /// unreadable on a busy channel.
  @State private var follows = true

  private var model: WeatherToolModel { screen.model }
  private static let bottomID = "weather.traffic.bottom"

  var body: some View {
    let entries = model.traffic
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          Text(L10n.Weather.Weather.Traffic.subtitle)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
          if entries.isEmpty {
            Text(L10n.Weather.Weather.Traffic.empty)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            bubble(entry, previous: index > 0 ? entries[index - 1] : nil)
          }
          // The follow sentinel. It is on screen exactly while the newest bubble is, so its
          // appearance and disappearance are "is the reader at the bottom" without a scroll
          // offset to read or a geometry reader to keep in sync.
          Color.clear
            .frame(height: 1)
            .id(Self.bottomID)
            .onAppear { follows = true }
            .onDisappear { follows = false }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      }
      .themedCanvas(theme)
      .task {
        model.isShowingTraffic = true
        await model.refreshTraffic()
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
      }
      .onChange(of: entries.last?.id) {
        guard follows else { return }
        withAnimation(.default) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
      }
    }
    .onDisappear { model.isShowingTraffic = false }
    .navigationTitle(L10n.Weather.Weather.Traffic.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(L10n.Weather.Weather.Traffic.clear, role: .destructive) {
          isConfirmingClear = true
        }
        .disabled(entries.isEmpty)
        .accessibilityIdentifier("weather.traffic.clear")
      }
    }
    .alert(L10n.Weather.Weather.Traffic.clearTitle, isPresented: $isConfirmingClear) {
      Button(L10n.Weather.Weather.Traffic.clear, role: .destructive) {
        Task { await model.clearTraffic() }
      }
      Button(L10n.Weather.Weather.Common.cancel, role: .cancel) {}
    } message: {
      Text(L10n.Weather.Weather.Traffic.clearMessage(entries.count))
    }
    .weatherToolChrome()
  }

  /// One bubble, with its sender's name over it only when the sender changed: a run of eight
  /// sweep packets from one radio is one name and eight bubbles, the way a chat reads.
  @ViewBuilder
  private func bubble(_ entry: WeatherTrafficEntry, previous: WeatherTrafficEntry?) -> some View {
    let isSent = entry.direction == .sent
    let name = senderName(entry)
    let showsName = previous.map { senderName($0) != name || $0.direction != entry.direction } ?? true
    VStack(alignment: isSent ? .trailing : .leading, spacing: 2) {
      if showsName {
        Text(name)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
      }
      NavigationLink {
        WeatherTrafficDetailView(screen: screen, entry: entry)
      } label: {
        VStack(alignment: .leading, spacing: 3) {
          Text(WeatherTrafficCopy.line(entry, tables: .shared))
            .font(.subheadline)
            .foregroundStyle(.primary)
          Text(WeatherTrafficCopy.facts(
            entry, now: screen.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 320, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 14)
            .fill(isSent ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.14)))
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("weather.traffic.row")
    }
    .frame(maxWidth: .infinity, alignment: isSent ? .trailing : .leading)
    .accessibilityElement(children: .combine)
  }

  /// The radio a datagram came from, this phone for one it sent, and neither when the header
  /// could not be read far enough to say.
  private func senderName(_ entry: WeatherTrafficEntry) -> String {
    guard entry.direction == .received else { return L10n.Weather.Weather.Traffic.you }
    guard let botID = entry.botID else { return L10n.Weather.Weather.Traffic.unknownSender }
    return model.botName(botID)
  }
}

// MARK: - One datagram

/// What one datagram carried: its own facts, the decoded message read back out of its bytes, and
/// the bytes themselves.
///
/// The hex is the row and everything above it is a reading of the row — so the summary is decoded
/// here from the stored payload rather than taken from the entry's header fields, and a datagram
/// this build cannot read says exactly that and claims nothing else.
struct WeatherTrafficDetailView: View {
  @Environment(\.appTheme) private var theme

  let screen: WeatherPageScreen
  let entry: WeatherTrafficEntry

  private var model: WeatherToolModel { screen.model }

  var body: some View {
    let summary = WeatherTrafficSummary.make(entry: entry, tables: .shared)
    List {
      Section {
        WeatherCardLabel(title: L10n.Weather.Weather.Traffic.about, systemImage: "dot.radiowaves.up.forward")
        row(L10n.Weather.Weather.Traffic.Field.when, WeatherFormatting.clockTime(
          entry.at, now: screen.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent))
        row(L10n.Weather.Weather.Traffic.Field.from, sender)
        row(L10n.Weather.Weather.Traffic.Field.size, L10n.Weather.Weather.Traffic.bytes(entry.length))
        if let seq = entry.seq {
          row(L10n.Weather.Weather.Traffic.Field.seq, String(seq))
        }
        if let snr = entry.snr {
          row(L10n.Weather.Weather.Traffic.Field.signal, L10n.Weather.Weather.Traffic.snr(
            WeatherTrafficCopy.decibels(snr)))
        }
        if let hops = WeatherTrafficCopy.hops(entry.pathLength) {
          row(L10n.Weather.Weather.Traffic.Field.hops, hops)
        }
        row(L10n.Weather.Weather.Traffic.Field.slot, String(entry.channelIndex))
        if let type = entry.type {
          row(L10n.Weather.Weather.Traffic.Field.type, String(type))
        }
        row(L10n.Weather.Weather.Traffic.Field.dataType, String(entry.dataType))
        if entry.isBacklog {
          Text(L10n.Weather.Weather.Traffic.backlog)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if entry.isDuplicate {
          Text(L10n.Weather.Weather.Traffic.duplicate)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .themedRowBackground(theme)

      Section {
        WeatherCardLabel(title: L10n.Weather.Weather.Traffic.fields, systemImage: "text.alignleft")
        if case .undecodable = summary.title {
          Text(L10n.Weather.Weather.Traffic.notDecoded)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else {
          Text(WeatherTrafficCopy.title(
            summary.title, isSent: entry.direction == .sent, tables: .shared))
            .font(.subheadline)
          ForEach(Array(WeatherTrafficCopy.details(summary, tables: .shared).enumerated()), id: \.offset) { _, value in
            Text(value)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
      }
      .themedRowBackground(theme)

      Section {
        WeatherCardLabel(title: L10n.Weather.Weather.Traffic.hex, systemImage: "number")
        // Byte pairs with spaces between them: the same bytes, wrappable at every one of them,
        // and still one selection when somebody copies it out to compare against the spec.
        Text(WeatherTrafficCopy.hexBlock(entry.hex))
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("weather.traffic.hex")
      }
      .themedRowBackground(theme)
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
    .navigationTitle(WeatherTrafficCopy.title(
      summary.title, isSent: entry.direction == .sent, tables: .shared))
    .navigationBarTitleDisplayMode(.inline)
    .weatherToolChrome()
  }

  private var sender: String {
    guard entry.direction == .received else { return L10n.Weather.Weather.Traffic.sent }
    guard let botID = entry.botID else { return L10n.Weather.Weather.Traffic.unknownSender }
    return model.botName(botID)
  }

  private func row(_ label: String, _ value: String) -> some View {
    LabeledContent(label) {
      Text(value)
        .monospacedDigit()
    }
  }
}

// MARK: - Copy

/// The words a channel traffic row is made of, as pure functions of the entry and its summary
/// (docs/MESHWX_UI.md §12).
///
/// `WeatherTrafficSummary` is values and no strings, for the same reason the rest of the screen
/// rules are: this is where they become a sentence, once, for both the bubble and its detail.
enum WeatherTrafficCopy {
  /// "Alert map · part 3 of 7 · 38 areas · the whole country".
  static func line(_ entry: WeatherTrafficEntry, tables: MeshWXTables) -> String {
    let summary = WeatherTrafficSummary.make(entry: entry, tables: tables)
    let head = title(summary.title, isSent: entry.direction == .sent, tables: tables)
    return ([head] + details(summary, tables: tables)).joined(separator: " · ")
  }

  /// What the datagram *is*. A request this phone sent is named for what it is rather than for
  /// who sent it: "Request from 0A1B2C" pointing at the reader is not a fact worth a row.
  static func title(_ title: WeatherTrafficTitle, isSent: Bool, tables: MeshWXTables) -> String {
    switch title {
    case .warning: return L10n.Weather.Weather.Traffic.Title.warning
    case .cancel: return L10n.Weather.Weather.Traffic.Title.cancel
    case .alertList: return L10n.Weather.Weather.Traffic.Title.digest
    case .observations: return L10n.Weather.Weather.Traffic.Title.observations
    case .forecast: return L10n.Weather.Weather.Traffic.Title.forecast
    case .text: return L10n.Weather.Weather.Traffic.Title.text
    case .notAvailable: return L10n.Weather.Weather.Traffic.Title.notAvailable
    case .coverage: return L10n.Weather.Weather.Traffic.Title.coverage
    case let .request(sender):
      return isSent
        ? L10n.Weather.Weather.Traffic.Title.requestSent
        : L10n.Weather.Weather.Traffic.Title.request(senderPrefix(sender))
    case .alertMap: return L10n.Weather.Weather.Traffic.Title.areaSweep
    case .undecodable: return L10n.Weather.Weather.Traffic.Title.unreadable
    case .unknownType: return L10n.Weather.Weather.Traffic.Title.otherData
    }
  }

  /// Everything after the title, in reading order.
  ///
  /// The event an alert names comes first and is not in the summary's own detail list: the
  /// identity is on the title case, and "Alert" with nothing after it is a row that says less
  /// than the bytes do.
  static func details(_ summary: WeatherTrafficSummary, tables: MeshWXTables) -> [String] {
    var parts: [String] = []
    switch summary.title {
    case let .warning(identity), let .cancel(identity):
      parts.append(WeatherFormatting.eventName(identity.event, tables: tables))
    case let .notAvailable(letter):
      // The request letter the refusal echoes back (spec §8.3), which is what says *which* of
      // this phone's asks it answers.
      parts.append(String(letter))
    default:
      break
    }
    parts.append(contentsOf: summary.detail.compactMap { detail($0, tables: tables) })
    return parts
  }

  static func detail(_ detail: WeatherTrafficDetail, tables: MeshWXTables) -> String? {
    switch detail {
    case let .stations(count):
      return count == 1
        ? L10n.Weather.Weather.Traffic.Detail.stationsOne
        : L10n.Weather.Weather.Traffic.Detail.stations(count)
    case let .entries(count):
      return count == 1
        ? L10n.Weather.Weather.Traffic.Detail.alertsOne
        : L10n.Weather.Weather.Traffic.Detail.alerts(count)
    case let .areas(count):
      return count == 1
        ? L10n.Weather.Weather.Traffic.Detail.areasOne
        : L10n.Weather.Weather.Traffic.Detail.areas(count)
    case let .offices(count):
      return count == 1
        ? L10n.Weather.Weather.Traffic.Detail.officesOne
        : L10n.Weather.Weather.Traffic.Detail.offices(count)
    case let .part(index, total), let .chunk(index, total):
      // Zero-based on the wire (spec §7C, §8.1) and one-based for a reader: "part 1 of 7" is the
      // first packet, and nobody counting packets on a screen starts at nought.
      return L10n.Weather.Weather.Traffic.Detail.part(Int(index) + 1, Int(total))
    case let .point(index):
      return WeatherCopy.pointName(index, tables: tables) ?? String(index)
    case .botPoint:
      return L10n.Weather.Weather.Traffic.Detail.botPoint
    case let .station(index):
      return tables.station(at: index).map { WeatherNames.stationName($0.name) } ?? String(index)
    case let .requestText(text):
      return text
    case let .reason(reason):
      return self.reason(reason)
    case let .cancelReason(reason):
      return cancelReason(reason)
    case let .scoped(states):
      // A scoped packet that is not the one the scope rides on cannot say what it covers, and
      // "no states" would read as "nothing" rather than as "not in these bytes".
      return states.isEmpty
        ? L10n.Weather.Weather.Traffic.Detail.scopedUnknown
        : WeatherAreaMapCopy.stateList(states)
    case .national:
      return L10n.Weather.Weather.Traffic.Detail.national
    case .cut:
      return L10n.Weather.Weather.Traffic.Detail.cut
    case .includesAdvisories:
      return L10n.Weather.Weather.Traffic.Detail.advisories
    }
  }

  static func reason(_ reason: MeshWXNotAvailableReason) -> String {
    switch reason {
    case .noData: L10n.Weather.Weather.Traffic.Reason.noData
    case .unknownLocation: L10n.Weather.Weather.Traffic.Reason.unknownLocation
    case .unsupported: L10n.Weather.Weather.Traffic.Reason.unsupported
    case .botError: L10n.Weather.Weather.Traffic.Reason.botError
    case .rateLimited: L10n.Weather.Weather.Traffic.Reason.rateLimited
    case .other: L10n.Weather.Weather.Traffic.Reason.other
    }
  }

  /// Nil for a reason nibble this build does not know: the bubble then says an alert ended and
  /// leaves the reason to the bytes, rather than translating a number into a claim.
  static func cancelReason(_ reason: MeshWXCancelReason) -> String? {
    switch reason {
    case .cancelled: L10n.Weather.Weather.Traffic.CancelReason.cancelled
    case .expiredEarly: L10n.Weather.Weather.Traffic.CancelReason.expiredEarly
    case .upgraded: L10n.Weather.Weather.Traffic.CancelReason.upgraded
    case .other: nil
    }
  }

  /// "159 B · seq 212 · SNR 12 dB · 2 hops · 1:35 PM" — what is known, and nothing that is not.
  /// A datagram this phone sent has no signal and no path, so its line is shorter, which is the
  /// honest shape rather than a row of dashes.
  static func facts(
    _ entry: WeatherTrafficEntry, now: Date, calendar: Calendar, locale: Locale
  ) -> String {
    var parts = [L10n.Weather.Weather.Traffic.bytes(entry.length)]
    if let seq = entry.seq { parts.append(L10n.Weather.Weather.Traffic.seq(Int(seq))) }
    if let snr = entry.snr { parts.append(L10n.Weather.Weather.Traffic.snr(decibels(snr))) }
    if let hops = hops(entry.pathLength) { parts.append(hops) }
    parts.append(WeatherFormatting.clockTime(entry.at, now: now, calendar: calendar, locale: locale))
    if entry.isBacklog { parts.append(L10n.Weather.Weather.Traffic.backlog) }
    if entry.isDuplicate { parts.append(L10n.Weather.Weather.Traffic.duplicate) }
    return parts.joined(separator: " · ")
  }

  /// "2 hops" from the encoded path-length byte, "flooded" for the no-path marker, and nothing at
  /// all for a packet that reached this phone without passing a repeater — an absent line reads
  /// as "straight from the radio", which is what it is.
  static func hops(_ pathLength: UInt8?) -> String? {
    guard let pathLength else { return nil }
    guard pathLength != PacketBuilder.floodPathSentinel else {
      return L10n.Weather.Weather.Traffic.flood
    }
    let count = decodePathLen(pathLength)?.hopCount ?? Int(pathLength & 63)
    switch count {
    case 0: return nil
    case 1: return L10n.Weather.Weather.Traffic.hopsOne
    case let count: return L10n.Weather.Weather.Traffic.hops(count)
    }
  }

  /// "12", "6.5": whole decibels without a trailing nought, a half when the radio reported one.
  static func decibels(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
    value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
  }

  /// The first three bytes of somebody's public key, upper case — as much as anyone on the
  /// channel knows about who asked (spec §7B).
  static func senderPrefix(_ data: Data, bytes: Int = 3) -> String {
    data.prefix(bytes).map { String(format: "%02X", $0) }.joined()
  }

  /// The payload as byte pairs: the same hex, with somewhere for every line to break.
  static func hexBlock(_ hex: String) -> String {
    stride(from: 0, to: hex.count, by: 2).map { offset in
      let start = hex.index(hex.startIndex, offsetBy: offset)
      let end = hex.index(start, offsetBy: min(2, hex.count - offset))
      return String(hex[start..<end])
    }.joined(separator: " ")
  }
}
