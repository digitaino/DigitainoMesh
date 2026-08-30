import MC1Services
import SwiftUI

/// Every repeater this radio can reach, with both legs of each link.
///
/// The header says where the numbers come from, because it changes what the controls mean: on
/// custom firmware the radio owns the table and the app only asks it to measure, so the app
/// transmits nothing of its own; on stock firmware the app is the engine and every probe here
/// is a packet it sends.
struct RepeaterSignalPopover: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme

  /// Presents the full range-testing screen. The compact row below is only an entry point —
  /// heard counts, alert tones and target switching live on `RepeaterWatchView`.
  /// Owned by `RadioStatusControl` so its link-loss dismissal can see an active watch
  /// sheet and leave the popover alone rather than yank a presenter mid-presentation.
  @Binding var showWatchScreen: Bool

  private var model: RepeaterSignalModel {
    appState.repeaterSignals
  }

  /// Value-typed sample of the reference the refresh would push, so `task(id:)` compares
  /// coordinates rather than `CLLocation` object identity. Carries the phone fix's
  /// timestamp too: a fresh fix at an unchanged spot must still re-run the refresh, or a
  /// fix aging past the staleness window would never be replaced while the table is open.
  private struct LocationSample: Equatable {
    let latitude: Double
    let longitude: Double
    let fixTimestamp: Date?
  }

  private var referenceLocationSample: LocationSample? {
    // Mirrors `AppState.bestAvailableLocation`'s priority: phone fix, else radio.
    if let fix = appState.locationService.currentLocation {
      return LocationSample(
        latitude: fix.coordinate.latitude,
        longitude: fix.coordinate.longitude,
        fixTimestamp: fix.timestamp
      )
    }
    guard let device = appState.connectedDevice, device.hasLocation else { return nil }
    return LocationSample(latitude: device.latitude, longitude: device.longitude, fixTimestamp: nil)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      sourceRow

      Divider().padding(.horizontal, 8)
      table

      if model.watched != nil {
        Divider().padding(.horizontal, 8)
        watchedRow
      }

      if let power = appState.services?.adaptivePowerService, power.isEnabled {
        Divider().padding(.horizontal, 8)
        RepeaterTxPowerControl(service: power)
      }

      if appState.connectedDevice?.supportsPathHashMode == true {
        Divider().padding(.horizontal, 8)
        RepeaterPathHashPicker()
      }
    }
    .frame(width: 288)
    .padding(.bottom, 8)
    .sheet(isPresented: $showWatchScreen) {
      NavigationStack {
        RepeaterWatchView()
      }
    }
    // The Motion & Fitness prompt this table used to fire at open now lives in
    // `RadioStatusControl`, deferred until after the popover has fully dismissed — a
    // system alert must never land while a popover transition is in flight (suspected
    // aggravator in TestFlight crash B8A782EC).
    // Proximity disambiguation wants the freshest fix while the table is visible: push at
    // open, and again when a new fix lands. Keyed on a value sample, not the CLLocation —
    // `bestAvailableLocation`'s radio-fallback branch allocates a fresh object on every
    // read, and object-identity comparison would restart the task (and its one-shot
    // request) on every render. Only ever a one-shot under existing permission — never a
    // prompt.
    .task(id: referenceLocationSample) {
      await appState.refreshSignalBarsReferenceLocation(requestingFixIfMissing: true)
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 12) {
      Text(L10n.Localizable.SignalBars.title)
        .font(.subheadline.weight(.semibold))

      Spacer(minLength: 0)

      // Hides every stale row in one action. Local only: on custom firmware the radio's own
      // table and OLED are untouched, so an entry reappears the moment it is heard again.
      if model.hasStaleRepeaters {
        Button {
          Task { await model.clearStaleRepeaters() }
        } label: {
          Image(systemName: "eraser.line.dashed")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Localizable.SignalBars.clearStale)
      }

      Button {
        Task { await model.startProbe() }
      } label: {
        // Fixed footprint: the spinner and the glyph differ in intrinsic size, and the
        // swap must not reshape a presented popover's header mid-render.
        Group {
          if model.isRefreshing {
            ProgressView().controlSize(.mini)
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .frame(width: 20, height: 20)
      }
      .buttonStyle(.plain)
      .disabled(model.isRefreshing)
      .accessibilityLabel(L10n.Localizable.SignalBars.scan)
    }
    .font(.subheadline)
    .padding(.horizontal, 12)
    .padding(.top, 12)
    .padding(.bottom, 6)
  }

  /// Whether these bars are mirrored from the radio or measured by the app.
  private var sourceRow: some View {
    let isViewer = model.mode == .viewer
    return HStack(spacing: 4) {
      Image(systemName: isViewer
        ? "antenna.radiowaves.left.and.right"
        : "iphone.radiowaves.left.and.right")
        .font(.system(size: 9))
      Text(isViewer
        ? L10n.Localizable.SignalBars.sourceRadio
        : L10n.Localizable.SignalBars.sourceApp)
        .font(.caption2)
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
    .accessibilityElement(children: .combine)
  }

  // MARK: - Table

  @ViewBuilder
  private var table: some View {
    let repeaters = model.displayRepeaters
    if repeaters.isEmpty {
      // While a signal-mapper run owns the airtime, the engine is deliberately stopped —
      // saying "scanning" here would be a lie and the refresh button below is inert.
      // Purely informative on purpose: an action that tears the popover host down from
      // inside it is the iOS 26 zoom-morph crash family.
      Text(
        appState.signalMapperRideSession != nil
          ? L10n.Localizable.SignalBars.pausedForSurvey
          : L10n.Localizable.SignalBars.scanning
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      columnHeaders
      ScrollView {
        // One clock for every row's Age column, ticking while the popover is open.
        // Coarse on purpose: single-unit ages (see `RepeaterAgeFormat`) change rarely.
        TimelineView(.periodic(from: .now, by: 10)) { context in
          LazyVStack(spacing: 0) {
            ForEach(repeaters) { repeater in
              RepeaterSignalRow(
                repeater: repeater,
                isWatched: model.isWatched(repeater),
                now: context.date
              )
              .contextMenu { rowActions(for: repeater) }
              if repeater.id != repeaters.last?.id {
                Divider().padding(.horizontal, 8)
              }
            }
          }
        }
      }
      .frame(maxHeight: 264)
    }
  }

  /// Mirrors `RepeaterSignalRow`'s frames exactly — same flexible identity column, same fixed
  /// leg and age widths — so the headers sit over their columns at every popover width.
  private var columnHeaders: some View {
    HStack(spacing: 4) {
      Text(L10n.Localizable.SignalBars.Column.id)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(L10n.Localizable.SignalBars.Column.rx)
        .frame(width: RepeaterSignalRow.Column.leg)
      Text(L10n.Localizable.SignalBars.Column.tx)
        .frame(width: RepeaterSignalRow.Column.leg)
      Text(L10n.Localizable.SignalBars.Column.age)
        .frame(width: RepeaterSignalRow.Column.age, alignment: .trailing)
    }
    .font(.caption2.weight(.medium))
    .foregroundStyle(.tertiary)
    .padding(.horizontal, 12)
    .padding(.bottom, 4)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private func rowActions(for repeater: RepeaterSignal) -> some View {
    Button {
      Task { await model.requestRefresh(target: repeater.id) }
    } label: {
      Label(L10n.Localizable.SignalBars.pingNow, systemImage: "dot.radiowaves.left.and.right")
    }

    if model.isWatched(repeater) {
      Button(role: .destructive) {
        Task { await model.watchRepeater(nil) }
      } label: {
        Label(L10n.Localizable.SignalBars.stopWatching, systemImage: "binoculars.fill")
      }
    } else {
      Button {
        Task { await model.watchRepeater(repeater.id) }
      } label: {
        Label(L10n.Localizable.SignalBars.watch, systemImage: "binoculars")
      }
    }

    Divider()

    // Local-only hide: the row comes back on its own if the radio hears the repeater again.
    Button(role: .destructive) {
      Task { await model.dismissRepeater(repeater.id) }
    } label: {
      Label(L10n.Localizable.SignalBars.removeFromList, systemImage: "eye.slash")
    }
  }

  // MARK: - Watched repeater

  /// The repeater under range test, with how many times it has been heard since the watch
  /// started — the number that tells a user walking a boundary whether they are still in
  /// range.
  ///
  /// Only a summary and an entry point: tapping it opens `RepeaterWatchView`, where the
  /// alert tones and target switching a walking range test actually needs have room to live.
  @ViewBuilder
  private var watchedRow: some View {
    if let watched = model.watched {
      HStack(spacing: 6) {
        Button {
          showWatchScreen = true
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "binoculars.fill")
              .font(.system(size: 10))
              .foregroundStyle(theme.accentColor)

            Text(watchedName(for: watched))
              .font(.system(.caption, design: .monospaced).weight(.semibold))
              .lineLimit(1)

            RepeaterSignalGlyph(leg: .rx, quality: watched.rxQuality, size: 12)

            Spacer(minLength: 0)

            if watched.heardCount > 0 {
              Text(watched.heardCount, format: .number)
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            }

            Image(systemName: "chevron.forward")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.tertiary)
          }
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Localizable.SignalBars.Watch.openAccessibility(
          watchedName(for: watched)
        ))

        Button(role: .destructive) {
          Task { await model.watchRepeater(nil) }
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Localizable.SignalBars.stopWatching)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
  }

  /// The watched repeater's resolved name when its row is still in the table, otherwise its
  /// hash — a watch survives the repeater dropping out of range, which is the whole point.
  private func watchedName(for watched: WatchedRepeaterState) -> String {
    model.displayRepeaters
      .first { watched.id.identifiesSameNode(as: $0.id) }?
      .name ?? watched.id.hex
  }
}

// MARK: - TX Power

/// The active adaptive-power step, with the steps the radio can actually reach.
///
/// Present here because power and received signal are one decision: a repeater that cannot
/// hear us is the reason to step up, and this list is where that becomes visible.
private struct RepeaterTxPowerControl: View {
  let service: AdaptivePowerService

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "bolt.fill")
        .font(.system(size: 10))
        .foregroundStyle(tint)

      Text(L10n.Localizable.SignalBars.txPower)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)

      Spacer(minLength: 4)

      Menu {
        ForEach(service.availableSteps) { step in
          Button {
            Task { await service.setUserOverride(stepIndex: step.id) }
          } label: {
            if step.id == service.currentStepIndex {
              Label(step.label, systemImage: "checkmark")
            } else {
              Text(step.label)
            }
          }
        }

        if service.isElevated || service.isUserOverride {
          Divider()
          Button {
            Task { await service.resetToBase() }
          } label: {
            Label(L10n.Localizable.SignalBars.resetPower, systemImage: "arrow.counterclockwise")
          }
        }
      } label: {
        HStack(spacing: 4) {
          Text(service.currentStep.label)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.fill.tertiary, in: .capsule)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(L10n.Localizable.SignalBars.txPower)
      .accessibilityValue(service.currentStep.label)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var tint: Color {
    if service.isAtMax { return .red }
    return service.isElevated ? .orange : .green
  }
}
