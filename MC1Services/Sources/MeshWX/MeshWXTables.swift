import Foundation
import OSLog

// MARK: - Table records

/// A METAR station (`stations.json`).
public struct MeshWXStation: Sendable, Hashable, Codable {
  public let icao: String
  public let name: String
  public let state: String
  public let lat: Double
  public let lon: Double
}

/// A PFM forecast point (`pfm_points.json`). ``index`` is the `point` u16 on the wire.
public struct MeshWXPoint: Sendable, Hashable, Codable {
  public let index: UInt16
  public let name: String
  /// Issuing NWS office code, e.g. `EWX`.
  public let office: String
  public let lat: Double
  public let lon: Double
  /// The forecast zone the point sits in, e.g. `TXZ192`.
  public let zone: String
}

/// A populated place (`places.json`), for search and autocomplete.
public struct MeshWXPlace: Sendable, Hashable, Codable {
  public let name: String
  public let state: String
  public let lat: Double
  public let lon: Double
  public let population: Int
  public init(name: String, state: String, lat: Double, lon: Double, population: Int) {
    self.name = name
    self.state = state
    self.lat = lat
    self.lon = lon
    self.population = population
  }
}

/// A forecast zone (`zones.json`). ``lat``/``lon`` are the centroid, which is the pin
/// an app drops when it has no polygon for the zone.
public struct MeshWXZone: Sendable, Hashable, Codable {
  public let id: String
  public let name: String
  public let office: String
  public let state: String
  public let lat: Double
  public let lon: Double
}

/// A county, parish, borough or independent city (`counties.json`).
public struct MeshWXCounty: Sendable, Hashable, Codable {
  public let ugc: String
  public let name: String
  public let state: String
  public let lat: Double
  public let lon: Double
}

/// An NWS forecast office (`wfos.json`).
public struct MeshWXOffice: Sendable, Hashable, Codable {
  public let code: String
  public let states: [String]
  public let lat: Double
  public let lon: Double
}

/// The two names a VTEC event has: a wire-era abbreviation for a badge and a full name
/// for a headline.
public struct MeshWXEventName: Sendable, Hashable, Codable {
  public let short: String
  public let long: String
}

/// One area of a warning, resolved to a name and a pin.
///
/// ``name`` and the coordinates are optional because the bundle is versioned and the
/// wire is not: a county added to the NWS tables after this bundle was cut still
/// decodes to a valid UGC, just without a label. Losing the name must not lose the area.
public struct MeshWXNamedArea: Sendable, Hashable, Codable {
  public let ugc: String
  public let name: String?
  public let state: String
  public let isCounty: Bool
  public let lat: Double?
  public let lon: Double?
}

// MARK: - Geography

/// Great-circle distance. Small enough to inline here rather than pull CoreLocation into
/// a module that must build and test on a Mac with no location services.
public enum MeshWXGeo {
  static let earthRadiusMiles = 3958.7613
  static let earthRadiusKilometres = 6371.0088

  public static func distanceMiles(
    fromLat lat1: Double, lon lon1: Double, toLat lat2: Double, lon lon2: Double
  ) -> Double {
    haversine(lat1, lon1, lat2, lon2) * earthRadiusMiles
  }

  public static func distanceKilometres(
    fromLat lat1: Double, lon lon1: Double, toLat lat2: Double, lon lon2: Double
  ) -> Double {
    haversine(lat1, lon1, lat2, lon2) * earthRadiusKilometres
  }

  /// Central angle in radians.
  static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let toRadians = Double.pi / 180
    let dLat = (lat2 - lat1) * toRadians
    let dLon = (lon2 - lon1) * toRadians
    let a =
      sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * toRadians) * cos(lat2 * toRadians) * sin(dLon / 2)
      * sin(dLon / 2)
    return 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
  }
}

// MARK: - Tables

