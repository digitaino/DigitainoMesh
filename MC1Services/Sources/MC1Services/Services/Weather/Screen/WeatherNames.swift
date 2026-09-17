import Foundation
import MeshWX

/// Turning the bundle's names into words a person reads (docs/MESHWX_UI.md §3 A12).
///
/// The tables are NOAA's: station names in capitals with aviation abbreviations
/// ("DRAUGHON-MILLER CNTRL TX RGNL ARPT"), forecast points with a county and state stuck on
/// the end ("Austin Camp Mabry-Travis TX"), census places in capitals. Places follow spec §9.1
/// (``MeshWXPlaceNames``), the weather bot's rule; station names add state codes and abbreviations.
public enum WeatherNames {
  static let stateCodes: Set<String> = [
    "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA", "HI", "ID", "IL", "IN", "IA", "KS",
    "KY", "LA", "ME", "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ", "NM", "NY",
    "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV",
    "WI", "WY", "DC", "PR", "VI", "GU", "AS", "MP"
  ]

  static let stationAbbreviations: [String: String] = [
    "ARPT": "Airport", "AIRPT": "Airport", "AP": "Airport",
    "INTL": "International", "RGNL": "Regional", "REGL": "Regional", "CNTRL": "Central",
    "MUNI": "Municipal", "MEM": "Memorial", "FLD": "Field", "CNTY": "County", "MTN": "Mountain",
    "FT": "Fort", "ST": "St"
  ]

  /// Capitals to title case by the place rule's word casing (``MeshWXPlaceNames``), keeping state
  /// codes in capitals too, as station names carry them ("CNTRL TX RGNL ARPT").
  /// A name already in mixed case is left alone: it was not the bundle's to shout.
  public static func titleCased(_ raw: String, expanding abbreviations: [String: String] = [:]) -> String {
    guard raw == raw.uppercased() else { return raw }
    return MeshWXPlaceNames.titleCased(raw, keepingUpper: stateCodes, expanding: abbreviations)
  }

  /// A `places.json` name as shown (spec §9.1): "ADJUNTAS ZONA URBANA" → "Adjuntas".
  public static func placeName(_ raw: String) -> String {
    MeshWXPlaceNames.placeName(raw)
  }

  /// **The one function a bundle name is shown through** (docs/MESHWX_UI.md §3.1 U-25, U-26).
  ///
  /// One site read "Austin-Camp Mabry", the next "Austin Camp Mabry" and the third "Austin Camp
  /// Mabry, TX", because three call sites each did their own tidying. Every name on screen comes
  /// through here now, and `qualified` is the **only** thing that varies: whether the bundle's
  /// trailing "-…" is a qualifier this name can be shown without.
  ///
  /// It has to vary, because the two tables mean opposite things by a hyphen. A station's is part
  /// of its name — "OCALA INTERNATIONAL AIRPORT-JIM TAYLOR FIELD", "AUSTIN-BERGSTROM INTL
  /// AIRPORT" — and 81 of the 205 hyphenated station names would lose half of themselves to the
  /// point rule. A forecast point's hyphen always separates the name from where it is.
  ///
  /// The casing is judged on the **whole** name, before any tail comes off: "351001
  /// (PATJENS)-Sherman OR" is a mixed-case name the bundle did not shout, and stripping first
  /// would leave an all-capitals head to be title-cased into "351001 (Patjens)".
  ///
  /// - Parameter qualified: the name carries a bundle qualifier after a hyphen (a forecast point).
  static func displayName(_ raw: String, qualified: Bool) -> String {
    let cased = titleCased(raw, expanding: stationAbbreviations)
    return qualified ? withoutQualifier(cased) : cased
  }

  /// "DRAUGHON-MILLER CNTRL TX RGNL ARPT" → "Draughon-Miller Central TX Regional Airport".
  public static func stationName(_ raw: String) -> String {
    displayName(raw, qualified: false)
  }

  /// A forecast point's name without the bundle's tail: "Austin Camp Mabry-Travis TX" → "Austin
  /// Camp Mabry", "Luis Munoz Marin International Airport-San Juan" → "Luis Munoz Marin
  /// International Airport".
  ///
  /// Internal on purpose: a point is **shown** by ``pointLabel(_:)``, which keeps the state on, so
  /// no screen can show the bare head while its neighbour shows the labelled one.
  static func pointName(_ raw: String) -> String {
    displayName(raw, qualified: true)
  }

  /// "Austin Camp Mabry, TX" — **the way a forecast point is named**, everywhere one is named:
  /// the forecast header, the Places rows for what was heard on the channel, and the empty
  /// place's "nearest forecast point" line (docs/MESHWX_UI.md §3.1 U-25). The state stays on for
  /// the reason a place's does (`WeatherFormatting.placeName`): it is what tells two of them
  /// apart. A point whose tail is a town, not a state, is left with its name alone.
  public static func pointLabel(_ raw: String) -> String {
    let name = pointName(raw)
    guard let state = pointState(raw) else { return name }
    return "\(name), \(state)"
  }

  /// A forecast point's state from its bundle name, "Austin Camp Mabry-Travis TX" → "TX".
  public static func pointState(_ raw: String) -> String? {
    guard raw.contains("-"), let last = raw.split(separator: " ").last, last.count == 2,
          last.allSatisfy({ $0.isUppercase && $0.isLetter }) else { return nil }
    return String(last)
  }

  /// The bundle's tail on a forecast point's name, dropped once: a county and state ("-Travis
  /// TX"), or the town the point is named for ("-San Juan"). The town form is only a qualifier
  /// when the head is a name on its own — more than one word — so a point called "Boerne-Kendall
  /// TX" keeps its county rule and one called "Foo-Bar" keeps its name.
  static func withoutQualifier(_ raw: String) -> String {
    guard let dash = raw.lastIndex(of: "-") else { return raw }
    let head = raw[..<dash].trimmingCharacters(in: .whitespaces)
    let tail = raw[raw.index(after: dash)...].trimmingCharacters(in: .whitespaces)
    guard !head.isEmpty, !tail.isEmpty else { return raw }
    let words = tail.split(separator: " ")
    let isCountyAndState = words.count >= 2 && words[words.count - 1].count == 2
      && stateCodes.contains(String(words[words.count - 1]))
    guard isCountyAndState || head.contains(" ") else { return raw }
    return head
  }

  /// "ROUND ROCK", "TX" → "Round Rock, TX"; "HELL'S KITCHEN", "NY" → "Hell's Kitchen, NY" (spec §9.1).
  public static func placeLabel(name: String, state: String) -> String {
    MeshWXPlaceNames.label(name: name, state: state)
  }

  /// The label for a coordinate: the nearest place of any size worth naming within 25 km.
  public static func placeLabel(near coordinate: MeshWXCoordinate, tables: MeshWXTables) -> String? {
    tables.nearestPlace(toLat: coordinate.latitude, lon: coordinate.longitude)
      .map { placeLabel(name: $0.name, state: $0.state) }
  }
}
