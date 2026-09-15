import Foundation
import MeshWX

/// Turning the bundle's names into words a person reads (docs/MESHWX_UI.md §3 A12).
///
/// The tables are NOAA's: station names in capitals with aviation abbreviations
/// ("DRAUGHON-MILLER CNTRL TX RGNL ARPT"), forecast points with a county and state stuck on
/// the end ("Austin Camp Mabry-Travis TX"), census places in capitals.
public enum WeatherNames {
  static let stateCodes: Set<String> = [
    "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA", "HI", "ID", "IL", "IN", "IA", "KS",
    "KY", "LA", "ME", "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ", "NM", "NY",
    "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV",
    "WI", "WY", "DC", "PR", "VI", "GU", "AS", "MP"
  ]

  /// Words that stay in capitals: military field designators and similar initialisms.
  static let initialisms: Set<String> = ["AFB", "AAF", "ARB", "ANGB", "NAS", "NAF", "NOLF", "MCAS", "USCG", "II", "III"]

  static let stationAbbreviations: [String: String] = [
    "ARPT": "Airport", "AIRPT": "Airport", "AP": "Airport",
    "INTL": "International", "RGNL": "Regional", "REGL": "Regional", "CNTRL": "Central",
    "MUNI": "Municipal", "MEM": "Memorial", "FLD": "Field", "CNTY": "County", "MTN": "Mountain",
    "FT": "Fort", "ST": "St"
  ]

  /// Capitals to title case, word by word, keeping state codes and initialisms as they are.
  /// A name already in mixed case is left alone: it was not the bundle's to shout.
  public static func titleCased(_ raw: String, expanding abbreviations: [String: String] = [:]) -> String {
    guard raw == raw.uppercased() else { return raw }
    var result = ""
    var word = ""
    func flush() {
      guard !word.isEmpty else { return }
      let upper = word.uppercased()
      if let expanded = abbreviations[upper] {
        result += expanded
      } else if (upper.count == 2 && stateCodes.contains(upper)) || initialisms.contains(upper) {
        result += upper
      } else {
        result += upper.prefix(1) + upper.dropFirst().lowercased()
      }
      word = ""
    }
    for character in raw {
      if character.isLetter || character.isNumber || character == "'" {
        word.append(character)
      } else {
        flush()
        result.append(character)
      }
    }
    flush()
    return result
  }

  /// "DRAUGHON-MILLER CNTRL TX RGNL ARPT" → "Draughon-Miller Central TX Regional Airport".
  public static func stationName(_ raw: String) -> String {
    titleCased(raw, expanding: stationAbbreviations)
  }

  /// "Austin Camp Mabry-Travis TX" → "Austin Camp Mabry". A name without the county-and-state
  /// tail ("…Airport-San Juan") is returned as it is.
  public static func pointName(_ raw: String) -> String {
    guard let dash = raw.lastIndex(of: "-") else { return raw }
    let tail = raw[raw.index(after: dash)...].split(separator: " ")
    guard tail.count >= 2, let last = tail.last, last.count == 2, stateCodes.contains(String(last)) else {
      return raw
    }
    let head = raw[..<dash].trimmingCharacters(in: .whitespaces)
    return head.isEmpty ? raw : head
  }

  /// "ROUND ROCK", "TX" → "Round Rock, TX".
  public static func placeLabel(name: String, state: String) -> String {
    "\(titleCased(name)), \(state)"
  }

  /// The label for a coordinate: the nearest place of any size worth naming within 25 km.
  public static func placeLabel(near coordinate: MeshWXCoordinate, tables: MeshWXTables) -> String? {
    tables.nearestPlace(toLat: coordinate.latitude, lon: coordinate.longitude)
      .map { placeLabel(name: $0.name, state: $0.state) }
  }
}
