import MC1Services
import SwiftUI

/// Range-tests one repeater.
///
/// The signal popover keeps a compact watched row as an entry point, but a range test is a
/// walking task: the phone is at arm's length or in a pocket, the user is watching a
/// boundary rather than a table, and the numbers that matter — how many times it has been
/// heard, how long since the last one, and both legs of the link — need to be readable at a
/// glance and audible when they are not. That does not fit in a popover, so it lives here.
///
/// The watch itself is engine state (`SignalBarsEngine.watchRepeater(_:)`), so it survives
/// this screen closing, the repeater dropping out of range, and a walk back into it.
struct RepeaterWatchView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss

  @AppStorage(RepeaterWatchPreferenceKey.soundEnabled) private var soundEnabled = false
  @AppStorage(RepeaterWatchPreferenceKey.toneID) private var toneID = RepeaterWatchTone.note.rawValue

  @State private var candidates: [RepeaterCandidate] = []
  @State private var showPicker = false
  @State private var isFlashing = false
  @State private var tonePlayer = RepeaterWatchTonePlayer()

  private var model: RepeaterSignalModel {
    appState.repeaterSignals
  }

  private var watched: WatchedRepeaterState? {
    model.watched
  }

  private var tone: RepeaterWatchTone {
    RepeaterWatchTone.named(toneID)
  }

  var body: some View {
    List {
      if let watched {
        liveSection(watched)
        alertSection
        controlsSection
      } else {
        emptySection
      }
    }
    .themedCanvas(theme)
    .navigationTitle(L10n.Localizable.SignalBars.Watch.title)
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showPicker) {
      NavigationStack {
        RepeaterPickerView(
          mode: .single,
          candidates: candidates,
          selection: Set([watchedCandidate?.publicKey].compactMap(\.self)),
          onToggle: { candidate in
            Task { await model.watchRepeater(candidate.hexID) }
          }
        )
        .navigationTitle(L10n.Localizable.SignalBars.Watch.choose)
      }
    }
    // Every sighting of the watched repeater bumps this counter; it is the one signal both
    // the flash and the tone key off, so the two can never disagree about what was heard.
    .onChange(of: watched?.heardCount) { previous, current in
      guard let current, let previous, current > previous else { return }
      flash()
      if soundEnabled { tonePlayer.play(tone) }
    }
    .task(id: appState.servicesVersion) { await reloadCandidates() }
  }

  private var watchedCandidate: RepeaterCandidate? {
    guard let watched else { return nil }
    return candidates.first { $0.hexID.identifiesSameNode(as: watched.id) }
  }

  private func reloadCandidates() async {
    candidates = await RepeaterCandidateSource.load(
      dataStore: appState.offlineDataStore,
      radioID: appState.connectedDevice?.radioID,
      signals: model,
      pathHashMode: appState.connectedDevice?.pathHashMode ?? 0
    )
  }

  private func flash() {
    isFlashing = true
    Task {
      try? await Task.sleep(for: .milliseconds(120))
      isFlashing = false
    }
  }

  // MARK: - Empty state

  private var emptySection: some View {
    Section {
      ContentUnavailableView {
        Label(L10n.Localizable.SignalBars.Watch.emptyTitle, systemImage: "binoculars")
      } description: {
        Text(L10n.Localizable.SignalBars.Watch.emptyDescription)
      } actions: {
        Button(L10n.Localizable.SignalBars.Watch.choose) { showPicker = true }
          .buttonStyle(.borderedProminent)
      }
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
    }
  }

  // MARK: - Live readout

  private func liveSection(_ watched: WatchedRepeaterState) -> some View {
    Section {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 8) {
          Image(systemName: "binoculars.fill")
            .foregroundStyle(theme.accentColor)
          Text(watchedName(watched))
            .font(.title3.weight(.semibold))
            .lineLimit(1)
          Spacer(minLength: 0)
        }

        // The count is the number a user walking a boundary actually reads: still climbing
        // means still in range, stalled means it is time to turn back.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(watched.heardCount, format: .number)
            .font(.system(size: 44, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
          Text(L10n.Localizable.SignalBars.Watch.heardCountLabel)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        HStack(spacing: 24) {
          legReadout(leg: .rx, title: L10n.Localizable.SignalBars.Column.rx, snr: watched.rxSnr)
          legReadout(leg: .tx, title: L10n.Localizable.SignalBars.Column.tx, snr: watched.txSnr)
          Spacer(minLength: 0)
        }

        if let lastHeardAt = watched.lastHeardAt {
          HStack(spacing: 4) {
            Text(L10n.Localizable.SignalBars.Watch.lastHeard)
              .foregroundStyle(.tertiary)
            RelativeTimestampText(date: lastHeardAt)
          }
          .font(.caption)
        } else {
          Text(L10n.Localizable.SignalBars.Watch.notYetHeard)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(theme.accentColor.opacity(isFlashing ? 0.18 : 0))
          .animation(.easeOut(duration: 0.6), value: isFlashing)
      )
      .accessibilityElement(children: .combine)
      .accessibilityLabel(L10n.Localizable.SignalBars.Watch.accessibilitySummary(
        watchedName(watched),
        watched.heardCount
      ))
    }
    .themedRowBackground(theme)
  }

  private func legReadout(leg: RepeaterSignalLeg, title: String, snr: Double?) -> some View {
    let quality = SNRQuality(snr: snr)
    return HStack(spacing: 6) {
      RepeaterSignalGlyph(leg: leg, quality: quality, size: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Text(snr.map { formattedDecibels($0) } ?? "—")
          .font(.callout.monospaced())
          .foregroundStyle(quality.color)
      }
    }
    .accessibilityElement(children: .combine)
  }

  /// Decibels go through a `FormatStyle` into a `%@` placeholder rather than a `%f` in the
  /// strings file, so the decimal separator follows the reader's locale.
  private func formattedDecibels(_ value: Double) -> String {
    L10n.Localizable.SignalBars.Watch.decibels(
      value.formatted(.number.precision(.fractionLength(1)))
    )
  }

  /// The watched repeater's resolved name when its row is still in the table, otherwise its
  /// hash — a watch survives the repeater dropping out of range, which is the whole point.
  private func watchedName(_ watched: WatchedRepeaterState) -> String {
    model.displayRepeaters
      .first { watched.id.identifiesSameNode(as: $0.id) }?
      .name ?? watched.id.hex
  }

  // MARK: - Alert

  private var alertSection: some View {
    Section {
      Toggle(isOn: $soundEnabled) {
        Label(L10n.Localizable.SignalBars.Watch.alertTone, systemImage: "speaker.wave.2.fill")
      }

      if soundEnabled {
        Picker(L10n.Localizable.SignalBars.Watch.tone, selection: $toneID) {
          ForEach(RepeaterWatchTone.allCases) { tone in
            Text(tone.localizedName).tag(tone.rawValue)
          }
        }
        .onChange(of: toneID) { _, newValue in
          tonePlayer.play(RepeaterWatchTone.named(newValue))
        }

        Button {
          tonePlayer.play(tone)
        } label: {
          Label(L10n.Localizable.SignalBars.Watch.preview, systemImage: "play.circle")
        }
      }
    } header: {
      Text(L10n.Localizable.SignalBars.Watch.alerts)
    } footer: {
      Text(L10n.Localizable.SignalBars.Watch.alertsFooter)
    }
    .themedRowBackground(theme)
  }

  // MARK: - Controls

  private var controlsSection: some View {
    Section {
      Button {
        showPicker = true
      } label: {
        Label(L10n.Localizable.SignalBars.Watch.change, systemImage: "arrow.triangle.2.circlepath")
      }

      Button(role: .destructive) {
        Task {
          await model.watchRepeater(nil)
          dismiss()
        }
      } label: {
        Label(L10n.Localizable.SignalBars.stopWatching, systemImage: "binoculars")
      }
    }
    .themedRowBackground(theme)
  }
}

#Preview {
  NavigationStack {
    RepeaterWatchView()
  }
  .environment(\.appState, AppState())
}