/// The preload bundle of spec §9: everything the wire refers to by index.
///
/// The protocol's first design rule is "the mesh carries identifiers and numbers, the
/// phone carries tables and words", so this type is not a convenience — without it a
/// decoded warning is `event 3, office 35, state 42` and nothing an app can draw.
///
/// Immutable after construction, so the whole thing is `Sendable` and ``shared`` can be
/// touched from any actor. Loading is by `JSONDecoder`, which measured roughly three
/// times faster than `JSONSerialization` plus manual casting on the 1.4 MB places file
/// (≈21 ms against ≈64 ms); the whole bundle loads in well under a tenth of a second.
///
/// Nothing here traps. A missing or malformed file logs and leaves that one table empty:
/// a weather app that crashes on launch because a resource did not copy is worse than
/// one that cannot name a county.
public final class MeshWXTables: Sendable {
  private static let log = Logger(subsystem: "com.mc1", category: "MeshWX")

  /// The app-wide tables, loaded from the module bundle on first use.
  public static let shared = MeshWXTables()

  // MARK: Wire index tables (index.json)

  /// `protocol.json` `version` — 8 for v5.0.
  public let protocolVersion: Int
  /// NWS office codes, ordered; the `office` byte indexes this.
  public let offices: [String]
  /// ICAO codes, ordered; the `station` u16 indexes this.
  public let stations: [String]
  /// State and territory codes, ordered; the area-run state field indexes this.
  public let states: [String]

  // MARK: Event tables (protocol.json)

  /// Wire byte → VTEC code, e.g. `3` → `"SV.W"`.
  public let eventCodes: [UInt8: String]
  /// VTEC code → wire byte.
  public let eventByCode: [String: UInt8]
  /// VTEC code → its short and long names.
  public let eventNames: [String: MeshWXEventName]
  /// Sky code → the bundle's name for it (`"broken"`, `"thunderstorm"`).
  public let skyNames: [MeshWXSky: String]

  // MARK: Reference data

  /// Forecast points in wire order.
  public let points: [MeshWXPoint]
  /// Populated places, for search.
  public let places: [MeshWXPlace]

  private let stationsByICAO: [String: MeshWXStation]
  private let stationIndexByICAO: [String: UInt16]
  private let zonesByID: [String: MeshWXZone]
  private let countiesByUGC: [String: MeshWXCounty]
  private let officesByCode: [String: MeshWXOffice]

  // MARK: - Loading

  /// The bundled preload directory, or nil if the resource bundle did not build.
  ///
  /// Named `PreloadBundle` rather than `Resources` because `codesign` refuses a flat iOS
  /// resource bundle that carries a top-level `Resources/` — see the target in `Package.swift`.
  public static var bundledResourceDirectory: URL? {
    Bundle.module.resourceURL?.appendingPathComponent("PreloadBundle", isDirectory: true)
  }

  /// Load the bundled tables.
  public convenience init() {
    self.init(resourceDirectory: Self.bundledResourceDirectory)
  }

