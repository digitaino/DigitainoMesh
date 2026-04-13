import CoreLocation
import Foundation
import SwiftUI

// MARK: - MeshWX Protocol Decoder
// Supports three 0x20 warning wire formats:
//   v2 (legacy): uint16 relative expiry, int8 deltas × 0.01°
//   MVP (current live): uint32 absolute expiry, int16 BE deltas × 0.001°
//   Full VTEC (future/deferred): VTEC fields, action codes, ETN, office
//
// 0x31 Forecast (MVP, active):
//   location_type + location_id + issued_offset + periods (7 bytes each)
//
// References:
//   VTEC: NWSI 10-1703
//   CAP v1.2: https://docs.oasis-open.org/emergency/cap/v1.2/CAP-v1.2-os.html
//   pyIEM: https://github.com/akrherz/pyIEM

// MARK: - Message Types

/// Decoded MeshWX message types.
enum MeshWXMessage: Sendable {
    case radarGrid(MeshWXRadarFrame)
    case warningPolygon(MeshWXWarning)
    case forecast(MeshWXForecast)
    case observation(MeshWXObservation)
    case outlook(MeshWXOutlook)
    case stormReports(MeshWXStormReports)
    case rainObservations(MeshWXRainObservations)
    case taf(MeshWXTAF)
    case warningsNear(MeshWXWarningsNear)
    case notAvailable(MeshWXNotAvailable)
}

// MARK: - Radar Frame

struct MeshWXRadarFrame: Sendable, Equatable, Codable {
    let regionID: UInt8
    let frameSeq: UInt8
    /// Minutes since midnight UTC.
    let timestamp: UInt16
    /// Km per grid cell.
    let scaleKm: UInt8
    /// Grid dimension (16 for legacy 0x10, 32 or 64 for new 0x11). Grid is gridSize×gridSize.
    let gridSize: Int
    /// Row-major reflectivity levels (0x0–0xE). Count = gridSize × gridSize.
    let grid: [UInt8]

    func cell(row: Int, col: Int) -> UInt8 {
        guard row >= 0, row < gridSize, col >= 0, col < gridSize else { return 0 }
        return grid[row * gridSize + col]
    }
    var isEmpty: Bool { grid.allSatisfy { $0 == 0 } }
}

// MARK: - Warning

/// A decoded weather warning. Supports MVP (current live) and full VTEC (future) formats.
/// v2 messages are also decoded with best-effort field translation.
struct MeshWXWarning: Sendable, Identifiable, Equatable {
    let id: UUID

    // MARK: v3 Primary Fields

    /// Index into the VTEC phenomena table (0x00–0x40). See `MeshWXDecoder.vtecPhenomena`.
    /// For MVP/v2 messages this is mapped from the old arbitrary warning_type nibble.
    let phenomenaIndex: UInt8

    /// VTEC significance: 0=Warning(W), 1=Watch(A), 2=Advisory(Y),
    ///                    3=Statement(S), 4=Forecast(F), 5=Outlook(O), 6=Synopsis(N).
    let vtecSignificance: UInt8

    /// CAP severity: 0=Unknown, 1=Minor, 2=Moderate, 3=Severe, 4=Extreme.
    let capSeverity: UInt8

    /// VTEC action: 0=NEW, 1=CON, 2=EXT, 3=EXA, 4=EXB, 5=UPG, 6=CAN, 7=EXP, 8=COR, 9=ROU.
    /// Always 0 (NEW) for MVP/v2 messages.
    let action: UInt8

    /// VTEC Event Tracking Number. 0 for MVP/v2 messages.
    let etn: UInt16

    /// Issuing WFO 3-letter code (e.g. "EWX"). Empty for MVP/v2 messages.
    let office: String

    let urgency: UInt8
    let certainty: UInt8

    /// Absolute expiry as Unix timestamp in minutes.
    let expiryUnixMinutes: UInt32

    let vertices: [CLLocationCoordinate2D]
    let headline: String

    // MARK: Computed

    var expiryDate: Date {
        Date(timeIntervalSince1970: TimeInterval(expiryUnixMinutes) * 60)
    }

    /// Dedup key. Full VTEC: (phenomena, significance, office, etn).
    /// MVP/v2 fallback: uses first vertex + expiry.
    var dedupKey: String {
        if !office.isEmpty || etn != 0 {
            return "\(phenomenaIndex)-\(vtecSignificance)-\(office)-\(etn)"
        }
        let lat = vertices.first.map { Int($0.latitude * 10000) } ?? 0
        let lng = vertices.first.map { Int($0.longitude * 10000) } ?? 0
        return "\(phenomenaIndex)-\(vtecSignificance)-\(lat)-\(lng)-\(expiryUnixMinutes)"
    }

    // MARK: Compat Shims

    var warningType: UInt8 { phenomenaIndex }

    /// Maps vtecSignificance to old scale: 3=Warning, 2=Watch, 1=Advisory (higher = more severe).
    var severity: UInt8 {
        switch vtecSignificance {
        case 0x0: return 3
        case 0x1: return 2
        default:  return 1
        }
    }

    var expiryMinutes: UInt16 {
        let remaining = max(0, expiryDate.timeIntervalSinceNow / 60)
        return UInt16(min(remaining, Double(UInt16.max)))
    }

    var isTerminating: Bool { action == 6 || action == 7 }
    var isNewOrUpgrade: Bool { action == 0 || action == 5 }

    static func == (lhs: MeshWXWarning, rhs: MeshWXWarning) -> Bool { lhs.id == rhs.id }
}

// MARK: - Forecast (0x31)

/// A decoded 0x31 city forecast response. Each period covers ~12 hours.
struct MeshWXForecast: Sendable {

    struct Period: Sendable {
        let periodID: UInt8       // 0=today, 1=tonight, 2=D2 day, 3=D2 night, …
        let highF: Int?           // nil when byte is 127 (N/A)
        let lowF: Int?
        let skyCode: UInt8        // 0=clear … 4=overcast (see protocol.json sky_codes)
        let precipPct: UInt8      // 0–100
        let windDir: UInt8        // 4-bit: 0=N,1=NE,2=E,3=SE,4=S,5=SW,6=W,7=NW,8=calm
        let windSpeedMph: UInt8   // nibble × 5 mph
        let conditionFlags: UInt8 // bit flags: bit0=tstorm, bit1=frost, bit2=fog, …

        var skyName: String {
            switch skyCode {
            case 0: return "Clear"
            case 1: return "Few Clouds"
            case 2: return "Partly Cloudy"
            case 3: return "Mostly Cloudy"
            case 4: return "Overcast"
            case 5: return "Foggy"
            case 8: return "Rain"
            case 9: return "Snow"
            case 10: return "Thunderstorm"
            default: return "Mixed"
            }
        }

        var skySystemImage: String {
            switch skyCode {
            case 0: return "sun.max.fill"
            case 1: return "cloud.sun.fill"
            case 2: return "cloud.sun.fill"
            case 3: return "cloud.fill"
            case 4: return "cloud.fill"
            case 5: return "cloud.fog.fill"
            case 6: return "smoke.fill"
            case 7: return "sun.haze.fill"
            case 8: return "cloud.rain.fill"
            case 9: return "cloud.snow.fill"
            case 10: return "cloud.bolt.rain.fill"
            case 11: return "cloud.drizzle.fill"
            case 12: return "cloud.fog.fill"
            case 13: return "wind.snow"
            default: return "cloud.fill"
            }
        }

        var skyColor: Color {
            switch skyCode {
            case 0: return .yellow
            case 1, 2: return .orange
            case 8, 11: return .cyan
            case 9: return .blue
            case 10: return Color(red: 0.6, green: 0.4, blue: 0.9)
            default: return .gray
            }
        }

        var windDirName: String {
            ["N","NE","E","SE","S","SW","W","NW","Calm"][min(Int(windDir), 8)]
        }

        var hasPrecip: Bool { precipPct > 0 }
        var hasThunderstorm: Bool { conditionFlags & 0x01 != 0 }
        var hasFrost: Bool { conditionFlags & 0x02 != 0 }
        var hasFog: Bool { conditionFlags & 0x04 != 0 }
    }

    /// Location type from protocol.json (1=zone,2=station,3=place,4=latlon,5=wfo,6=pfm_point).
    let locationType: UInt8
    /// Location ID bytes (variable length per type).
    let locationIDBytes: Data
    /// Hours ago this forecast was issued.
    let issuedHoursAgo: UInt8
    let periods: [Period]
    let receivedAt: Date

    /// For pfm_point (locationType==6), the 3-byte uint24 BE index.
    var pfmPointIndex: Int? {
        guard locationType == 6, locationIDBytes.count >= 3 else { return nil }
        return Int(locationIDBytes[0]) << 16 | Int(locationIDBytes[1]) << 8 | Int(locationIDBytes[2])
    }
}

// MARK: - Observation (0x30)

/// A decoded 0x30 current-conditions observation from a METAR station or NWS zone.
struct MeshWXObservation: Sendable {
    let locationType: UInt8
    let locationIDBytes: Data
    /// Minutes since midnight UTC when the observation was recorded.
    let timestampMinutes: UInt16
    let tempF: Int8
    let dewpointF: Int8
    let windDir: UInt8       // 4-bit: 0=N,1=NE,2=E,3=SE,4=S,5=SW,6=W,7=NW,8=calm
    let skyCode: UInt8       // 4-bit: same palette as forecast periods
    let windSpeedKts: UInt8  // knots (as sent by bot)
    let windGustKts: UInt8   // 0 = no gust
    let visibilityMi: UInt8
    let pressureRaw: UInt8   // (inHg − 29.00) × 100 — decode as 29.00 + raw/100
    let feelsLikeDelta: Int8 // signed offset from tempF
    let receivedAt: Date

    // MARK: Computed

