import CryptoKit
import Foundation
import Testing

@testable import MeshWX

/// US ZIP codes (spec §9 `zips.json`, §11): the bot's own table, looked up and labelled by the
/// label rule of spec §9.1, so a ZIP resolves and reads the same texted to the bot as typed into the app.
///
/// Every expected label here is the bot's (`resolver.resolve(zip)['name']`, asserted by the same
/// table in meshwx `tests/test_place_names.py`), not read off this implementation.
@Suite("MeshWX ZIP codes")
struct MeshWXZipTests {
  let tables = MeshWXTables.shared

  /// SHA-256 of `meshcore_weather/client_data/zips.json` at bot commit 5993383.
  static let botFileSHA256 = "1a1bc0b68b4f2e74e4e02c05092ef0863281b9ee1291d3dc29a67578934c716c"
  /// SHA-256 of the bot's label for every ZIP in the table, in ZIP order, joined by newlines
  /// (`geodata.names.place_label(name, state, zip)`; meshwx `tests/test_place_names.py` pins it too).
  static let botLabelsSHA256 = "f7bed783cf389ba4e2e2a7ab8ea8d83808f635f55a4376f2ca017c7d590c505f"

  static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  @Test func bundledFileIsTheBotsByteForByte() throws {
    let directory = try #require(MeshWXTables.bundledResourceDirectory)
    let data = try Data(contentsOf: directory.appendingPathComponent("zips.json"))
    #expect(data.count == 1_082_771)
    #expect(Self.hex(SHA256.hash(data: data)) == Self.botFileSHA256)
  }

  @Test func tableHasEveryRow() {
    #expect(tables.zipCount == 33_144)
    let codes = tables.zipCodes()
    #expect(codes.first == "00601")
    #expect(codes.allSatisfy { $0.utf8.count == 5 })
  }

  @Test func tableIsReadOnTheFirstZipQueryAndNotBefore() {
    let fresh = MeshWXTables(resourceDirectory: MeshWXTables.bundledResourceDirectory)
    #expect(!fresh.isZipTableLoaded, "loading the tables must not read zips.json")
    _ = fresh.searchPlaces(query: "austin")
    #expect(fresh.zip("Austin") == nil)
    #expect(fresh.zip("7870") == nil)
    #expect(!fresh.isZipTableLoaded, "a query that is not a ZIP must not read it either")
    #expect(fresh.zip("78701")?.label == "Austin, TX 78701")
    #expect(fresh.isZipTableLoaded)
  }

  @Test func coldLookupsFromManyTasksAgree() async {
    let fresh = MeshWXTables(resourceDirectory: MeshWXTables.bundledResourceDirectory)
    let labels = await withTaskGroup(of: String?.self) { group in
      for _ in 0..<8 {
        group.addTask { fresh.zip("78701")?.label }
      }
      var all: [String?] = []
      for await label in group { all.append(label) }
      return all
    }
    #expect(labels.count == 8)
    #expect(labels.allSatisfy { $0 == "Austin, TX 78701" })
    #expect(fresh.zipCount == 33_144)
  }

  @Test func austin() throws {
    let zip = try #require(tables.zip("78701"))
    #expect(zip.code == "78701")
    #expect(zip.lat == 30.2706)
    #expect(zip.lon == -97.7426)
    #expect(zip.placeIndex == 29645)
    #expect(zip.place.name == "AUSTIN")
    #expect(zip.place.state == "TX")
    #expect(zip.label == "Austin, TX 78701")
  }

  @Test func leadingZeroIsKept() throws {
    let zip = try #require(tables.zip("00901"))
    #expect(zip.code == "00901")
    #expect(zip.lat == 18.4654)
    #expect(zip.lon == -66.1046)
    #expect(zip.label == "San Juan, PR 00901")
    #expect(tables.zip("901") == nil)
  }

