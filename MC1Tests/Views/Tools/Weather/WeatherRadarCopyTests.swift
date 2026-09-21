import Foundation
import MC1Services
import MeshWX
import Testing

@testable import MC1

/// The sentences a radar picture is read out in (docs/MESHWX_UI.md §18, spec revision 11, §3).
///
/// The screens are two lists and a map; what they *say* is all here, and every rule the owner
/// decided on is a sentence rather than a pixel: "precipitation", not "rain", because radar sees
/// snow; widths named and not measured; a picture past half an hour saying so out loud; unknown
/// ground never described as dry.
@Suite("Weather radar copy")
struct WeatherRadarCopyTests {
  typealias F = WeatherFormattingTests

  static let now = F.now
  static let place = "Austin, TX"
  /// The zoom 0 square Austin falls in: 29 N to 31 N, 99 W to 97 W.
  static let tile = MeshWXRadarTile(south: 29, west: -99, zoom: 0)
  static let austin = MeshWXCoordinate(latitude: 30.2672, longitude: -97.7431)

  static func minutes(ago: Int) -> UInt32 {
    MeshWXPresentation.unixMinutes(for: now) - UInt32(ago)
  }

  static func reach(_ level: MeshWXRadarLevel, _ kilometres: Double, _ bearing: MeshWXCompass)
    -> WeatherRadarSummary.Reach {
    WeatherRadarSummary.Reach(level: level, kilometres: kilometres, bearing: bearing)
  }

  static func lines(
    here: MeshWXRadarLevel?,
    nearest: WeatherRadarSummary.Reach? = nil,
    heavy: WeatherRadarSummary.Reach? = nil
  ) -> [String] {
    WeatherCopy.radarSummary(
      WeatherRadarSummary(here: here, nearest: nearest, nearestHeavy: heavy), placeName: place)
  }

  // MARK: - What the picture says (§3)

  @Test
  func `precipitation over the place is named by its level, and never as rain`() {
    #expect(Self.lines(here: .light) == ["Light precipitation at Austin, TX."])
    #expect(Self.lines(here: .moderate) == ["Moderate precipitation at Austin, TX."])
    #expect(Self.lines(here: .heavy) == ["Heavy precipitation at Austin, TX."])
  }