    var pressureInHg: Double { 29.00 + Double(pressureRaw) / 100.0 }
    var feelsLikeF: Int { Int(tempF) + Int(feelsLikeDelta) }
    var hasGust: Bool { windGustKts > 0 }
    /// Wind speed converted to mph (1 kt ≈ 1.151 mph).
    var windSpeedMph: UInt8 { UInt8(min(255, Int(windSpeedKts) * 1151 / 1000)) }
    var windGustMph: UInt8  { UInt8(min(255, Int(windGustKts)  * 1151 / 1000)) }
    /// Temperature in Celsius (converted from stored Fahrenheit).
    var tempC: Int { (Int(tempF) - 32) * 5 / 9 }
    var dewpointC: Int { (Int(dewpointF) - 32) * 5 / 9 }
    var feelsLikeC: Int { (feelsLikeF - 32) * 5 / 9 }
    var relativeHumidityPct: Int {
        // Magnus approximation (requires Celsius input)
        let t  = Double(Int(tempF - 32)) * 5.0 / 9.0
        let td = Double(Int(dewpointF - 32)) * 5.0 / 9.0
        let rh = 100.0 * exp((17.625 * td) / (243.04 + td)) / exp((17.625 * t) / (243.04 + t))
        return max(0, min(100, Int(rh.rounded())))
    }

    var windDirName: String {
        ["N","NE","E","SE","S","SW","W","NW","Calm"][min(Int(windDir), 8)]
    }

    var skyName: String {
        switch skyCode {
        case 0: return "Clear"
        case 1: return "Few Clouds"
        case 2: return "Partly Cloudy"
        case 3: return "Mostly Cloudy"
        case 4: return "Overcast"
        case 5: return "Foggy"
        case 8: return "Rain"
        case 9: return "Snow"
        case 10: return "Thunderstorm"
        default: return "Mixed"
        }
    }

