import CoreLocation
import Foundation
import os

private let logger = Logger(subsystem: "com.mc1", category: "WeatherCache")

/// In-memory cache for MeshWX weather data received from the #wx-broadcast channel.
///
/// Stores warning polygons and radar frames, handling deduplication and expiry.
/// Observable so map views can react to new weather data.
@Observable
@MainActor
final class WeatherCache {

    // MARK: - Message Log

    /// A single entry in the weather message log (for the Tools debug view).
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let rawSize: Int
        let hexDump: String
        let decoded: MeshWXMessage?
        let summary: String
    }

    /// Rolling log of all raw messages received on the wx-broadcast channel.
    private(set) var messageLog: [LogEntry] = []

    /// Maximum log entries to keep in memory.
    private let maxLogEntries = 200

    /// Count of ALL channel messages received (across all channels), for debugging delivery.
    private(set) var totalChannelMessagesReceived: Int = 0

    /// Last few channel names seen (for debugging which channels are active).
    private(set) var recentChannelNames: [String] = []

    /// Records that a channel message was received (any channel, for debugging).
    func logChannelMessageReceived(channelName: String?) {
        totalChannelMessagesReceived += 1
        let name = channelName ?? "(nil)"
        if !recentChannelNames.contains(name) {
            recentChannelNames.append(name)
            if recentChannelNames.count > 20 {
                recentChannelNames.removeFirst()
            }
        }
    }

    /// Records a raw payload and its decode result in the message log.
    func logMessage(rawPayload: Data, decoded: MeshWXMessage?) {
        // Partial chunks of a multi-chunk radar message return nil while buffering — not a failure.
        // Skip these; only the final assembled frame (non-nil) will appear in the log.
        if decoded == nil, MeshWXDecoder.radarChunkInfo(rawPayload) != nil { return }

        let hex = rawPayload.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
        let summary: String
        switch decoded {
        case .warningPolygon(let w):
            let officeTag = w.office.isEmpty ? "" : " [\(w.office)]"
            summary = "\(w.actionName) \(w.displayTitle)\(officeTag) — \(w.vertices.count) vertices, exp \(w.expiryMinutes)m"
        case .radarGrid(let r):
            summary = "Radar region \(r.regionID) seq \(r.frameSeq)"
        case .forecast(let f):
            summary = "Forecast \(f.periods.count) periods"
        case .observation(let o):
            summary = "Obs \(o.displayName) \(o.tempF)°F \(o.skyName) wind \(o.windDirName) \(o.windSpeedMph)mph"
        case .outlook(let o):
            summary = "Outlook \(o.days.count) days"
        case .stormReports(let s):
            summary = "Storm reports \(s.reports.count) reports"
        case .rainObservations(let r):
            summary = "Rain obs \(r.cities.count) cities"
        case .taf(let t):
            summary = "TAF \(t.icao) \(t.tempF)°F \(t.skyName)"
        case .warningsNear(let w):
            summary = "Warnings near \(w.entries.count) entries"
        case .qpfGrid(let r):
            summary = "QPF grid region \(r.regionID) \(r.gridSize)×\(r.gridSize)"
        case .fireWeather(let fw):
            summary = "Fire weather \(fw.periods.count) periods"
        case .dailyClimate(let dc):
            summary = "Daily climate \(dc.cities.count) cities (\(dc.dayLabel))"
        case .nowcast(let n):
            let urgency = n.isUrgent ? " ⚠️ urgent" : ""
            summary = "Nowcast \(n.validHours)h\(urgency)"
        case .notAvailable(let na):
            let key = na.pendingKey ?? "unknown"
            summary = "NOT_AVAILABLE '\(key)': \(na.reasonDescription)"
        case nil:
            // COBS-decode to get the actual message type byte (rawPayload is still COBS-encoded)
            let decodedPayload = MeshWXDecoder.cobsDecode(rawPayload) ?? rawPayload
            let first = decodedPayload.first.map { String(format: "0x%02x", $0) } ?? "empty"
            summary = "Decode failed (type: \(first), \(rawPayload.count)B)"
        }

        let entry = LogEntry(
            timestamp: Date(),
            rawSize: rawPayload.count,
            hexDump: hex,
            decoded: decoded,
            summary: summary
        )

        messageLog.append(entry)
        if messageLog.count > maxLogEntries {
            messageLog.removeFirst(messageLog.count - maxLogEntries)
        }
    }

    // MARK: - Warnings

    /// Active warnings, deduplicated and auto-pruned.
    private(set) var warnings: [MeshWXWarning] = []

    // MARK: - Radar

    /// Latest radar frame per region. Keyed by region ID.
    private(set) var radarFrames: [UInt8: [MeshWXRadarFrame]] = [:]

    // MARK: - Forecasts

    /// Most recent forecast per pfm_point index. Keyed by pfmPointIndex.
    private(set) var forecasts: [Int: MeshWXForecast] = [:]

    /// Maps pfmPointIndex → ICAO of the station that triggered the forecast request.
    /// Set when the user explicitly requests a forecast from an observation's context menu.
    /// Used to group the forecast visually with its requesting station.
    private(set) var forecastOrigins: [Int: String] = [:]

    func setForecastOrigin(pfmPointIndex: Int, icao: String) {
        forecastOrigins[pfmPointIndex] = icao
    }

    // MARK: - Observations

    /// Latest observation per location key. Keyed by MeshWXObservation.locationKey.
    private(set) var observations: [String: MeshWXObservation] = [:]

    // MARK: - Outlooks

    /// Latest HWO outlook per location key. Keyed by MeshWXOutlook.locationKey.
    private(set) var outlooks: [String: MeshWXOutlook] = [:]

    // MARK: - Storm Reports

    /// Latest LSR storm reports per location key.
    private(set) var stormReports: [String: MeshWXStormReports] = [:]

    // MARK: - Rain Observations

    /// Latest rain observations per location key.
    private(set) var rainObservations: [String: MeshWXRainObservations] = [:]

    // MARK: - TAFs

    /// Latest TAF per ICAO station.
    private(set) var tafs: [String: MeshWXTAF] = [:]

    // MARK: - Warnings Near

    /// Latest warnings-near response per location key.
    private(set) var warningsNear: [String: MeshWXWarningsNear] = [:]

    // MARK: - v4 New Products

    /// Latest nowcast (short-term forecast) per location key.
    private(set) var nowcasts: [String: MeshWXNowcast] = [:]

    /// Latest fire weather forecast per location key.
    private(set) var fireWeathers: [String: MeshWXFireWeather] = [:]

    /// Latest daily climate report (regional hi/lo/precip). Replaced each broadcast.
    private(set) var dailyClimate: MeshWXDailyClimate?

    /// Latest QPF (quantitative precipitation forecast) frame per region.
    private(set) var qpfFrames: [UInt8: MeshWXRadarFrame] = [:]

    // MARK: - Pending Requests

    /// Keys of in-flight product requests (present = awaiting bot response).
    /// Format: "metar:ICAO", "forecast:pfmIdx", "taf:ICAO".
    /// Cleared automatically when data arrives; lets the UI show a spinner.
    private(set) var pendingKeys: Set<String> = []

    /// Keys the local user has ever explicitly requested (never cleared on data arrival).
    /// Used to separate "Your Requests" from "Broadcasts" in the Weather tab.
    private(set) var requestedKeys: Set<String> = []

    /// Keys for which the bot replied NOT_AVAILABLE, mapped to the reason code.
    /// Cleared when a new request is sent or real data arrives for the same key.
    private(set) var unavailableKeys: [String: UInt8] = [:]

    func addPending(_ key: String) {
        unavailableKeys.removeValue(forKey: key)  // clear stale not-available state
        pendingKeys.insert(key)
        requestedKeys.insert(key)
    }
    func clearPending(_ key: String) {
        pendingKeys.remove(key)
        unavailableKeys.removeValue(forKey: key)  // data arrived — clear unavailable too
    }
    func isPending(_ key: String) -> Bool { pendingKeys.contains(key) }

    /// Transient notice shown briefly in the UI when the bot replies NOT_AVAILABLE.
    /// Nil = nothing to show. Auto-cleared by the view after display.
    private(set) var notAvailableNotice: String? = nil

    func clearNotAvailableNotice() { notAvailableNotice = nil }

    /// Marks a key as NOT_AVAILABLE, clears its pending state, and sets the transient notice.
    func markUnavailable(_ key: String, reason: UInt8) {
        pendingKeys.remove(key)
        unavailableKeys[key] = reason
        let product: String
        if key.hasPrefix("metar:") {
            product = "\(key.dropFirst(6)) conditions"
        } else if key.hasPrefix("taf:") {
            product = "\(key.dropFirst(4)) TAF"
        } else if key.hasPrefix("forecast:") {
            product = "forecast"
        } else {
            product = key
        }
        let suffix: String
        switch reason {
        case 0x1: suffix = " — unknown location"
        case 0x3: suffix = " — bot error"
        default:  suffix = ""
        }
        notAvailableNotice = "\(product) not available\(suffix)"
    }
    func isUnavailable(_ key: String) -> Bool { unavailableKeys[key] != nil }
    func unavailableReason(for key: String) -> UInt8? { unavailableKeys[key] }
    func isRequested(_ key: String) -> Bool { requestedKeys.contains(key) }

    /// Maximum radar frames to keep per region (ring buffer).
    private let maxFramesPerRegion = 12

    // MARK: - Ingest

    /// Ingest a decoded warning, handling v3 action codes for correct cache management.
    ///
    /// - CAN/EXP: removes the matching warning from the active list.
    /// - NEW/UPG: inserts or replaces.
    /// - CON/EXT/EXA/EXB/COR/ROU: updates an existing entry, or inserts if not found.
    func ingestWarning(_ warning: MeshWXWarning) {
        pruneExpiredWarnings()

        if warning.isTerminating {
            // CAN or EXP — remove the warning from active list
            let before = warnings.count
            warnings.removeAll { $0.dedupKey == warning.dedupKey }
            logger.info("Warning removed (\(warning.actionName)): \(warning.displayTitle), removed \(before - self.warnings.count) entries")
            return
        }

        if let existingIndex = warnings.firstIndex(where: { $0.dedupKey == warning.dedupKey }) {
            warnings[existingIndex] = warning
            logger.debug("Warning updated (\(warning.actionName)): \(warning.displayTitle)")
        } else {
            warnings.append(warning)
            logger.info("Warning ingested (\(warning.actionName)): \(warning.displayTitle) [\(warning.office)] ETN=\(warning.etn) (\(warning.vertices.count) vertices)")
        }
    }

    /// Ingest a decoded forecast, replacing any older forecast for the same pfm_point.
    /// Non-pfm_point forecasts (no stable index) are stored under key -1.
    func ingestForecast(_ forecast: MeshWXForecast) {
        let key = forecast.pfmPointIndex ?? -1
        forecasts[key] = forecast
        clearPending("forecast:\(key)")
        logger.debug("Forecast ingested: pfmPoint \(key), \(forecast.periods.count) periods")
    }

    /// Ingest a current-conditions observation, replacing any older one for the same location.
    /// If the incoming obs has the same METAR issuance time as the cached one, the update is
    /// skipped so that `receivedAt` reflects when the data was first received, not each rebroadcast.
    func ingestObservation(_ observation: MeshWXObservation) {
        if let existing = observations[observation.locationKey],
           existing.timestampMinutes == observation.timestampMinutes {
            // Same METAR issuance rebroadcast — keep original receivedAt, just clear pending
            clearPending("metar:\(observation.displayName)")
            return
        }
        observations[observation.locationKey] = observation
        clearPending("metar:\(observation.displayName)")
        logger.debug("Observation ingested: \(observation.displayName) \(observation.tempF)°F")
    }

    /// Ingest an HWO outlook, replacing any older one for the same location.
    func ingestOutlook(_ outlook: MeshWXOutlook) {
        outlooks[outlook.locationKey] = outlook
        logger.debug("Outlook ingested: \(outlook.days.count) days")
    }

    /// Ingest LSR storm reports, replacing any older ones for the same location.
    func ingestStormReports(_ reports: MeshWXStormReports) {
        stormReports[reports.locationKey] = reports
        logger.debug("Storm reports ingested: \(reports.reports.count) reports")
    }

    /// Ingest rain observations, replacing any older ones for the same location.
    func ingestRainObservations(_ obs: MeshWXRainObservations) {
        rainObservations[obs.locationKey] = obs
        logger.debug("Rain observations ingested: \(obs.cities.count) cities")
    }

    /// Ingest a TAF, replacing any older one for the same station.
    func ingestTAF(_ taf: MeshWXTAF) {
        tafs[taf.icao] = taf
        clearPending("taf:\(taf.icao)")
        logger.debug("TAF ingested: \(taf.icao) \(taf.tempF)°F")
    }

    /// Ingest a warnings-near response, replacing any older one for the same location.
    func ingestWarningsNear(_ warnings: MeshWXWarningsNear) {
        warningsNear[warnings.locationKey] = warnings
        logger.debug("Warnings-near ingested: \(warnings.entries.count) entries")
    }

    /// Ingest a nowcast, replacing any older one for the same location.
    func ingestNowcast(_ nowcast: MeshWXNowcast) {
        nowcasts[nowcast.locationKey] = nowcast
        logger.debug("Nowcast ingested: \(nowcast.validHours)h valid, urgent=\(nowcast.isUrgent)")
    }

    /// Ingest a fire weather forecast, replacing any older one for the same location.
    func ingestFireWeather(_ fw: MeshWXFireWeather) {
        fireWeathers[fw.locationKey] = fw
        logger.debug("Fire weather ingested: \(fw.periods.count) periods")
    }

    /// Ingest a daily climate report. Always replaces the previous one.
    func ingestDailyClimate(_ dc: MeshWXDailyClimate) {
        dailyClimate = dc
        logger.debug("Daily climate ingested: \(dc.cities.count) cities, \(dc.dayLabel)")
    }

    /// Ingest a QPF grid frame, keeping only the latest per region.
    func ingestQPFFrame(_ frame: MeshWXRadarFrame) {
        qpfFrames[frame.regionID] = frame
        logger.debug("QPF frame ingested: region \(frame.regionID)")
    }

    /// Ingest a decoded radar frame, keeping a ring buffer per region.
    func ingestRadarFrame(_ frame: MeshWXRadarFrame) {
        var frames = radarFrames[frame.regionID] ?? []

        // Deduplicate by timestamp
        if frames.contains(where: { $0.timestamp == frame.timestamp }) {
            return
        }

        frames.append(frame)

        // Keep only the most recent frames
        if frames.count > maxFramesPerRegion {
            frames.removeFirst(frames.count - maxFramesPerRegion)
        }

        radarFrames[frame.regionID] = frames
        logger.debug("Radar frame ingested: region \(frame.regionID), seq \(frame.frameSeq)")
    }

    // MARK: - Pruning

    /// Remove warnings that have passed their expiry date.
    func pruneExpiredWarnings() {
        let now = Date()
        let before = warnings.count
        warnings.removeAll { $0.expiryDate < now }
        let removed = before - warnings.count
        if removed > 0 {
            logger.debug("Pruned \(removed) expired warnings")
        }
    }

    /// Starts a loop that prunes expired warnings every 60 seconds.
    /// Call once after the cache is loaded. Safe to call multiple times — subsequent calls are ignored.
    func startExpiryTimer() {
        guard expiryTimerTask == nil else { return }
        expiryTimerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                pruneExpiredWarnings()
            }
        }
    }

    private var expiryTimerTask: Task<Void, Never>?

    /// Removes a single forecast by its pfm_point key and rewrites the persisted file without it.
    /// Also clears the forecastOrigins entry so the station group is cleaned up.
    func removeForecast(key: Int) {
        forecasts.removeValue(forKey: key)
        forecastOrigins.removeValue(forKey: key)
        let fileURL = Self.cacheFileURL
        Task.detached(priority: .utility) {
            guard var saved = try? JSONDecoder().decode(PersistedWeatherData.self,
                                                       from: Data(contentsOf: fileURL)) else { return }
            // Decode each payload and drop those matching this key
            saved.forecastPayloads = saved.forecastPayloads.filter { payload in
                guard let msg = MeshWXDecoder.decode(payload),
                      case .forecast(let f) = msg else { return false }
                return f.pfmPointIndex != key
            }
            try? JSONEncoder().encode(saved).write(to: fileURL)
        }
    }

    func removeObservation(key: String) { observations.removeValue(forKey: key) }
    func removeTAF(icao: String)        { tafs.removeValue(forKey: icao) }
    func removeOutlook(key: String)     { outlooks.removeValue(forKey: key) }
    func removeStormReports(key: String){ stormReports.removeValue(forKey: key) }
    func removeRainObservations(key: String) { rainObservations.removeValue(forKey: key) }
    func removeWarningsNear(key: String){ warningsNear.removeValue(forKey: key) }

    /// Clears all cached data and the on-disk persistence file.
    func clearAll() {
        warnings.removeAll()
        radarFrames.removeAll()
        forecasts.removeAll()
        forecastOrigins.removeAll()
        observations.removeAll()
        outlooks.removeAll()
        stormReports.removeAll()
        rainObservations.removeAll()
        tafs.removeAll()
        warningsNear.removeAll()
        nowcasts.removeAll()
        fireWeathers.removeAll()
        dailyClimate = nil
        qpfFrames.removeAll()
        pendingKeys.removeAll()
        requestedKeys.removeAll()
        unavailableKeys.removeAll()
        notAvailableNotice = nil
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: Self.cacheFileURL)
        }
    }

    // MARK: - Queries

    /// Returns the latest radar frame for a given region, if any.
    func latestRadarFrame(for regionID: UInt8) -> MeshWXRadarFrame? {
        radarFrames[regionID]?.last
    }

    /// Returns all region IDs that have radar data.
    var activeRadarRegions: Set<UInt8> {
        Set(radarFrames.keys.filter { !(radarFrames[$0]?.isEmpty ?? true) })
    }

    /// True if there is any weather data to display.
    var hasData: Bool {
        !warnings.isEmpty || !radarFrames.isEmpty || !forecasts.isEmpty || !observations.isEmpty
        || !outlooks.isEmpty || !stormReports.isEmpty || !rainObservations.isEmpty
        || !tafs.isEmpty || !warningsNear.isEmpty || !pendingKeys.isEmpty || !unavailableKeys.isEmpty
        || !nowcasts.isEmpty || !fireWeathers.isEmpty || dailyClimate != nil || !qpfFrames.isEmpty
    }

    // MARK: - Persistence
    //
    // Forecasts, warnings, and observations are persisted as raw wire payloads (base64 in JSON).
    // On load, payloads are re-decoded — this naturally handles expiry, deduplication,
    // and protocol upgrades (stale/unrecognised bytes silently drop).

    private struct PersistedWeatherData: Codable {
        var forecastPayloads: [Data] = []
        var warningPayloads: [Data] = []
        var observationPayloads: [Data] = []
        /// Latest assembled radar frame per region ID (String key for JSON compatibility).
        /// Stored as the decoded struct so multi-chunk frames survive restart correctly.
        /// Legacy key `radarPayloads` (raw Data) is silently ignored by the decoder.
        var radarFrames: [String: MeshWXRadarFrame] = [:]
    }

    nonisolated private static let cacheFileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("wx_cache.json")
    }()

    /// Loads previously persisted forecasts/warnings/observations from disk.
    /// Call once at app start (after AppState is set up).
    func loadPersistedData() {
        guard let data = try? Data(contentsOf: Self.cacheFileURL),
              let saved = try? JSONDecoder().decode(PersistedWeatherData.self, from: data)
        else { return }

        var loaded = 0
        for payload in saved.warningPayloads {
            if let msg = MeshWXDecoder.decode(payload), case .warningPolygon(let w) = msg {
                ingestWarning(w); loaded += 1
            }
        }
        for payload in saved.forecastPayloads {
            if let msg = MeshWXDecoder.decode(payload), case .forecast(let f) = msg {
                ingestForecast(f); loaded += 1
            }
        }
        for payload in saved.observationPayloads {
            if let msg = MeshWXDecoder.decode(payload), case .observation(let o) = msg {
                ingestObservation(o); loaded += 1
            }
        }
        for frame in saved.radarFrames.values {
            ingestRadarFrame(frame); loaded += 1
        }
        logger.info("Loaded \(loaded) persisted weather items from disk")
    }

    /// Saves a raw wire payload so it survives app restart.
    /// Call after ingesting a forecast, warning, observation, or radar frame.
    func persistPayload(_ payload: Data, type: PersistType) {
        let fileURL = Self.cacheFileURL
        Task.detached(priority: .utility) {
            var saved = (try? JSONDecoder().decode(PersistedWeatherData.self,
                                                   from: Data(contentsOf: fileURL))) ?? PersistedWeatherData()
            switch type {
            case .forecast:
                saved.forecastPayloads.append(payload)
                if saved.forecastPayloads.count > 60 { saved.forecastPayloads.removeFirst() }
            case .warning:
                saved.warningPayloads.append(payload)
                if saved.warningPayloads.count > 80 { saved.warningPayloads.removeFirst() }
            case .observation:
                saved.observationPayloads.append(payload)
                if saved.observationPayloads.count > 40 { saved.observationPayloads.removeFirst() }
            case .radar(let frame):
                // Only keep the single latest frame per region — enough to show a static snapshot on restart
                saved.radarFrames[String(frame.regionID)] = frame
            }
            try? JSONEncoder().encode(saved).write(to: fileURL)
        }
    }

    enum PersistType { case forecast, warning, observation, radar(MeshWXRadarFrame) }

    // MARK: - Debug

    #if DEBUG
    /// Injects sample weather warnings for testing the map overlay.
    /// Call from Xcode console or via a debug button.
    func injectTestData() {
        logger.info("Injecting test weather data")

        let now = UInt32(Date().timeIntervalSince1970 / 60)

        // Sample Tornado Warning (Oklahoma City area) — v3 fields
        let tornadoWarning = MeshWXWarning(
            id: UUID(),
            phenomenaIndex: 0x33,   // TO — Tornado
            vtecSignificance: 0x0,  // W — Warning
            capSeverity: 0x4,       // Extreme
            action: 0,              // NEW
            etn: 1001,
            office: "OUN",          // Norman, OK WFO
            urgency: 1, certainty: 1,
            expiryUnixMinutes: now + 60,
            vertices: [
                CLLocationCoordinate2D(latitude: 35.50, longitude: -97.60),
                CLLocationCoordinate2D(latitude: 35.55, longitude: -97.45),
                CLLocationCoordinate2D(latitude: 35.40, longitude: -97.40),
                CLLocationCoordinate2D(latitude: 35.35, longitude: -97.55),
                CLLocationCoordinate2D(latitude: 35.50, longitude: -97.60),
            ],
            headline: "TORNADO WARNING: OKC Metro"
        )
        ingestWarning(tornadoWarning)

        // Sample Severe Thunderstorm Watch (wider area)
        let tstormWatch = MeshWXWarning(
            id: UUID(),
            phenomenaIndex: 0x30,   // SV — Severe Thunderstorm
            vtecSignificance: 0x1,  // A — Watch
            capSeverity: 0x3,       // Severe
            action: 0,              // NEW
            etn: 2042,
            office: "OUN",
            urgency: 2, certainty: 2,
            expiryUnixMinutes: now + 240,
            vertices: [
                CLLocationCoordinate2D(latitude: 36.00, longitude: -98.00),
                CLLocationCoordinate2D(latitude: 36.00, longitude: -96.50),
                CLLocationCoordinate2D(latitude: 34.50, longitude: -96.50),
                CLLocationCoordinate2D(latitude: 34.50, longitude: -98.00),
                CLLocationCoordinate2D(latitude: 36.00, longitude: -98.00),
            ],
            headline: "SVR TSTORM WATCH: Central OK"
        )
        ingestWarning(tstormWatch)

        // Sample Flash Flood Warning (smaller area)
        let floodWarning = MeshWXWarning(
            id: UUID(),
            phenomenaIndex: 0x0E,   // FF — Flash Flood
            vtecSignificance: 0x0,  // W — Warning
            capSeverity: 0x3,       // Severe
            action: 0,              // NEW
            etn: 3077,
            office: "OUN",
            urgency: 1, certainty: 1,
            expiryUnixMinutes: now + 120,
            vertices: [
                CLLocationCoordinate2D(latitude: 35.20, longitude: -97.50),
                CLLocationCoordinate2D(latitude: 35.25, longitude: -97.35),
                CLLocationCoordinate2D(latitude: 35.15, longitude: -97.30),
                CLLocationCoordinate2D(latitude: 35.10, longitude: -97.45),
                CLLocationCoordinate2D(latitude: 35.20, longitude: -97.50),
            ],
            headline: "FLASH FLOOD WARNING: Norman OK"
        )
        ingestWarning(floodWarning)

        logger.info("Test data injected: \(self.warnings.count) warnings")
    }
    #endif
}