  @Test func zipPlusFourLooksUpItsFirstFiveDigits() throws {
    let plain = try #require(tables.zip("78701"))
    #expect(tables.zip("78701-1234") == plain)
    #expect(tables.zip(" 78701-1234 ") == plain)
  }

  @Test func zipsNotInTheTableAreUnknown() {
    #expect(tables.zip("99999") == nil)
    #expect(tables.zip("20500") == nil, "the White House: a business ZIP with no ZCTA")
    #expect(tables.zip("20500-0001") == nil)
  }

  @Test func onlyFiveDigitsOrZipPlusFourIsAZip() {
    #expect(MeshWXTables.zipCode(in: "78701") == "78701")
    #expect(MeshWXTables.zipCode(in: " 02134 ") == "02134")
    #expect(MeshWXTables.zipCode(in: "78701-1234") == "78701")
    #expect(MeshWXTables.zipCode(in: "7870") == nil)
    #expect(MeshWXTables.zipCode(in: "787011") == nil)
    #expect(MeshWXTables.zipCode(in: "78701-12") == nil)
    #expect(MeshWXTables.zipCode(in: "78701-") == nil)
    #expect(MeshWXTables.zipCode(in: "78701 1234") == nil)
    #expect(MeshWXTables.zipCode(in: "KAUS") == nil)
    #expect(MeshWXTables.zipCode(in: "TXZ192") == nil)
    #expect(MeshWXTables.zipCode(in: "") == nil)
    // Never by prefix: four digits find nothing, though hundreds of ZIPs start with them.
    #expect(tables.zip("7870") == nil)
  }

  @Test(arguments: [
    ("78701", "Austin, TX 78701"),
    ("00901", "San Juan, PR 00901"),
    ("02134", "Allston, MA 02134"),
    ("00601", "Adjuntas, PR 00601"),  // ADJUNTAS ZONA URBANA
    ("00603", "Caban, PR 00603"),  // CABAN COMUNIDAD
    ("99801", "Juneau, AK 99801"),  // JUNEAU CITY AND
    ("10019", "Hell's Kitchen, NY 10019"),  // 's after a letter stays lower
    ("20010", "Central 14th Street / Spring Road, DC 20010"),  // an ordinal after digits
    ("00650", "Estancias de Florida, PR 00650"),  // ESTANCIAS DE FLORIDA COMUNIDAD: a joining word
    ("08562", "McGuire AFB, NJ 08562"),  // Mc, and an initialism
    ("96706", "\u{2018}Ewa Gentry, HI 96706"),  // a mark starting the word
    ("06461", "Milford, CT 06461"),  // MILFORD CITY (BALANCE)
    ("02138", "West Cambridge/Harvard Square, MA 02138"),
    ("01944", "Manchester-by-the-Sea, MA 01944"),
    ("12930", "St. Regis Falls, NY 12930"),
    ("37352", "Lynchburg, Moore County, TN 37352"),  // … METROPOLITAN GOVERNMENT
    ("10001", "Times Square, NY 10001"),
    ("99501", "Anchorage, AK 99501"),
  ])
  func labelIsTheBots(code: String, label: String) {
    #expect(tables.zip(code)?.label == label)
  }

  @Test func everyLabelIsTheBots() {
    let labels = tables.zipCodes().compactMap { tables.zip($0)?.label }
    #expect(labels.count == 33_144)
    let digest = SHA256.hash(data: Data(labels.joined(separator: "\n").utf8))
    #expect(Self.hex(digest) == Self.botLabelsSHA256)
  }

