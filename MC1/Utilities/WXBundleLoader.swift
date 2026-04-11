import Foundation
import CoreLocation

// MARK: - WXBundleLoader

/// Loads and searches MeshWX location data from bundle JSON files.
///
/// Bundle files (from meshcore-weather/client_data/):
///   pfm_points.json   — [[name, wfo, lat, lon, zone], …]  (1,873 NWS forecast points)
///   stations.json     — {ICAO: {name, state, lat, lon}}   (METAR station dict)
///   places.json       — [[name, state, lat, lon], …]      (~30k US Census places)
///   weather_dict.json — {code: description}               (condition code labels)
///   wfos.json         — [{id, name, lat, lon}, …]         (WFO office list)
enum WXBundleLoader {

    // MARK: - Types

    struct PFMPoint: Identifiable, Sendable {
        let id: Int              // array index — used as location_id in 0x02 request
        let name: String
        let wfo: String
        let latitude: Double
        let longitude: Double
        let zone: String

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    struct Station: Identifiable, Sendable {
        let id: String           // ICAO code
        let name: String
        let state: String
        let latitude: Double
        let longitude: Double
    }

    struct Place: Identifiable, Sendable {
        let id: Int              // array index in places.json
        let name: String
        let state: String
        let latitude: Double
        let longitude: Double

        var displayName: String { "\(name), \(state)" }
        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    // MARK: - Cached Data

    nonisolated(unsafe) private static var _pfmPoints: [PFMPoint]?
    nonisolated(unsafe) private static var _stations: [Station]?
    nonisolated(unsafe) private static var _places: [Place]?
    nonisolated(unsafe) private static var _weatherDict: [String: String]?

    static var allPFMPoints: [PFMPoint] {
        if let cached = _pfmPoints { return cached }
        _pfmPoints = loadPFMPoints()
        return _pfmPoints ?? []
    }

    static var allStations: [Station] {
        if let cached = _stations { return cached }
        _stations = loadStations()
        return _stations ?? []
    }

    static var allPlaces: [Place] {
        if let cached = _places { return cached }
        _places = loadPlaces()
        return _places ?? []
    }

    static var weatherDict: [String: String] {
        if let cached = _weatherDict { return cached }
        _weatherDict = loadWeatherDict()
        return _weatherDict ?? [:]
    }

    // MARK: - Search

    /// Maps 2-letter US state abbreviations to full lowercase state names for search expansion.
    private static let stateAbbreviations: [String: String] = [
        "al": "alabama", "ak": "alaska", "az": "arizona", "ar": "arkansas",
        "ca": "california", "co": "colorado", "ct": "connecticut", "de": "delaware",
        "fl": "florida", "ga": "georgia", "hi": "hawaii", "id": "idaho",
        "il": "illinois", "in": "indiana", "ia": "iowa", "ks": "kansas",
        "ky": "kentucky", "la": "louisiana", "me": "maine", "md": "maryland",
        "ma": "massachusetts", "mi": "michigan", "mn": "minnesota", "ms": "mississippi",
        "mo": "missouri", "mt": "montana", "ne": "nebraska", "nv": "nevada",
        "nh": "new hampshire", "nj": "new jersey", "nm": "new mexico", "ny": "new york",
        "nc": "north carolina", "nd": "north dakota", "oh": "ohio", "ok": "oklahoma",
        "or": "oregon", "pa": "pennsylvania", "ri": "rhode island", "sc": "south carolina",
        "sd": "south dakota", "tn": "tennessee", "tx": "texas", "ut": "utah",
        "vt": "vermont", "va": "virginia", "wa": "washington", "wv": "west virginia",
        "wi": "wisconsin", "wy": "wyoming", "dc": "district of columbia",
        "pr": "puerto rico",
    ]

    /// Search US Census places by city name/state. Returns up to `limit` results.
    /// Each result resolves to the nearest pfm_point for the 0x02 request.
    /// Supports 2-letter state abbreviations (e.g. "tx" → Texas).
    /// Results sorted: city-name prefix matches first, then city-name contains, then state matches.
    static func searchPlaces(query: String, limit: Int = 40) -> [(place: Place, pfmPoint: PFMPoint)] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)

        // Expand abbreviation to full state name (e.g. "tx" → "texas")
        let expandedState = stateAbbreviations[q]

