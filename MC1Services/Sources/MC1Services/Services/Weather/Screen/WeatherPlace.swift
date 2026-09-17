import Foundation
import MeshWX

/// A phone fix reduced to the values a weather screen compares.
///
/// A value type on purpose: SwiftUI watches it with `onChange`, and a `CLLocation` compares by
/// identity, so a fresh object per read would restart work on every render.
public struct WeatherLocationSample: Sendable, Hashable {
  public var latitude: Double
  public var longitude: Double
  /// Metres; negative when the fix carries no usable accuracy.
  public var horizontalAccuracy: Double
  public var timestamp: Date

  public init(latitude: Double, longitude: Double, horizontalAccuracy: Double, timestamp: Date) {
    self.latitude = latitude
    self.longitude = longitude
    self.horizontalAccuracy = horizontalAccuracy
    self.timestamp = timestamp
  }

  public var coordinate: MeshWXCoordinate {
    MeshWXCoordinate(latitude: latitude, longitude: longitude)
  }
}

/// The one place the Weather screen answers for (docs/MESHWX_UI.md §5).
public struct WeatherPlace: Sendable, Hashable {
  public enum Kind: Sendable, Hashable {
    /// Where the phone is, from a fix no older than an hour.
    case current
    /// Where the phone was: shown with its age and never enough for a "no alerts" claim.
    case lastKnown
    /// A town, ZIP or station the user searched for.
    case searched
  }

  /// What a searched place was found as, so the header says what it is rather than calling
  /// everything a town (docs/MESHWX_UI.md §10). A ZIP says so through `zipCode`.
  public enum SearchedAs: String, Sendable, Hashable, Codable {
    case town
    /// A weather station found by its airport code, named by the town it serves.
    case airportCode
    /// A forecast point held because somebody on the channel asked about it.
    case forecastPoint
  }

  public var kind: Kind
  public var coordinate: MeshWXCoordinate
  /// "Austin, TX".
  public var label: String
  /// How far from `coordinate` the user may really be. An alert that passes within this
  /// distance covers the place.
  public var uncertaintyKilometres: Double
  /// The fix time for a location place.
  public var locatedAt: Date?
  /// The five digits of a searched ZIP ("78701"); nil for any other place.
  public var zipCode: String?
  /// How a searched place was found. Meaningless for a location place.
  public var searchedAs: SearchedAs

  public init(
    kind: Kind,
    coordinate: MeshWXCoordinate,
    label: String,
    uncertaintyKilometres: Double,
    locatedAt: Date? = nil,
    zipCode: String? = nil,
    searchedAs: SearchedAs = .town
  ) {
    self.kind = kind
    self.coordinate = coordinate
    self.label = label
    self.uncertaintyKilometres = uncertaintyKilometres
    self.locatedAt = locatedAt
    self.zipCode = zipCode
    self.searchedAs = searchedAs
  }

  public static let lastKnownAfter: TimeInterval = 60 * 60
  static let freshFixAge: TimeInterval = 5 * 60
  static let maximumDriftKilometres = 25.0
  static let searchedUncertaintyKilometres = 5.0

  /// The place for a phone fix.
  public static func location(_ sample: WeatherLocationSample, label: String, now: Date) -> WeatherPlace {
    let age = max(0, now.timeIntervalSince(sample.timestamp))
    return WeatherPlace(
      kind: age > lastKnownAfter ? .lastKnown : .current,
      coordinate: sample.coordinate,
      label: label,
      uncertaintyKilometres: uncertainty(accuracyMetres: sample.horizontalAccuracy, age: age),
      locatedAt: sample.timestamp
    )
  }

  /// The place for a searched town: its census centre, with a radius a town spans.
  public static func searched(_ place: MeshWXPlace) -> WeatherPlace {
    WeatherPlace(
      kind: .searched,
      coordinate: MeshWXCoordinate(latitude: place.lat, longitude: place.lon),
      label: WeatherNames.placeLabel(name: place.name, state: place.state),
      uncertaintyKilometres: searchedUncertaintyKilometres
    )
  }

  /// The place for a searched ZIP: the ZIP's own point, not its town's, labelled by spec §9.1 as
  /// the weather bot labels it ("Austin, TX 78701"), with a town's radius.
  public static func zip(_ zip: MeshWXZip) -> WeatherPlace {
    WeatherPlace(
      kind: .searched,
      coordinate: MeshWXCoordinate(latitude: zip.lat, longitude: zip.lon),
      label: zip.label,
      uncertaintyKilometres: searchedUncertaintyKilometres,
      zipCode: zip.code
    )
  }

