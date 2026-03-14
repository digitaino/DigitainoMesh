import CoreLocation
import MapKit
import MC1Services
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.mc1", category: "SignalSurvey")

@MainActor @Observable
final class SignalSurveyViewModel {

    // MARK: - Survey State

    enum SurveyState: Equatable {
        case idle
        case active(sessionID: UUID)
        case loading
    }

    private(set) var state: SurveyState = .idle
    private(set) var activeSession: SurveySessionDTO?
    private(set) var sessions: [SurveySessionDTO] = []
    private(set) var livePointCount: Int = 0
    var errorMessage: String?

    var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    // MARK: - Map State

    var cameraPosition: MapCameraPosition = .automatic
    var mapStyleSelection: MapStyleSelection = .standard
    var showingLayersMenu = false

    // MARK: - Visualization

    enum VisualizationMode: String, CaseIterable {
        case pointCloud = "Points"
        case gridHeatmap = "Heatmap"
    }

    var visualizationMode: VisualizationMode = .pointCloud {
        didSet {
            if visualizationMode == .gridHeatmap {
                rebuildGrid()
            }
        }
    }

    private(set) var displayPoints: [SignalSurveyPointDTO] = []
    private(set) var gridCells: [GridCell] = []

    /// Selected session for historical browsing (nil = show all)
    var selectedSessionID: UUID?

    // MARK: - Grid Cell for Heatmap

    struct GridCell: Identifiable {
        let id: String
        let centerLatitude: Double
        let centerLongitude: Double
        let averageSNR: Double?
        let averageRSSI: Double?
        let minSNR: Double?
        let maxSNR: Double?
        let packetCount: Int
        let snrQuality: SNRQuality
        let vertices: [CLLocationCoordinate2D]
        let earliestTimestamp: Date?
        let latestTimestamp: Date?

        static func == (lhs: GridCell, rhs: GridCell) -> Bool {
            lhs.id == rhs.id &&
            lhs.packetCount == rhs.packetCount &&
            lhs.averageSNR == rhs.averageSNR &&
            lhs.snrQuality == rhs.snrQuality
        }
    }

    /// The currently selected hex cell (tapped by user).
    var selectedCell: GridCell?

    // MARK: - Active Probing

    /// Whether active trace probing is enabled during survey.
    var probeEnabled: Bool = false {
        didSet {
            guard isActive else { return }
            if probeEnabled, let bps = binaryProtocolService, let ls = locationServiceRef {
                startProbeLoop(locationService: ls)
            } else {
                stopProbeLoop()
            }
        }
    }

    /// Number of probe traces sent in the current session.
    private(set) var probeCount: Int = 0

    private var binaryProtocolService: BinaryProtocolService?
    private var locationServiceRef: LocationService?
    private var probeTask: Task<Void, Never>?
    private var lastProbeHex: HexGrid.AxialCoord?
    private var lastProbeTime: Date = .distantPast
    private var probeReferenceLatitude: Double = 30.0

    private static let minProbeInterval: TimeInterval = 10
    private static let maxProbeInterval: TimeInterval = 30
    private static let probeCheckInterval: TimeInterval = 2

    // MARK: - Session Management

    func startSurvey(
        surveyService: SurveyService,
        locationService: LocationService,
        binaryProtocolService: BinaryProtocolService? = nil
    ) async {
        state = .loading
        do {
            let session: SurveySessionDTO
            do {
                session = try await surveyService.startSession()
            } catch SurveyServiceError.sessionAlreadyActive {
                // Stale in-memory state — force reset and retry
                await surveyService.forceReset()
                session = try await surveyService.startSession()
            }
            activeSession = session
            state = .active(sessionID: session.id)
            livePointCount = 0
            probeCount = 0
            selectedSessionID = session.id

            // Store references for probing
            self.binaryProtocolService = binaryProtocolService
            self.locationServiceRef = locationService

            // Start continuous GPS
            locationService.startContinuousUpdates { _ in
                // Location updates flow through LocationService.currentLocation
                // which the SurveyService's locationProvider reads
            }

            // Wire live point handler
            await surveyService.setPointRecordedHandler { [weak self] point in
                await MainActor.run {
                    self?.handleNewPoint(point)
                }
            }

            // Start probe loop if enabled
            if probeEnabled, binaryProtocolService != nil {
                startProbeLoop(locationService: locationService)
            }

            logger.info("Survey started: \(session.id)")
        } catch {
            state = .idle
            errorMessage = error.localizedDescription
            logger.error("Failed to start survey: \(error.localizedDescription)")
        }
    }

