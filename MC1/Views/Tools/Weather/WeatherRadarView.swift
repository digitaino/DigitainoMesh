import MC1Services
import MeshWX
import SwiftUI

/// The radar screen (docs/MESHWX_UI.md §18), pushed from the place page's card.
///
/// One square of earth at a time, drawn the way a radar picture has to be drawn to be read: the
/// cells at the bottom, the alerts this phone holds over them as **outlines**, the place on top.
/// An alert polygon filled the way the alert map fills it would cover precisely the cells that
/// made it issue.
///
/// The width control is the rest of the screen. A tile is one packet whatever its width, so the
/// choice is not about cost — it is about whether the question is "is it raining here" or "is
/// that line going to reach us", and those want 2° and 8° pictures respectively. Each width shows
/// what is held for **its own square**, or that nobody has asked for it yet, which is a different
/// thing from a picture that does not reach the place.
struct WeatherRadarView: View {
  @Environment(\.appTheme) private var theme

  /// The page this was opened from: the square, the place in the sentences and the radio asked
  /// are all that page's (docs/MESHWX_UI.md §13).
  let screen: WeatherPageScreen

  /// Which width is on screen. Opened on the width of the picture the card was showing, so
  /// pushing the card shows the same picture rather than an empty Local square.
  @State private var zoom: UInt8
  @State private var drawing = WeatherMapDrawing()

  init(screen: WeatherPageScreen, zoom: UInt8 = WeatherRadarCard.pageZoom) {
    self.screen = screen
    _zoom = State(initialValue: min(zoom, Self.widestOffered))
  }

  /// Zoom 3 exists on the wire and is not offered (spec revision 11, §3): a 16° tile is a picture
  /// of eight states, drawn 50 km to a cell, and nothing anybody opens a radar screen to ask.
  static let widestOffered: UInt8 = 2
  static let offeredZooms: [UInt8] = [0, 1, 2]

  private var model: WeatherToolModel { screen.model }
  private var card: WeatherRadarCard { screen.radarWidth(zoom) }
  private var request: WeatherRequest? { screen.radarRequest(zoom: zoom) }

