import MapKit

/// Loads and indexes the bundled zones.geojson file so zone-based NWS warnings
/// can be rendered as map polygons.
///
/// Zone codes follow the format: [STATE_2LETTER]Z[3-DIGIT-NUMBER] e.g. "TXZ192".
/// The stateIdx in MeshWX protocol is an index into the sorted list of state/territory codes below.
@MainActor
final class ZoneGeometryStore {

    static let shared = ZoneGeometryStore()

    // MARK: - State Index Table (74 entries, sorted alphabetically — matches MeshWX protocol)

    static let stateCodes: [String] = [
        "AK","AL","AM","AN","AR","AS","AZ","CA","CO","CT",
        "DC","DE","FL","FM","GA","GM","GU","HI","IA","ID",
        "IL","IN","KS","KY","LA","LC","LE","LH","LM","LO",
        "LS","MA","MD","ME","MH","MI","MN","MO","MP","MS",
        "MT","NC","ND","NE","NH","NJ","NM","NV","NY","OH",
        "OK","OR","PA","PH","PK","PM","PR","PS","PW","PZ",
        "RI","SC","SD","SL","TN","TX","UT","VA","VI","VT",
        "WA","WI","WV","WY"
    ]

    // MARK: - State

    private(set) var isLoaded = false
    private var polygonsByCode: [String: [MKPolygon]] = [:]

    private init() {}

    // MARK: - Loading

    /// Kicks off background loading if not already done. Safe to call multiple times.
    func loadIfNeeded() {
        guard !isLoaded else { return }
        Task.detached(priority: .utility) {
            let result = Self.parseGeoJSON()
            await MainActor.run {
                self.polygonsByCode = result
                self.isLoaded = true
            }
        }
    }

    // MARK: - Lookup

    /// Returns all polygons for a given zone code (e.g. "TXZ192"), or empty array if not found.
    func polygons(for code: String) -> [MKPolygon] {
        polygonsByCode[code] ?? []
    }

    /// Converts stateIdx + zoneNum from the MeshWX protocol into a zone code string.
    static func zoneCode(stateIdx: UInt8, zoneNum: UInt16) -> String? {
        let idx = Int(stateIdx)
        guard idx < stateCodes.count else { return nil }
        return "\(stateCodes[idx])Z\(String(format: "%03d", zoneNum))"
    }

    // MARK: - GeoJSON Parsing (runs off main thread)

    nonisolated static func parseGeoJSON() -> [String: [MKPolygon]] {
        guard let url = Bundle.main.url(forResource: "zones", withExtension: "geojson"),
              let data = try? Data(contentsOf: url) else {
            return [:]
        }

        guard let features = try? MKGeoJSONDecoder().decode(data) else {
            return [:]
        }

        var result: [String: [MKPolygon]] = [:]
        result.reserveCapacity(6000)

        for item in features {
            guard let feature = item as? MKGeoJSONFeature,
                  let propData = feature.properties,
                  let props = try? JSONDecoder().decode([String: String].self, from: propData),
                  let code = props["code"] else { continue }

            var polys: [MKPolygon] = []
            for shape in feature.shapes {
                if let polygon = shape as? MKPolygon {
                    polys.append(polygon)
                } else if let multi = shape as? MKMultiPolygon {
                    polys.append(contentsOf: multi.polygons)
                }
            }
            if !polys.isEmpty {
                result[code] = polys
            }
        }

        return result
    }
}