  /// Load the eight JSON tables from a directory — the designated initializer, so a
  /// tool or a test can point at an updated bundle without rebuilding the app.
  public init(resourceDirectory: URL?) {
    let decoder = JSONDecoder()

    let protocolFile: ProtocolFile? = Self.load("protocol", from: resourceDirectory, decoder)
    let indexFile: IndexFile? = Self.load("index", from: resourceDirectory, decoder)
    let stationsFile: [String: StationRecord]? = Self.load("stations", from: resourceDirectory, decoder)
    let pointsFile: PointsFile? = Self.load("pfm_points", from: resourceDirectory, decoder)
    let placesFile: PlacesFile? = Self.load("places", from: resourceDirectory, decoder)
    let zonesFile: [String: ZoneRecord]? = Self.load("zones", from: resourceDirectory, decoder)
    let countiesFile: [String: CountyRecord]? = Self.load("counties", from: resourceDirectory, decoder)
    let wfosFile: [String: OfficeRecord]? = Self.load("wfos", from: resourceDirectory, decoder)

    protocolVersion = protocolFile?.version ?? 0
    offices = indexFile?.offices ?? []
    stations = indexFile?.stations ?? []
    states = indexFile?.states ?? []

    // The events table is keyed by VTEC code on disk and by wire byte on the air, so
    // both directions are built once here rather than scanned per warning.
    var byByte: [UInt8: String] = [:]
    var byCode: [String: UInt8] = [:]
    for (code, value) in protocolFile?.events ?? [:] {
      guard let byte = UInt8(exactly: value) else { continue }
      byByte[byte] = code
      byCode[code] = byte
    }
    eventCodes = byByte
    eventByCode = byCode
    eventNames = protocolFile?.eventNames ?? [:]

    var sky: [MeshWXSky: String] = [:]
    for (name, value) in protocolFile?.skyCodes ?? [:] {
      guard let raw = UInt8(exactly: value), let code = MeshWXSky(rawValue: raw) else { continue }
      sky[code] = name
    }
    skyNames = sky

    points = (pointsFile?.points ?? []).enumerated().compactMap { index, row in
      guard let wireIndex = UInt16(exactly: index) else { return nil }
      return MeshWXPoint(
        index: wireIndex, name: row.name, office: row.office, lat: row.lat, lon: row.lon,
        zone: row.zone)
    }
    places = (placesFile?.places ?? []).map {
      MeshWXPlace(name: $0.name, state: $0.state, lat: $0.lat, lon: $0.lon, population: $0.population)
    }

    stationsByICAO = (stationsFile ?? [:]).reduce(into: [:]) { result, entry in
      result[entry.key] = MeshWXStation(
        icao: entry.key, name: entry.value.name, state: entry.value.state, lat: entry.value.lat,
        lon: entry.value.lon)
    }
    var indexByICAO: [String: UInt16] = [:]
    for (position, icao) in (indexFile?.stations ?? []).enumerated() {
      guard let wireIndex = UInt16(exactly: position) else { break }
      indexByICAO[icao] = wireIndex
    }
    stationIndexByICAO = indexByICAO

    zonesByID = (zonesFile ?? [:]).reduce(into: [:]) { result, entry in
      result[entry.key] = MeshWXZone(
        id: entry.key, name: entry.value.name, office: entry.value.wfo, state: entry.value.state,
        lat: entry.value.lat, lon: entry.value.lon)
    }
    countiesByUGC = (countiesFile ?? [:]).reduce(into: [:]) { result, entry in
      result[entry.key] = MeshWXCounty(
        ugc: entry.key, name: entry.value.name, state: entry.value.state, lat: entry.value.lat,
        lon: entry.value.lon)
    }
    officesByCode = (wfosFile ?? [:]).reduce(into: [:]) { result, entry in
      result[entry.key] = MeshWXOffice(
        code: entry.key, states: entry.value.states, lat: entry.value.lat, lon: entry.value.lon)
    }
  }

  private static func load<T: Decodable>(
    _ name: String, from directory: URL?, _ decoder: JSONDecoder
  ) -> T? {
    guard let directory else {
      log.warning("MeshWX resources missing from the bundle; \(name).json not loaded")
      return nil
    }
    let url = directory.appendingPathComponent("\(name).json", isDirectory: false)
    do {
      return try decoder.decode(T.self, from: try Data(contentsOf: url, options: .mappedIfSafe))
    } catch {
      log.warning("MeshWX table \(name).json failed to load: \(error.localizedDescription)")
      return nil
    }
  }

  // MARK: - Wire index lookups
  //
  // All of these return nil rather than trapping on an index past the end of the table.
  // `index.json` is append-only, so an out-of-range index means the bundle is older than
  // the bot — a normal thing on a mesh, not a bug.

  public func officeCode(_ index: UInt8) -> String? {
    offices.indices.contains(Int(index)) ? offices[Int(index)] : nil
  }

  public func stationICAO(_ index: UInt16) -> String? {
    stations.indices.contains(Int(index)) ? stations[Int(index)] : nil
  }