  /// max(accuracy, 0.5 km) + 1 km for each minute of age past five, capped at 25 km.
  ///
  /// A kilometre a minute is someone driving. For someone walking it over-includes a
  /// neighbouring county, and the cost of that is being shown an alert close enough to be
  /// worth seeing — the cheap side of the error.
  static func uncertainty(accuracyMetres: Double, age: TimeInterval) -> Double {
    let accuracy = accuracyMetres >= 0 ? accuracyMetres / 1000 : 1
    let drift = min(max(0, age - freshFixAge) / 60, maximumDriftKilometres)
    return max(accuracy, 0.5) + drift
  }
}

// MARK: - Saved places

/// A place the user keeps in Places, held across visits to the tool (docs/MESHWX_UI.md §5).
///
/// Not a `WeatherPlace`: what is worth keeping is what the user chose — a town, a ZIP, a station
/// found by its airport code — while the kind and the uncertainty radius are the screen's
/// business and are read back from `place`. The tool still opens on the phone's own location;
/// these are the places one tap away from it.
public struct WeatherSavedPlace: Sendable, Hashable, Codable, Identifiable {
  /// "Round Rock, TX", as the header shows it.
  public var label: String
  public var latitude: Double
  public var longitude: Double
  /// The five digits of a saved ZIP, as `WeatherPlace.zipCode`.
  public var zipCode: String?
  public var searchedAs: WeatherPlace.SearchedAs
  /// The wire index of the station an airport-code place was found by: its row opens that
  /// station's screen rather than a town of the same name (docs/MESHWX_UI.md §12).
  public var stationIndex: UInt16?
  /// When it was last chosen. Newest first in the sheet.
  public var chosenAt: Date
  /// The bell is on: a warning covering this place notifies (docs/MESHWX_UI.md §16). Off for
  /// every place until the user turns it on — nothing is watched by being saved.
  public var isWatched: Bool

  public init(
    label: String,
    latitude: Double,
    longitude: Double,
    zipCode: String? = nil,
    searchedAs: WeatherPlace.SearchedAs = .town,
    stationIndex: UInt16? = nil,
    chosenAt: Date,
    isWatched: Bool = false
  ) {
    self.label = label
    self.latitude = latitude
    self.longitude = longitude
    self.zipCode = zipCode
    self.searchedAs = searchedAs
    self.stationIndex = stationIndex
    self.chosenAt = chosenAt
    self.isWatched = isWatched
  }

  private enum CodingKeys: String, CodingKey {
    case label, latitude, longitude, zipCode, searchedAs, stationIndex, chosenAt, isWatched
  }

  /// A list written before bells existed reads as saved places with none on, rather than not
  /// reading at all.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    label = try container.decode(String.self, forKey: .label)
    latitude = try container.decode(Double.self, forKey: .latitude)
    longitude = try container.decode(Double.self, forKey: .longitude)
    zipCode = try container.decodeIfPresent(String.self, forKey: .zipCode)
    searchedAs = try container.decode(WeatherPlace.SearchedAs.self, forKey: .searchedAs)
    stationIndex = try container.decodeIfPresent(UInt16.self, forKey: .stationIndex)
    chosenAt = try container.decode(Date.self, forKey: .chosenAt)
    isWatched = try container.decodeIfPresent(Bool.self, forKey: .isWatched) ?? false
  }

  public var coordinate: MeshWXCoordinate {
    MeshWXCoordinate(latitude: latitude, longitude: longitude)
  }

  /// One row per place, whichever way it was found: a town picked from a search and the same
  /// town picked from the channel's suggestions are one saved place, and picking it again only
  /// moves it up. Coordinates are rounded to about 100 m, finer than any of these sources.
  public var id: String {
    if let zipCode { return "zip:\(zipCode)" }
    if let stationIndex { return "station:\(stationIndex)" }
    return String(format: "at:%.3f,%.3f", latitude, longitude)
  }

  /// The place the screen answers for.
  public var place: WeatherPlace {
    WeatherPlace(
      kind: .searched,
      coordinate: coordinate,
      label: label,
      uncertaintyKilometres: WeatherPlace.searchedUncertaintyKilometres,
      zipCode: zipCode,
      searchedAs: searchedAs)
  }

  public static func from(
    _ place: WeatherPlace,
    stationIndex: UInt16? = nil,
    at chosenAt: Date,
    isWatched: Bool = false
  ) -> WeatherSavedPlace {
    WeatherSavedPlace(
      label: place.label,
      latitude: place.coordinate.latitude,
      longitude: place.coordinate.longitude,
      zipCode: place.zipCode,
      searchedAs: place.searchedAs,
      stationIndex: stationIndex,
      chosenAt: chosenAt,
      isWatched: isWatched)
  }
}