        let matches = allPlaces
            .filter { place in
                let name = place.name.lowercased()
                let state = place.state.lowercased()
                if name.hasPrefix(q) || name.contains(q) { return true }
                if let expanded = expandedState, state == expanded { return true }
                return state.contains(q)
            }
            .sorted { a, b in
                let aq = a.name.lowercased()
                let bq = b.name.lowercased()
                // City prefix match ranks above city contains match
                let aPrefix = aq.hasPrefix(q)
                let bPrefix = bq.hasPrefix(q)
                if aPrefix != bPrefix { return aPrefix }
                // Within same tier, alphabetical by city name
                if aq != bq { return aq < bq }
                return a.state < b.state
            }
            .prefix(limit)

        return matches.compactMap { place in
            guard let pfm = nearestPFMPoint(to: place.coordinate) else { return nil }
            return (place: place, pfmPoint: pfm)
        }
    }

    /// Search pfm_points by NWS grid name or WFO code.
    static func searchPFMPoints(query: String, limit: Int = 30) -> [PFMPoint] {
        guard !query.isEmpty else { return Array(allPFMPoints.prefix(limit)) }
        let q = query.lowercased()
        return allPFMPoints
            .filter { $0.name.lowercased().contains(q) || $0.wfo.lowercased().contains(q) }
            .prefix(limit)
            .map { $0 }
    }

    /// Search stations by ICAO code, airport name, or state.
    static func searchStations(query: String, limit: Int = 30) -> [Station] {
        guard !query.isEmpty else { return Array(allStations.prefix(limit)) }
        let q = query.lowercased()
        return allStations
            .filter {
                $0.id.lowercased().contains(q) ||
                $0.name.lowercased().contains(q) ||
                $0.state.lowercased().contains(q)
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Returns the PFMPoint nearest to a coordinate.
    static func nearestPFMPoint(to coordinate: CLLocationCoordinate2D) -> PFMPoint? {
        allPFMPoints.min { a, b in
            haversine(a.latitude, a.longitude, coordinate.latitude, coordinate.longitude) <
            haversine(b.latitude, b.longitude, coordinate.latitude, coordinate.longitude)
        }
    }

    /// Returns a human-readable label for a weather condition code.
    static func conditionName(for code: String) -> String {
        weatherDict[code] ?? code
    }

    // MARK: - Loaders

    private static func loadPFMPoints() -> [PFMPoint] {
        guard let url = Bundle.main.url(forResource: "pfm_points", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["points"] as? [[Any]] else {
            return []
        }
        return raw.enumerated().compactMap { index, entry in
            guard entry.count >= 4,
                  let name = entry[0] as? String,
                  let wfo  = entry[1] as? String,
                  let lat  = (entry[2] as? NSNumber)?.doubleValue,
                  let lon  = (entry[3] as? NSNumber)?.doubleValue else { return nil }
            let zone = (entry.count >= 5 ? entry[4] as? String : nil) ?? ""
            return PFMPoint(id: index, name: name, wfo: wfo, latitude: lat, longitude: lon, zone: zone)
        }
    }

    private static func loadStations() -> [Station] {
        guard let url = Bundle.main.url(forResource: "stations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return []
        }
        return raw.compactMap { icao, info in
            guard let name  = info["name"]  as? String,
                  let state = info["state"] as? String,
                  let lat   = (info["lat"]  as? NSNumber)?.doubleValue,
                  let lon   = (info["lon"]  as? NSNumber)?.doubleValue else { return nil }
            return Station(id: icao, name: name, state: state, latitude: lat, longitude: lon)
        }.sorted { $0.id < $1.id }
    }

    private static func loadPlaces() -> [Place] {
        guard let url = Bundle.main.url(forResource: "places", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["places"] as? [[Any]] else {
            return []
        }
        return raw.enumerated().compactMap { index, entry in
            guard entry.count >= 4,
                  let name  = entry[0] as? String,
                  let state = entry[1] as? String,
                  let lat   = (entry[2] as? NSNumber)?.doubleValue,
                  let lon   = (entry[3] as? NSNumber)?.doubleValue else { return nil }
            return Place(id: index, name: name, state: state, latitude: lat, longitude: lon)
        }
    }

    private static func loadWeatherDict() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "weather_dict", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return raw
    }

    // MARK: - Helpers

    private static func haversine(_ lat1: Double, _ lon1: Double,
                                   _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat/2)*sin(dLat/2)
              + cos(lat1 * .pi/180)*cos(lat2 * .pi/180)*sin(dLon/2)*sin(dLon/2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
