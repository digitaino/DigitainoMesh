import Foundation
@testable import MC1Services
import MeshWX
import Testing

/// The request grammar is the one part of the protocol the app *sends*, so every line of the
/// spec §8.2 table is pinned here byte for byte.
@Suite("WeatherRequest")
struct WeatherRequestTests {
  @Test
  func `every request renders the spec's wire text`() {
    let expected: [(WeatherRequest, String)] = [
      (.digest, ">d"),
      (.activeWarnings, ">w"),
      (.warning(identity: "SV.W.EWX.42"), ">w SV.W.EWX.42"),
      (.warningsTouching(ugc: "TXC453"), ">w TXC453"),
      (.warningsTouching(ugc: "TXZ192"), ">w TXZ192"),
      (.warningText(identity: "SV.W.EWX.42"), ">wt SV.W.EWX.42"),
      (.observations, ">o"),
      (.observation(station: "KAUS"), ">o KAUS"),
      (.homeForecast, ">f"),
      (.forecast(point: 102), ">f 102"),
      (.forecastForPlace("round rock tx"), ">f round rock tx"),
      (.forecastDiscussion(office: "EWX"), ">afd EWX"),
      (.spaceWeather, ">space"),
      (.stormReports(state: "TX"), ">storm TX"),
      (.rainfall(state: "TX"), ">rain TX"),
      (.metar(station: "KAUS"), ">metar KAUS"),
      (.taf(station: "KAUS"), ">taf KAUS"),
      (.hazardousOutlook, ">hwo"),
      (.coverage, ">cov"),
      (.areaSweep(includesAdvisories: false, states: []), ">wmap"),
      (.areaSweep(includesAdvisories: true, states: []), ">wmap all"),
      // Spec revision 11, §7D: three decimals, the `>f` form, and no `z` word at zoom 0.
      (.radar(latitude: 30.27, longitude: -97.74, zoom: 0), ">radar 30.270,-97.740"),
      (.radar(latitude: 30.27, longitude: -97.74, zoom: 2), ">radar 30.270,-97.740 z2"),
      (.radar(latitude: 32.78, longitude: -96.80, zoom: 0), ">radar 32.780,-96.800"),
      (.radar(latitude: 32.78, longitude: -96.80, zoom: 3), ">radar 32.780,-96.800 z3"),
      // Spec revision 13, §7E: the detail level is `z-1`, the `request_radar_detail` vector.
      (.radar(latitude: 32.78, longitude: -96.80, zoom: -1), ">radar 32.780,-96.800 z-1"),
      // §7D.4: `loop` after the zoom, and the held pictures as UTC `HHMM`, newest first — the
      // `request_radar_loop` vector, whatever order the minutes were handed over in.
      (.radarLoop(latitude: 30.27, longitude: -97.74, zoom: 0, held: []), ">radar 30.270,-97.740 loop"),
      (.radarLoop(latitude: 30.27, longitude: -97.74, zoom: 0, held: [Self.at2338, Self.at2353]),
       ">radar 30.270,-97.740 loop 2353 2338"),
      (.radarLoop(latitude: 30.27, longitude: -97.74, zoom: 2, held: [Self.at2353]),
       ">radar 30.270,-97.740 z2 loop 2353"),
      (.radarLoop(latitude: 32.78, longitude: -96.80, zoom: -1, held: []),
       ">radar 32.780,-96.800 z-1 loop")
    ]
    for (request, text) in expected {
      #expect(request.wireText == text)
      #expect(text.utf8.count <= MeshWXWire.maxRequestTextBytes)
    }
  }

  /// 2026-09-20 23:38 UTC, the minute printed on the vectors' Dallas picture, and the picture a
  /// quarter hour after it.
  static let at2338: UInt32 = 29_832_458
  static let at2353: UInt32 = 29_832_473

