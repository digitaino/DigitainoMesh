import MC1Services
import MeshWX
import SwiftUI

/// One place's page (docs/MESHWX_UI.md §4, §5): one list, top to bottom, answering "what's the
/// weather here".
///
///     MY LOCATION
///        86°  ☁︎ Cloudy · High 92° · Low 71°                (on the canvas, not in a card)
///     Camp Mabry · 6 km · as of 8:24 PM ›
///     Everything is current · WX-AUS 4:25 PM               (what a refresh would ask for)
///     ⚠︎ Tornado Warning · until 9:41 PM                    (only when one covers this place)
///     FORECAST · ISSUED 4:02 PM  ‹ rows ›
///     WEATHER SERVICE TEXT REPORTS  ‹ rows ›
///     WX-AUS · heard 2 min ago · alerts as of 8:02 PM ›
///
/// No section appears or vanishes with the coverage verdict except the out-of-area line and the
/// banner's absence, so the page is the same shape every time it is opened. Nothing here asks the
/// radio by itself: the pull and the Update button are the same plan (§11.1).
struct WeatherPlacePageView: View {
  @Environment(\.appTheme) private var theme

  let model: WeatherToolModel
  let page: WeatherPage
  let onOpenRadio: () -> Void
  let onAddChannel: () -> Void
  let onOpenSettings: () -> Void
  let onUseMyLocation: () -> Void

  /// This page's own build, and nothing else's. A page being swiped past shows what the phone
  /// already holds for its own place instead of the neighbouring page's weather under its name —
  /// and every screen opened from here is handed this, so it answers for this place too.
  private var screen: WeatherPageScreen? {
    model.screen(for: page.id)
  }

  var body: some View {
    List {
      if let screen {
        content(screen)
      } else {
        preview
      }
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
    // No bottom content margin of its own: the tool's controls are in the system's bottom
    // toolbar, so the list is inset by exactly that bar (docs/MESHWX_UI.md §3.1 U-7).
    .refreshable {
      // Inert until this page has a build: a pull in that window would send the previous place's
      // requests under this page's name.
      guard let screen else { return }
      // Nothing can be asked at all. A pull that silently does nothing reads as a broken gesture,
      // so it says why instead (docs/MESHWX_UI.md §3.1 U-6).
      if let block = screen.snapshot.requestBlock {
        model.noteBlockedPull(WeatherCopy.requestBlocked(block, source: screen.sourceName))
        return
      }
      await model.refresh(pageID: page.id)
    }
  }

  // MARK: - The page

  @ViewBuilder
  private func content(_ screen: WeatherPageScreen) -> some View {
    // Something about the radio blocks weather altogether: said first, above everything.
    if let banner = screen.snapshot.banner {
      WeatherRadioBannerSection(model: model, banner: banner, onAddChannel: onAddChannel)
    }

    // The blocking reason is said **once on the page** (docs/MESHWX_UI.md §3.1 U-24). A banner is
    // the loudest thing on the list and carries it whenever there is one, so the status line
    // under the weather stands down rather than printing the same sentence a card below it.
    WeatherConditionsSection(
      screen: screen, onOpenSettings: onOpenSettings, onUseMyLocation: onUseMyLocation,
      showsStatus: !bannerSaysTheBlock(screen))

    // Under the weather, where a weather app puts it (§3.2 Q1, Q7).
    if let warning = screen.context.banner {
      WeatherWarningBannerSection(screen: screen, banner: warning)
    }

    // Nothing held for this place at all: the block above already says so, once, and names what
    // is nearest (docs/MESHWX_UI.md §3.1 U-13). With no place at all it is already the whole of
    // what the page can say (§3.1 U-19).
    if WeatherEmptyPlace.make(screen: screen) == nil, screen.context.conditions != .noPlace {
      WeatherForecastSection(screen: screen)
    }

    // After the forecast (spec revision 11, §3), and outside the empty-place rule above: radar is
    // the one product that always has something to say about a coordinate — the square is two
    // degrees and no bundle has to hold a point or a station in it — so a place with nothing else
    // is exactly the place where it is worth offering. The section has no refusal state to stack
    // on the calm card (§3.1 U-13): it is one line and an ask, or a picture.
    WeatherRadarSection(screen: screen)

    reports(screen)

    WeatherRadioRowSection(screen: screen, onOpen: onOpenRadio)
  }

  /// Nothing can be asked at all **and** the banner already says why: the firmware, the missing
  /// channel and the silent channel are all banners, and each of them was printed twice on one
  /// screen.
  private func bannerSaysTheBlock(_ screen: WeatherPageScreen) -> Bool {
    screen.snapshot.requestBlock != nil && screen.snapshot.banner != nil
  }

  /// The Weather Service products, as rows that open the text (docs/MESHWX_UI.md §8). They are
  /// the only thing below the forecast: the stations, the alerts in the wider area and everything
  /// about the radio moved to the radio page.
  private func reports(_ screen: WeatherPageScreen) -> some View {
    Section {
      WeatherCardLabel(title: L10n.Weather.Weather.Reports.title, systemImage: "doc.text")
      ForEach(WeatherReportProduct.allCases, id: \.self) { product in
        NavigationLink {
          WeatherReportProductView(screen: screen, product: product)
        } label: {
          Text(product.title)
        }
        .accessibilityIdentifier(product.accessibilityIdentifier)
      }
    }
    .themedRowBackground(theme)
  }

  // MARK: - Swiping past

  /// A page the snapshot does not speak for: its name and what the phone already holds for it,
  /// which is what a Places row shows. It fills in as soon as the swipe settles.
  private var preview: some View {
    Section {
      VStack(spacing: 8) {
        ProgressView()
        Text(previewReading)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 24)
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      .accessibilityElement(children: .combine)
    }
  }

  private var previewReading: String {
    guard let coordinate = page.savedPlace?.coordinate ?? model.latestSample?.coordinate else {
      return L10n.Weather.Weather.Picker.noReading
    }
    return WeatherCopy.placeRow(
      WeatherPlaceRowReading.make(
        readings: model.snapshot?.readings ?? [], at: coordinate, now: model.now),
      now: model.now)
  }
}

extension WeatherEmptyPlace {
  /// This page's version of the rule: the conditions it would lead with and the forecast it holds.
  @MainActor
  static func make(screen: WeatherPageScreen) -> WeatherEmptyPlace? {
    make(conditions: screen.context.conditions, forecast: screen.snapshot.forecast)
  }
}

// MARK: - The warning banner (§7)

/// The one strip under the weather, always the same height: the alert covering this place, when
/// it ends, and a count of any others. Tapping it opens the alert; the count opens the list on the
/// radio page. There is no card, ever — a page that rearranges itself in a storm is a page whose
/// shape cannot be learned.
struct WeatherWarningBannerSection: View {
  @Environment(\.appTheme) private var theme