  /// The one sentence that must never be "Dry at Austin": inside the square, outside the picture.
  /// The mosaic did not look here, and a screen that filled that in with fair weather would be
  /// inventing the one thing a radar cannot tell you.
  @Test
  func `a picture that does not reach the place says so, and says nothing else`() {
    #expect(Self.lines(here: nil, nearest: Self.reach(.heavy, 20, .north))
      == ["This picture does not reach Austin, TX."])
  }

  @Test
  func `a picture with nothing on it anywhere is one sentence`() {
    #expect(Self.lines(here: MeshWXRadarLevel.none) == ["No precipitation on this picture."])
  }

  /// Standing in the rain, the nearest *other* wet cell is seven kilometres away and means
  /// nothing. Dry, it is the whole of what the picture has to say.
  @Test
  func `the nearest precipitation is named only when it is not falling here`() {
    #expect(Self.lines(here: MeshWXRadarLevel.none, nearest: Self.reach(.light, 45.2, .northWest))
      == ["Dry at Austin, TX.", "Nearest precipitation 45 km NW."])
    #expect(Self.lines(here: .light, nearest: Self.reach(.light, 45.2, .northWest))
      == ["Light precipitation at Austin, TX."])
  }

  /// A separate heavy core is named either way: it is the one thing on a picture worth knowing
  /// about from inside light rain. The screen rules have already dropped it when it is the cell
  /// just named, or when the reader is standing in it.
  @Test
  func `a separate heavy core is named whether or not it is falling here`() {
    #expect(Self.lines(here: .light, heavy: Self.reach(.heavy, 80.4, .northWest))
      == ["Light precipitation at Austin, TX.", "Heavy precipitation 80 km NW."])
    #expect(Self.lines(
      here: MeshWXRadarLevel.none, nearest: Self.reach(.light, 45.2, .northWest),
      heavy: Self.reach(.heavy, 80.4, .west))
      == [
        "Dry at Austin, TX.", "Nearest precipitation 45 km NW.", "Heavy precipitation 80 km W."
      ])
  }

  // MARK: - The time line (§3)

  static func picture(minutesOld: Int, coarse: Bool = false, bounds: MeshWXRadarBounds? = nil)
    -> WeatherRadarPicture {
    let radar = MeshWXRadar(
      takenMinutes: minutes(ago: minutesOld), south: 29, west: -99, zoom: 0, product: 1,
      isCoarse: coarse, bounds: bounds,
      cells: [UInt8](repeating: 0, count: coarse ? 256 : 1024))
    let stored = WeatherStoredRadarTile(
      tile: tile, radar: radar, receivedAt: now, source: .goesSatellite)
    return WeatherRadarPicture(
      stored: stored,
      age: WeatherRadarAge.make(takenMinutes: radar.takenMinutes, now: now),
      summary: WeatherRadarSummary(here: MeshWXRadarLevel.none, nearest: nil, nearestHeavy: nil),
      isWiderThanAsked: false)
  }

  static func timeLine(minutesOld: Int) -> String {
    F.plain(WeatherCopy.radarTime(
      picture(minutesOld: minutesOld), now: now, calendar: F.calendar, locale: F.locale))
  }

  @Test
  func `the time line is the picture's own clock time and its age`() {
    #expect(Self.timeLine(minutesOld: 12) == "Picture from 11:08 PM · 12 min old")
    // Under a minute there is no age worth printing: "0 s old" reads as a stopwatch.
    #expect(Self.timeLine(minutesOld: 0) == "Picture from 11:20 PM")
  }

  /// Half an hour is two mosaics. The picture stays on screen — where a storm was half an hour
  /// ago is worth more than nothing — but the line says out loud that it has moved.
  @Test
  func `from thirty minutes the time line says the precipitation has moved`() {
    #expect(!Self.picture(minutesOld: 29).age.isOld)
    #expect(Self.timeLine(minutesOld: 29) == "Picture from 10:51 PM · 29 min old")
    #expect(Self.picture(minutesOld: 45).age.isOld)
    #expect(Self.timeLine(minutesOld: 45)
      == "Picture from 10:35 PM · 45 min old · Precipitation has moved since.")
  }

  // MARK: - Refusals (§3)

  static func refusal(_ reason: MeshWXNotAvailableReason, source: String = "WX-AUS") -> String? {
    WeatherCopy.requestStatus(
      .settled(.notAvailable(reason), at: now), source: source,
      request: .radar(latitude: austin.latitude, longitude: austin.longitude, zoom: 0),
      now: now, calendar: F.calendar, locale: F.locale)
  }

  /// Radar is the request whose refusal carries most of the information: three of these ask the
  /// reader to do entirely different things, and the generic "not available" said none of them.
  @Test
  func `each refusal says which of the four it is`() {
    #expect(Self.refusal(.noData) == "WX-AUS has no recent radar picture for this area.")
    #expect(Self.refusal(.unsupported) == "WX-AUS does not receive radar pictures.")
    #expect(Self.refusal(.rateLimited)
      == "WX-AUS sent this picture a few minutes ago and has nothing newer yet.")
    // Reason 1 is the forecast's sentence: the same fact, and the app sends a coordinate, so it
    // means the radio could not place it at all.
    #expect(Self.refusal(.unknownLocation) == "WX-AUS didn't recognize that place")
    // Anything else falls back to the words every other request uses.
    #expect(Self.refusal(.botError) == "WX-AUS had an error")
  }

  @Test
  func `a refusal names a generic radio at a sentence start`() {
    #expect(Self.refusal(.unsupported, source: "the weather radio")
      == "The weather radio does not receive radar pictures.")
  }

  /// The alert map's rate-limit sentence is the alert map's: a sweep somebody else paid eight
  /// packets for is about to arrive, which is not what a radar reason 4 means.
  @Test
  func `radar does not borrow the alert map's busy sentence`() {
    let sweep = WeatherCopy.requestStatus(
      .settled(.notAvailable(.rateLimited), at: Self.now), source: "WX-AUS",
      request: .areaSweep(includesAdvisories: false, states: []), now: Self.now,
      calendar: F.calendar, locale: F.locale)
    #expect(sweep != Self.refusal(.rateLimited))
  }

  // MARK: - Widths (§3)

  /// Not kilometres, which is the owner's decision: a tile is two degrees, 222 km tall everywhere
  /// and a different width at every latitude.
  @Test
  func `the three offered widths have names and the fourth has none`() {
    #expect(WeatherCopy.radarWidthName(0) == "Local")
    #expect(WeatherCopy.radarWidthName(1) == "Regional")
    #expect(WeatherCopy.radarWidthName(2) == "Wide")
    #expect(WeatherCopy.radarWidthName(3) == nil)
  }

  @Test
  func `a tile is named by its centre, in the three decimals a request is written in`() {
    #expect(WeatherCopy.radarCentre(Self.tile) == "30.000,-98.000")
    #expect(WeatherCopy.radarCentre(MeshWXRadarTile(south: 26, west: -102, zoom: 2))
      == "30.000,-98.000")
  }

  // MARK: - Rows elsewhere in the tool (§3, §12)

  @Test
  func `a request row names the picture and the coordinate asked about`() {
    #expect(WeatherCopy.requestName(
      .radar(latitude: 30.2672, longitude: -97.7431, zoom: 0), tables: .shared)
      == "Radar picture · 30.267,-97.743")
  }

  /// The Cached row: a square of earth has no name, so it is the width and the middle. Nothing on
  /// the wire says who asked for it, and the lattice means several people may have.
  @Test
  func `a cached radar row is the width and the tile's centre`() {
    #expect(WeatherCopy.cacheGroup(.radarPictures) == "Radar pictures")
    #expect(WeatherCopy.channelSubject(.radar(tile: Self.tile))
      == "Radar picture · Local · 30.000,-98.000")
  }

  @Test
  func `a channel traffic row reads Radar picture, the width, and the wet cells`() {
    let summary = WeatherTrafficSummary(
      title: .radar,
      detail: [.tile(south: 29, west: -99, zoom: 0), .wetCells(214)])
    #expect(WeatherTrafficCopy.title(.radar, isSent: false, tables: .shared) == "Radar picture")
    #expect(WeatherTrafficCopy.details(summary, tables: .shared)
      == ["Local", "214 cells with precipitation"])
  }

  @Test
  func `one wet cell is one cell, and an unoffered width falls back to the centre`() {
    #expect(WeatherTrafficCopy.detail(.wetCells(1), tables: .shared) == "1 cell with precipitation")
    #expect(WeatherTrafficCopy.detail(.tile(south: 16, west: -112, zoom: 3), tables: .shared)
      == "24.000,-104.000")
  }

  // MARK: - The mosaic line (§12.1)

  @Test
  func `the mosaic is named when the bundle knows it, and nothing is claimed when it does not`() {
    let tables = MeshWXTables.shared
    if let first = tables.radarProductNames.first {
      #expect(WeatherCopy.radarMosaic(0, tables: tables) == "Cut from the \(first) mosaic.")
    }
    #expect(WeatherCopy.radarMosaic(200, tables: tables) == nil)
  }
}