    func stopSurvey(
        surveyService: SurveyService,
        locationService: LocationService,
        dataStore: PersistenceStore?,
        deviceID: UUID?
    ) async {
        guard case .active = state else { return }

        // Stop probing first
        stopProbeLoop()

        do {
            try await surveyService.stopSession()
            locationService.stopContinuousUpdates()
            await surveyService.setPointRecordedHandler(nil)
            state = .idle
            activeSession = nil

            // Clear probe references
            binaryProtocolService = nil
            locationServiceRef = nil
            lastProbeHex = nil

            if let dataStore, let deviceID {
                await loadSessions(dataStore: dataStore, deviceID: deviceID)
            }
            logger.info("Survey stopped with \(self.livePointCount) points, \(self.probeCount) probes sent")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to stop survey: \(error.localizedDescription)")
        }
    }

    // MARK: - Live Updates

    private func handleNewPoint(_ point: SignalSurveyPointDTO) {
        livePointCount += 1
        displayPoints.append(point)

        if visualizationMode == .gridHeatmap {
            rebuildGrid()
        }

        // Center on first point
        if livePointCount == 1 {
            cameraPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))
        }
    }

    // MARK: - Data Loading

    func loadSessions(dataStore: PersistenceStore, deviceID: UUID) async {
        do {
            sessions = try await dataStore.fetchSurveySessions(deviceID: deviceID)
        } catch {
            logger.error("Failed to load sessions: \(error.localizedDescription)")
        }
    }

    func loadPoints(dataStore: PersistenceStore, sessionID: UUID) async {
        do {
            displayPoints = try await dataStore.fetchSurveyPoints(sessionID: sessionID)
            livePointCount = displayPoints.count

            if visualizationMode == .gridHeatmap {
                rebuildGrid()
            }

            centerOnData()
        } catch {
            logger.error("Failed to load points: \(error.localizedDescription)")
        }
    }

    func loadAllPoints(dataStore: PersistenceStore, deviceID: UUID) async {
        do {
            displayPoints = try await dataStore.fetchSurveyPoints(deviceID: deviceID)
            livePointCount = displayPoints.count

            if visualizationMode == .gridHeatmap {
                rebuildGrid()
            }

            centerOnData()
        } catch {
            logger.error("Failed to load all points: \(error.localizedDescription)")
        }
    }

    // MARK: - Grid Heatmap Computation

    func rebuildGrid() {
        guard !displayPoints.isEmpty else {
            gridCells = []
            return
        }

        // Use average latitude of all points for Mercator correction
        let refLat = displayPoints.map(\.latitude).reduce(0, +) / Double(displayPoints.count)

        var buckets: [HexGrid.AxialCoord: [SignalSurveyPointDTO]] = [:]

        for point in displayPoints {
            let hex = HexGrid.axialFromLatLon(latitude: point.latitude, longitude: point.longitude, referenceLatitude: refLat)
            buckets[hex, default: []].append(point)
        }

        gridCells = buckets.map { coord, points in
            let center = HexGrid.centerLatLon(from: coord, referenceLatitude: refLat)
            let snrValues = points.compactMap(\.snr)
            let rssiValues = points.compactMap(\.rssi)
            let avgSNR = snrValues.isEmpty ? nil : snrValues.reduce(0, +) / Double(snrValues.count)
            let avgRSSI = rssiValues.isEmpty ? nil : Double(rssiValues.reduce(0, +)) / Double(rssiValues.count)
            let timestamps = points.map(\.timestamp).sorted()

            return GridCell(
                id: coord.key,
                centerLatitude: center.latitude,
                centerLongitude: center.longitude,
                averageSNR: avgSNR,
                averageRSSI: avgRSSI,
                minSNR: snrValues.min(),
                maxSNR: snrValues.max(),
                packetCount: points.count,
                snrQuality: SNRQuality(snr: avgSNR),
                vertices: HexGrid.vertices(for: coord, referenceLatitude: refLat),
                earliestTimestamp: timestamps.first,
                latestTimestamp: timestamps.last
            )
        }

        // Clear selection if the cell no longer exists
        if let selected = selectedCell, !gridCells.contains(where: { $0.id == selected.id }) {
            selectedCell = nil
        }
    }

    // MARK: - Camera

    func centerOnData() {
        let coordinates = displayPoints.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        guard !coordinates.isEmpty else { return }

        var minLat = coordinates[0].latitude
        var maxLat = coordinates[0].latitude
        var minLon = coordinates[0].longitude
        var maxLon = coordinates[0].longitude

        for coord in coordinates {
            minLat = min(minLat, coord.latitude)
            maxLat = max(maxLat, coord.latitude)
            minLon = min(minLon, coord.longitude)
            maxLon = max(maxLon, coord.longitude)
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: min(180, (maxLat - minLat) * 1.5 + 0.005),
            longitudeDelta: min(360, (maxLon - minLon) * 1.5 + 0.005)
        )
        cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
    }

    // MARK: - Session Management

    func deleteSession(id: UUID, dataStore: PersistenceStore) async {
        do {
            try await dataStore.deleteSurveySession(id: id)
            sessions.removeAll { $0.id == id }
            if selectedSessionID == id {
                selectedSessionID = nil
                displayPoints = []
                gridCells = []
                livePointCount = 0
            }
        } catch {
            logger.error("Failed to delete session: \(error.localizedDescription)")
        }
    }

    func renameSession(id: UUID, name: String, dataStore: PersistenceStore) async {
        do {
            try await dataStore.updateSurveySessionName(id: id, name: name)
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                sessions[index].name = name
            }
        } catch {
            logger.error("Failed to rename session: \(error.localizedDescription)")
        }
    }

    // MARK: - Probe Loop

    /// Starts the periodic probe loop that sends flood traces.
    private func startProbeLoop(locationService: LocationService) {
        stopProbeLoop()

        // Set reference latitude from current location or fallback
        if let loc = locationService.currentLocation {
            probeReferenceLatitude = loc.coordinate.latitude
        }

        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.probeCheckInterval))
                guard !Task.isCancelled else { break }

                guard let self else { break }
                guard self.isActive, self.probeEnabled else { break }
                guard let locationService = self.locationServiceRef else { break }
                guard let location = locationService.currentLocation else { continue }

                if self.shouldProbe(location: location) {
                    await self.sendProbe(location: location)
                }
            }
        }

        logger.info("Probe loop started")
    }

    /// Stops the periodic probe loop.
    private func stopProbeLoop() {
        probeTask?.cancel()
        probeTask = nil
    }

    /// Determines whether a probe should be sent based on time and cell-exit.
    private func shouldProbe(location: CLLocation) -> Bool {
        let elapsed = Date().timeIntervalSince(lastProbeTime)

        // Always respect minimum interval
        guard elapsed >= Self.minProbeInterval else { return false }

        // Fire if max interval exceeded (ensure data even when stationary)
        if elapsed >= Self.maxProbeInterval { return true }

        // Fire if we've moved to a new hex cell
        let currentHex = HexGrid.axialFromLatLon(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            referenceLatitude: probeReferenceLatitude
        )
        if let lastHex = lastProbeHex, currentHex != lastHex {
            return true
        }

        return false
    }

    /// Sends a flood trace probe and updates tracking state.
    private func sendProbe(location: CLLocation) async {
        guard let bps = binaryProtocolService else { return }

        let tag = UInt32.random(in: 0...UInt32.max)
        do {
            _ = try await bps.sendTrace(tag: tag)
            probeCount += 1
            lastProbeTime = Date()
            lastProbeHex = HexGrid.axialFromLatLon(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                referenceLatitude: probeReferenceLatitude
            )
            logger.debug("Probe #\(self.probeCount) sent (tag: \(tag))")
        } catch {
            logger.warning("Probe failed: \(error.localizedDescription)")
        }
    }
}