  /// Spec revision 13, §7D.4: the held pictures go newest first and only as many as keep the
  /// request within 40 bytes. `>radar 30.270,-97.740 loop` is 26 bytes, so two fit and a third
  /// would be 41; the detail level's ` z-1` still leaves room for exactly two; a coordinate that
  /// is southern and western both leaves room for one. Never more than five, whatever fits.
  @Test
  func `a loop lists its newest held pictures, as many as fit 40 bytes`() {
    let hour = (0..<5).map { Self.at2353 - UInt32($0) * 15 }  // 2353 2338 2323 2308 2253
    let austin = WeatherRequest.radarLoop(latitude: 30.27, longitude: -97.74, zoom: 0, held: hour.reversed())
    #expect(austin.wireText == ">radar 30.270,-97.740 loop 2353 2338")
    #expect(austin.wireText.utf8.count == 36)

    let detail = WeatherRequest.radarLoop(latitude: 30.27, longitude: -97.74, zoom: -1, held: hour)
    #expect(detail.wireText == ">radar 30.270,-97.740 z-1 loop 2353 2338")
    #expect(detail.wireText.utf8.count == MeshWXWire.maxRequestTextBytes)

    let sydney = WeatherRequest.radarLoop(latitude: -33.9, longitude: -151.2, zoom: -1, held: hour)
    #expect(sydney.wireText == ">radar -33.900,-151.200 z-1 loop 2353")

    // The shortest coordinate there is leaves room for three.
    let equator = WeatherRequest.radarLoop(latitude: 0, longitude: 0, zoom: 0, held: hour)
    #expect(equator.wireText == ">radar 0.000,0.000 loop 2353 2338 2323")

    // Hour and minute in UTC, four digits, across midnight; a picture listed twice is listed once.
    let pastMidnight = Self.at2353 + 15  // 00:08
    #expect(WeatherRequest.radarLoop(
      latitude: 30.27, longitude: -97.74, zoom: 0, held: [pastMidnight, Self.at2353, Self.at2353]
    ).wireText == ">radar 30.270,-97.740 loop 0008 2353")
    for request in [austin, detail, sydney] {
      #expect(request.wireText.utf8.count <= MeshWXWire.maxRequestTextBytes)
    }
  }

  /// Spec revision 13, §7E: the bot answers a detail ask with the zoom 0 tile for the same
  /// coordinate where no picture is fine enough, so that tile settles it as well. A loop expects
  /// the same tile its single picture would.
  @Test
  func `a detail ask also expects the Local tile the bot falls back to`() {
    let detail = WeatherRequest.radar(latitude: 30.27, longitude: -97.74, zoom: -1)
    #expect(detail.expectedReply == .radar(
      tile: MeshWXRadarTile(south: 30, west: -98, zoom: -1),
      fallback: MeshWXRadarTile(south: 29, west: -99, zoom: 0)))
    #expect(WeatherRequest.radarLoop(latitude: 30.27, longitude: -97.74, zoom: -1, held: [Self.at2338])
      .expectedReply == detail.expectedReply)
    #expect(WeatherRequest.radarLoop(latitude: 30.27, longitude: -97.74, zoom: 1, held: [])
      .expectedReply == .radar(tile: MeshWXRadarTile(south: 28, west: -100, zoom: 1), fallback: nil))
    #expect(detail.acceptsAnswerFromAnyBot)
    #expect(WeatherRequest.radarLoop(latitude: 30.27, longitude: -97.74, zoom: 0, held: [])
      .acceptsAnswerFromAnyBot)
  }

  /// Spec revision 11, §7D: the tile is decided by the lattice, so the request knows which square
  /// of earth it is waiting for before the answer arrives — and any bot's tile of that square is
  /// it, because the lattice is the same arithmetic everywhere.
  @Test
  func `a radar request expects the tile its coordinate falls in`() {
    let request = WeatherRequest.radar(latitude: 30.27, longitude: -97.74, zoom: 0)
    #expect(request.expectedReply
      == .radar(tile: MeshWXRadarTile(south: 29, west: -99, zoom: 0), fallback: nil))
    #expect(WeatherRequest.radar(latitude: 30.27, longitude: -97.74, zoom: 2).expectedReply
      == .radar(tile: MeshWXRadarTile(south: 28, west: -100, zoom: 2), fallback: nil))
    // Two places in the same square are one question, which is the whole reason the lattice is
    // fixed rather than centred on whoever asked: Austin and a town fifty kilometres away ask for
    // one tile between them, and the second one costs the channel nothing.
    #expect(WeatherRequest.radar(latitude: 29.88, longitude: -98.40, zoom: 0).expectedReply
      == request.expectedReply)
    #expect(request.acceptsAnswerFromAnyBot)
  }

  /// Spec §8.3 lists the letters a Not-available reply can carry: w, o, f, a, s, r, m, t, h, d.
  @Test
  func `request letters are the first letter after the prefix`() {
    #expect(WeatherRequest.digest.requestLetter == "d")
    #expect(WeatherRequest.activeWarnings.requestLetter == "w")
    #expect(WeatherRequest.warningText(identity: "SV.W.EWX.42").requestLetter == "w")
    #expect(WeatherRequest.observation(station: "KAUS").requestLetter == "o")
    #expect(WeatherRequest.forecastForPlace("austin tx").requestLetter == "f")
    #expect(WeatherRequest.forecastDiscussion(office: "EWX").requestLetter == "a")
    #expect(WeatherRequest.spaceWeather.requestLetter == "s")
    #expect(WeatherRequest.stormReports(state: "TX").requestLetter == "s")
    #expect(WeatherRequest.rainfall(state: "TX").requestLetter == "r")
    #expect(WeatherRequest.metar(station: "KAUS").requestLetter == "m")
    #expect(WeatherRequest.taf(station: "KAUS").requestLetter == "t")
    #expect(WeatherRequest.hazardousOutlook.requestLetter == "h")
    #expect(WeatherRequest.coverage.requestLetter == "c")
    // The sweep rides on `w` like every other warning request, so a refusal for it comes back
    // under the same letter (spec §8.3).
    #expect(WeatherRequest.areaSweep(includesAdvisories: false, states: []).requestLetter == "w")
    #expect(WeatherRequest.areaSweep(includesAdvisories: true, states: []).requestLetter == "w")
    // Spec revision 11, §7D: `>radar` is the one request whose letter is not its own first. `r`
    // is `>rain`, and a refusal that could mean either is a refusal nobody can act on.
    #expect(WeatherRequest.radar(latitude: 30.27, longitude: -97.74, zoom: 0).requestLetter == "x")
    #expect(WeatherRequest.radar(latitude: 30.27, longitude: -97.74, zoom: 2).requestLetter == "x")
    // Revision 13: the detail level and the loop are `>radar` too.
    #expect(WeatherRequest.radar(latitude: 30.27, longitude: -97.74, zoom: -1).requestLetter == "x")
    #expect(WeatherRequest.radarLoop(latitude: 30.27, longitude: -97.74, zoom: 0, held: [])
      .requestLetter == "x")
    #expect(WeatherRequest.rainfall(state: "TX").requestLetter == "r", "still the rain request")
  }

  /// Spec §7A: a statement describes the bot that sent it, so another bot's — or another
  /// bot's answer to somebody else — says nothing about this one's area.
  @Test
  func `only the bot asked can answer for its own area`() {
    #expect(!WeatherRequest.coverage.acceptsAnswerFromAnyBot)
    #expect(!WeatherRequest.observations.acceptsAnswerFromAnyBot)
    #expect(WeatherRequest.observation(station: "KAUS").acceptsAnswerFromAnyBot)
    // Spec §7C: a sweep is one bot's reading of the country, cut where its own feed runs out,
    // so another bot's sweep is not this request's answer.
    #expect(!WeatherRequest.areaSweep(includesAdvisories: false, states: []).acceptsAnswerFromAnyBot)
    #expect(!WeatherRequest.areaSweep(includesAdvisories: true, states: []).acceptsAnswerFromAnyBot)
  }

  @Test
  func `expected replies carry the station, point and subject the request named`() {
    #expect(WeatherRequest.digest.expectedReply == .digest)
    #expect(WeatherRequest.activeWarnings.expectedReply == .warnings)
    // Only the bare `>w` ends with a digest; the other two are that warning, or warnings naming that area.
    #expect(WeatherRequest.warning(identity: "SV.W.EWX.42").expectedReply == .warning(identity: "SV.W.EWX.42"))
    #expect(WeatherRequest.warningsTouching(ugc: "TXZ192").expectedReply == .warningsTouching(ugc: "TXZ192"))
    #expect(WeatherRequest.observations.expectedReply == .observations(station: nil))
    #expect(WeatherRequest.observation(station: "KAUS").expectedReply == .observations(station: "KAUS"))
    #expect(WeatherRequest.homeForecast.expectedReply == .forecast(point: nil))
    #expect(WeatherRequest.forecast(point: 102).expectedReply == .forecast(point: 102))
    // A place is resolved by the bot; the point that comes back may even be 0xFFFF.
    #expect(WeatherRequest.forecastForPlace("round rock tx").expectedReply == .forecast(point: nil))
    #expect(WeatherRequest.warningText(identity: "x").expectedReply == .text(subject: 0))
    #expect(WeatherRequest.forecastDiscussion(office: "EWX").expectedReply == .text(subject: 1))
    #expect(WeatherRequest.spaceWeather.expectedReply == .text(subject: 2))
    #expect(WeatherRequest.stormReports(state: "TX").expectedReply == .text(subject: 3))
    #expect(WeatherRequest.rainfall(state: "TX").expectedReply == .text(subject: 4))
    #expect(WeatherRequest.metar(station: "KAUS").expectedReply == .text(subject: 5))
    #expect(WeatherRequest.taf(station: "KAUS").expectedReply == .text(subject: 5))
    #expect(WeatherRequest.hazardousOutlook.expectedReply == .text(subject: 6))
    #expect(WeatherRequest.coverage.expectedReply == .coverage)
    // Both scopes expect the same answer: the sweep's own flag says which one arrived, and a bot
    // that will not widen to advisories still answers the tap with the narrow sweep.
    #expect(WeatherRequest.areaSweep(includesAdvisories: false, states: []).expectedReply == .areaSweep)
    #expect(WeatherRequest.areaSweep(includesAdvisories: true, states: []).expectedReply == .areaSweep)
  }

  /// Two scopes are two requests: one on the air must not settle the other's button, and the
  /// request log has to be able to say which one was asked for.
  @Test
  func `the two map scopes are distinct requests`() {
    #expect(WeatherRequest.areaSweep(includesAdvisories: false, states: [])
      != WeatherRequest.areaSweep(includesAdvisories: true, states: []))
  }

  // MARK: - Revision 10

  /// Spec revision 10, §1.2. The compact form on purpose: upper case, run together, no
  /// separators, so fifteen states fit the forty-byte request text beside `>wmap all `.
  @Test
  func `a scoped map names its states run together and upper case`() {
    #expect(WeatherRequest.areaSweep(includesAdvisories: false, states: ["TX"]).wireText == ">wmap TX")
    #expect(WeatherRequest.areaSweep(includesAdvisories: true, states: ["TX", "OK"]).wireText == ">wmap all OKTX")
    // Sorted and upper-cased wherever it was built, so one selection is one request: the
    // five-minute slot and the request log both key off the value.
    #expect(WeatherRequest.areaSweep(includesAdvisories: false, states: ["tx", "ok"]).wireText == ">wmap OKTX")
    #expect(WeatherRequest.areaSweep(includesAdvisories: false, states: ["OK", "TX"])
      == WeatherRequest.areaSweep(includesAdvisories: false, states: ["OK", "TX"]))
    #expect(WeatherRequest.sweepStates(["tx", "OK", "tx"]) == ["OK", "TX"])
    // Fifteen two-letter codes, `>wmap all ` in front: exactly the forty bytes the wire allows.
    let fifteen = ["AL", "AR", "AZ", "CO", "IA", "KS", "LA", "MO", "MS", "NE", "NM", "OK", "TN", "TX", "UT"]
    let widest = WeatherRequest.areaSweep(includesAdvisories: true, states: fifteen).wireText
    #expect(widest.utf8.count == 40)
    #expect(widest.utf8.count <= MeshWXWire.maxRequestTextBytes)
  }

  /// Spec revision 10, §1.1: `>part <group> <idx>[,<idx>…]`, decimal, no spaces after the commas.
  @Test
  func `a parts request names its group and its indexes in decimal`() {
    #expect(WeatherRequest.parts(group: 212, indexes: [1, 4, 6], of: .areaSweep).wireText
      == ">part 212 1,4,6")
    #expect(WeatherRequest.parts(group: 0, indexes: [0], of: .text(subject: 3)).wireText
      == ">part 0 0")
    // `p`, its own letter in the §8.3 table, so a refusal for it cannot be read as a `>wmap` one.
    #expect(WeatherRequest.parts(group: 212, indexes: [1], of: .areaSweep).requestLetter == "p")
    // The kind is for the log's wording; it is not on the wire and pairs nothing.
    #expect(WeatherRequest.parts(group: 212, indexes: [1], of: .areaSweep).expectedReply
      == .parts(group: 212))
    #expect(WeatherRequest.parts(group: 212, indexes: [1], of: .text(subject: 3)).expectedReply
      == .parts(group: 212))
    // A `group` byte is one bot's counter and means nothing on another's.
    #expect(!WeatherRequest.parts(group: 212, indexes: [1], of: .areaSweep).acceptsAnswerFromAnyBot)
  }

  /// Spec revision 10, §1.3: three decimals, recognised by the comma, and the `f` letter the rest
  /// of the forecast grammar uses.
  @Test
  func `a coordinate forecast is two signed decimals with three places`() {
    let santaFe = WeatherRequest.forecastAt(latitude: 35.6870, longitude: -105.9378)
    #expect(santaFe.wireText == ">f 35.687,-105.938")
    #expect(santaFe.requestLetter == "f")
    #expect(santaFe.expectedReply == .forecast(point: nil))
    // The bot resolves the point for itself, exactly as it does for `>f <place>`.
    #expect(!santaFe.acceptsAnswerFromAnyBot)
    #expect(WeatherRequest.forecastAt(latitude: 0, longitude: 0).wireText == ">f 0.000,0.000")
    #expect(WeatherRequest.coordinateKey(latitude: 35.6870, longitude: -105.9378)
      == "35.687,-105.938")
  }

  /// The request log and the weather state on a phone already hold `WeatherRequest` values, so a
  /// file written before revision 10 has to keep loading. `>wmap` was the whole country then, and
  /// that is what it decodes as.
  @Test
  func `an old areaSweep in a saved file decodes as the whole country`() throws {
    let old = Data(#"{"areaSweep":{"includesAdvisories":true}}"#.utf8)
    #expect(try JSONDecoder().decode(WeatherRequest.self, from: old)
      == .areaSweep(includesAdvisories: true, states: []))
  }

  /// Every case survives a round trip through the encoding a phone's files are written in — and
  /// the encoded shape is the contract the JavaScript port reads (`meshwx/web/docs/PORTING.md`),
  /// so the two spellings that are easy to get wrong are pinned as bytes.
  @Test
  func `every request round-trips through its saved form`() throws {
    let all: [WeatherRequest] = [
      .digest, .activeWarnings, .warning(identity: "SV.W.EWX.42"), .warningsTouching(ugc: "TXC453"),
      .warningText(identity: "SV.W.EWX.42"), .observations, .observation(station: "KAUS"),
      .homeForecast, .forecast(point: 102), .forecastForPlace("round rock tx"),
      .forecastAt(latitude: 35.687, longitude: -105.938), .forecastDiscussion(office: "EWX"),
      .spaceWeather, .stormReports(state: "TX"), .rainfall(state: "TX"), .metar(station: "KAUS"),
      .taf(station: "KAUS"), .hazardousOutlook, .coverage,
      .areaSweep(includesAdvisories: false, states: []),
      .areaSweep(includesAdvisories: true, states: ["OK", "TX"]),
      .parts(group: 212, indexes: [1, 4, 6], of: .areaSweep),
      .parts(group: 7, indexes: [2], of: .text(subject: 3)),
      .radar(latitude: 30.27, longitude: -97.74, zoom: 0),
      .radar(latitude: 32.78, longitude: -96.80, zoom: 2),
      .radar(latitude: 32.78, longitude: -96.80, zoom: -1),
      .radarLoop(latitude: 30.27, longitude: -97.74, zoom: 0, held: []),
      .radarLoop(latitude: 32.78, longitude: -96.80, zoom: -1, held: [Self.at2353, Self.at2338])
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    for request in all {
      let data = try encoder.encode(request)
      #expect(try JSONDecoder().decode(WeatherRequest.self, from: data) == request, "\(request)")
    }
    #expect(String(decoding: try encoder.encode(WeatherRequest.digest), as: UTF8.self)
      == #"{"digest":{}}"#)
    #expect(String(decoding: try encoder.encode(WeatherRequest.forecastForPlace("austin tx")), as: UTF8.self)
      == #"{"forecastForPlace":{"_0":"austin tx"}}"#)
    #expect(String(decoding: try encoder.encode(
      WeatherRequest.areaSweep(includesAdvisories: false, states: ["TX"])), as: UTF8.self)
      == #"{"areaSweep":{"includesAdvisories":false,"states":["TX"]}}"#)
    #expect(String(decoding: try encoder.encode(
      WeatherRequest.parts(group: 212, indexes: [1, 4], of: .text(subject: 3))), as: UTF8.self)
      == #"{"parts":{"group":212,"indexes":[1,4],"of":{"text":{"subject":3}}}}"#)
    #expect(String(decoding: try encoder.encode(
      WeatherRequest.radar(latitude: 30.5, longitude: -97.5, zoom: 2)), as: UTF8.self)
      == #"{"radar":{"latitude":30.5,"longitude":-97.5,"zoom":2}}"#)
    #expect(String(decoding: try encoder.encode(
      WeatherRequest.radarLoop(latitude: 30.5, longitude: -97.5, zoom: -1, held: [Self.at2353])),
      as: UTF8.self)
      == #"{"radarLoop":{"held":[29832473],"latitude":30.5,"longitude":-97.5,"zoom":-1}}"#)
  }

  /// A request log written before revision 13 holds a radar zoom of 0 to 2, which reads the same
  /// as an `Int`.
  @Test
  func `a radar request saved before revision 13 still decodes`() throws {
    let old = Data(#"{"radar":{"latitude":30.27,"longitude":-97.74,"zoom":1}}"#.utf8)
    #expect(try JSONDecoder().decode(WeatherRequest.self, from: old)
      == .radar(latitude: 30.27, longitude: -97.74, zoom: 1))
  }
}