  public func stationIndex(forICAO icao: String) -> UInt16? {
    stationIndexByICAO[icao.uppercased()]
  }

  public func stateCode(_ index: UInt8) -> String? {
    states.indices.contains(Int(index)) ? states[Int(index)] : nil
  }

  /// VTEC code for an event byte, e.g. `3` → `"SV.W"`.
  public func vtec(for event: UInt8) -> String? { eventCodes[event] }

  /// Short and long names for an event byte.
  public func eventName(for event: UInt8) -> (short: String, long: String)? {
    guard let code = eventCodes[event], let name = eventNames[code] else { return nil }
    return (name.short, name.long)
  }

  /// Severity from the VTEC significance letter (spec §3).
  public func severity(for event: UInt8) -> MeshWXSeverity? {
    guard let code = eventCodes[event] else { return nil }
    return MeshWXSeverity(vtec: code)
  }

  /// A label that is always printable: the table's name, or `"unknown (#42)"` when the
  /// bundle does not know the index.
  public func officeLabel(_ index: UInt8) -> String {
    officeCode(index) ?? Self.unknownLabel(Int(index))
  }

  public func stationLabel(_ index: UInt16) -> String {
    stationICAO(index) ?? Self.unknownLabel(Int(index))
  }

  public func stateLabel(_ index: UInt8) -> String {
    stateCode(index) ?? Self.unknownLabel(Int(index))
  }

  public func eventLabel(for event: UInt8) -> String {
    eventName(for: event)?.long ?? vtec(for: event) ?? Self.unknownLabel(Int(event))
  }

  static func unknownLabel(_ index: Int) -> String { "unknown (#\(index))" }

  // MARK: - Reference lookups

  public func station(icao: String) -> MeshWXStation? { stationsByICAO[icao.uppercased()] }

  /// The station a wire index names, in one step.
  public func station(at index: UInt16) -> MeshWXStation? {
    stationICAO(index).flatMap { stationsByICAO[$0] }
  }

  public func point(at index: UInt16) -> MeshWXPoint? {
    points.indices.contains(Int(index)) ? points[Int(index)] : nil
  }

  public func zone(_ id: String) -> MeshWXZone? { zonesByID[id.uppercased()] }

  public func county(_ ugc: String) -> MeshWXCounty? { countiesByUGC[ugc.uppercased()] }

  public func office(_ code: String) -> MeshWXOffice? { officesByCode[code.uppercased()] }

  /// Nearest forecast point by great-circle distance — the "forecast for my location"
  /// lookup of spec §11. Send `>f <index>` for what comes back and label the answer
  /// with the point's name and its distance, because it is not the user's coordinate.
  public func nearestPoint(toLat lat: Double, lon: Double) -> MeshWXPoint? {
    var best: MeshWXPoint?
    var bestAngle = Double.infinity
    for point in points {
      // Compare the central angle rather than a distance: it is monotonic in distance
      // and saves a multiply per candidate across ~1900 points.
      let angle = MeshWXGeo.haversine(lat, lon, point.lat, point.lon)
      if angle < bestAngle {
        bestAngle = angle
        best = point
      }
    }
    return best
  }

  // MARK: - Search (spec §11)

  /// The place to name a coordinate by ("Austin"), within `radiusKilometres`.
  ///
  /// Nearest place of at least `minimumPopulation` people first, then the nearest place of
  /// any size: a point in central Austin is "Austin", not the 400-person village whose
  /// census centroid happens to sit 800 m closer. Nil when nothing is within the radius —
  /// a label from 60 km away would tell the user they are somewhere they are not.
  public func nearestPlace(
    toLat lat: Double, lon: Double, within radiusKilometres: Double = 25,
    minimumPopulation: Int = 1_000
  ) -> MeshWXPlace? {
    var bestSizeable: (place: MeshWXPlace, distance: Double)?
    var bestAny: (place: MeshWXPlace, distance: Double)?
    for place in places {
      let distance = MeshWXGeo.distanceKilometres(fromLat: lat, lon: lon, toLat: place.lat, lon: place.lon)
      guard distance <= radiusKilometres else { continue }
      if bestAny == nil || distance < bestAny!.distance { bestAny = (place, distance) }
      if place.population >= minimumPopulation,
         bestSizeable == nil || distance < bestSizeable!.distance {
        bestSizeable = (place, distance)
      }
    }
    return bestSizeable?.place ?? bestAny?.place
  }

