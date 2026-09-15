import Foundation
import MC1Services
import MeshWX
import Testing

@testable import MC1

/// Asking again for a text reply that arrived with a hole in it (spec §8.1).
///
/// The hard part is that a reply names only its subject: "storm reports" does not say which
/// state was asked for, and re-sending `>storm` without one is a Not-available message and
/// wasted airtime. So the mapping is subject → request only where the subject *is* the whole
/// request; everything else comes from what the app last sent.
@Suite("Weather text requests")
struct WeatherTextRequestsTests {

  // MARK: - Subjects that are their own request

  @Test
  func `space weather and the outlook need no argument`() {
    #expect(WeatherTextRequests.subjectOnlyRequest(for: .spaceWeather) == .spaceWeather)
    #expect(WeatherTextRequests.subjectOnlyRequest(for: .hazardousOutlook) == .hazardousOutlook)
  }

  @Test
  func `subjects that name something have no request of their own`() {
    let needArguments: [MeshWXTextSubject] = [
      .warningNarrative, .forecastDiscussion, .stormReports, .rainfall, .metarOrTAF,
    ]
    for subject in needArguments {
      #expect(WeatherTextRequests.subjectOnlyRequest(for: subject) == nil)
    }
  }

  // MARK: - Recovering the argument

  @Test
  func `a remembered request supplies the station a METAR needs`() {
    let remembered: [UInt8: WeatherRequest] = [
      MeshWXTextSubject.metarOrTAF.rawValue: .metar(station: "KAUS")
    ]
    #expect(
      WeatherTextRequests.repeatRequest(for: .metarOrTAF, lastRequests: remembered)
        == .metar(station: "KAUS")
    )
  }

  @Test
  func `a remembered request supplies the state storm reports need`() {
    let remembered: [UInt8: WeatherRequest] = [
      MeshWXTextSubject.stormReports.rawValue: .stormReports(state: "TX")
    ]
    #expect(
      WeatherTextRequests.repeatRequest(for: .stormReports, lastRequests: remembered)
        == .stormReports(state: "TX")
    )
  }

  /// Nothing remembered and nothing derivable means no button, rather than a request the bot
  /// will decline.
  @Test
  func `an unremembered argument request cannot be repeated`() {
    #expect(WeatherTextRequests.repeatRequest(for: .rainfall, lastRequests: [:]) == nil)
    #expect(WeatherTextRequests.repeatRequest(for: .forecastDiscussion, lastRequests: [:]) == nil)
  }

  @Test
  func `a subject that is its own request survives an empty memory`() {
    #expect(WeatherTextRequests.repeatRequest(for: .spaceWeather, lastRequests: [:]) == .spaceWeather)
  }

  /// A TAF and a METAR share subject 5, so what was last asked for decides which comes back —
  /// the subject alone would always re-send the METAR.
  @Test
  func `memory wins over the subject default`() {
    let remembered: [UInt8: WeatherRequest] = [
      MeshWXTextSubject.metarOrTAF.rawValue: .taf(station: "KAUS")
    ]
    #expect(
      WeatherTextRequests.repeatRequest(for: .metarOrTAF, lastRequests: remembered)
        == .taf(station: "KAUS")
    )
  }

  // MARK: - The key the memory is stored under

  /// The model files a sent request under the subject code its reply will carry. If those two
  /// tables ever drift, "ask again" would look up an empty slot and silently do nothing.
  @Test
  func `every text request expects the subject its reply is filed under`() {
    let pairs: [(WeatherRequest, MeshWXTextSubject)] = [
      (.warningText(identity: "SV.W.EWX.42"), .warningNarrative),
      (.forecastDiscussion(office: "EWX"), .forecastDiscussion),
      (.spaceWeather, .spaceWeather),
      (.stormReports(state: "TX"), .stormReports),
      (.rainfall(state: "TX"), .rainfall),
      (.metar(station: "KAUS"), .metarOrTAF),
      (.taf(station: "KAUS"), .metarOrTAF),
      (.hazardousOutlook, .hazardousOutlook),
    ]
    for (request, subject) in pairs {
      guard case let .text(code) = request.expectedReply else {
        Issue.record("\(request.wireText) does not expect a text reply")
        continue
      }
      #expect(code == subject.rawValue)
    }
  }
}