  let screen: WeatherPageScreen
  let banner: WeatherWarningBanner

  var body: some View {
    let tables = MeshWXTables.shared
    let item = banner.item
    let tint = WeatherFormatting.color(for: WeatherFormatting.tint(for: item.warning.event, tables: tables))

    Section {
      NavigationLink {
        WeatherAlertDetailView(screen: screen, identity: item.identity)
      } label: {
        HStack(alignment: .center, spacing: 10) {
          Image(systemName: WeatherFormatting.symbol(for: item.warning.event, tables: tables))
            .font(.title3)
            .foregroundStyle(tint)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text(WeatherFormatting.eventName(item.warning.event, tables: tables))
              .font(.headline)
            Text(qualifier)
              .font(.subheadline)
              .foregroundStyle(item.kind == .active ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
          }
          Spacer(minLength: 8)
          if banner.more > 0 {
            Text(L10n.Weather.Weather.Alerts.more(banner.more))
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
          Capsule()
            .fill(tint)
            .frame(width: 4)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
      }
      .accessibilityIdentifier("weather.warningBanner")
    }
    .themedRowBackground(theme)
  }

  /// "until 9:41 PM · in 40 min" for a live warning; for one that just ended, or an upgrade whose
  /// replacement never came, what became of it instead.
  private var qualifier: String {
    WeatherCopy.alertQualifier(banner.item, placeName: screen.placeName, now: screen.now)
      ?? WeatherFormatting.untilLine(
        expiresAt: banner.item.expiresAt, now: screen.now, calendar: .autoupdatingCurrent,
        locale: .autoupdatingCurrent)
  }
}

// MARK: - The radio row (§10)

/// The last row on every page, and the way to the radio page. It is the only thing here that says
/// anything about the alert list, and it turns orange when that list is old or missing, or when
/// this phone missed messages: the page above says nothing on a quiet day, so this row is where
/// "nothing said" stops meaning "nothing happening".
struct WeatherRadioRowSection: View {
  @Environment(\.appTheme) private var theme

  let screen: WeatherPageScreen
  let onOpen: () -> Void

  var body: some View {
    let row = screen.context.radioRow
    let tint = row.needsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
    Section {
      Button(action: onOpen) {
        HStack(spacing: 10) {
          Image(systemName: "antenna.radiowaves.left.and.right")
            .foregroundStyle(tint)
            .accessibilityHidden(true)
          Text(WeatherCopy.radioRow(
            row, source: screen.sourceName, now: screen.now, calendar: .autoupdatingCurrent,
            locale: .autoupdatingCurrent))
          .foregroundStyle(tint)
          .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
        .font(.subheadline)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isButton)
      .accessibilityIdentifier("weather.radioRow")
    }
    .themedRowBackground(theme)
  }
}

// MARK: - Radio banners (§10)

/// At most one banner, only when something about the radio blocks weather altogether.
struct WeatherRadioBannerSection: View {
  @Environment(\.appTheme) private var theme

  let model: WeatherToolModel
  let banner: WeatherScreenSnapshot.Banner
  let onAddChannel: () -> Void

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 10) {
        Label {
          Text(WeatherCopy.banner(banner))
            .font(.subheadline)
        } icon: {
          Image(systemName: banner == .noBotHeard ? "antenna.radiowaves.left.and.right" : "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
        if banner == .channelMissing, model.isChannelSyncDone {
          HStack(spacing: 10) {
            Button(L10n.Weather.Weather.Banner.addChannel, action: onAddChannel)
              .buttonStyle(.bordered)
              .disabled(model.isAddingChannel)
            if model.isAddingChannel {
              ProgressView()
            }
          }
        }
      }
      .padding(.vertical, 2)
    }
    .themedRowBackground(theme)
  }
}