  /// Place search: prefix match on the name, then nearest to `near` if given, then the
  /// biggest (spec §11).
  ///
  /// Distance before population is deliberate. 207 names exist in more than one state —
  /// Round Rock is in TX and AZ — and the one the user means is almost always the one
  /// they can drive to, not the one with more people in it.
  public func searchPlaces(
    query: String, nearLat lat: Double? = nil, lon: Double? = nil, limit: Int = 25
  ) -> [MeshWXPlace] {
    let prefix = Self.searchKey(query)
    guard !prefix.isEmpty, limit > 0 else { return [] }
    let matches = places.filter { Self.hasPrefix(prefix, in: $0.name) }

    guard let lat, let lon else {
      // No anchor to rank against: biggest first, name as the tie-break so the order is
      // stable between launches.
      return Array(
        matches.sorted {
          $0.population != $1.population ? $0.population > $1.population : $0.name < $1.name
        }.prefix(limit))
    }
    var ranked: [(place: MeshWXPlace, angle: Double)] = []
    ranked.reserveCapacity(matches.count)
    for place in matches {
      ranked.append((place, MeshWXGeo.haversine(lat, lon, place.lat, place.lon)))
    }
    ranked.sort { left, right in
      left.angle == right.angle
        ? left.place.population > right.place.population : left.angle < right.angle
    }
    return ranked.prefix(limit).map(\.place)
  }

  /// Station search by ICAO prefix or name substring (spec §11), nearest first when a
  /// location is given.
  public func searchStations(
    query: String, nearLat lat: Double? = nil, lon: Double? = nil, limit: Int = 25
  ) -> [MeshWXStation] {
    let key = Self.searchKey(query)
    guard !key.isEmpty, limit > 0 else { return [] }
    let matches = stationsByICAO.values.filter {
      Self.hasPrefix(key, in: $0.icao) || Self.contains(key, in: $0.name)
    }

    guard let lat, let lon else {
      // Stable and predictable without a location: alphabetical by ICAO.
      return Array(matches.sorted { $0.icao < $1.icao }.prefix(limit))
    }
    var ranked: [(station: MeshWXStation, angle: Double)] = []
    ranked.reserveCapacity(matches.count)
    for station in matches {
      ranked.append((station, MeshWXGeo.haversine(lat, lon, station.lat, station.lon)))
    }
    ranked.sort { left, right in
      left.angle == right.angle ? left.station.icao < right.station.icao : left.angle < right.angle
    }
    return ranked.prefix(limit).map(\.station)
  }

  // MARK: - Areas

  /// Resolve a warning's area runs to named places with pins (spec §9).
  ///
  /// Runs whose state index is unknown are dropped — there is no UGC to build without
  /// the state code — but a UGC the bundle has no row for is kept, name nil, so the app
  /// can still say "and 3 more areas" instead of under-reporting the warning.
  public func namedAreas(for runs: [MeshWXAreaRun]) -> [MeshWXNamedArea] {
    runs.flatMap { run -> [MeshWXNamedArea] in
      guard let state = stateCode(run.stateIndex) else { return [] }
      return run.ugcCodes(states: states).map { ugc in
        if run.isCounty {
          let county = county(ugc)
          return MeshWXNamedArea(
            ugc: ugc, name: county?.name, state: state, isCounty: true, lat: county?.lat,
            lon: county?.lon)
        }
        let zone = zone(ugc)
        return MeshWXNamedArea(
          ugc: ugc, name: zone?.name, state: state, isCounty: false, lat: zone?.lat, lon: zone?.lon)
      }
    }
  }

