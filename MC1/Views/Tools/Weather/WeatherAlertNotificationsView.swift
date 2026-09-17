import MC1Services
import MeshWX
import SwiftUI
import UIKit

/// Alert notifications (docs/MESHWX_UI.md §16): the places being watched and what can actually
/// reach them, the two things that are not storm warnings, and what this promises — which is less
/// than a weather radio, and says so.
///
/// Reached from the Alerts card and from the weather radio's page. Turning a bell *on* happens in
/// Places, beside the place itself; this screen is where the user sees whether any of it is
/// working.
struct WeatherAlertNotificationsView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase

  let model: WeatherToolModel

  var body: some View {
    List {
      deniedSection
      placesSection
      alsoSection
      promiseSection
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
    .navigationTitle(L10n.Weather.Weather.Notifications.title)
    .navigationBarTitleDisplayMode(.inline)
    .weatherToolChrome()
    .task {
      await model.refreshWatchState()
    }
    .onChange(of: scenePhase) { _, phase in
      // Permission can be turned off in Settings while the app is away.
      guard phase == .active else { return }
      Task { await model.refreshWatchState() }
    }
  }

  // MARK: - Permission

  @ViewBuilder
  private var deniedSection: some View {
    if model.notificationsAuthorization == .denied {
      Section {
        Text(L10n.Weather.Weather.Notifications.denied)
          .font(.subheadline)
        Button(L10n.Weather.Weather.Notifications.openSettings) {
          guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
          openURL(url)
        }
      }
      .themedRowBackground(theme)
    }
  }

  // MARK: - Places

  private var placesSection: some View {
    Section {
      WeatherCardLabel(title: L10n.Weather.Weather.Notifications.placesHeader, systemImage: "bell")
      if model.isMyLocationWatched {
        row(
          title: L10n.Weather.Weather.Notifications.myLocation,
          detail: deliveryState,
          caption: myLocationAge,
          stop: { await model.setMyLocationWatch(false) })
      }
      ForEach(model.watchedPlaces) { place in
        row(
          title: place.label,
          detail: deliveryState,
          caption: nil,
          stop: { await model.setWatch(false, forPlaceID: place.id) })
      }
      if !model.isWatchingAnything {
        Text(L10n.Weather.Weather.Notifications.empty)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .themedRowBackground(theme)
  }

  /// One watched place: what it is called, whether anything can reach it now, and the bell that
  /// stops it.
  private func row(
    title: String,
    detail: String,
    caption: String?,
    stop: @escaping () async -> Void
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(detail)
          .font(.footnote)
          .foregroundStyle(.secondary)
        if let caption {
          Text(caption)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
      Button {
        Task { await stop() }
      } label: {
        Image(systemName: "bell.fill")
          .foregroundStyle(.tint)
          .padding(.vertical, 4)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(L10n.Weather.Weather.Notifications.stopWatching(title))
    }
  }

  /// What can arrive right now: the radio is the whole path, so this is its state, and when it is
  /// down it says since when only if this visit saw it go.
  private var deliveryState: String {
    guard !model.isRadioConnected else { return L10n.Weather.Weather.Notifications.connected }
    guard let since = model.radioDisconnectedAt else {
      return L10n.Weather.Weather.Notifications.disconnected
    }
    return L10n.Weather.Weather.Notifications.disconnectedSince(WeatherFormatting.clockTime(
      since, now: model.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent))
  }

  /// My location is matched against the last position the app took, which is only ever while the
  /// app was in use: the age is on the row, always, and nothing here says the phone is followed.
  private var myLocationAge: String {
    guard let position = model.myLocationPosition else {
      return L10n.Weather.Weather.Notifications.noPosition
    }
    return L10n.Weather.Weather.Notifications.positionAge(
      WeatherFormatting.age(position.timestamp, now: model.now))
  }

  // MARK: - The two toggles

  private var alsoSection: some View {
    Section {
      WeatherCardLabel(title: L10n.Weather.Weather.Notifications.alsoHeader)
      Toggle(isOn: Binding(
        get: { model.subscriptions.notifiesOtherWarnings },
        set: { model.setOtherWarnings($0) }
      )) {
        VStack(alignment: .leading, spacing: 2) {
          Text(L10n.Weather.Weather.Notifications.otherWarnings)
          Text(L10n.Weather.Weather.Notifications.otherWarningsDetail)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      Toggle(isOn: Binding(
        get: { model.subscriptions.notifiesTornadoNearby },
        set: { model.setTornadoNearby($0) }
      )) {
        VStack(alignment: .leading, spacing: 2) {
          Text(L10n.Weather.Weather.Notifications.tornadoNearby)
          Text(L10n.Weather.Weather.Notifications.tornadoNearbyDetail)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    } footer: {
      Text(L10n.Weather.Weather.Notifications.stormsAlways)
    }
    .themedRowBackground(theme)
  }

  // MARK: - What this promises

  /// Deliberately conservative, and revisited only after the on-device test: everything here
  /// depends on a radio being in range and the app still running.
  private var promiseSection: some View {
    Section {
      Text(L10n.Weather.Weather.Notifications.promise)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("weather.notifications.promise")
    }
    .themedRowBackground(theme)
  }
}
