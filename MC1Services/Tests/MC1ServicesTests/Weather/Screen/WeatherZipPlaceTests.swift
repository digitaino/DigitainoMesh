import CryptoKit
import Foundation
import MeshWX
import Testing

@testable import MC1Services

/// A searched ZIP as the place the screen answers for, and town rows named as the weather bot
/// names places (spec §9.1).
@Suite("Weather ZIP place")
struct WeatherZipPlaceTests {
  @Test func aZipIsASearchedPlaceAtItsOwnPointWithTheBotsLabel() throws {
    let zip = try #require(MeshWXTables.shared.zip("02134"))
    let place = WeatherPlace.zip(zip)
    #expect(place.kind == .searched)
    #expect(place.label == "Allston, MA 02134")
    #expect(place.coordinate == MeshWXCoordinate(latitude: 42.358, longitude: -71.1286))
    #expect(place.uncertaintyKilometres == WeatherPlace.searched(zip.place).uncertaintyKilometres)
  }

  /// A ZIP reads as its town's row does, with the ZIP after it: one rule (spec §9.1) for both.
  @Test func theZipLabelIsTheTownRowWithTheZip() throws {
    let tables = MeshWXTables.shared
    let kitchen = try #require(tables.zip("10019"))
    #expect(kitchen.label == "Hell's Kitchen, NY 10019")
    #expect(WeatherPlace.searched(kitchen.place).label == "Hell's Kitchen, NY")

    let adjuntas = try #require(tables.zip("00601"))
    #expect(adjuntas.label == "Adjuntas, PR 00601")
    #expect(WeatherPlace.searched(adjuntas.place).label == "Adjuntas, PR")

    for code in ["08562", "20010", "00650", "00901", "78701", "96706", "37352"] {
      let zip = try #require(tables.zip(code))
      #expect(zip.label == "\(WeatherPlace.searched(zip.place).label) \(code)")
      #expect(WeatherPlace.zip(zip).zipCode == code)
    }
    #expect(WeatherPlace.searched(adjuntas.place).zipCode == nil)
  }

  /// SHA-256 of the bot's label for every `places.json` entry, in file order, joined by newlines
  /// (`geodata.names.place_label(name, state)`; meshwx `tests/test_place_names.py` pins it too).
  static let botTownLabelsSHA256 = "26c6cde0f481cca8377b5c491117cd89d41c1e2e9f994281419f4553978e150a"

  @Test func everyTownRowReadsAsTheBotNamesIt() {
    let places = MeshWXTables.shared.places
    #expect(places.count == 34_937)
    let labels = places.map { WeatherNames.placeLabel(name: $0.name, state: $0.state) }
    let digest = SHA256.hash(data: Data(labels.joined(separator: "\n").utf8))
    #expect(digest.map { String(format: "%02x", $0) }.joined() == Self.botTownLabelsSHA256)
  }

  /// Town rows the bot's `resolver` names the same way (meshwx `tests/test_place_names.py`).
  @Test(arguments: [
    ("HELL'S KITCHEN", "NY", "Hell's Kitchen, NY"),
    ("CENTRAL 14TH STREET / SPRING ROAD", "DC", "Central 14th Street / Spring Road, DC"),
    ("MCGUIRE AFB", "NJ", "McGuire AFB, NJ"),
    ("ADJUNTAS ZONA URBANA", "PR", "Adjuntas, PR"),
    ("SAN JUAN ZONA URBANA", "PR", "San Juan, PR"),
    ("SAN JUAN", "PR", "San Juan, PR"),
    ("VILLA HUGO II COMUNIDAD", "PR", "Villa Hugo II, PR"),
    ("AUSTIN", "TX", "Austin, TX"),
    ("LA FAYETTE", "AL", "La Fayette, AL"),
    ("DE QUEEN", "AR", "De Queen, AR"),
    ("DOWNTOWN DC", "DC", "Downtown DC, DC"),
    ("BAYOU LA BATRE", "AL", "Bayou La Batre, AL"),
    ("MARINA DEL REY", "CA", "Marina del Rey, CA"),
    ("LAKE OF THE WOODS", "AZ", "Lake of the Woods, AZ"),
    ("MANCHESTER-BY-THE-SEA", "MA", "Manchester-by-the-Sea, MA"),
    ("O'FALLON", "IL", "O'Fallon, IL"),
    ("\u{2018}EWA GENTRY", "HI", "\u{2018}Ewa Gentry, HI"),
    ("OLINDA, CDP", "HI", "Olinda, HI"),
    ("KEARNS METRO TOWNSHIP", "UT", "Kearns, UT"),
    ("NASHVILLE-DAVIDSON METROPOLITAN GOVERNMENT (BALANCE)", "TN", "Nashville-Davidson, TN"),
  ])
  func townRowsReadAsTheBotNamesThem(name: String, state: String, label: String) throws {
    let place = try #require(MeshWXTables.shared.places.first { $0.name == name && $0.state == state })
    #expect(WeatherPlace.searched(place).label == label)
  }
}

