import MapKit

/// Loads and indexes the bundled zones.geojson file so zone-based NWS warnings
/// can be rendered as map polygons.
///
/// Zone codes follow the format: [STATE_2LETTER]Z[3-DIGIT-NUMBER] e.g. "TXZ192".
/// The stateIdx in MeshWX 0x21 protocol is an index into the state list defined by
/// state_index.json (from Vendor/meshcore-weather submodule). Indices are protocol-fixed
/// and must NOT be re-sorted — see state_index.json description for details.
@MainActor
final class ZoneGeometryStore {

    static let shared = ZoneGeometryStore()

    // MARK: - State Index Table

    /// Loaded at init from bundled state_index.json. Falls back to the embedded default
    /// which mirrors the submodule's state_index.json at the time this code was written.
    /// To update: run `git submodule update --remote Vendor/meshcore-weather` then rebuild.
    private(set) var stateCodes: [String]

    /// Authoritative default — mirrors Vendor/meshcore-weather state_index.json.
    /// Order is protocol-fixed (NOT alphabetical). TX=42, ND=33, MI=21.
    private static let defaultStateCodes: [String] = [
        "AL","AK","AZ","AR","CA","CO","CT","DE","FL","GA",
        "HI","ID","IL","IN","IA","KS","KY","LA","ME","MD",
        "MA","MI","MN","MS","MO","MT","NE","NV","NH","NJ",
        "NM","NY","NC","ND","OH","OK","OR","PA","RI","SC",
        "SD","TN","TX","UT","VT","VA","WA","WV","WI","WY",
        "DC","PR","VI","GU","AS","MP","MH","FM","PW",
        "AN","AM","GM","PK","PZ","PH","CI","CN","US","MX",
        "PM","LE","LO","LH","LM","LS","LC","SL","PS"
    ]

    // MARK: - State

    private(set) var isLoaded = false
    private var polygonsByCode: [String: [MKPolygon]] = [:]

    private init() {
        // Try to load state index from bundled state_index.json (kept in sync with
        // Vendor/meshcore-weather submodule). Falls back to defaultStateCodes.
        if let url = Bundle.main.url(forResource: "state_index", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let parsed = try? JSONDecoder().decode(StateIndexFile.self, from: data),
           !parsed.states.isEmpty {
            stateCodes = parsed.states
        } else {
            stateCodes = Self.defaultStateCodes
        }
    }

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
    @MainActor
    static func zoneCode(stateIdx: UInt8, zoneNum: UInt16) -> String? {
        let codes = shared.stateCodes
        let idx = Int(stateIdx)
        guard idx < codes.count else { return nil }
        return "\(codes[idx])Z\(String(format: "%03d", zoneNum))"
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
            for shape in feature.geometry {
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

// MARK: - Decodable helper

private struct StateIndexFile: Decodable {
    let states: [String]
}
