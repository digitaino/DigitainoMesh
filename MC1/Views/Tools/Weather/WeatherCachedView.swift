import MC1Services
import MeshWX
import SwiftUI

/// Everything this phone kept from `#meshwx`, grouped and counted (docs/MESHWX_UI.md §12).
///
/// Reached from one disclosed row at the foot of the weather radio's page. Each row names the
/// thing, when its content was taken and when it arrived, and opens the screen that shows it in
/// full where there is one. The header says where all of it came from — and that who asked for it
/// is not something this phone can know.
struct WeatherCachedView: View {
  @Environment(\.appTheme) private var theme

  /// The page this list was opened from, so a row that opens a station or an alert opens it
  /// against that place.
  let screen: WeatherPageScreen

  /// Which way the same pile is read. **Heard on #meshwx used to be a section of its own on the
  /// radio page**, above a station count and above this screen's own row, so the page said the
  /// same thing three times in three shapes (docs/MESHWX_UI.md §3.1 U-16). What was heard and
  /// what is cached are one pile: this is the time-ordered view of it.
  @State private var isNewestFirst = false

  var body: some View {
    List {
      Section {
        Text(L10n.Weather.Weather.Cache.intro)
          .font(.subheadline)
          .foregroundStyle(.secondary)
        if !screen.snapshot.heard.isEmpty {
          Picker(L10n.Weather.Weather.Cache.title, selection: $isNewestFirst) {
            Text(L10n.Weather.Weather.Cache.byKind).tag(false)
            Text(L10n.Weather.Weather.Cache.newestFirst).tag(true)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }
      }
      .themedRowBackground(theme)

      if isNewestFirst {
        heardSection
      } else {
        ForEach(screen.snapshot.cache.groups) { group in
          Section {
            WeatherCardLabel(
              title: L10n.Weather.Weather.Cache.group(WeatherCopy.cacheGroup(group.group), group.count),
              systemImage: "tray.full")
            ForEach(group.items) { item in
              row(item)
            }
          }
          .themedRowBackground(theme)
        }
      }
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
    .navigationTitle(L10n.Weather.Weather.Cache.title)
    .navigationBarTitleDisplayMode(.inline)
    .weatherPendingBar(model: screen.model, requestsOnScreen: [])
    .weatherToolChrome()
  }

  /// What the channel carried recently, newest first: the scheduled broadcasts and the answers,
  /// in one list and not told apart. On a broadcast channel they are the same thing, and
  /// separating them would be a claim about who asked.
  private var heardSection: some View {
    Section {
      ForEach(screen.snapshot.heard) { item in
        label(subject: item.subject, contentAt: item.contentAt, receivedAt: item.receivedAt)
      }
    } footer: {
      Text(L10n.Weather.Weather.Heard.footer)
    }
    .themedRowBackground(theme)
  }

  /// A row opens the screen that shows the thing in full. A reply nobody here asked for names
  /// only its subject, so it opens nothing rather than a station screen picked by guesswork.
  @ViewBuilder
  private func row(_ item: WeatherCachedItem) -> some View {
    switch item.destination {
    case let .station(index):
      NavigationLink {
        WeatherStationDetailView(screen: screen, index: index)
      } label: {
        label(item)
      }
    case let .alert(identity):
      NavigationLink {
        WeatherAlertDetailView(screen: screen, identity: identity)
      } label: {
        label(item)
      }
    case nil:
      label(item)
    }
  }

  private func label(_ item: WeatherCachedItem) -> some View {
    label(subject: item.subject, contentAt: item.contentAt, receivedAt: item.receivedAt)
  }

  private func label(subject: WeatherChannelSubject, contentAt: Date?, receivedAt: Date) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(WeatherCopy.channelSubject(subject))
      Text(WeatherCopy.channelTimes(
        contentAt: contentAt, receivedAt: receivedAt, now: screen.now,
        calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent))
      .font(.footnote)
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}
