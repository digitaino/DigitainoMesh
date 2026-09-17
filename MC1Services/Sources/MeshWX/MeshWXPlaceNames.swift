import Foundation

// MARK: - Place labels (spec §9.1)

/// How a bundle place name is shown: the rule of spec §9.1, which the weather bot's text replies
/// follow too (`meshcore_weather/geodata/names.py`), so a town or a ZIP reads the same texted to
/// the bot as shown in the app: "Hell's Kitchen, NY 10019", "Adjuntas, PR", "McGuire AFB, NJ".
///
/// Works on Unicode scalars, as the bot works on code points: letters are general category L,
/// digits Nd, and case changes are each scalar's full mapping. `MeshWXZipTests` and
/// `WeatherScreenTests` hash every label against the bot's.
public enum MeshWXPlaceNames {
  /// Census legal and statistical descriptors nobody says, removed from the end of a name in this
  /// order, each at most once, with the spaces and commas left in front of them.
  public static let suffixes = [
    " CITY (BALANCE)", " (BALANCE)", " (HISTORICAL)", " (VILLAGE)",
    " CONSOLIDATED GOVERNMENT", " METROPOLITAN GOVERNMENT", " METRO GOVERNMENT",
    " UNIFIED GOVERNMENT", " URBAN COUNTY", " METRO TOWNSHIP",
    " ZONA URBANA", " COMUNIDAD", " COLONIA", " MUNICIPIO", " CDP", " CITY AND", " URBAN",
  ]

  /// Words kept in capitals. State codes are not among them: in place names LA, DE, IN, HI and OR
  /// are words ("La Grange", "De Queen", "Valley Hi"), and DC, the one real code, is listed.
  public static let initialisms: Set<String> = [
    "AFB", "AAF", "ARB", "ANGB", "NAS", "NAF", "NOLF", "MCAS", "USCG", "MCBH", "WMATA",
    "DC", "NE", "NW", "SE", "SW", "VA", "UC", "KC", "II", "III",
  ]

  /// Joining words, lower case anywhere but first: "Lake of the Woods", "Marina del Rey".
  public static let particles: Set<String> = ["OF", "THE", "IN", "ON", "AT", "BY", "AND", "OR", "DE", "DEL", "DU"]

  /// Apostrophes and the Hawaiian ʻokina with its stand-ins: part of a word, not between words.
  static let marks: Set<Unicode.Scalar> = ["'", "\u{2019}", "\u{2018}", "\u{02BB}", "`"]

  /// `"Austin, TX"` for a `places.json` entry; `"Austin, TX 78701"` with a ZIP.
  public static func label(name: String, state: String, zip: String? = nil) -> String {
    let label = "\(placeName(name)), \(state)"
    return zip.map { "\(label) \($0)" } ?? label
  }

  /// `"ADJUNTAS ZONA URBANA"` → `"Adjuntas"`: the suffixes dropped, then ``titleCased(_:keepingUpper:expanding:)``.
  public static func placeName(_ name: String) -> String {
    var scalars = uppercased(name.unicodeScalars)
    for suffix in suffixes {
      let tail = Array(suffix.unicodeScalars)
      guard scalars.count >= tail.count, scalars.suffix(tail.count).elementsEqual(tail) else { continue }
      scalars.removeLast(tail.count)
      while let last = scalars.last, last == " " || last == "," { scalars.removeLast() }
    }
    return titleCased(scalars)
  }

  /// Any casing in, the same out: `"HELL'S KITCHEN"` → "Hell's Kitchen", `"CENTRAL 14TH STREET"` →
  /// "Central 14th Street", `"MCGUIRE AFB"` → "McGuire AFB", `"‘EWA"` → "‘Ewa".
  ///
  /// A word is a run of letters, digits and ``marks``; anything else is kept as it is between words.
  /// A word in `abbreviations` becomes its expansion; one in ``initialisms`` or `keepingUpper` stays
  /// in capitals; one of the ``particles`` after the first word is lower case. Otherwise every letter
  /// is lower case except the first character, the one after a leading "MC", and one right after a
  /// mark that starts the word or follows its one-letter start (O'Fallon).
  ///
  /// Place labels pass nothing extra; station names (MC1Services `WeatherNames`) keep state codes
  /// and expand aviation abbreviations.
  public static func titleCased(
    _ text: String, keepingUpper: Set<String> = [], expanding abbreviations: [String: String] = [:]
  ) -> String {
    titleCased(uppercased(text.unicodeScalars), keepingUpper: keepingUpper, expanding: abbreviations)
  }

  private static func titleCased(
    _ scalars: [Unicode.Scalar], keepingUpper: Set<String> = [], expanding abbreviations: [String: String] = [:]
  ) -> String {
    var result = String.UnicodeScalarView()
    var index = 0
    var isFirstWord = true
    while index < scalars.count {
      guard isWordScalar(scalars[index]) else {
        result.append(scalars[index])
        index += 1
        continue
      }
      var end = index
      while end < scalars.count, isWordScalar(scalars[end]) { end += 1 }
      let word = Array(scalars[index..<end])
      var key = String.UnicodeScalarView()
      key.append(contentsOf: word)
      let upper = String(key)
      if let expanded = abbreviations[upper] {
        result.append(contentsOf: expanded.unicodeScalars)
      } else if initialisms.contains(upper) || keepingUpper.contains(upper) {
        result.append(contentsOf: word)
      } else if !isFirstWord, particles.contains(upper) {
        result.append(contentsOf: lowercased(word))
      } else {
        for (offset, scalar) in word.enumerated() {
          guard isLetter(scalar) else {
            result.append(scalar)
            continue
          }
          let capital = offset == 0
            || (offset == 2 && word[0] == "M" && word[1] == "C")
            || (marks.contains(word[offset - 1]) && (offset == 1 || (offset == 2 && isLetter(word[0]))))
          result.append(contentsOf: capital ? [scalar] : lowercased([scalar]))
        }
      }
      isFirstWord = false
      index = end
    }
    return String(result)
  }

  private static func uppercased(_ scalars: String.UnicodeScalarView) -> [Unicode.Scalar] {
    scalars.flatMap { $0.properties.uppercaseMapping.unicodeScalars }
  }

  private static func lowercased(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
    scalars.flatMap { $0.properties.lowercaseMapping.unicodeScalars }
  }

  private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
    guard !marks.contains(scalar) else { return false }
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
    default: return false
    }
  }

  private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
    marks.contains(scalar) || isLetter(scalar) || scalar.properties.generalCategory == .decimalNumber
  }
}
