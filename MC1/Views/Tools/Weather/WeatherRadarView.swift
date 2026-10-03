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
///
/// Since revision 13 (docs/MESHWX_REV13.md §3) every width can play the last hour of its square as
/// a loop. Nothing plays and nothing asks by itself.
struct WeatherRadarView: View {
  @Environment(\.appTheme) private var theme

  /// The page this was opened from: the square, the place in the sentences and the radio asked
  /// are all that page's (docs/MESHWX_UI.md §13).
  let screen: WeatherPageScreen

  /// Which width is on screen. Opened on the width of the picture the card was showing, so
  /// pushing the card shows the same picture rather than an empty Local square.
  @State private var zoom: Int
  @State private var drawing = WeatherMapDrawing()
  /// The list's height, which caps the square: at full width in landscape, or on an iPad, a 1:1
  /// map is taller than the screen, and an interactive map that fills the screen takes every drag
  /// there is — the rest of the screen could only be reached through the row's 12 pt inset.
  @State private var listHeight: CGFloat = 0

  // MARK: The loop's player

  /// The loop is playing. Never set by anything but the Play button: nothing plays by itself.
  @State private var isPlaying = false
  /// The frame on screen while playing or paused, as an index into the loop's frames, oldest
  /// first. Nil is the ordinary still of the newest picture.
  @State private var frameIndex: Int?
  /// Each frame's drawing, made once when the player starts and kept for as long as the frames
  /// are the same ones (spec revision 13, §3): a step swaps a drawing and builds nothing.
  @State private var frameDrawings: [WeatherMapDrawing] = []
  @State private var frameDrawingsKey: WeatherRadarLoopKey?

  init(screen: WeatherPageScreen, zoom: Int = WeatherRadarCard.pageZoom) {
    self.screen = screen
    _zoom = State(initialValue: min(max(zoom, 0), Self.widestOffered))
  }

  /// Zoom 3 exists on the wire and is not offered (spec revision 11, §3): a 16° tile is a picture
  /// of eight states, drawn 50 km to a cell, and nothing anybody opens a radar screen to ask.
  static let widestOffered = 2
  static let offeredZooms = [0, 1, 2]
  /// How long a frame of the loop stays up, and the newest: long enough to read where the line
  /// was, and a beat on the newest so the loop reads as arriving at now (spec revision 13, §3).
  static let frameSeconds = 0.8
  static let newestFrameSeconds = 2.0

  private var model: WeatherToolModel { screen.model }
  private var card: WeatherRadarCard { screen.radarWidth(zoom) }
  private var request: WeatherRequest? { screen.radarRequest(zoom: zoom) }
  /// The square on screen: the place's at this width, whether or not a picture is held for it.
  /// The camera frames it, and its frames are the loop.
  private var tile: MeshWXRadarTile? { screen.radarTile(zoom: zoom) }

  var body: some View {
    let card = card
    let loop = tile.map { screen.radarLoop(tile: $0) } ?? .empty
    let loopRequest = loopAsk(loop)
    let framesToDraw = activeLoopKey(card, loop: loop)
    // The width is set under the picture it changes, and the ask is in the bar (docs/MESHWX_UI.md
    // §3.1 U-51): both used to be the last section, under the legend, so choosing a width moved a
    // map that had scrolled off the top, and an answer landed where the tap could not see it.
    List {
      mapSection(card, loop: loop)
      loopSection(loop, request: loopRequest)
      readingSection(card, loop: loop)
      legendSection
    }
    .listStyle(.insetGrouped)
    .weatherReadableWidth()
    .themedCanvas(theme)
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
    .navigationTitle(L10n.Weather.Weather.Radar.title)
    .navigationBarTitleDisplayMode(.inline)
    .weatherPendingBar(
      model: model, requestsOnScreen: Set([request, loopRequest].compactMap { $0 }))
    .weatherAskBar(screen: screen, ask: request.map { WeatherBarAsk(title: askTitle(card), request: $0) })
    .weatherToolChrome()
    // Changing width stops the loop: the frames are another square's.
    .onChange(of: zoom) { stop() }
    // Leaving the screen stops it too. Coming back shows the newest picture, still.
    .onDisappear { stop() }
    .task(id: isPlaying) { await play() }
    .task(id: framesToDraw) { await drawFrames(framesToDraw) }
  }

  /// The longest side the square may have: the width it is given, but never more than two
  /// thirds of the screen's height, so the controls under it are always a scroll away and never
  /// behind it.
  private var mapSide: CGFloat {
    listHeight > 0 ? max(220, listHeight * 0.65) : .infinity
  }

  // MARK: - The map