  /// The areas of a warning, resolved. Empty when the product carries none.
  public func namedAreas(for warning: MeshWXWarning) -> [MeshWXNamedArea] {
    namedAreas(for: warning.areas ?? [])
  }

  // MARK: - ASCII search helpers
  //
  // Byte-wise ASCII case folding rather than `uppercased()` or `range(of:options:)`:
  // a place search runs over 35 000 names on every keystroke, and neither allocating a
  // string per candidate nor bridging to NSString belongs on that path.

  static func searchKey(_ query: String) -> [UInt8] {
    Array(query.trimmingCharacters(in: .whitespacesAndNewlines).utf8).map(foldASCII)
  }

  private static func foldASCII(_ byte: UInt8) -> UInt8 {
    (byte >= 97 && byte <= 122) ? byte - 32 : byte
  }

  static func hasPrefix(_ key: [UInt8], in value: String) -> Bool {
    var iterator = value.utf8.makeIterator()
    for expected in key {
      guard let byte = iterator.next(), foldASCII(byte) == expected else { return false }
    }
    return true
  }

  static func contains(_ key: [UInt8], in value: String) -> Bool {
    guard !key.isEmpty else { return true }
    let haystack = Array(value.utf8)
    guard haystack.count >= key.count else { return false }
    for start in 0...(haystack.count - key.count) {
      var matched = true
      for offset in key.indices where foldASCII(haystack[start + offset]) != key[offset] {
        matched = false
        break
      }
      if matched { return true }
    }
    return false
  }
}

// MARK: - On-disk shapes
//
// Kept private and minimal: these mirror the bundle's JSON exactly, and the public
// records above are what the app sees, so a future reshuffle of the bundle is a change
// to this file alone.

extension MeshWXTables {
  private struct ProtocolFile: Decodable {
    let version: Int
    let events: [String: Int]
    let eventNames: [String: MeshWXEventName]
    let skyCodes: [String: Int]

    enum CodingKeys: String, CodingKey {
      case version
      case events
      case eventNames = "event_names"
      case skyCodes = "sky_codes"
    }
  }

  private struct IndexFile: Decodable {
    let offices: [String]
    let stations: [String]
    let states: [String]
  }

  private struct StationRecord: Decodable {
    let name: String
    let state: String
    let lat: Double
    let lon: Double
  }

  /// `[name, office, lat, lon, zone]` — a positional array, so it is decoded by hand.
  private struct PointRecord: Decodable {
    let name: String
    let office: String
    let lat: Double
    let lon: Double
    let zone: String

    init(from decoder: any Decoder) throws {
      var row = try decoder.unkeyedContainer()
      name = try row.decode(String.self)
      office = try row.decode(String.self)
      lat = try row.decode(Double.self)
      lon = try row.decode(Double.self)
      zone = try row.decode(String.self)
    }
  }

  private struct PointsFile: Decodable {
    let points: [PointRecord]
  }

  /// `[NAME, ST, lat, lon, population]`.
  private struct PlaceRecord: Decodable {
    let name: String
    let state: String
    let lat: Double
    let lon: Double
    let population: Int

    init(from decoder: any Decoder) throws {
      var row = try decoder.unkeyedContainer()
      name = try row.decode(String.self)
      state = try row.decode(String.self)
      lat = try row.decode(Double.self)
      lon = try row.decode(Double.self)
      population = try row.decode(Int.self)
    }
  }

  private struct PlacesFile: Decodable {
    let places: [PlaceRecord]
  }

  private struct ZoneRecord: Decodable {
    let name: String
    let wfo: String
    let state: String
    let lat: Double
    let lon: Double
  }

  private struct CountyRecord: Decodable {
    let name: String
    let state: String
    let lat: Double
    let lon: Double
  }

  private struct OfficeRecord: Decodable {
    let states: [String]
    let lat: Double
    let lon: Double
  }
}
