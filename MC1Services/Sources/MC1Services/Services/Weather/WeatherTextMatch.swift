import Foundation
import MeshWX

/// Whether a text reply is the answer to one particular request.
///
/// A text chunk carries its subject and nothing else (spec §8.1): somebody else's `>storm OK`, a
/// TAF when this phone asked for the METAR (both are subject 5), or another warning's narrative
/// all arrive looking like the reply this phone is waiting for. The request's argument has to be
/// read back out of the words, and a reply that does not show it neither settles the request nor
/// becomes this phone's.
///
/// The keys, per request, as far as the kit shows the bot's wording (vector
/// `text_warning_narrative_chunk0`, and the bot's human `metar` / `taf` replies):
/// - `>metar KAUS`: the first chunk opens as a METAR (`METAR`, `SPECI`, or the station followed by
///   a `DDHHMMZ` time) and names the station in its first words.
/// - `>taf KAUS`: the first chunk opens with `TAF` and names the station in its first words.
/// - `>wt SV.W.EWX.42`: the first chunk names the event ("SEVERE THUNDERSTORM WARNING"), and when
///   the warning is held with named areas, the text names one of them. The text carries neither
///   the office nor the tracking number.
/// - `>storm TX`, `>rain TX`: the state code as an upper-case word. The kit has no sample of
///   either reply, so this is a best guess (docs/MESHWX_UI.md §14).
/// - `>afd`, `>space`, `>hwo`: the subject alone. Space weather and the outlook take no argument;
///   the discussion's office has no key the kit shows.
///
/// Evaluated on every chunk against everything received so far, so a reply whose key lies in a
/// chunk that arrives later settles when that chunk does.
enum WeatherTextMatch {
  static func matches(
    _ request: WeatherRequest,
    assembly: WeatherTextAssembly,
    states: [UInt16: WeatherBotState],
    tables: MeshWXTables
  ) -> Bool {
    guard case let .text(subject) = request.expectedReply, assembly.subject.rawValue == subject else {
      return false
    }
    switch request {
    case let .metar(station):
      guard let lead = leadWords(assembly) else { return false }
      let station = station.uppercased()
      let opensAsMETAR = lead.first == "METAR" || lead.first == "SPECI"
        || (lead.first == station && lead.dropFirst().first.map(isObservationTime) == true)
      return opensAsMETAR && lead.prefix(3).contains(station)

    case let .taf(station):
      guard let lead = leadWords(assembly) else { return false }
      return lead.first == "TAF" && lead.contains(station.uppercased())

    case let .warningText(identityString):
      guard let identity = WeatherAlertRequests.identity(from: identityString, tables: tables),
            let eventName = tables.eventName(for: identity.event)?.long,
            let lead = assembly.chunks[0],
            containsWord(eventName, in: lead, caseInsensitive: true)
      else { return false }
      let areaNames = heldWarning(identity, in: states).map { tables.namedAreas(for: $0).compactMap(\.name) } ?? []
      guard !areaNames.isEmpty else { return true }
      let text = joinedText(assembly)
      return areaNames.contains { containsWord($0, in: text, caseInsensitive: true) }

    case let .stormReports(state), let .rainfall(state):
      return containsWord(state.uppercased(), in: joinedText(assembly), caseInsensitive: false)

    default:
      return true
    }
  }

  /// The warning an identity names, from whichever bot holds it (lowest bot id first, so the
  /// answer does not depend on dictionary order), or the upgrade marker it left.
  static func heldWarning(_ identity: MeshWXWarningIdentity, in states: [UInt16: WeatherBotState]) -> MeshWXWarning? {
    let botIDs = states.keys.sorted()
    if let held = botIDs.lazy.compactMap({ states[$0]?.warnings[identity] }).first { return held.warning }
    return botIDs.lazy.compactMap { states[$0]?.pendingUpgrades[identity] }.first?.warning
  }

  /// The first four words of chunk 0, upper-cased; nil until chunk 0 has arrived.
  private static func leadWords(_ assembly: WeatherTextAssembly) -> [String]? {
    assembly.chunks[0].map { lead in
      lead.uppercased().split(whereSeparator: \.isWhitespace).prefix(4).map(String.init)
    }
  }

  /// `150051Z`: a METAR's day-hour-minute group.
  private static func isObservationTime(_ word: String) -> Bool {
    let digits = word.dropLast()
    return word.count == 7 && word.hasSuffix("Z") && digits.allSatisfy { $0.isASCII && $0.isNumber }
  }

  /// The chunks received so far in order. Neighbouring chunks join directly — the bot splits on
  /// bytes, mid-word — and a missing chunk becomes a space so its neighbours cannot fuse into a
  /// word neither contains.
  static func joinedText(_ assembly: WeatherTextAssembly) -> String {
    (0..<assembly.total).map { assembly.chunks[$0] ?? " " }.joined()
  }

  static func containsWord(_ word: String, in text: String, caseInsensitive: Bool) -> Bool {
    let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: word) + "(?![A-Za-z0-9])"
    var options: String.CompareOptions = [.regularExpression]
    if caseInsensitive { options.insert(.caseInsensitive) }
    return text.range(of: pattern, options: options) != nil
  }
}