  var body: some View {
    let card = card
    List {
      mapSection(card)
      readingSection(card)
      legendSection
      widthSection(card)
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
    .navigationTitle(L10n.Weather.Weather.Radar.title)
    .navigationBarTitleDisplayMode(.inline)
    .weatherPendingBar(model: model, requestsOnScreen: Set([request].compactMap { $0 }))
    .weatherToolChrome()
  }

  // MARK: - The map

  /// Interactive, and framed on the square rather than on what is drawn in it: an empty width is
  /// still a map of the tile the ask would fill, so switching widths moves the camera to the
  /// square being talked about whether or not a picture has arrived for it.
  @ViewBuilder
  private func mapSection(_ card: WeatherRadarCard) -> some View {
    if let key = drawingKey(card) {
      Section {
        // Square, because the tile is: the outer frame is only the floor under a map that has no
        // size of its own (§18.2).
        WeatherAlertMapView(drawing: drawing, isInteractive: true)
          .aspectRatio(1, contentMode: .fit)
          .frame(maxWidth: .infinity, minHeight: 220)
          .clipShape(.rect(cornerRadius: 10))
          .accessibilityLabel(L10n.Weather.Weather.Radar.title)
          .accessibilityIdentifier("weather.radar.map")
          .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
          .task(id: key) {
            drawing = await Task.detached(priority: .userInitiated) {
              WeatherRadarDrawing.make(key, tables: .shared, geometry: .shared)
            }.value
          }
      }
      .themedRowBackground(theme)
    }
  }

  /// The alerts this device holds go on **this** map and not on the card's: here there is room to
  /// draw them without hiding the picture, and the two together are the only place in the tool
  /// that says whether the warning polygon has the storm in it.
  private func drawingKey(_ card: WeatherRadarCard) -> WeatherRadarMapKey? {
    guard let tile = screen.radarTile(zoom: zoom) else { return nil }
    return WeatherRadarMapKey(
      radar: card.picture?.stored.radar,
      tile: tile,
      warnings: screen.snapshot.alerts.map(\.warning),
      place: screen.place,
      isGeometryLoaded: screen.context.isGeometryLoaded)
  }

  // MARK: - What the picture says

  @ViewBuilder
  private func readingSection(_ card: WeatherRadarCard) -> some View {
    Section {
      switch card {
      case .noCoordinate, .missing:
        // Not "no radar picture": this width's square has simply never been asked for, and the
        // button below is the whole of what to do about it.
        Text(L10n.Weather.Weather.Radar.notAsked)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      case let .held(picture):
        Text(WeatherCopy.radarSummary(picture.summary, placeName: screen.placeName ?? "")
          .joined(separator: " "))
          .font(.subheadline)
          .fixedSize(horizontal: false, vertical: true)
        Text(WeatherCopy.radarTime(
          picture, now: screen.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent))
          .font(.footnote)
          .foregroundStyle(picture.age.isOld ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
          .fixedSize(horizontal: false, vertical: true)
        // Orange, like every other hole in a picture on this tool: grey cells are ground the
        // mosaic never covered, and a reader who takes them for clear weather has been misled by
        // the screen rather than by the radio.
        if picture.isPartial {
          Text(L10n.Weather.Weather.Radar.partial)
            .font(.footnote)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        // Quiet: half the detail is still the whole square, and the picture is not wrong — it is
        // what fitting a squall line into one packet costs.
        if picture.isCoarse {
          Text(L10n.Weather.Weather.Radar.coarse)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let footnote = mosaicLine(picture) {
          Text(footnote)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .themedRowBackground(theme)
  }

  /// "Cut from the Southern Plains mosaic. · Via GOES satellite" — which of the fourteen pictures
  /// this square came out of, and how the radio got it (§12.1). Nothing at all when the bundle
  /// does not know the product and the radio did not say where it came from.
  private func mosaicLine(_ picture: WeatherRadarPicture) -> String? {
    let parts = [
      WeatherCopy.radarMosaic(picture.stored.radar.product),
      WeatherCopy.dataSource(picture.stored.source)
    ].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  // MARK: - Legend

  /// Three swatches and their names. The colours are the picture's own
  /// (``WeatherRadarPalette``) and never an alert tint: this legend and §17's have to be readable
  /// on the same screen without either being mistaken for the other.
  private var legendSection: some View {
    Section {
      WeatherCardLabel(title: L10n.Weather.Weather.AreaMap.legend, systemImage: "paintpalette")
      ForEach([MeshWXRadarLevel.light, .moderate, .heavy], id: \.self) { level in
        HStack(spacing: 10) {
          RoundedRectangle(cornerRadius: 3)
            .fill(WeatherRadarPalette.color(for: level)
              .opacity(WeatherRadarPalette.fillOpacity))
            .frame(width: 22, height: 14)
          Text(Self.levelName(level))
            .font(.subheadline)
        }
        // The swatch is the colour the name is drawn beside; a reader who cannot see it gets the
        // name, which is the part that means anything.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.levelName(level))
      }
    }
    .themedRowBackground(theme)
  }

  static func levelName(_ level: MeshWXRadarLevel) -> String {
    switch level {
    case .heavy: L10n.Weather.Weather.Radar.Level.heavy
    case .moderate: L10n.Weather.Weather.Radar.Level.moderate
    // The legend never draws a dry cell, so `none` has no swatch of its own; it falls in with
    // light rather than inventing a fourth word for nothing.
    case .light, .none: L10n.Weather.Weather.Radar.Level.light
    }
  }

  // MARK: - Width, and the ask

  /// Local, Regional, Wide — **not** kilometres. A tile is two degrees: 222 km tall everywhere and
  /// a different width at every latitude, so a number on this control would be right on one
  /// parallel and wrong on all the others.
  private func widthSection(_ card: WeatherRadarCard) -> some View {
    Section {
      Picker(L10n.Weather.Weather.Radar.width, selection: $zoom) {
        ForEach(Self.offeredZooms, id: \.self) { option in
          Text(WeatherCopy.radarWidthName(Int(option)) ?? "").tag(option)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("weather.radar.width")

      if let request {
        // One packet, whatever the width and whatever is held: a radar answer is one packet or a
        // coarser packet, never two (spec revision 11, §1.1). Said before the tap, like every
        // other cost in the tool.
        if model.status(for: request).isAskable {
          Text(WeatherAreaMapCopy.packets(1))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        WeatherAskButton(
          screen: screen, title: askTitle(card), request: request, showsFootnotes: true)
        Text(L10n.Weather.Weather.Radar.Ask.footnote)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .themedRowBackground(theme)
  }

  /// "Ask WX-AUS for the radar picture" for a width with nothing on it; "Ask for a newer picture"
  /// once there is one, because that is what the tap is actually for.
  private func askTitle(_ card: WeatherRadarCard) -> String {
    card.picture == nil
      ? L10n.Weather.Weather.Radar.ask(screen.sourceName)
      : L10n.Weather.Weather.Radar.askNewer
  }
}