/// What the Places search offers a reader: no row that reads exactly like the one above it, and
/// an order they can see (docs/MESHWX_UI.md §3.1 U-22, U-23).
@Suite("Weather place search")
struct WeatherPlaceSearchTests {
  /// The bundle's own San Juan, PR: the municipio and its zona urbana, which spec §9.1 strips, so
  /// both rows read "San Juan, PR" — 7 km apart, and the live search showed both.
  @Test func aTownTheTableHoldsTwiceIsOneRow() throws {
    let tables = MeshWXTables.shared
    let found = tables.searchPlaces(query: "San Juan", limit: 25)
    let labels = found.map { WeatherNames.placeLabel(name: $0.name, state: $0.state) }
    #expect(labels.count(where: { $0 == "San Juan, PR" }) == 2)

    let rows = WeatherPlaceSearch.collapsingDuplicates(found)
    let kept = rows.map { WeatherNames.placeLabel(name: $0.name, state: $0.state) }
    #expect(kept.count(where: { $0 == "San Juan, PR" }) == 1)
    #expect(Set(kept).count == kept.count)
    // The one kept is the table's first, so the ranking still decides which place a tap opens.
    #expect(rows.first?.name == found.first?.name)
    // Every other row survives: collapsing is about rows that read alike, not about trimming.
    #expect(Set(kept) == Set(labels))
  }

  /// Two towns of one name in one state that are genuinely apart are two places.
  @Test func twoTownsOfOneNameFarApartAreBothKept() {
    let near = MeshWXPlace(name: "SPRINGFIELD", state: "TX", lat: 30.0, lon: -97.0, population: 100)
    let far = MeshWXPlace(name: "SPRINGFIELD", state: "TX", lat: 31.0, lon: -97.0, population: 50)
    let close = MeshWXPlace(name: "SPRINGFIELD ZONA URBANA", state: "TX", lat: 30.02, lon: -97.0, population: 0)
    #expect(WeatherPlaceSearch.collapsingDuplicates([near, far]).count == 2)
    #expect(WeatherPlaceSearch.collapsingDuplicates([near, close]).count == 1)
  }

  /// With no fix and no page to measure from, the rows carry no distance: population order is
  /// then an order nobody can read off the screen, so the list goes A to Z instead.
  @Test func withNothingToMeasureFromTheRowsAreAlphabetical() {
    let places = [
      MeshWXPlace(name: "SAN JUAN", state: "PR", lat: 18.46, lon: -66.10, population: 418_140),
      MeshWXPlace(name: "SAN JUAN", state: "TX", lat: 26.18, lon: -98.15, population: 36_556),
      MeshWXPlace(name: "SAN JUAN BAUTISTA", state: "CA", lat: 36.84, lon: -121.53, population: 1_961),
      MeshWXPlace(name: "SAN JUAN", state: "NM", lat: 36.05, lon: -106.06, population: 592)
    ]
    let ordered = WeatherPlaceSearch.ordered(places, hasOrigin: false)
    #expect(ordered.map { WeatherNames.placeLabel(name: $0.name, state: $0.state) }
      == ["San Juan Bautista, CA", "San Juan, NM", "San Juan, PR", "San Juan, TX"])
    // With somewhere to measure from, the table's own ranking is what the distances say, and it
    // is left exactly as it came.
    #expect(WeatherPlaceSearch.ordered(places, hasOrigin: true).map(\.state) == ["PR", "TX", "CA", "NM"])
  }
}
