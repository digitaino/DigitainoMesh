import MC1Services
import MeshWX
import SwiftUI

/// The Radar section of a place page (docs/MESHWX_UI.md §18), after the forecast.
///
/// Three states and no fourth. Nothing held is one line and the ask; a picture is a square map of
/// its tile, what it says about the place, and when it was taken; a place with no coordinate has
/// no section at all, because a tile is decided by a coordinate and by nothing else.
///
/// The map here is a **still**: the whole row opens the radar screen, where it zooms and carries
/// the alert outlines and the width control. A card that both panned and pushed would be a row
/// with two gestures fighting over it, which is the dead zone §3.1 U-32 went looking for.
struct WeatherRadarSection: View {
  @Environment(\.appTheme) private var theme

  /// The page this radar answers for, so the square, the place named in the sentences and the
  /// radio asked are that page's (docs/MESHWX_UI.md §13).
  let screen: WeatherPageScreen

  @State private var drawing = WeatherMapDrawing()

  private var model: WeatherToolModel { screen.model }
  /// The page's own ask is the narrowest width: the one that is actually about the place. The
  /// radar screen offers the others.
  private var request: WeatherRequest? { screen.radarRequest(zoom: WeatherRadarCard.pageZoom) }

  var body: some View {
    switch screen.radar {
    case .noCoordinate:
      // No section at all. Not an empty card: there is nothing to ask for and nothing to say.
      EmptyView()
    case .missing:
      emptySection
    case let .held(picture):
      heldSection(picture)
    }
  }

  // MARK: - Nothing held

  private var emptySection: some View {
    Section {
      WeatherCardLabel(title: L10n.Weather.Weather.Radar.title, systemImage: "cloud.rain")
      Text(L10n.Weather.Weather.Radar.empty)
        .font(.subheadline)
      ask(title: L10n.Weather.Weather.Radar.ask(screen.sourceName))
    }
    .themedRowBackground(theme)
  }

  // MARK: - A picture

  private func heldSection(_ picture: WeatherRadarPicture) -> some View {
    Section {
      // The width, quietly, and only when it is not the one this card's ask would fetch: a tile
      // somebody else asked for at another width is a picture of a bigger square than the button
      // below offers, and the card says which rather than letting the reader assume.
      WeatherCardLabel(
        title: L10n.Weather.Weather.Radar.title, systemImage: "cloud.rain",
        trailing: picture.isWiderThanAsked
          ? WeatherCopy.radarWidthName(picture.stored.tile.zoom) : nil)

      NavigationLink {
        WeatherRadarView(screen: screen, zoom: UInt8(picture.stored.tile.zoom))
      } label: {
        VStack(alignment: .leading, spacing: 8) {
          map(picture)
          Text(summaryLine(picture))
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
          Text(timeLine(picture))
            .font(.footnote)
            .foregroundStyle(picture.age.isOld ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
        }
        // The map has stopped taking hits, so the row needs a hit area of its own or it looks
        // tappable and does nothing (docs/MESHWX_UI.md §3.1 U-32).
        .contentShape(.rect)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel([
        L10n.Weather.Weather.Radar.title, summaryLine(picture), timeLine(picture)
      ].joined(separator: ". "))
      .accessibilityAddTraits(.isButton)
      .accessibilityIdentifier("weather.radar.open")

      ask(title: L10n.Weather.Weather.Radar.askNewer)
    }
    .themedRowBackground(theme)
  }

  /// A square of the tile, which is the shape the tile is: two degrees by two degrees. The outer
  /// frame is a floor and not the layout — a map has no size of its own, so if the aspect ratio is
  /// ever handed a proposal it cannot resolve the card is still a full-width map and not a
  /// vanished row.
  ///
  /// The shapes are built here rather than on the section, keyed on the picture: a `task` hung on
  /// the `Section` itself would be a modifier between the list and its rows, and this is a plain
  /// view inside one.
  private func map(_ picture: WeatherRadarPicture) -> some View {
    WeatherAlertMapView(drawing: drawing, isInteractive: false)
      .aspectRatio(1, contentMode: .fit)
      .frame(maxWidth: .infinity, minHeight: 180)
      .clipShape(.rect(cornerRadius: 10))
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .task(id: drawingKey(picture)) {
        let key = drawingKey(picture)
        drawing = await Task.detached(priority: .userInitiated) {
          WeatherRadarDrawing.make(key, tables: .shared, geometry: .shared)
        }.value
      }
  }

  /// No alerts on this map: the card is a picture of the precipitation, and the page already
  /// carries the one alert that covers the place in the banner above it (§7.3). The radar screen
  /// is where the two are drawn together.
  private func drawingKey(_ picture: WeatherRadarPicture) -> WeatherRadarMapKey {
    WeatherRadarMapKey(
      radar: picture.stored.radar, tile: picture.stored.tile, warnings: [], place: screen.place,
      isGeometryLoaded: screen.context.isGeometryLoaded)
  }

  // MARK: - Words

  private func summaryLine(_ picture: WeatherRadarPicture) -> String {
    WeatherCopy.radarSummary(picture.summary, placeName: screen.placeName ?? "")
      .joined(separator: " ")
  }

  private func timeLine(_ picture: WeatherRadarPicture) -> String {
    WeatherCopy.radarTime(
      picture, now: screen.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
  }

  /// The ask, its cost above it and the footnotes under it — the shape every ask in the tool has
  /// (§11). **Always one packet**, whatever is held and whatever the width: a radar answer is one
  /// packet or a coarser packet, never two (spec revision 11, §1.1).
  @ViewBuilder
  private func ask(title: String) -> some View {
    if let request {
      if model.status(for: request).isAskable {
        Text(WeatherAreaMapCopy.packets(1))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      WeatherAskButton(screen: screen, title: title, request: request, showsFootnotes: true)
      Text(L10n.Weather.Weather.Radar.Ask.footnote)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