/// The saved list's rules (docs/MESHWX_UI.md §5): a new place first, one row per place, and a
/// ceiling so the sheet stays a list of places rather than a history of taps.
///
/// The list's own order is the order: it is what the Places sheet shows and what the pager swipes
/// through (`WeatherPages`), and a drag in Places rewrites it. A place picked from a search goes
/// to the front; nothing else moves on its own — reordering the pages under a swiping finger is
/// exactly what a "newest first" sort would do.
public enum WeatherSavedPlaces {
  public static let limit = 12

  /// The list with this place in it.
  ///
  /// A place the list does not hold goes to the **front**; a place it already holds **stays where
  /// it is**. Picking Round Rock out of Places to look at it is not a request to reorder the
  /// pager: the row the user tapped would slide to the front under their finger and the dots
  /// would stop meaning what they meant a moment ago. Order is the user's, from a drag and from
  /// nothing else (docs/MESHWX_UI.md §3.1 U-4).
  ///
  /// Picking a place again keeps its bell: the row being replaced is the same place, and choosing
  /// it from a search must not quietly stop watching it.
  public static func remember(_ place: WeatherSavedPlace, in list: [WeatherSavedPlace]) -> [WeatherSavedPlace] {
    var chosen = place
    if let existing = list.first(where: { $0.id == place.id }) {
      // Its bell and its place in the order both survive being picked again; the label and the
      // time it was last chosen are refreshed, because both of those are about this tap.
      chosen.isWatched = existing.isWatched
      return ordered(list.map { $0.id == chosen.id ? chosen : $0 })
    }
    return ordered([chosen] + list)
  }

  /// One change to the saved list, as a value.
  ///
  /// Every change is described rather than computed by the caller, so it can be applied to the
  /// list **the store actually holds** rather than to whatever the screen was last shown. A model
  /// that writes its own copy overwrites everything saved since it was loaded, which is how four
  /// saved places became one (docs/MESHWX_UI.md §3.1 U-1).
  public enum Edit: Equatable {
    /// A place picked in Places: added at the front, or left where it is if it is already held.
    case remember(WeatherSavedPlace)
    case remove(id: String)
    /// The order a drag produced, by id. Ids rather than indexes: the store's list may hold a
    /// place this screen never saw, and an index would then move the wrong row.
    case reorder(ids: [String])
    case watch(Bool, id: String)

    /// Whether the edit can make the list longer, and so let the ceiling push a row off the end.
    var adds: Bool {
      if case .remember = self { return true }
      return false
    }

    /// The one id this edit asks to be dropped.
    var removedID: String? {
      if case let .remove(id) = self { return id }
      return nil
    }
  }

  public static func apply(_ edit: Edit, to list: [WeatherSavedPlace]) -> [WeatherSavedPlace] {
    switch edit {
    case let .remember(place): remember(place, in: list)
    case let .remove(id): removing(id, from: list)
    case let .reorder(ids): ordering(ids: ids, in: list)
    case let .watch(isOn, id): setting(watched: isOn, id: id, in: list)
    }
  }

  /// The list in the order these ids name. A place the ids do not name keeps its own order at the
  /// end: it was saved after the drag began, and a reorder is not a removal.
  public static func ordering(ids: [String], in list: [WeatherSavedPlace]) -> [WeatherSavedPlace] {
    var remaining = list
    var ordered: [WeatherSavedPlace] = []
    for id in ids {
      guard let index = remaining.firstIndex(where: { $0.id == id }) else { continue }
      ordered.append(remaining.remove(at: index))
    }
    return ordered + remaining
  }

  /// The places in `loaded` that `updated` no longer holds.
  ///
  /// The list is the only record of what the user chose, and a place lost from it is lost for
  /// good, so a write that drops one nobody asked to drop is refused rather than applied
  /// (``WeatherSavedPlacesStore/apply(_:)``).
  public static func dropped(_ updated: [WeatherSavedPlace], from loaded: [WeatherSavedPlace]) -> Set<String> {
    let after = Set(updated.map(\.id))
    return Set(loaded.map(\.id)).subtracting(after)
  }

