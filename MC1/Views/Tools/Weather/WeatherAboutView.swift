import MC1Services
import MeshWX
import SwiftUI

/// About weather on the mesh (docs/MESHWX_UI.md §12): how it works, which weather radio answers,
/// whether `#meshwx` is delivering, and clearing what was received.
///
/// The radio picker is inline rows with checkmarks, not a menu: picking reshapes the screen behind.
struct WeatherAboutView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appTheme) private var theme

  let model: WeatherToolModel

  @State private var isConfirmingClear = false
  /// The bot the confirmation names, fixed when it is presented: the source can change while the
  /// alert is up, and the clear must remove what the alert said it would.
  @State private var clearBotID: UInt16?
  @State private var clearsAfterAlert = false

  var body: some View {
    NavigationStack {
      List {
        Section {
          VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Weather.Weather.About.line1)
            Text(L10n.Weather.Weather.About.line2)
            if let coverage = coverageLine {
              Text(coverage)
            }
            Text(L10n.Weather.Weather.About.line3)
            Text(L10n.Weather.Weather.About.line4)
          }
          .font(.subheadline)
          .padding(.vertical, 4)
        }
        .themedRowBackground(theme)

        radiosSection
        channelSection

        Section {
          Button(L10n.Weather.Weather.About.clear, role: .destructive) {
            clearBotID = model.snapshot?.source?.botID
            isConfirmingClear = clearBotID != nil
          }
          .disabled(model.snapshot?.source == nil)
        } footer: {
          Text(L10n.Weather.Weather.About.clearFooter(model.sourceName))
        }
        .themedRowBackground(theme)
      }
      .listStyle(.insetGrouped)
      .themedCanvas(theme)
      .navigationTitle(L10n.Weather.Weather.About.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Weather.Weather.Common.done) { dismiss() }
        }
      }
      .alert(L10n.Weather.Weather.About.Alert.title(clearName), isPresented: $isConfirmingClear) {
        Button(L10n.Weather.Weather.About.Alert.clear, role: .destructive) {
          clearsAfterAlert = true
        }
        Button(L10n.Weather.Weather.Common.cancel, role: .cancel) {}
      } message: {
        Text(L10n.Weather.Weather.About.Alert.message(clearName))
      }
      .onChange(of: isConfirmingClear) { _, isShowing in
        guard !isShowing else { return }
        let botID = clearBotID
        clearBotID = nil
        guard clearsAfterAlert, let botID else { return }
        clearsAfterAlert = false
        Task { await model.clearReceivedWeather(botID: botID) }
      }
    }
  }

  private var clearName: String {
    clearBotID.map(model.botName) ?? model.sourceName
  }

  /// "WX-AUS reports on 14 weather stations; alerts are for the area around them."
  private var coverageLine: String? {
    guard let snapshot = model.snapshot, !snapshot.coverage.isEmpty else { return nil }
    return L10n.Weather.Weather.About.coverage(
      WeatherFormatting.sentenceStart(model.sourceName), snapshot.coverage.stations.count)
  }

  // MARK: - Radios

  private var radiosSection: some View {
    Section {
      // With one radio there is nothing to choose.
      if model.context.botRows.count >= 2 {
        Button {
          model.selectBot(nil)
        } label: {
          checkRow(
            title: L10n.Weather.Weather.About.automatic,
            detail: model.snapshot?.source.map { L10n.Weather.Weather.About.automaticDetail(model.botName($0.botID)) },
            isSelected: model.preferredBotID == nil)
        }
        .buttonStyle(.plain)
      }
      ForEach(model.context.botRows) { row in
        Button {
          model.selectBot(row.botID)
        } label: {
          checkRow(
            title: model.botName(row.botID), detail: detail(row),
            isSelected: model.context.botRows.count >= 2 && model.preferredBotID == row.botID)
        }
        .buttonStyle(.plain)
        .disabled(model.context.botRows.count < 2)
      }
    } header: {
      Text(L10n.Weather.Weather.About.radios)
    } footer: {
      Text(L10n.Weather.Weather.About.radiosFooter)
    }
    .themedRowBackground(theme)
  }

  private func detail(_ row: WeatherBotRow) -> String {
    var parts: [String] = []
    // "heard" only for live traffic; a radio known only from a drained backlog says nothing.
    if let heard = row.lastLiveHeardAt {
      parts.append(L10n.Weather.Weather.About.heard(WeatherFormatting.ago(heard, now: model.now)))
    } else if row.lastHeardAt == nil {
      parts.append(L10n.Weather.Weather.About.notHeard)
    }
    if let minutes = row.feedMinutes {
      parts.append(row.isFeedStale
        ? L10n.Weather.Weather.About.feedStale(WeatherFormatting.quietDuration(minutes: minutes))
        : L10n.Weather.Weather.About.feedOK)
    }
    if row.bot == nil {
      parts.append(L10n.Weather.Weather.About.noAdvert)
    }
    if model.snapshot?.source?.botID == row.botID {
      parts.append(L10n.Weather.Weather.About.inUse)
    }
    return parts.joined(separator: " · ")
  }

  private func checkRow(title: String, detail: String?, isSelected: Bool) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .foregroundStyle(.primary)
        if let detail {
          Text(detail)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 8)
      if isSelected {
        Image(systemName: "checkmark")
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
      }
    }
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  // MARK: - Channel

  private var channelSection: some View {
    Section {
      LabeledContent(L10n.Weather.Weather.About.channelSlot) {
        // Without a radio, or before its channel sync, the table can be empty: that is not
        // "not on your radio".
        Text(model.context.channelSlot.map { L10n.Weather.Weather.About.slot(Int($0)) }
          ?? (model.isRadioConnected && model.isChannelSyncDone
            ? L10n.Weather.Weather.About.noSlot
            : L10n.Weather.Weather.About.radioOffline))
      }
      LabeledContent(L10n.Weather.Weather.About.lastMessage) {
        Text(lastMessage)
      }
    } header: {
      Text(verbatim: WeatherChannel.name)
    }
    .themedRowBackground(theme)
  }

  /// This session's last datagram; without one, the last time any weather radio was heard live.
  private var lastMessage: String {
    let last = model.context.session.lastChannelDatagramAt
      ?? model.liveHeardAt
    guard let last else { return L10n.Weather.Weather.About.noMessage }
    return WeatherFormatting.clockTime(last, now: model.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
  }
}
