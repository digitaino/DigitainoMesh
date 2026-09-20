import Foundation
@testable import MC1Services
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
      (.areaSweep(includesAdvisories: false), ">wmap"),
      (.areaSweep(includesAdvisories: true), ">wmap all")
    ]
    for (request, text) in expected {
      #expect(request.wireText == text)
    }
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
    #expect(WeatherRequest.areaSweep(includesAdvisories: false).requestLetter == "w")
    #expect(WeatherRequest.areaSweep(includesAdvisories: true).requestLetter == "w")
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
    #expect(!WeatherRequest.areaSweep(includesAdvisories: false).acceptsAnswerFromAnyBot)
    #expect(!WeatherRequest.areaSweep(includesAdvisories: true).acceptsAnswerFromAnyBot)
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
    #expect(WeatherRequest.areaSweep(includesAdvisories: false).expectedReply == .areaSweep)
    #expect(WeatherRequest.areaSweep(includesAdvisories: true).expectedReply == .areaSweep)
  }

  /// Two scopes are two requests: one on the air must not settle the other's button, and the
  /// request log has to be able to say which one was asked for.
  @Test
  func `the two map scopes are distinct requests`() {
    #expect(WeatherRequest.areaSweep(includesAdvisories: false)
      != WeatherRequest.areaSweep(includesAdvisories: true))
  }
}