    var skySystemImage: String {
        switch skyCode {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3, 4: return "cloud.fill"
        case 5: return "cloud.fog.fill"
        case 8, 11: return "cloud.rain.fill"
        case 9: return "cloud.snow.fill"
        case 10: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    /// Deduplication/cache key: "type:hexID"
    var locationKey: String {
        let hex = locationIDBytes.map { String(format: "%02x", $0) }.joined()
        return "\(locationType):\(hex)"
    }

    /// Human-readable station or zone name derived from location bytes.
    var displayName: String {
        switch locationType {
        case 2: // STATION — 4 ASCII bytes (ICAO)
            guard locationIDBytes.count >= 4 else { return locationKey }
            let icao = String(bytes: locationIDBytes.prefix(4), encoding: .ascii)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            return icao ?? locationKey
        default:
            return locationKey
        }
    }

    /// "HH:MMZ"
    var timestampLabel: String {
        let h = timestampMinutes / 60
        let m = timestampMinutes % 60
        return String(format: "%02d:%02dZ", h, m)
    }
}

// MARK: - Outlook (0x32)

/// A decoded 0x32 Hazardous Weather Outlook (HWO) response.
/// Contains day-1 and days-2-7 hazard outlook from NWS.
struct MeshWXOutlook: Sendable {

    struct Day: Sendable {
        struct Hazard: Sendable {
            let hazardType: UInt8  // 0=thunderstorm,1=flood,2=winter,3=fire,4=heat,5=cold,6=wind,7=coastal,0xF=other
            let riskLevel: UInt8   // 0=none,1=marginal,2=slight,3=enhanced,4=moderate,5=high,6=extreme
        }
        let dayOffset: UInt8       // 1=today, 2=tomorrow, …7
        let hazards: [Hazard]

        var hazardSummary: String {
            hazards.compactMap { h in
                h.riskLevel > 0 ? "\(h.riskName) \(h.hazardTypeName)" : nil
            }.joined(separator: ", ")
        }
    }

    let locationType: UInt8
    let locationIDBytes: Data
    let issuedTimeMinutes: UInt16
    let days: [Day]
    let receivedAt: Date

    var locationKey: String {
        let hex = locationIDBytes.map { String(format: "%02x", $0) }.joined()
        return "\(locationType):\(hex)"
    }

    var issuedLabel: String {
        let h = issuedTimeMinutes / 60
        let m = issuedTimeMinutes % 60
        return String(format: "%02d:%02dZ", h, m)
    }
}

extension MeshWXOutlook.Day.Hazard {
    var hazardTypeName: String {
        switch hazardType {
        case 0: return "Thunderstorm"
        case 1: return "Flooding"
        case 2: return "Winter Weather"
        case 3: return "Fire Weather"
        case 4: return "Excessive Heat"
        case 5: return "Extreme Cold"
        case 6: return "High Wind"
        case 7: return "Coastal Hazard"
        default: return "Hazard"
        }
    }

    var hazardSystemImage: String {
        switch hazardType {
        case 0: return "cloud.bolt.fill"
        case 1: return "cloud.rain.fill"
        case 2: return "cloud.snow.fill"
        case 3: return "flame.fill"
        case 4: return "thermometer.sun.fill"
        case 5: return "thermometer.snowflake"
        case 6: return "wind"
        case 7: return "water.waves"
        default: return "exclamationmark.triangle.fill"
        }
    }

    var riskName: String {
        switch riskLevel {
        case 0: return "None"
        case 1: return "Marginal"
        case 2: return "Slight"
        case 3: return "Enhanced"
        case 4: return "Moderate"
        case 5: return "High"
        case 6: return "Extreme"
        default: return "Unknown"
        }
    }

    var riskColor: Color {
        switch riskLevel {
        case 1: return .green
        case 2: return .yellow
        case 3: return .orange
        case 4, 5: return .red
        case 6: return .purple
        default: return .gray
        }
    }
}

// MARK: - Storm Reports (0x33)

/// A decoded 0x33 Local Storm Reports (LSR) response.
struct MeshWXStormReports: Sendable {

    struct Report: Sendable {
        let eventType: UInt8    // 0=tornado,1=funnel cloud,2=waterspout,3=hail,4=wind,5=flood,6=rain,7=winter,8=ice,9=high wind,A=fog,B=wildfire,C=dust,D=other
        let magnitude: UInt8    // event-specific: hail=0.25" units, wind=mph, others=0
        let minutesAgo: UInt16
        let placeID: Int        // index into places.json
    }

    let locationType: UInt8
    let locationIDBytes: Data
    let reports: [Report]
    let receivedAt: Date

    var locationKey: String {
        let hex = locationIDBytes.map { String(format: "%02x", $0) }.joined()
        return "\(locationType):\(hex)"
    }
}

extension MeshWXStormReports.Report {
    var eventTypeName: String {
        switch eventType {
        case 0: return "Tornado"
        case 1: return "Funnel Cloud"
        case 2: return "Waterspout"
        case 3: return "Hail"
        case 4: return "Damaging Wind"
        case 5: return "Flash Flood"
        case 6: return "Heavy Rain"
        case 7: return "Winter Storm"
        case 8: return "Ice Storm"
        case 9: return "High Wind"
        case 10: return "Dense Fog"
        case 11: return "Wildfire"
        case 12: return "Dust Storm"
        default: return "Storm Report"
        }
    }

    var eventSystemImage: String {
        switch eventType {
        case 0: return "tornado"
        case 1, 2: return "tornado"
        case 3: return "cloud.hail.fill"
        case 4: return "wind.damage"
        case 5: return "cloud.rain.fill"
        case 6: return "cloud.heavyrain.fill"
        case 7: return "cloud.snow.fill"
        case 8: return "thermometer.snowflake"
        case 9: return "wind"
        case 10: return "cloud.fog.fill"
        case 11: return "flame.fill"
        case 12: return "sun.dust.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    var magnitudeLabel: String? {
        switch eventType {
        case 3: // Hail: magnitude in 0.25" increments
            guard magnitude > 0 else { return nil }
            let inches = Double(magnitude) * 0.25
            return String(format: "%.2f\" dia.", inches)
        case 4, 9: // Wind: magnitude in mph
            guard magnitude > 0 else { return nil }
            return "\(magnitude) mph"
        default:
            return nil
        }
    }

    var timeLabel: String {
        if minutesAgo < 60 { return "\(minutesAgo)m ago" }
        let h = minutesAgo / 60
        let m = minutesAgo % 60
        return m > 0 ? "\(h)h \(m)m ago" : "\(h)h ago"
    }
}

// MARK: - Rain Observations (0x34)

/// A decoded 0x34 rain observations response listing cities currently reporting precipitation.
struct MeshWXRainObservations: Sendable {

    struct City: Sendable {
        let placeID: Int        // index into places.json
        let rainType: UInt8     // 0=light rain,1=moderate rain,2=heavy rain,3=drizzle,4=shower,5=snow,6=sleet/freezing,7=other
        let tempF: Int8
    }

    let locationType: UInt8
    let locationIDBytes: Data
    let timestampMinutes: UInt16
    let cities: [City]
    let receivedAt: Date

    var locationKey: String {
        let hex = locationIDBytes.map { String(format: "%02x", $0) }.joined()
        return "\(locationType):\(hex)"
    }

    var timestampLabel: String {
        let h = timestampMinutes / 60
        let m = timestampMinutes % 60
        return String(format: "%02d:%02dZ", h, m)
    }
}

extension MeshWXRainObservations.City {
    var rainTypeName: String {
        switch rainType {
        case 0: return "Light Rain"
        case 1: return "Moderate Rain"
        case 2: return "Heavy Rain"
        case 3: return "Drizzle"
        case 4: return "Rain Shower"
        case 5: return "Snow"
        case 6: return "Sleet/Freezing"
        default: return "Precipitation"
        }
    }

    var rainSystemImage: String {
        switch rainType {
        case 0: return "cloud.drizzle.fill"
        case 1: return "cloud.rain.fill"
        case 2: return "cloud.heavyrain.fill"
        case 3: return "cloud.drizzle.fill"
        case 4: return "cloud.rain.fill"
        case 5: return "cloud.snow.fill"
        case 6: return "cloud.sleet.fill"
        default: return "drop.fill"
        }
    }

    var rainColor: Color {
        switch rainType {
        case 2: return .blue
        case 5: return Color(red: 0.5, green: 0.7, blue: 1.0)
        case 6: return Color(red: 0.4, green: 0.8, blue: 1.0)
        default: return .cyan
        }
    }
}

// MARK: - TAF (0x36)

/// A decoded 0x36 Terminal Aerodrome Forecast (TAF) snapshot for an aviation station.
/// 15-byte fixed format: [type(1)] [icao(4)] [time(2)] [obs_fields(8)]
struct MeshWXTAF: Sendable {
    let icao: String
    let timestampMinutes: UInt16
    let tempF: Int8          // stored in °F (converted from Celsius by decoder)
    let dewpointF: Int8
    let windDir: UInt8
    let skyCode: UInt8
    let windSpeedKts: UInt8  // knots (as sent by bot)
    let windGustKts: UInt8   // 0 = no gust
    let visibilityMi: UInt8
    let pressureRaw: UInt8
    let feelsLikeDelta: Int8 // Fahrenheit delta
    let receivedAt: Date

    var pressureInHg: Double { 29.00 + Double(pressureRaw) / 100.0 }
    var feelsLikeF: Int { Int(tempF) + Int(feelsLikeDelta) }
    var hasGust: Bool { windGustKts > 0 }
    /// Wind speed converted to mph (1 kt ≈ 1.151 mph).
    var windSpeedMph: UInt8 { UInt8(min(255, Int(windSpeedKts) * 1151 / 1000)) }
    var windGustMph: UInt8  { UInt8(min(255, Int(windGustKts)  * 1151 / 1000)) }
    /// Temperature in Celsius (converted from stored Fahrenheit).
    var tempC: Int { (Int(tempF) - 32) * 5 / 9 }
    var dewpointC: Int { (Int(dewpointF) - 32) * 5 / 9 }
    var feelsLikeC: Int { (feelsLikeF - 32) * 5 / 9 }

    var windDirName: String {
        ["N","NE","E","SE","S","SW","W","NW","Calm"][min(Int(windDir), 8)]
    }

    var skyName: String {
        switch skyCode {
        case 0: return "Clear"
        case 1: return "Few Clouds"
        case 2: return "Partly Cloudy"
        case 3: return "Mostly Cloudy"
        case 4: return "Overcast"
        case 5: return "Foggy"
        case 8: return "Rain"
        case 9: return "Snow"
        case 10: return "Thunderstorm"
        default: return "Mixed"
        }
    }

    var skySystemImage: String {
        switch skyCode {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3, 4: return "cloud.fill"
        case 5: return "cloud.fog.fill"
        case 8, 11: return "cloud.rain.fill"
        case 9: return "cloud.snow.fill"
        case 10: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    var timestampLabel: String {
        let h = timestampMinutes / 60
        let m = timestampMinutes % 60
        return String(format: "%02d:%02dZ", h, m)
    }
}

// MARK: - Warnings Near (0x37)

/// A decoded 0x37 "warnings near" response listing all active warnings affecting a zone.
struct MeshWXWarningsNear: Sendable {

    struct Entry: Sendable {
        let v2Type: UInt8          // high nibble: 1=tornado,2=severe tstorm,3=flash flood,4=flood,5=winter,6=wind,7=fire,8=marine,9=SPS
        let severity: UInt8        // low nibble: 1=advisory,2=watch,3=warning,4=emergency
        let expiryUnixMinutes: UInt32
        let stateIdx: UInt8
        let zoneNum: UInt16

        var expiryDate: Date { Date(timeIntervalSince1970: TimeInterval(expiryUnixMinutes) * 60) }

        var typeName: String {
            switch v2Type {
            case 1: return "Tornado"
            case 2: return "Severe Thunderstorm"
            case 3: return "Flash Flood"
            case 4: return "Flood"
            case 5: return "Winter Storm"
            case 6: return "High Wind"
            case 7: return "Fire Weather"
            case 8: return "Marine"
            case 9: return "Special Weather Statement"
            default: return "Weather Alert"
            }
        }

        var severityName: String {
            switch severity {
            case 1: return "Advisory"
            case 2: return "Watch"
            case 3: return "Warning"
            case 4: return "Emergency"
            default: return "Alert"
            }
        }

        var displayTitle: String { "\(typeName) \(severityName)" }

        var entryColor: Color {
            switch severity {
            case 4: return .red
            case 3: return v2Type == 1 ? .red : (v2Type == 3 ? .green : .orange)
            case 2: return .yellow
            default: return .gray
            }
        }
    }

    let locationType: UInt8
    let locationIDBytes: Data
    let entries: [Entry]
    let receivedAt: Date

    var locationKey: String {
        let hex = locationIDBytes.map { String(format: "%02x", $0) }.joined()
        return "\(locationType):\(hex)"
    }
}

// MARK: - Not Available (0x03)

/// Decoded 0x03 MSG_NOT_AVAILABLE response from the weather bot.
/// The bot sends this when it understands a request but cannot provide data.
/// Use `pendingKey` to stop the matching UI spinner and show an empty state.
struct MeshWXNotAvailable: Sendable {
    let dataType: UInt8       // hi nibble of byte 1
    let reason: UInt8         // lo nibble of byte 1
    let locationType: UInt8
    let locationIDBytes: Data

    var reasonDescription: String {
        switch reason {
        case 0x0: return "No data available"
        case 0x1: return "Unknown location"
        case 0x2: return "Product unsupported"
        case 0x3: return "Bot error"
        default:  return "Unavailable"
        }
    }

    /// Derives the pending-request key matching this response, if trackable.
    var pendingKey: String? {
        switch dataType {
        case 0x1: // FORECAST — LOC_PFM_POINT
            guard locationType == 0x06, locationIDBytes.count >= 3 else { return nil }
            let idx = (Int(locationIDBytes[0]) << 16) | (Int(locationIDBytes[1]) << 8) | Int(locationIDBytes[2])
            return "forecast:\(idx)"
        case 0x5: // METAR — LOC_STATION
            guard locationType == 0x02, locationIDBytes.count >= 4 else { return nil }
            let icao = String(bytes: locationIDBytes.prefix(4), encoding: .ascii)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
            return icao.isEmpty ? nil : "metar:\(icao)"
        case 0x6: // TAF — LOC_STATION
            guard locationType == 0x02, locationIDBytes.count >= 4 else { return nil }
            let icao = String(bytes: locationIDBytes.prefix(4), encoding: .ascii)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
            return icao.isEmpty ? nil : "taf:\(icao)"
        default:
            return nil
        }
    }
}

// MARK: - Decoder

enum MeshWXDecoder {

    // MARK: VTEC Phenomena Table (65 entries, indices 0x00–0x40)
    static let vtecPhenomena: [(code: String, name: String)] = [
        ("AF", "Ashfall"),                     // 0x00
        ("AS", "Air Stagnation"),              // 0x01
        ("BH", "Beach Hazard"),                // 0x02
        ("BS", "Blowing Snow"),                // 0x03
        ("BW", "Brisk Wind"),                  // 0x04
        ("BZ", "Blizzard"),                    // 0x05
        ("CF", "Coastal Flood"),               // 0x06
        ("DF", "Debris Flow"),                 // 0x07
        ("DS", "Dust Storm"),                  // 0x08
        ("DU", "Blowing Dust"),                // 0x09
        ("EC", "Extreme Cold"),                // 0x0A
        ("EH", "Excessive Heat"),              // 0x0B
        ("EW", "Extreme Wind"),                // 0x0C
        ("FA", "Areal Flood"),                 // 0x0D
        ("FF", "Flash Flood"),                 // 0x0E
        ("FG", "Dense Fog"),                   // 0x0F
        ("FL", "Flood"),                       // 0x10
        ("FR", "Frost"),                       // 0x11
        ("FW", "Fire Weather"),                // 0x12
        ("FZ", "Freeze"),                      // 0x13
        ("GL", "Gale"),                        // 0x14
        ("HF", "Hurricane Force Wind"),        // 0x15
        ("HT", "Heat"),                        // 0x16
        ("HU", "Hurricane"),                   // 0x17
        ("HW", "High Wind"),                   // 0x18
        ("HY", "Hydrologic"),                  // 0x19
        ("HZ", "Hard Freeze"),                 // 0x1A
        ("IP", "Sleet"),                       // 0x1B
        ("IS", "Ice Storm"),                   // 0x1C
        ("LE", "Lake Effect Snow"),            // 0x1D
        ("LO", "Low Water"),                   // 0x1E
        ("LS", "Lakeshore Flood"),             // 0x1F
        ("LW", "Lake Wind"),                   // 0x20
        ("MA", "Marine"),                      // 0x21
        ("MF", "Marine Dense Fog"),            // 0x22
        ("MH", "Marine Dense Smoke"),          // 0x23
        ("MS", "Marine Dense Smoke"),          // 0x24
        ("RB", "Small Craft Rough Bar"),       // 0x25
        ("RH", "Radiological Hazard"),         // 0x26
        ("RP", "Rip Current"),                 // 0x27
        ("SC", "Small Craft"),                 // 0x28
        ("SE", "Hazardous Seas"),              // 0x29
        ("SI", "Small Craft Winds"),           // 0x2A
        ("SM", "Dense Smoke"),                 // 0x2B
        ("SQ", "Snow Squall"),                 // 0x2C
        ("SR", "Storm"),                       // 0x2D
        ("SS", "Storm Surge"),                 // 0x2E
        ("SU", "High Surf"),                   // 0x2F
        ("SV", "Severe Thunderstorm"),         // 0x30
        ("SW", "Hazardous Seas"),              // 0x31
        ("TI", "Inland Tropical Storm Wind"),  // 0x32
        ("TO", "Tornado"),                     // 0x33
        ("TR", "Tropical Storm"),              // 0x34
        ("TS", "Tsunami"),                     // 0x35
        ("TY", "Typhoon"),                     // 0x36
        ("UP", "Heavy Freezing Spray"),        // 0x37
        ("VO", "Volcano"),                     // 0x38
        ("WC", "Wind Chill"),                  // 0x39
        ("WI", "Wind"),                        // 0x3A
        ("WS", "Winter Storm"),                // 0x3B
        ("WW", "Winter Weather"),              // 0x3C
        ("XH", "Extreme Heat"),                // 0x3D
        ("ZF", "Freezing Fog"),                // 0x3E
        ("ZR", "Freezing Rain"),               // 0x3F
        ("ZY", "Freezing Spray"),              // 0x40
    ]

    // MARK: v2 / MVP field mappings

    private static let v2TypeToPhenom: [UInt8: UInt8] = [
        0x1: 0x33, 0x2: 0x30, 0x3: 0x0E, 0x4: 0x10,
        0x5: 0x3B, 0x6: 0x18, 0x7: 0x12, 0x8: 0x21, 0x9: 0x00,
    ]
    private static let v2SevToSignificance: [UInt8: UInt8] = [
        0x1: 0x2, 0x2: 0x1, 0x3: 0x0, 0x4: 0x0,
    ]

    // MARK: Entry Point

    static func decode(_ data: Data) -> MeshWXMessage? {
        guard !data.isEmpty else { return nil }
        // If COBS decoding succeeds the data IS COBS-encoded — dispatch only on the
        // decoded content.  Falling back to decodeRaw(data) would treat the COBS
        // overhead byte as a message-type byte, potentially matching a case (e.g.
        // 0x37 warnings_near) and crashing on the misaligned payload.
        if let decoded = cobsDecode(data) { return decodeRaw(decoded) }
        return decodeRaw(data)
    }

    /// Returns true if the payload is a known protocol type that carries no decodable product data.
    /// Use this to suppress "decode failed" log noise for message types we intentionally ignore.
    /// - 0x0d: bot home/location broadcast
    /// - 0x21: warning_zones (not yet decoded on iOS)
    /// - 0x40: text_chunk (multi-part text reassembly, not decoded on iOS)
    static func isKnownNonProduct(_ data: Data) -> Bool {
        let raw = cobsDecode(data) ?? data
        guard let first = raw.first else { return false }
        return first == 0x0d || first == 0x21 || first == 0x40
    }

    private static func decodeRaw(_ data: Data) -> MeshWXMessage? {
        guard let first = data.first else { return nil }
        switch first {
        case 0x03: return decodeNotAvailable(data).map { .notAvailable($0) }
        case 0x10: return decodeRadarGrid(data).map { .radarGrid($0) }
        case 0x11: return decode0x11RadarGrid(data).map { .radarGrid($0) }
        case 0x20: return decodeWarning(data).map { .warningPolygon($0) }
        case 0x30: return decodeObservation(data).map { .observation($0) }
        case 0x31: return decodeForecast(data).map { .forecast($0) }
        case 0x32: return decodeOutlook(data).map { .outlook($0) }
        case 0x33: return decodeStormReports(data).map { .stormReports($0) }
        case 0x34: return decodeRainObservations(data).map { .rainObservations($0) }
        case 0x36: return decodeTAF(data).map { .taf($0) }
        case 0x37: return decodeWarningsNear(data).map { .warningsNear($0) }
        default:   return nil
        }
    }

    // MARK: 0x10 Radar Grid (legacy 16×16 packed nibbles)

    static func decodeRadarGrid(_ data: Data) -> MeshWXRadarFrame? {
        guard data.count >= 133, data[0] == 0x10 else { return nil }
        let regionID  = (data[1] >> 4) & 0x0F
        let frameSeq  = data[1] & 0x0F
        let timestamp = UInt16(data[2]) << 8 | UInt16(data[3])
        let scaleKm   = data[4]
        var grid = [UInt8](repeating: 0, count: 256)
        for i in 0..<128 {
            grid[i * 2]     = (data[5 + i] >> 4) & 0x0F
            grid[i * 2 + 1] = data[5 + i] & 0x0F
        }
        return MeshWXRadarFrame(regionID: regionID, frameSeq: frameSeq,
                                timestamp: timestamp, scaleKm: scaleKm,
                                gridSize: 16, grid: grid)
    }

    // MARK: 0x11 Radar Grid (variable-size, sparse or RLE, multi-message)
    //
    // Wire format:
    //  [0]     0x11
    //  [1]     (region_id << 4) | chunk_seq   — chunk_seq=0 for single-message
    //  [2]     grid_size (32 or 64)
    //  [3–4]   timestamp uint16 BE (minutes since midnight UTC)
    //  [5]     scale_km
    //  [6]     (encoding << 4) | total_chunks — encoding: 0=sparse, 1=RLE
    //                                         — total_chunks: 1 = single message
    //  [7+]    payload
    //
    // Sparse entries (encoding=0): 2 bytes each
    //   12-bit position | 4-bit value  → byte0=(pos>>4), byte1=((pos&0xF)<<4)|value
    //
    // RLE runs (encoding=1): 1 byte each
    //   4-bit run-length-minus-1 | 4-bit value  → byte=(((len-1)&0xF)<<4)|value
    //   run of 0 in high nibble = 1 cell; 15 = 16 cells

    // Buffer for multi-message 0x11 reassembly, keyed by (regionID << 16 | timestamp).
    // Including timestamp in the key allows simultaneous in-flight broadcasts for the same
    // region without collision (e.g. an old sequence still draining while a new one starts).
    nonisolated(unsafe) private static var radarChunkBuffer: [UInt32: RadarChunkAccumulator] = [:]

    private struct RadarChunkAccumulator {
        let gridSize: Int
        let timestamp: UInt16
        let scaleKm: UInt8
        let encoding: UInt8
        let totalChunks: Int
        var chunks: [Int: Data]

        var isComplete: Bool { chunks.count >= totalChunks }

        var assembledPayload: Data? {
            guard isComplete else { return nil }
            var result = Data()
            for seq in 0..<totalChunks {
                guard let chunk = chunks[seq] else { return nil }
                result.append(chunk)
            }
            return result
        }
    }

    static func decode0x11RadarGrid(_ data: Data) -> MeshWXRadarFrame? {
        guard data.count >= 7, data[0] == 0x11 else { return nil }

        let regionID    = (data[1] >> 4) & 0x0F
        let chunkSeq    = Int(data[1] & 0x0F)
        let gridSize    = Int(data[2])
        let timestamp   = UInt16(data[3]) << 8 | UInt16(data[4])
        let scaleKm     = data[5]
        let encoding    = (data[6] >> 4) & 0x0F
        let totalChunks = max(1, Int(data[6] & 0x0F))

        guard gridSize == 32 || gridSize == 64 else { return nil }

        let payload = Data(data.dropFirst(7))

        if totalChunks == 1 {
            return decodeRadarPayload(regionID: regionID, frameSeq: UInt8(chunkSeq),
                                      timestamp: timestamp, scaleKm: scaleKm,
                                      gridSize: gridSize, encoding: encoding,
                                      payload: payload)
        }

        // Multi-chunk: buffer and decode when all chunks have arrived.
        // Key includes timestamp so different broadcasts for the same region don't collide.
        let bufferKey = UInt32(regionID) << 16 | UInt32(timestamp)
        var acc = radarChunkBuffer[bufferKey] ?? RadarChunkAccumulator(
            gridSize: gridSize, timestamp: timestamp, scaleKm: scaleKm,
            encoding: encoding, totalChunks: totalChunks, chunks: [:]
        )
        acc.chunks[chunkSeq] = payload
        radarChunkBuffer[bufferKey] = acc

        guard acc.isComplete, let assembled = acc.assembledPayload else { return nil }
        radarChunkBuffer.removeValue(forKey: bufferKey)

        return decodeRadarPayload(regionID: regionID,
                                  frameSeq: 0,
                                  timestamp: acc.timestamp, scaleKm: acc.scaleKm,
                                  gridSize: acc.gridSize, encoding: acc.encoding,
                                  payload: assembled)
    }

    /// Returns chunk metadata for a 0x11 multi-chunk radar message without modifying the accumulator buffer.
    /// Returns nil if the data is not a multi-chunk 0x11 message (i.e. single-chunk or not 0x11 at all).
    static func radarChunkInfo(_ data: Data) -> (regionID: Int, chunkSeq: Int, totalChunks: Int)? {
        guard let decoded = cobsDecode(data), decoded.count >= 7, decoded[0] == 0x11 else { return nil }
        let totalChunks = max(1, Int(decoded[6] & 0x0F))
        guard totalChunks > 1 else { return nil }
        return (regionID: Int((decoded[1] >> 4) & 0x0F),
                chunkSeq:  Int(decoded[1] & 0x0F),
                totalChunks: totalChunks)
    }

    private static func decodeRadarPayload(
        regionID: UInt8, frameSeq: UInt8,
        timestamp: UInt16, scaleKm: UInt8,
        gridSize: Int, encoding: UInt8,
        payload: Data
    ) -> MeshWXRadarFrame? {
        let totalCells = gridSize * gridSize
        var grid = [UInt8](repeating: 0, count: totalCells)

        switch encoding {
        case 0: // Sparse: 2 bytes → 12-bit position + 4-bit value
            var i = payload.startIndex
            while payload.distance(from: i, to: payload.endIndex) >= 2 {
                let b0  = payload[i]
                let b1  = payload[payload.index(after: i)]
                let pos = (Int(b0) << 4) | (Int(b1) >> 4)
                let val = b1 & 0x0F
                if pos < totalCells { grid[pos] = val }
                i = payload.index(i, offsetBy: 2)
            }

        case 1: // RLE: 1 byte → (run_length - 1) in high nibble, value in low nibble
            var cellIndex = 0
            for byte in payload {
                let run   = Int((byte >> 4) & 0x0F) + 1   // 0→1 cell, 15→16 cells
                let value = byte & 0x0F
                for _ in 0..<run {
                    if cellIndex < totalCells { grid[cellIndex] = value }
                    cellIndex += 1
                }
            }

        default:
            return nil
        }

        return MeshWXRadarFrame(regionID: regionID, frameSeq: frameSeq,
                                timestamp: timestamp, scaleKm: scaleKm,
                                gridSize: gridSize, grid: grid)
    }

    // MARK: 0x20 Warning Polygon

    /// Dispatches to the appropriate decoder based on wire format.
    ///
    /// Detection order:
    ///  1. **Full VTEC** (future/deferred): ≥21 bytes, bytes 6–8 are uppercase ASCII WFO code
    ///  2. **MVP** (current live): uint32 at bytes 2–5 > 1,000,000 (absolute Unix minutes)
    ///  3. **v2** (legacy): uint16 relative expiry at bytes 2–3
    static func decodeWarning(_ data: Data) -> MeshWXWarning? {
        guard data.count >= 11, data[0] == 0x20 else { return nil }
        if isFullVTECFormat(data)  { return decodeWarningFullVTEC(data) }
        if isMVPFormat(data)       { return decodeWarningMVP(data) }
        return decodeWarningV2(data)
    }

    private static func isFullVTECFormat(_ data: Data) -> Bool {
        guard data.count >= 21 else { return false }
        return data[6] >= 0x41 && data[6] <= 0x5A &&
               data[7] >= 0x41 && data[7] <= 0x5A &&
               data[8] >= 0x41 && data[8] <= 0x5A
    }

    private static func isMVPFormat(_ data: Data) -> Bool {
        guard data.count >= 13 else { return false }
        // MVP uses absolute Unix minutes; real timestamps > ~29M (April 2026).
        // v2 used relative minutes 0–10080. Threshold of 1,000,000 cleanly separates them.
        let expiry = UInt32(data[2]) << 24 | UInt32(data[3]) << 16
                   | UInt32(data[4]) << 8  | UInt32(data[5])
        return expiry > 1_000_000
    }

    // MARK: MVP 0x20 Decoder (current live bot)
    //
    // Wire format:
    //  [0]     0x20
    //  [1]     warning_type << 4 | severity  (old nibble codes from protocol.json)
    //  [2–5]   expires_unix_min uint32 BE     (absolute — the key v3 change from v2)
    //  [6]     vertex_count uint8
    //  [7–9]   first lat int24 BE (degrees × 10000)
    //  [10–12] first lng int24 BE (degrees × 10000)
    //  [13+]   remaining vertices: int16 BE dlat (× 0.001°), int16 BE dlon (× 0.001°)
    //  then    headline UTF-8

    private static func decodeWarningMVP(_ data: Data) -> MeshWXWarning? {
        guard data.count >= 13 else { return nil }

        let v2Type      = (data[1] >> 4) & 0x0F
        let v2Sev       = data[1] & 0x0F
        let expiry      = UInt32(data[2]) << 24 | UInt32(data[3]) << 16
                        | UInt32(data[4]) << 8  | UInt32(data[5])
        let vertexCount = Int(data[6])
        guard vertexCount >= 1 else { return nil }

        let lat0 = Double(readInt24(data, offset: 7)) / 10000.0
        let lng0 = Double(readInt24(data, offset: 10)) / 10000.0
        var vertices = [CLLocationCoordinate2D(latitude: lat0, longitude: lng0)]

        let deltaStart = 13
        let available  = min(vertexCount - 1, (data.count - deltaStart) / 4)
        for i in 0..<available {
            let off  = deltaStart + i * 4
            let dLat = Int16(bitPattern: UInt16(data[off])     << 8 | UInt16(data[off + 1]))
            let dLng = Int16(bitPattern: UInt16(data[off + 2]) << 8 | UInt16(data[off + 3]))
            vertices.append(CLLocationCoordinate2D(
                latitude:  lat0 + Double(dLat) / 1000.0,
                longitude: lng0 + Double(dLng) / 1000.0
            ))
        }

        let headlineStart = deltaStart + (vertexCount - 1) * 4
        let headline = headlineStart < data.count
            ? (String(data: data[headlineStart...], encoding: .utf8) ?? "") : ""

        return makeWarning(v2Type: v2Type, v2Sev: v2Sev,
                           expiryUnixMinutes: expiry,
                           vertices: vertices, headline: headline)
    }

    // MARK: v2 Decoder (legacy)
    //
    // Wire format:
    //  [0]    0x20
    //  [1]    warning_type << 4 | severity
    //  [2–3]  expiryMinutes uint16 BE (relative to receipt time)
    //  [4]    vertex_count
    //  [5–7]  first lat int24 BE (* 10000)
    //  [8–10] first lng int24 BE (* 10000)
    //  [11+]  delta pairs: int8 dlat, int8 dln (× 0.01°)
    //  then   headline UTF-8

    private static func decodeWarningV2(_ data: Data) -> MeshWXWarning? {
        guard data.count >= 11 else { return nil }

        let v2Type      = (data[1] >> 4) & 0x0F
        let v2Sev       = data[1] & 0x0F
        let relExpiry   = UInt16(data[2]) << 8 | UInt16(data[3])
        let vertexCount = Int(data[4])
        guard vertexCount >= 1 else { return nil }

        let lat0 = Double(readInt24(data, offset: 5)) / 10000.0
        let lng0 = Double(readInt24(data, offset: 8)) / 10000.0
        var vertices = [CLLocationCoordinate2D(latitude: lat0, longitude: lng0)]

        let deltaStart = 11
        let available  = min(vertexCount - 1, (data.count - deltaStart) / 2)
        for i in 0..<available {
            let dLat = Int8(bitPattern: data[deltaStart + i * 2])
            let dLng = Int8(bitPattern: data[deltaStart + i * 2 + 1])
            vertices.append(CLLocationCoordinate2D(
                latitude:  lat0 + Double(dLat) * 0.01,
                longitude: lng0 + Double(dLng) * 0.01
            ))
        }

        let headlineStart = deltaStart + (vertexCount - 1) * 2
        let headline = headlineStart < data.count
            ? (String(data: data[headlineStart...], encoding: .utf8) ?? "") : ""

        let nowMinutes = UInt32(Date().timeIntervalSince1970 / 60)
        return makeWarning(v2Type: v2Type, v2Sev: v2Sev,
                           expiryUnixMinutes: nowMinutes + UInt32(relExpiry),
                           vertices: vertices, headline: headline)
    }

    // MARK: Full VTEC 0x20 Decoder (future/deferred)
    //
    // Wire format:
    //  [0]     0x20
    //  [1]     phenomenaIndex (VTEC table)
    //  [2]     vtecSignificance<<4 | capSeverity
    //  [3]     action
    //  [4–5]   ETN uint16 BE
    //  [6–8]   WFO office (3 uppercase ASCII chars)
    //  [9]     urgency<<4 | certainty
    //  [10–13] expiryUnixMinutes uint32 BE
    //  [14]    vertex_count
    //  [15–17] first lat int24 BE (* 10000)
    //  [18–20] first lng int24 BE (* 10000)
    //  [21+]   delta pairs: int16 BE dlat × 0.001°, int16 BE dlon × 0.001°
    //  then    headline UTF-8

    private static func decodeWarningFullVTEC(_ data: Data) -> MeshWXWarning? {
        guard data.count >= 21 else { return nil }

        let phenomenaIndex = data[1]
        let sevByte        = data[2]
        let vtecSig        = (sevByte >> 4) & 0x0F
        let capSev         = sevByte & 0x0F
        let action         = data[3]
        let etn            = UInt16(data[4]) << 8 | UInt16(data[5])
        let office         = String(bytes: [data[6], data[7], data[8]], encoding: .ascii) ?? ""
        let urgCert        = data[9]
        let urgency        = (urgCert >> 4) & 0x0F
        let certainty      = urgCert & 0x0F
        let expiry         = UInt32(data[10]) << 24 | UInt32(data[11]) << 16
                           | UInt32(data[12]) << 8  | UInt32(data[13])
        let vertexCount    = Int(data[14])
        guard vertexCount >= 1 else { return nil }

        let lat0 = Double(readInt24(data, offset: 15)) / 10000.0
        let lng0 = Double(readInt24(data, offset: 18)) / 10000.0
        var vertices = [CLLocationCoordinate2D(latitude: lat0, longitude: lng0)]

        let deltaStart = 21
        let available  = min(vertexCount - 1, (data.count - deltaStart) / 4)
        for i in 0..<available {
            let off  = deltaStart + i * 4
            let dLat = Int16(bitPattern: UInt16(data[off])     << 8 | UInt16(data[off + 1]))
            let dLng = Int16(bitPattern: UInt16(data[off + 2]) << 8 | UInt16(data[off + 3]))
            vertices.append(CLLocationCoordinate2D(
                latitude:  lat0 + Double(dLat) / 1000.0,
                longitude: lng0 + Double(dLng) / 1000.0
            ))
        }

        let headlineStart = deltaStart + (vertexCount - 1) * 4
        let headline = headlineStart < data.count
            ? (String(data: data[headlineStart...], encoding: .utf8) ?? "") : ""

        return MeshWXWarning(
            id: UUID(), phenomenaIndex: phenomenaIndex,
            vtecSignificance: vtecSig, capSeverity: capSev,
            action: action, etn: etn, office: office,
            urgency: urgency, certainty: certainty,
            expiryUnixMinutes: expiry, vertices: vertices, headline: headline
        )
    }

    private static func makeWarning(v2Type: UInt8, v2Sev: UInt8,
                                    expiryUnixMinutes: UInt32,
                                    vertices: [CLLocationCoordinate2D],
                                    headline: String) -> MeshWXWarning {
        let phenom  = v2TypeToPhenom[v2Type] ?? 0x00
        let sig     = v2SevToSignificance[v2Sev] ?? 0x02
        let capSev: UInt8 = v2Sev >= 4 ? 4 : (v2Sev >= 3 ? 3 : (v2Sev >= 2 ? 2 : 1))
        return MeshWXWarning(
            id: UUID(), phenomenaIndex: phenom,
            vtecSignificance: sig, capSeverity: capSev,
            action: 0, etn: 0, office: "",
            urgency: 0, certainty: 0,
            expiryUnixMinutes: expiryUnixMinutes,
            vertices: vertices, headline: headline
        )
    }

    // MARK: 0x31 Forecast Decoder
    //
    // Wire format:
    //  [0]       0x31
    //  [1]       location_type (1=zone,2=station,3=place,4=latlon,5=wfo,6=pfm_point)
    //  [2..N]    location_id bytes (3 bytes for pfm_point uint24)
    //  [N+1]     issued_offset (hours ago)
    //  [N+2]     period_count
    //  [N+3...]  periods: 7 bytes each
    //    +0  period_id
    //    +1  high_f  (int8, 127 = N/A)
    //    +2  low_f   (int8, 127 = N/A)
    //    +3  sky_code
    //    +4  precip_pct
    //    +5  wind_dir(4-bit) | wind_speed_nibble(4-bit)  (speed × 5 mph)
    //    +6  condition_flags

    static func decodeForecast(_ data: Data) -> MeshWXForecast? {
        guard data.count >= 5, data[0] == 0x31 else { return nil }

        let locationType = data[1]
        let idLength     = locationIDLength(locationType)
        let headerEnd    = 2 + idLength  // byte index after location_id

        guard data.count >= headerEnd + 2 else { return nil }

        let locationIDBytes  = Data(data[2..<(2 + idLength)])
        let issuedHoursAgo   = data[headerEnd]
        let periodCount      = Int(data[headerEnd + 1])
        let periodsStart     = headerEnd + 2

        guard data.count >= periodsStart + periodCount * 7 else { return nil }

        let periods: [MeshWXForecast.Period] = (0..<periodCount).map { i in
            let off = periodsStart + i * 7
            let highByte = Int8(bitPattern: data[off + 1])
            let lowByte  = Int8(bitPattern: data[off + 2])
            let windByte = data[off + 5]
            return MeshWXForecast.Period(
                periodID:       data[off],
                highF:          highByte == 127 ? nil : Int(highByte),
                lowF:           lowByte  == 127 ? nil : Int(lowByte),
                skyCode:        data[off + 3],
                precipPct:      data[off + 4],
                windDir:        (windByte >> 4) & 0x0F,
                windSpeedMph:   (windByte & 0x0F) * 5,
                conditionFlags: data[off + 6]
            )
        }

        return MeshWXForecast(
            locationType: locationType,
            locationIDBytes: locationIDBytes,
            issuedHoursAgo: issuedHoursAgo,
            periods: periods,
            receivedAt: Date()
        )
    }

    /// Returns the expected byte length of location_id for a given location_type.
    static func locationIDLength(_ locationType: UInt8) -> Int {
        switch locationType {
        case 1: return 3   // zone: state_idx(1) + zone_num(2)
        case 2: return 4   // station: ICAO 4 ASCII bytes
        case 3: return 3   // place: uint24 index
        case 4: return 8   // latlon: int32 lat + int32 lon (× 10000)
        case 5: return 2   // wfo: 2-byte index
        case 6: return 3   // pfm_point: uint24 index
        default: return 3
        }
    }

    // MARK: 0x30 Observation Decoder
    //
    // Wire format:
    //  [0]       0x30
    //  [1]       location_type (1=zone,2=station,3=place,4=latlon,5=wfo,6=pfm_point)
    //  [2..N]    location_id bytes (4 bytes for ICAO station, 3 for zone, etc.)
    //  [N+1..2]  timestamp uint16 LE (minutes since midnight UTC)
    //  [N+3]     temp_f int8
    //  [N+4]     dewpoint_f int8
    //  [N+5]     (wind_dir << 4) | sky_code — high nibble = dir, low = sky
    //  [N+6]     wind_speed_mph uint8
    //  [N+7]     wind_gust_mph uint8 (0 = no gust)
    //  [N+8]     visibility_mi uint8
    //  [N+9]     pressure uint8 — (inHg − 29.00) × 100
    //  [N+10]    feels_like_delta int8 — signed offset from temp_f

    static func decodeObservation(_ data: Data) -> MeshWXObservation? {
        guard data.count >= 2, data[0] == 0x30 else { return nil }

        let locationType = data[1]
        let idLen = locationIDLength(locationType)
        let obsStart = 2 + idLen  // first byte of observation data

        guard data.count >= obsStart + 10 else { return nil }

        let locationIDBytes = Data(data[2..<(2 + idLen)])
        let timestamp   = UInt16(data[obsStart]) | (UInt16(data[obsStart + 1]) << 8)
        // Observation data is sent in Fahrenheit by the bot — no conversion needed.
        let tempF       = Int8(bitPattern: data[obsStart + 2])
        let dewpointF   = Int8(bitPattern: data[obsStart + 3])
        let windSky     = data[obsStart + 4]
        let windDir     = (windSky >> 4) & 0x0F
        let skyCode     = windSky & 0x0F
        let windSpeedKts = data[obsStart + 5]  // knots
        let windGustKts  = data[obsStart + 6]  // knots, 0 = no gust
        let visibility  = data[obsStart + 7]
        let pressure    = data[obsStart + 8]
        let feelsLike   = Int8(bitPattern: data[obsStart + 9])  // Fahrenheit delta

        return MeshWXObservation(
            locationType: locationType,
            locationIDBytes: locationIDBytes,
            timestampMinutes: timestamp,
            tempF: tempF,
            dewpointF: dewpointF,
            windDir: windDir,
            skyCode: skyCode,
            windSpeedKts: windSpeedKts,
            windGustKts: windGustKts,
            visibilityMi: visibility,
            pressureRaw: pressure,
            feelsLikeDelta: feelsLike,
            receivedAt: Date()
        )
    }

    // MARK: 0x32 Outlook Decoder
    //
    // Wire format:
    //  [0]       0x32
    //  [1]       location_type
    //  [2..N]    location_id bytes
    //  [N+1..2]  issued_time uint16 LE (minutes since midnight UTC)
    //  [N+3]     day_count
    //  Per day:
    //    +0  day_offset (1–7)
    //    +1  hazard_count
    //    Per hazard (2 bytes): hazard_type uint8, risk_level uint8

    static func decodeOutlook(_ data: Data) -> MeshWXOutlook? {
        guard data.count >= 2, data[0] == 0x32 else { return nil }
        let locType = data[1]
        let idLen = locationIDLength(locType)
        let headerEnd = 2 + idLen
        guard data.count >= headerEnd + 3 else { return nil }

        let locationIDBytes = Data(data[2..<(2 + idLen)])
        let issued = UInt16(data[headerEnd]) | (UInt16(data[headerEnd + 1]) << 8)
        let dayCount = Int(data[headerEnd + 2])

        var days: [MeshWXOutlook.Day] = []
        var off = headerEnd + 3
        for _ in 0..<dayCount {
            guard off + 1 < data.count else { break }
            let dayOffset = data[off]
            let hazardCount = Int(data[off + 1])
            off += 2
            var hazards: [MeshWXOutlook.Day.Hazard] = []
            for _ in 0..<hazardCount {
                guard off + 1 < data.count else { break }
                hazards.append(MeshWXOutlook.Day.Hazard(hazardType: data[off], riskLevel: data[off + 1]))
                off += 2
            }
            days.append(MeshWXOutlook.Day(dayOffset: dayOffset, hazards: hazards))
        }

        return MeshWXOutlook(locationType: locType, locationIDBytes: locationIDBytes,
                             issuedTimeMinutes: issued, days: days, receivedAt: Date())
    }

    // MARK: 0x33 Storm Reports Decoder
    //
    // Wire format:
    //  [0]       0x33
    //  [1]       location_type
    //  [2..N]    location_id bytes
    //  [N+1]     report_count
    //  Per report (7 bytes):
    //    +0  event_type uint8
    //    +1  magnitude uint8
    //    +2..3  minutes_ago uint16 LE
    //    +4..6  place_id uint24 LE

    static func decodeStormReports(_ data: Data) -> MeshWXStormReports? {
        guard data.count >= 2, data[0] == 0x33 else { return nil }
        let locType = data[1]
        let idLen = locationIDLength(locType)
        let headerEnd = 2 + idLen
        guard data.count >= headerEnd + 1 else { return nil }

        let locationIDBytes = Data(data[2..<(2 + idLen)])
        let reportCount = Int(data[headerEnd])
        var reports: [MeshWXStormReports.Report] = []
        var off = headerEnd + 1
        for _ in 0..<reportCount {
            guard off + 6 < data.count else { break }
            let eventType  = data[off]
            let magnitude  = data[off + 1]
            let minutesAgo = UInt16(data[off + 2]) | (UInt16(data[off + 3]) << 8)
            let placeID    = Int(data[off + 4]) | (Int(data[off + 5]) << 8) | (Int(data[off + 6]) << 16)
            reports.append(MeshWXStormReports.Report(eventType: eventType, magnitude: magnitude,
                                                     minutesAgo: minutesAgo, placeID: placeID))
            off += 7
        }

        return MeshWXStormReports(locationType: locType, locationIDBytes: locationIDBytes,
                                  reports: reports, receivedAt: Date())
    }

    // MARK: 0x34 Rain Observations Decoder
    //
    // Wire format:
    //  [0]       0x34
    //  [1]       location_type
    //  [2..N]    location_id bytes
    //  [N+1..2]  timestamp uint16 LE (minutes since midnight UTC)
    //  [N+3]     city_count
    //  Per city (5 bytes):
    //    +0..2  place_id uint24 LE
    //    +3     rain_type uint8
    //    +4     temp_f int8

    static func decodeRainObservations(_ data: Data) -> MeshWXRainObservations? {
        guard data.count >= 2, data[0] == 0x34 else { return nil }
        let locType = data[1]
        let idLen = locationIDLength(locType)
        let headerEnd = 2 + idLen
        guard data.count >= headerEnd + 3 else { return nil }

        let locationIDBytes = Data(data[2..<(2 + idLen)])
        let timestamp  = UInt16(data[headerEnd]) | (UInt16(data[headerEnd + 1]) << 8)
        let cityCount  = Int(data[headerEnd + 2])
        var cities: [MeshWXRainObservations.City] = []
        var off = headerEnd + 3
        for _ in 0..<cityCount {
            guard off + 4 < data.count else { break }
            let placeID  = Int(data[off]) | (Int(data[off + 1]) << 8) | (Int(data[off + 2]) << 16)
            let rainType = data[off + 3]
            let tempF    = Int8(bitPattern: data[off + 4])
            cities.append(MeshWXRainObservations.City(placeID: placeID, rainType: rainType, tempF: tempF))
            off += 5
        }

        return MeshWXRainObservations(locationType: locType, locationIDBytes: locationIDBytes,
                                      timestampMinutes: timestamp, cities: cities, receivedAt: Date())
    }

    // MARK: 0x36 TAF Decoder
    //
    // Wire format:
    //  [0]     0x36
    //  [1]     loc_type byte (0x02 = LOC_STATION) — skip for field decoding
    //  [2..5]  station ICAO (4 ASCII bytes)
    //  [5..6]  time uint16 LE (minutes since midnight UTC) — overlaps last ICAO byte
    //  [7]     temp_c int8 (Celsius — converted to °F on decode)
    //  [8]     dewpoint_c int8 (Celsius)
    //  [9]     (wind_dir << 4) | sky_code
    //  [10]    wind_speed_mph uint8
    //  [11]    wind_gust_mph uint8 (0 = no gust)
    //  [12]    visibility_mi uint8
    //  [13]    pressure_raw uint8 — (inHg − 29.00) × 100
    //  [14]    feels_like_delta int8 (Celsius delta)

    static func decodeTAF(_ data: Data) -> MeshWXTAF? {
        guard data.count >= 15, data[0] == 0x36 else { return nil }
        // [1] is the loc_type byte; ICAO starts at [2]
        let icao = String(bytes: data[2..<6], encoding: .ascii)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? "????"
        let timestamp  = UInt16(data[5]) | (UInt16(data[6]) << 8)
        let tempC      = Int8(bitPattern: data[7])
        let dewC       = Int8(bitPattern: data[8])
        let windSky    = data[9]
        let windDir    = (windSky >> 4) & 0x0F
        let skyCode    = windSky & 0x0F
        let windSpeed  = data[10]
        let windGust   = data[11]
        let visibility = data[12]
        let pressure   = data[13]
        let feelsLikeC = Int8(bitPattern: data[14])

        // Bot sends temperatures in Celsius; convert to Fahrenheit for display
        let tempF      = Int8(max(-128, min(127, Int(tempC)     * 9 / 5 + 32)))
        let dewF       = Int8(max(-128, min(127, Int(dewC)      * 9 / 5 + 32)))
        let feelsLikeF = Int8(max(-128, min(127, Int(feelsLikeC) * 9 / 5)))

        return MeshWXTAF(icao: icao, timestampMinutes: timestamp,
                         tempF: tempF, dewpointF: dewF,
                         windDir: windDir, skyCode: skyCode,
                         windSpeedKts: windSpeed, windGustKts: windGust,
                         visibilityMi: visibility, pressureRaw: pressure,
                         feelsLikeDelta: feelsLikeF, receivedAt: Date())
    }

    // MARK: 0x37 Warnings Near Decoder
    //
    // Wire format:
    //  [0]       0x37
    //  [1]       location_type
    //  [2..N]    location_id bytes
    //  [N+1]     entry_count
    //  Per entry (8 bytes):
    //    +0  warning_type(high nibble) | severity(low nibble)
    //    +1..4  expires_unix_min uint32 BE
    //    +5  state_idx uint8
    //    +6..7  zone_num uint16 BE

    static func decodeWarningsNear(_ data: Data) -> MeshWXWarningsNear? {
        guard data.count >= 2, data[0] == 0x37 else { return nil }
        let locType = data[1]
        let idLen = locationIDLength(locType)
        let headerEnd = 2 + idLen
        guard data.count >= headerEnd + 1 else { return nil }

        let locationIDBytes = Data(data[2..<(2 + idLen)])
        let entryCount = Int(data[headerEnd])
        var entries: [MeshWXWarningsNear.Entry] = []
        var off = headerEnd + 1
        for _ in 0..<entryCount {
            guard off + 7 < data.count else { break }
            let typeSev  = data[off]
            let v2Type   = (typeSev >> 4) & 0x0F
            let severity = typeSev & 0x0F
            let expiry   = UInt32(data[off + 1]) << 24 | UInt32(data[off + 2]) << 16
                         | UInt32(data[off + 3]) << 8  | UInt32(data[off + 4])
            let stateIdx = data[off + 5]
            let zoneNum  = UInt16(data[off + 6]) << 8 | UInt16(data[off + 7])
            entries.append(MeshWXWarningsNear.Entry(v2Type: v2Type, severity: severity,
                                                    expiryUnixMinutes: expiry,
                                                    stateIdx: stateIdx, zoneNum: zoneNum))
            off += 8
        }

        return MeshWXWarningsNear(locationType: locType, locationIDBytes: locationIDBytes,
                                  entries: entries, receivedAt: Date())
    }

    // MARK: 0x03 Not Available Decoder

    /// Decodes a 0x03 MSG_NOT_AVAILABLE response.
    private static func decodeNotAvailable(_ data: Data) -> MeshWXNotAvailable? {
        guard data.count >= 3, data[0] == 0x03 else { return nil }
        let dataType = (data[1] >> 4) & 0x0F
        let reason   = data[1] & 0x0F
        let locationType = data[2]
        let idLen = locationIDLength(locationType)
        guard data.count >= 3 + idLen else { return nil }
        let locationIDBytes = Data(data[3..<(3 + idLen)])
        return MeshWXNotAvailable(
            dataType: dataType, reason: reason,
            locationType: locationType, locationIDBytes: locationIDBytes
        )
    }

    // MARK: 0x02 Request Builder

    /// Builds an 8-byte 0x02 FORECAST data request for a PFM point index.
    /// Send this as a direct message (DM) to the weather bot.
    ///
    /// Wire format:
    ///  [0]   0x02 (data_request)
    ///  [1]   data_type(4-bit) << 4 | flags(4-bit)  — 0x10 for FORECAST
    ///  [2–3] client_newest uint16 LE (minutes since midnight UTC; 0 = no cache)
    ///  [4]   location_type = 0x06 (pfm_point)
    ///  [5–7] pfm_point index uint24 BE
    static func buildForecastRequest(pfmPointIndex: Int) -> Data {
        var data = Data(count: 8)
        data[0] = 0x02
        data[1] = 0x10   // data_type = 1 (FORECAST) << 4 | flags = 0
        data[2] = 0x00   // client_newest low byte (LE, value 0)
        data[3] = 0x00   // client_newest high byte
        data[4] = 0x06   // LOC_PFM_POINT
        let idx = UInt32(pfmPointIndex)
        data[5] = UInt8((idx >> 16) & 0xFF)
        data[6] = UInt8((idx >> 8)  & 0xFF)
        data[7] = UInt8(idx         & 0xFF)
        return data
    }

    /// Builds a 0x02 METAR/observation request for a station by ICAO code.
    ///
    /// Wire format:
    ///  [0]   0x02
    ///  [1]   0x50 (data_type = 5 METAR << 4)
    ///  [2–3] client_newest uint16 LE (0 = no cache)
    ///  [4]   location_type = 0x02 (station)
    ///  [5–8] ICAO code as 4 ASCII bytes (zero-padded if shorter)
    static func buildMetarRequest(icao: String) -> Data {
        var data = Data(count: 9)
        data[0] = 0x02
        data[1] = 0x50   // data_type = 5 (METAR/observation)
        data[2] = 0x00
        data[3] = 0x00
        data[4] = 0x02   // LOC_STATION
        let bytes = Array(icao.utf8.prefix(4))
        for (i, b) in bytes.enumerated() { data[5 + i] = b }
        return data
    }

    /// Builds a 0x02 data request for a pfm_point index with the given data_type nibble.
    private static func buildPFMPointRequest(dataType: UInt8, pfmPointIndex: Int) -> Data {
        var data = Data(count: 8)
        data[0] = 0x02
        data[1] = (dataType & 0x0F) << 4
        data[2] = 0x00
        data[3] = 0x00
        data[4] = 0x06  // LOC_PFM_POINT
        let idx = UInt32(pfmPointIndex)
        data[5] = UInt8((idx >> 16) & 0xFF)
        data[6] = UInt8((idx >> 8)  & 0xFF)
        data[7] = UInt8(idx         & 0xFF)
        return data
    }

    /// Builds a 0x02 DATA_OUTLOOK (data_type=2) request for a pfm_point.
    static func buildOutlookRequest(pfmPointIndex: Int) -> Data {
        buildPFMPointRequest(dataType: 0x2, pfmPointIndex: pfmPointIndex)
    }

    /// Builds a 0x02 DATA_STORM_REPORTS (data_type=3) request for a pfm_point.
    static func buildStormReportsRequest(pfmPointIndex: Int) -> Data {
        buildPFMPointRequest(dataType: 0x3, pfmPointIndex: pfmPointIndex)
    }

    /// Builds a 0x02 DATA_RAIN_OBS (data_type=4) request for a pfm_point.
    static func buildRainObsRequest(pfmPointIndex: Int) -> Data {
        buildPFMPointRequest(dataType: 0x4, pfmPointIndex: pfmPointIndex)
    }

    /// Builds a 0x02 DATA_TAF (data_type=6) request for a station ICAO code.
    static func buildTAFRequest(icao: String) -> Data {
        var data = Data(count: 9)
        data[0] = 0x02
        data[1] = 0x60  // data_type = 6 (TAF)
        data[2] = 0x00
        data[3] = 0x00
        data[4] = 0x02  // LOC_STATION
        let bytes = Array(icao.utf8.prefix(4))
        for (i, b) in bytes.enumerated() { data[5 + i] = b }
        return data
    }

    /// Builds a 0x02 DATA_WARNINGS_NEAR (data_type=7) request for a pfm_point.
    static func buildWarningsNearRequest(pfmPointIndex: Int) -> Data {
        buildPFMPointRequest(dataType: 0x7, pfmPointIndex: pfmPointIndex)
    }

    // MARK: Helpers

    private static func readInt24(_ data: Data, offset: Int) -> Int32 {
        let raw = (Int32(data[offset]) << 16) | (Int32(data[offset + 1]) << 8) | Int32(data[offset + 2])
        return raw & 0x800000 != 0 ? raw | Int32(bitPattern: 0xFF000000) : raw
    }

    // MARK: COBS

    static func cobsDecode(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var output = Data()
        output.reserveCapacity(data.count)
        var index = data.startIndex
        while index < data.endIndex {
            let code = data[index]
            index = data.index(after: index)
            guard code != 0 else { return nil }
            let runLength = Int(code) - 1
            guard data.distance(from: index, to: data.endIndex) >= runLength else { return nil }
            output.append(contentsOf: data[index..<data.index(index, offsetBy: runLength)])
            index = data.index(index, offsetBy: runLength)
            if code < 0xFF && index < data.endIndex { output.append(0x00) }
        }
        return output
    }

    static func cobsEncode(_ data: Data) -> Data {
        var output = Data()
        output.reserveCapacity(data.count + data.count / 254 + 1)
        var blockStart = output.count
        output.append(0)
        var runLength: UInt8 = 1
        for byte in data {
            if byte == 0x00 {
                output[blockStart] = runLength
                blockStart = output.count
                output.append(0)
                runLength = 1
            } else {
                output.append(byte)
                runLength += 1
                if runLength == 0xFF {
                    output[blockStart] = runLength
                    blockStart = output.count
                    output.append(0)
                    runLength = 1
                }
            }
        }
        output[blockStart] = runLength
        return output
    }
}

// MARK: - Display Names

extension MeshWXWarning {

    var typeName: String {
        let idx = Int(phenomenaIndex)
        guard idx < MeshWXDecoder.vtecPhenomena.count else { return "Weather" }
        return MeshWXDecoder.vtecPhenomena[idx].name
    }

    var phenomenaCode: String {
        let idx = Int(phenomenaIndex)
        guard idx < MeshWXDecoder.vtecPhenomena.count else { return "??" }
        return MeshWXDecoder.vtecPhenomena[idx].code
    }

    var severityName: String {
        switch vtecSignificance {
        case 0x0: return "Warning";  case 0x1: return "Watch"
        case 0x2: return "Advisory"; case 0x3: return "Statement"
        case 0x4: return "Forecast"; case 0x5: return "Outlook"
        case 0x6: return "Synopsis"; default:  return "Alert"
        }
    }

    var actionName: String {
        switch action {
        case 0: return "NEW"; case 1: return "CON"; case 2: return "EXT"
        case 3: return "EXA"; case 4: return "EXB"; case 5: return "UPG"
        case 6: return "CAN"; case 7: return "EXP"; case 8: return "COR"
        case 9: return "ROU"; default: return "???"
        }
    }

    var displayTitle: String { "\(typeName) \(severityName)" }
}

// MARK: - Warning Colors

extension MeshWXWarning {

    var swiftUIColor: Color {
        switch vtecSignificance {
        case 0x0: return phenomenaWarningColor
        case 0x1: return phenomenaWatchColor
        case 0x2: return .yellow
        case 0x3: return .blue
        default:  return .gray
        }
    }

    private var phenomenaWarningColor: Color {
        switch phenomenaIndex {
        case 0x33: return .red
        case 0x30: return Color(red: 1.0, green: 0.3, blue: 0)
        case 0x0E: return .green
        case 0x10: return Color(red: 0, green: 0.5, blue: 0)
        case 0x3B: return .blue
        case 0x35: return .purple
        case 0x12: return Color(red: 0.8, green: 0.4, blue: 0)
        default:   return .red
        }
    }

    private var phenomenaWatchColor: Color {
        switch phenomenaIndex {
        case 0x33: return Color(red: 1.0, green: 0.5, blue: 0)
        case 0x0E, 0x10: return Color(red: 0, green: 0.7, blue: 0)
        default:   return .orange
        }
    }
}

// MARK: - Reflectivity Colors

extension MeshWXRadarFrame {
    static func reflectivityColor(for level: UInt8) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        switch level {
        case 0x0: return (0,   0,   0,   0)
        case 0x1: return (0,   236, 224, 255)
        case 0x2: return (1,   160, 246, 255)
        case 0x3: return (0,   0,   246, 255)
        case 0x4: return (0,   255, 0,   255)
        case 0x5: return (0,   200, 0,   255)
        case 0x6: return (0,   144, 0,   255)
        case 0x7: return (255, 255, 0,   255)
        case 0x8: return (231, 192, 0,   255)
        case 0x9: return (255, 144, 0,   255)
        case 0xA: return (255, 0,   0,   255)
        case 0xB: return (214, 0,   0,   255)
        case 0xC: return (192, 0,   0,   255)
        case 0xD: return (255, 0,   255, 255)
        case 0xE: return (153, 85,  201, 255)
        default:  return (0,   0,   0,   0)
        }
    }
}

// MARK: - Region Definitions

struct MeshWXRegion: Sendable {
    let id: UInt8; let name: String
    let north: Double; let south: Double; let west: Double; let east: Double
    /// Default scale in km per grid cell for this region (from regions.json).
    let scaleKm: Int

    var centerLatitude: Double  { (north + south) / 2.0 }
    var centerLongitude: Double { (west + east)  / 2.0 }

    // MARK: - Bundle Loading

    nonisolated(unsafe) private static var _all: [UInt8: MeshWXRegion]?

    /// All known radar regions, loaded from regions.json (with hardcoded fallback).
    static var all: [UInt8: MeshWXRegion] {
        if let cached = _all { return cached }
        _all = loadFromBundle() ?? hardcoded
        return _all!
    }

    private static func loadFromBundle() -> [UInt8: MeshWXRegion]? {
        guard let url = Bundle.main.url(forResource: "regions", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return nil
        }
        var result: [UInt8: MeshWXRegion] = [:]
        for (key, dict) in root {
            let idVal: UInt8
            if (key.hasPrefix("0x") || key.hasPrefix("0X")),
               let parsed = UInt8(key.dropFirst(2), radix: 16) {
                idVal = parsed
            } else if let parsed = UInt8(key) {
                idVal = parsed
            } else { continue }
            guard let name  = dict["name"]  as? String,
                  let north = (dict["north"] as? NSNumber)?.doubleValue,
                  let south = (dict["south"] as? NSNumber)?.doubleValue,
                  let west  = (dict["west"]  as? NSNumber)?.doubleValue,
                  let east  = (dict["east"]  as? NSNumber)?.doubleValue else { continue }
            let scaleKm = (dict["scale_km"] as? NSNumber)?.intValue ?? 55
            result[idVal] = MeshWXRegion(id: idVal, name: name,
                                         north: north, south: south, west: west, east: east,
                                         scaleKm: scaleKm)
        }
        return result.isEmpty ? nil : result
    }

    /// Hardcoded fallback matching regions.json — used if the bundle file is unavailable.
    private static let hardcoded: [UInt8: MeshWXRegion] = [
        0x0: MeshWXRegion(id: 0x0, name: "Northeast",     north: 48,   south: 37, west: -82,  east: -67,  scaleKm: 55),
        0x1: MeshWXRegion(id: 0x1, name: "Southeast",     north: 37,   south: 24, west: -92,  east: -75,  scaleKm: 55),
        0x2: MeshWXRegion(id: 0x2, name: "Upper Midwest", north: 50,   south: 40, west: -98,  east: -82,  scaleKm: 55),
        0x3: MeshWXRegion(id: 0x3, name: "Southern",      north: 37,   south: 25, west: -105, east: -88,  scaleKm: 55),
        0x4: MeshWXRegion(id: 0x4, name: "Central",       north: 44,   south: 34, west: -105, east: -90,  scaleKm: 55),
        0x5: MeshWXRegion(id: 0x5, name: "Mountain",      north: 49,   south: 31, west: -117, east: -102, scaleKm: 55),
        0x6: MeshWXRegion(id: 0x6, name: "Pacific",       north: 49,   south: 32, west: -125, east: -114, scaleKm: 40),
        0x7: MeshWXRegion(id: 0x7, name: "Alaska",        north: 72,   south: 51, west: -180, east: -130, scaleKm: 175),
        0x8: MeshWXRegion(id: 0x8, name: "Hawaii",        north: 23,   south: 18, west: -161, east: -154, scaleKm: 28),
        0x9: MeshWXRegion(id: 0x9, name: "Puerto Rico",   north: 19.5, south: 17, west: -68,  east: -65,  scaleKm: 12),
    ]

    static func region(for coordinate: CLLocationCoordinate2D) -> MeshWXRegion? {
        all.values.first {
            coordinate.latitude  >= $0.south && coordinate.latitude  <= $0.north &&
            coordinate.longitude >= $0.west  && coordinate.longitude <= $0.east
        }
    }
}