  /// The list after a drag in Places. Order is the user's from here on, and the pager follows it.
  ///
  /// `destination` is `onMove`'s: the index the rows land *before*, counted in the list as it was.
  /// The move is written out here rather than taken from SwiftUI's `move(fromOffsets:toOffset:)`
  /// so the rule stays in the layer that is tested on macOS.
  public static func moving(
    fromOffsets source: IndexSet,
    toOffset destination: Int,
    in list: [WeatherSavedPlace]
  ) -> [WeatherSavedPlace] {
    let indexes = source.filter { list.indices.contains($0) }
    guard !indexes.isEmpty else { return list }
    let picked = indexes.map { list[$0] }
    var moved = list
    for index in indexes.sorted(by: >) {
      moved.remove(at: index)
    }
    let landing = max(0, min(destination - indexes.count { $0 < destination }, moved.count))
    moved.insert(contentsOf: picked, at: landing)
    return moved
  }

  public static func removing(_ id: String, from list: [WeatherSavedPlace]) -> [WeatherSavedPlace] {
    list.filter { $0.id != id }
  }

  /// The list with one place's bell turned on or off. Removing the place removes the watch with
  /// it: they are one row.
  ///
  /// Nothing is trimmed here. A bell adds no row, so there is nothing for the ceiling to make
  /// room for, and turning one on must never take a page out from under the pager — least of all
  /// the page the tap came from.
  public static func setting(
    watched: Bool,
    id: String,
    in list: [WeatherSavedPlace]
  ) -> [WeatherSavedPlace] {
    list.map { place in
      guard place.id == id else { return place }
      var updated = place
      updated.isWatched = watched
      return updated
    }
  }

  /// The list as given, cut to the ceiling from the end.
  ///
  /// A watched place never falls off: the ceiling is there so the sheet stays a list of places,
  /// and dropping one the user asked to be warned about — silently, because they searched for
  /// twelve towns — is not what it is for. The newest pick is always kept too, so choosing a town
  /// always shows it.
  public static func ordered(_ list: [WeatherSavedPlace]) -> [WeatherSavedPlace] {
    var room = max(limit - list.count(where: \.isWatched), 1)
    return list.filter { place in
      if place.isWatched { return true }
      guard room > 0 else { return false }
      room -= 1
      return true
    }
  }
}

// MARK: - The search rows (§12, §3.1 U-22, U-23)

/// What the Places search offers, once the table has answered (docs/MESHWX_UI.md §12).
///
/// `MeshWXTables.searchPlaces` finds the names; these two rules decide what a reader is actually
/// shown. Both came out of one live search for "San Juan": six rows, the first and the last both
/// reading "San Juan, PR", none of them carrying a distance and the order between them one only
/// the table could see.
public enum WeatherPlaceSearch {
  /// A town of one name and one state, twice, this close together is the table's own doubling and
  /// not two places.
  public static let duplicateWithinKilometres: Double = 15

  /// Two rows that read the same word for word are one row.
  ///
  /// `places.json` carries San Juan, PR as both the municipio and its zona urbana, 7 km apart,
  /// and spec §9.1 drops "ZONA URBANA" from the second: the search offered "San Juan, PR" twice,
  /// with nothing on either row to choose by. The first is kept, so the table's own ranking —
  /// nearest, then biggest — still decides which coordinate a tap opens. Only a near neighbour is
  /// folded in: two towns of one name in one state that are genuinely apart are two places, and
  /// both belong on the list.
  public static func collapsingDuplicates(_ places: [MeshWXPlace]) -> [MeshWXPlace] {
    var kept: [MeshWXPlace] = []
    for place in places {
      let label = WeatherNames.placeLabel(name: place.name, state: place.state)
      let isDouble = kept.contains {
        WeatherNames.placeLabel(name: $0.name, state: $0.state) == label
          && MeshWXGeo.distanceKilometres(fromLat: $0.lat, lon: $0.lon, toLat: place.lat, lon: place.lon)
            <= duplicateWithinKilometres
      }
      if !isDouble { kept.append(place) }
    }
    return kept
  }

  /// The rows in the order they are shown.
  ///
  /// The table ranks by distance when it has somewhere to measure from, and the rows say that
  /// distance, so that order is one the reader can see. With nothing to measure from the rows
  /// carry no distance either, and the table's fallback — biggest first — is an order nobody can
  /// read off the screen. A to Z is.
  public static func ordered(_ places: [MeshWXPlace], hasOrigin: Bool) -> [MeshWXPlace] {
    let ordered = hasOrigin ? places : places.sorted {
      WeatherNames.placeLabel(name: $0.name, state: $0.state)
        < WeatherNames.placeLabel(name: $1.name, state: $1.state)
    }
    return collapsingDuplicates(ordered)
  }
}