  /// Interactive, and framed on the square rather than on what is drawn in it: an empty width is
  /// still a map of the tile the ask would fill, so switching widths moves the camera to the
  /// square being talked about whether or not a picture has arrived for it.
  @ViewBuilder
  private func mapSection(_ card: WeatherRadarCard, loop: WeatherRadarLoop) -> some View {
    Section {
      if let key = drawingKey(card) {
        // Square, because the tile is: the outer frame is only the floor under a map that has no
        // size of its own (§18.2). Centred when the height caps it.
        WeatherAlertMapView(drawing: shownDrawing(card, loop: loop), isInteractive: true)
          .aspectRatio(1, contentMode: .fit)
          .frame(maxWidth: mapSide, minHeight: 220)
          .clipShape(.rect(cornerRadius: 10))
          .frame(maxWidth: .infinity)
          .accessibilityLabel(L10n.Weather.Weather.Radar.title)
          .accessibilityIdentifier("weather.radar.map")
          .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
          // The picture is the answer: the capsule's Show scrolls back to it.
          .weatherAskResult()
          .task(id: key) {
            drawing = await Task.detached(priority: .userInitiated) {
              WeatherRadarDrawing.make(key, tables: .shared, geometry: .shared)
            }.value
          }
      }
      widthPicker
    }
    .themedRowBackground(theme)
  }

  /// Local, Regional, Wide — **not** kilometres. A tile is two degrees: 222 km tall everywhere and
  /// a different width at every latitude, so a number on this control would be right on one
  /// parallel and wrong on all the others.
  private var widthPicker: some View {
    Picker(L10n.Weather.Weather.Radar.width, selection: $zoom) {
      ForEach(Self.offeredZooms, id: \.self) { option in
        Text(WeatherCopy.radarWidthName(option) ?? "").tag(option)
      }
    }
    .pickerStyle(.segmented)
    .accessibilityIdentifier("weather.radar.width")
  }

  /// The alerts this device holds go on **this** map and not on the card's: here there is room to
  /// draw them without hiding the picture, and the two together are the only place in the tool
  /// that says whether the warning polygon has the storm in it.
  private func drawingKey(_ card: WeatherRadarCard) -> WeatherRadarMapKey? {
    guard let tile else { return nil }
    return WeatherRadarMapKey(
      radar: card.picture?.stored.radar,
      tile: tile,
      warnings: screen.snapshot.alerts.map(\.warning),
      place: screen.place,
      isGeometryLoaded: screen.context.isGeometryLoaded)
  }

  /// The frame on screen while the loop plays or is paused, else the still. A frame whose drawing
  /// is not made yet — the moment after Play — shows the still rather than nothing.
  private func shownDrawing(_ card: WeatherRadarCard, loop: WeatherRadarLoop) -> WeatherMapDrawing {
    guard let index = frameIndex, let key = frameDrawingsKey,
      key == loopKey(card, loop: loop), frameDrawings.indices.contains(index)
    else { return drawing }
    return frameDrawings[index]
  }

  // MARK: - The loop