  /// The spec §9.1 cases, as meshwx `tests/test_place_names.py` asserts them for the bot.
  @Test(arguments: [
    ("HELL'S KITCHEN", "Hell's Kitchen"),
    ("CENTRAL 14TH STREET / SPRING ROAD", "Central 14th Street / Spring Road"),
    ("MCGUIRE AFB", "McGuire AFB"),
    ("VILLA HUGO II COMUNIDAD", "Villa Hugo II"),
    ("DOWNTOWN DC", "Downtown DC"),
    ("H STREET NE", "H Street NE"),
    ("LA GRANGE", "La Grange"),
    ("DE QUEEN", "De Queen"),
    ("VALLEY HI", "Valley Hi"),
    ("TRUTH OR CONSEQUENCES", "Truth or Consequences"),
    ("ADJUNTAS ZONA URBANA", "Adjuntas"),
    ("CABAN COMUNIDAD", "Caban"),
    ("JUNEAU CITY AND", "Juneau"),
    ("OLINDA, CDP", "Olinda"),
    ("MILFORD CITY (BALANCE)", "Milford"),
    ("NASHVILLE-DAVIDSON METROPOLITAN GOVERNMENT (BALANCE)", "Nashville-Davidson"),
    ("LEXINGTON-FAYETTE URBAN COUNTY", "Lexington-Fayette"),
    ("KEARNS METRO TOWNSHIP", "Kearns"),
    ("CAMERON PARK COLONIA", "Cameron Park"),
    ("ESTANCIAS DE FLORIDA COMUNIDAD", "Estancias de Florida"),
    ("PALMAS DEL MAR", "Palmas del Mar"),
    ("BAYOU LA BATRE", "Bayou La Batre"),
    ("DEL RIO", "Del Rio"),
    ("LAKE OF THE WOODS", "Lake of the Woods"),
    ("MANCHESTER-BY-THE-SEA", "Manchester-by-the-Sea"),
    ("O'FALLON", "O'Fallon"),
    ("D'IBERVILLE", "D'Iberville"),
    ("LAND O' LAKES", "Land O' Lakes"),
    ("\u{2018}EWA GENTRY", "\u{2018}Ewa Gentry"),
    ("KAPA\u{2018}A", "Kapa\u{2018}a"),
    ("KO \u{02BB}OLINA-HONOKAI HALE", "Ko \u{02BB}Olina-Honokai Hale"),
    ("round rock", "Round Rock"),
  ])
  func placeNamesFollowTheLabelRule(raw: String, shown: String) {
    #expect(MeshWXPlaceNames.placeName(raw) == shown)
    #expect(MeshWXPlaceNames.placeName(shown) == shown, "any casing in, the same out")
  }

  @Test func titleCasingAloneKeepsSuffixesAndLabelsAddStateAndZip() {
    #expect(MeshWXPlaceNames.titleCased("ADJUNTAS ZONA URBANA") == "Adjuntas Zona Urbana")
    #expect(MeshWXPlaceNames.label(name: "SAN JUAN ZONA URBANA", state: "PR") == "San Juan, PR")
    #expect(MeshWXPlaceNames.label(name: "AUSTIN", state: "TX", zip: "78701") == "Austin, TX 78701")
  }

  @Test func aMissingTableMakesEveryZipUnknown() {
    let empty = MeshWXTables(resourceDirectory: URL(fileURLWithPath: "/nonexistent/meshwx"))
    #expect(empty.zip("78701") == nil)
    #expect(empty.zipCount == 0)
    #expect(empty.isZipTableLoaded, "a failed read is not retried on every keystroke")
  }

  /// The bot drops a row whose place index is past the end of `places`; so does the app.
  @Test func aRowNamingAPlaceTheBundleLacksIsUnknown() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meshwx-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{"places": [["AUSTIN", "TX", 30.2711, -97.7437, 961855]]}"#.utf8)
      .write(to: directory.appendingPathComponent("places.json"))
    try Data(#"{"version": 1, "source": "test", "zips": [["78701", 30.2706, -97.7426, 0], ["78702", 30.2634, -97.7151, 9]]}"#.utf8)
      .write(to: directory.appendingPathComponent("zips.json"))
    let tables = MeshWXTables(resourceDirectory: directory)
    #expect(tables.zip("78701")?.label == "Austin, TX 78701")
    #expect(tables.zip("78702") == nil)
    #expect(tables.zipCount == 2)
  }
}