  /// Play and Pause, what is missing, and the ask for the rest of the hour (spec revision 13, §3).
  /// Absent while there is nothing to play and nothing to ask.
  @ViewBuilder
  private func loopSection(_ loop: WeatherRadarLoop, request: WeatherRequest?) -> some View {
    let asks = !loop.isFull && request != nil
    if loop.canPlay || asks {
      Section {
        if loop.canPlay {
          Button {
            togglePlay()
          } label: {
            Label(
              isPlaying ? L10n.Weather.Weather.Radar.Loop.pause : L10n.Weather.Weather.Radar.Loop.play,
              systemImage: isPlaying ? "pause.fill" : "play.fill")
          }
          .buttonStyle(.borderless)
          .accessibilityIdentifier("weather.radar.loop.play")
        }
        if loop.hasGap {
          Text(L10n.Weather.Weather.Radar.Loop.missing)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if asks, let request {
          loopAskRow(request)
        }
      }
      .themedRowBackground(theme)
    }
  }

  /// "Up to 5 packets" above the button and the note under it, said before the tap like every
  /// other cost in the tool. The bar keeps the single picture's ask; this one is the loop's own.
  private func loopAskRow(_ request: WeatherRequest) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if model.status(for: request).isAskable {
        Text(L10n.Weather.Weather.Radar.Loop.cost(WeatherRadarLoop.maxFrames))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      WeatherAskButton(
        screen: screen, title: L10n.Weather.Weather.Radar.Loop.ask, request: request,
        showsBlockReason: false)
      Text(L10n.Weather.Weather.Radar.Loop.footnote)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityIdentifier("weather.radar.loop.ask")
  }

  /// The loop's ask lists the frames on screen as held, so the radio leaves them out (spec
  /// revision 13, §7D.4).
  private func loopAsk(_ loop: WeatherRadarLoop) -> WeatherRequest? {
    guard let place = screen.place else { return nil }
    return loop.ask(
      latitude: place.coordinate.latitude, longitude: place.coordinate.longitude, zoom: zoom)
  }

  private func loopKey(_ card: WeatherRadarCard, loop: WeatherRadarLoop) -> WeatherRadarLoopKey? {
    guard loop.canPlay, var base = drawingKey(card) else { return nil }
    base.radar = nil
    return WeatherRadarLoopKey(base: base, radars: loop.frames.map(\.radar))
  }

  /// The frames to draw while the player is in use, and nil otherwise: nobody who never presses
  /// Play pays for five drawings.
  private func activeLoopKey(_ card: WeatherRadarCard, loop: WeatherRadarLoop) -> WeatherRadarLoopKey? {
    isPlaying || frameIndex != nil ? loopKey(card, loop: loop) : nil
  }

  private func drawFrames(_ key: WeatherRadarLoopKey?) async {
    guard let key, key != frameDrawingsKey else { return }
    let drawings = await Task.detached(priority: .userInitiated) {
      WeatherRadarDrawing.loop(key, tables: .shared, geometry: .shared)
    }.value
    guard !Task.isCancelled else { return }
    frameDrawings = drawings
    frameDrawingsKey = key
    if let index = frameIndex, index >= drawings.count { frameIndex = drawings.count - 1 }
  }

  /// From the still, Play starts at the oldest frame; from a pause, where it paused.
  private func togglePlay() {
    if isPlaying {
      isPlaying = false
      return
    }
    if frameIndex == nil { frameIndex = 0 }
    isPlaying = true
  }

  /// One frame at a time, 0.8 s each and 2 s on the newest, round and round until paused.
  private func play() async {
    guard isPlaying else { return }
    while !Task.isCancelled, isPlaying {
      let count = tile.map { screen.radarLoop(tile: $0).frames.count } ?? 0
      guard count >= 2 else {
        stop()
        return
      }
      let index = min(frameIndex ?? 0, count - 1)
      frameIndex = index
      let seconds = index == count - 1 ? Self.newestFrameSeconds : Self.frameSeconds
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled, isPlaying else { return }
      frameIndex = (index + 1) % count
    }
  }

  private func stop() {
    isPlaying = false
    frameIndex = nil
  }

  // MARK: - What the picture says

  @ViewBuilder
  private func readingSection(_ card: WeatherRadarCard, loop: WeatherRadarLoop) -> some View {
    Section {
      if drawingKey(card) == nil {
        readingRows(card, loop: loop)
          .weatherAskResult()
      } else {
        readingRows(card, loop: loop)
      }
      // What the bar's Ask is doing, beside the picture it will change. One packet, whatever the
      // width and whatever is held: a radar answer is one packet or a coarser packet, never two
      // (spec revision 11, §1.1). Said before the tap, like every other cost in the tool.
      if let request {
        WeatherAskStatusRow(
          screen: screen, request: request, cost: WeatherAreaMapCopy.packets(1),
          note: L10n.Weather.Weather.Radar.Ask.footnote)
      }
    }
    .themedRowBackground(theme)
  }

  @ViewBuilder
  private func readingRows(_ card: WeatherRadarCard, loop: WeatherRadarLoop) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      switch card {
      case .noCoordinate, .missing:
        // Not "no radar picture": this width's square has simply never been asked for, and the
        // bar's Ask is the whole of what to do about it.
        Text(L10n.Weather.Weather.Radar.notAsked)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      case let .held(picture):
        // Always the newest picture's, whatever frame is on screen (spec revision 13, §3).
        Text(WeatherCopy.radarSummary(picture.summary, placeName: screen.placeName ?? "")
          .joined(separator: " "))
          .font(.subheadline)
          .fixedSize(horizontal: false, vertical: true)
        timeLine(picture, loop: loop)
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
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The newest picture's time line, or — while the loop plays, or is paused on an older frame —
  /// that frame's own time and its place in the loop, "6:08 PM · 2 of 5", in the caution tone
  /// whenever the frame is old enough to be (spec revision 13, §3).
  @ViewBuilder
  private func timeLine(_ picture: WeatherRadarPicture, loop: WeatherRadarLoop) -> some View {
    if let index = frameIndex, loop.frames.indices.contains(index),
      isPlaying || index < loop.frames.count - 1 {
      let frame = loop.frames[index]
      let age = WeatherRadarAge.make(takenMinutes: frame.takenMinutes, now: screen.now)
      Text(L10n.Weather.Weather.Radar.Loop.frame(
        WeatherFormatting.clockTime(
          frame.takenAt, now: screen.now, calendar: .autoupdatingCurrent,
          locale: .autoupdatingCurrent),
        index + 1, loop.frames.count))
        .font(.footnote)
        .monospacedDigit()
        .foregroundStyle(age.isOld ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("weather.radar.loop.frame")
    } else {
      Text(WeatherCopy.radarTime(
        picture, now: screen.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent))
        .font(.footnote)
        .foregroundStyle(picture.age.isOld ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        .fixedSize(horizontal: false, vertical: true)
    }
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

  // MARK: - The ask

  /// "Ask for radar" for a width with nothing on it; "Ask for a newer picture" once there is one,
  /// because that is what the tap is actually for. Short, because it is a bar button: the radio it
  /// asks is named in the status beside the picture.
  private func askTitle(_ card: WeatherRadarCard) -> String {
    card.picture == nil
      ? L10n.Weather.Weather.Radar.askShort
      : L10n.Weather.Weather.Radar.askNewer
  }
}
