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

    var visualizationMode: VisualizationMode = .gridHeatmap {
        didSet {
            if visualizationMode == .gridHeatmap {
                rebuildGrid()
            }
        }
    }

    /// All raw points from the current session/selection (unfiltered).
    private(set) var allPoints: [SignalSurveyPointDTO] = []

    /// Points after applying surveyFilter. Used for rendering.
    private(set) var displayPoints: [SignalSurveyPointDTO] = []
    private(set) var gridCells: [GridCell] = []

    /// Selected session for historical browsing (nil = show all)
    var selectedSessionID: UUID?

    // MARK: - Survey Filter

    enum SurveyFilter: String, CaseIterable {
        case all = "All"
        case passiveOnly = "Passive"
        case traceOnly = "Active"
    }

    var surveyFilter: SurveyFilter = .all {
        didSet {
            applyFilter()
        }
    }

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
        let uniqueSenders: [String]
        let uniqueRelayNodes: [String]
        let isDeadZone: Bool

        static func == (lhs: GridCell, rhs: GridCell) -> Bool {
            lhs.id == rhs.id &&
            lhs.packetCount == rhs.packetCount &&
            lhs.averageSNR == rhs.averageSNR &&
            lhs.snrQuality == rhs.snrQuality &&
            lhs.isDeadZone == rhs.isDeadZone
        }
    }

    /// The currently selected hex cell (tapped by user).
    var selectedCell: GridCell? {
        didSet {
            if selectedCell?.id != oldValue?.id {
                selectedRelayFilter = nil
            }
        }
    }

    /// Optional filter: show stats for only packets via this relay within the selected cell.
    var selectedRelayFilter: String?

    /// Persistent grid buckets for incremental updates during live survey.
    private var gridBuckets: [HexGrid.AxialCoord: [SignalSurveyPointDTO]] = [:]
    private var gridReferenceLatitude: Double = 30.0

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

    /// Distance threshold in meters for distance-based probing (0 = disabled, use time/cell-exit only).
    var probeDistanceMeters: Double = 50

    private var binaryProtocolService: BinaryProtocolService?
    private var locationServiceRef: LocationService?
    private var probeTask: Task<Void, Never>?
    private var lastProbeHex: HexGrid.AxialCoord?
    private var lastProbeTime: Date = .distantPast
    private var lastProbeLocation: CLLocation?
    private var probeReferenceLatitude: Double = 30.0

    /// Locations where probes were sent, for dead zone detection.
    private(set) var probeSendLocations: [(coordinate: CLLocationCoordinate2D, hexCoord: HexGrid.AxialCoord, time: Date)] = []

    private static let minProbeInterval: TimeInterval = 10
    private static let maxProbeInterval: TimeInterval = 30
    private static let probeCheckInterval: TimeInterval = 2
    /// How long to wait after a probe before marking its cell as a dead zone.
    private static let deadZoneTimeout: TimeInterval = 15

    // MARK: - Probe Feedback

    /// Incremented on successful manual probe send (drives haptic feedback).
    var probeSuccessHaptic: Int = 0

    /// Incremented on probe failure (drives haptic feedback).
    var probeErrorHaptic: Int = 0

    /// Brief error message for probe failure, auto-cleared by the view.
    var probeErrorMessage: String?

    /// Incremented on successful manual probe — drives visual pulse animation.
    var probeVisualPulse: Int = 0

    /// Whether a manual probe can be sent right now.
    var canSendManualProbe: Bool {
        isActive && binaryProtocolService != nil && locationServiceRef?.currentLocation != nil
    }

    // MARK: - Contact & Repeater Resolution

    /// Map from display name to ContactDTO, for resolving senders in the cell card.
    private(set) var contactsByName: [String: ContactDTO] = [:]

    /// All contacts for the current device.
    private(set) var allContacts: [ContactDTO] = []

    /// Repeater-type contacts with valid locations, for map annotations.
    private(set) var repeaterContacts: [ContactDTO] = []

    /// Repeater annotations resolved from grid cell relay nodes. Updated alongside grid.
    private(set) var mapRepeaterAnnotations: [(hexID: String, contact: ContactDTO)] = []

    /// The repeater contact tapped on the map, for presenting detail sheet.
    var selectedMapRepeater: ContactDTO?

    /// The resolved contact for the currently selected relay filter, if it has a location.
    var selectedRepeaterContact: ContactDTO? {
        guard let hexID = selectedRelayFilter else { return nil }
        guard let contact = resolveRepeater(hexID: hexID), contact.hasLocation else { return nil }
        return contact
    }

    /// Resolves a hex ID string (e.g. "07", "A1B2") to the best-matching repeater contact.
    func resolveRepeater(hexID: String) -> ContactDTO? {
        guard let hashBytes = Data(hexString: hexID) else { return nil }
        return RepeaterResolver.bestMatch(for: hashBytes, in: repeaterContacts, userLocation: nil)
    }

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
            probeSendLocations = []
            gridBuckets = [:]
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
            lastProbeLocation = nil
            probeSendLocations = []

            if let dataStore, let deviceID {
                await loadSessions(dataStore: dataStore, deviceID: deviceID)
            }
            logger.info("Survey stopped with \(self.livePointCount) points, \(self.probeCount) probes sent")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to stop survey: \(error.localizedDescription)")
        }
    }

    /// Resume the view model state if the SurveyService still has an active session
    /// (e.g. user navigated away and came back while survey was running).
    func resumeIfActive(
        surveyService: SurveyService,
        locationService: LocationService,
        binaryProtocolService: BinaryProtocolService? = nil,
        dataStore: PersistenceStore,
        deviceID: UUID
    ) async {
        // Already active in this view model — nothing to do
        guard !isActive else { return }

        guard let sessionID = await surveyService.currentSessionID else { return }

        // The service has an active session — restore view model state
        let session = sessions.first(where: { $0.id == sessionID })
        activeSession = session
        state = .active(sessionID: sessionID)
        selectedSessionID = sessionID

        // Load existing points for this session
        await loadPoints(dataStore: dataStore, sessionID: sessionID)

        // Store references for probing
        self.binaryProtocolService = binaryProtocolService
        self.locationServiceRef = locationService

        // Re-wire live point handler
        await surveyService.setPointRecordedHandler { [weak self] point in
            await MainActor.run {
                self?.handleNewPoint(point)
            }
        }

        // Resume probe loop if enabled
        if probeEnabled, binaryProtocolService != nil {
            startProbeLoop(locationService: locationService)
        }

        logger.info("Resumed active survey session: \(sessionID), \(self.livePointCount) existing points")
    }

    // MARK: - Live Updates

    private func handleNewPoint(_ point: SignalSurveyPointDTO) {
        logger.debug("handleNewPoint called, total: \(self.livePointCount + 1)")
        livePointCount += 1
        allPoints.append(point)

        // Check if this point passes the current filter
        if passesFilter(point) {
            displayPoints.append(point)

            if visualizationMode == .gridHeatmap {
                updateGridCell(for: point)
            }
        }

        // Center on first point
        if livePointCount == 1 {
            gridReferenceLatitude = point.latitude
            cameraPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))
        }
    }

    // MARK: - Filtering

    private func passesFilter(_ point: SignalSurveyPointDTO) -> Bool {
        switch surveyFilter {
        case .all: true
        case .passiveOnly: point.payloadType != .trace
        case .traceOnly: point.payloadType == .trace
        }
    }

    private func applyFilter() {
        displayPoints = allPoints.filter { passesFilter($0) }
        rebuildGrid()
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
            allPoints = try await dataStore.fetchSurveyPoints(sessionID: sessionID)
            livePointCount = allPoints.count
            applyFilter()
            centerOnData()
        } catch {
            logger.error("Failed to load points: \(error.localizedDescription)")
        }
    }

    func loadAllPoints(dataStore: PersistenceStore, deviceID: UUID) async {
        do {
            allPoints = try await dataStore.fetchSurveyPoints(deviceID: deviceID)
            livePointCount = allPoints.count
            applyFilter()
            centerOnData()
        } catch {
            logger.error("Failed to load all points: \(error.localizedDescription)")
        }
    }

    // MARK: - Grid Heatmap Computation

    /// Full rebuild — used for batch loads, filter changes, and viz mode switches.
    func rebuildGrid() {
        guard !displayPoints.isEmpty else {
            gridCells = []
            gridBuckets = [:]
            return
        }

        // Use average latitude of ALL points (not filtered) for stable Mercator correction across filters
        gridReferenceLatitude = allPoints.map(\.latitude).reduce(0, +) / Double(allPoints.count)

        gridBuckets = [:]
        for point in displayPoints {
            let hex = HexGrid.axialFromLatLon(latitude: point.latitude, longitude: point.longitude, referenceLatitude: gridReferenceLatitude)
            gridBuckets[hex, default: []].append(point)
        }

        // Build data cells
        var cells = gridBuckets.map { coord, points in
            Self.makeGridCell(coord: coord, points: points, refLat: gridReferenceLatitude)
        }

        // Add dead zone cells for probed-but-no-response hexes
        let now = Date()
        let dataCellIDs = Set(cells.map(\.id))
        for probe in probeSendLocations where now.timeIntervalSince(probe.time) >= Self.deadZoneTimeout {
            let key = probe.hexCoord.key
            guard !dataCellIDs.contains(key) else { continue }
            let center = HexGrid.centerLatLon(from: probe.hexCoord, referenceLatitude: gridReferenceLatitude)
            cells.append(GridCell(
                id: key,
                centerLatitude: center.latitude,
                centerLongitude: center.longitude,
                averageSNR: nil,
                averageRSSI: nil,
                minSNR: nil,
                maxSNR: nil,
                packetCount: 0,
                snrQuality: .unknown,
                vertices: HexGrid.vertices(for: probe.hexCoord, referenceLatitude: gridReferenceLatitude),
                earliestTimestamp: nil,
                latestTimestamp: nil,
                uniqueSenders: [],
                uniqueRelayNodes: [],
                isDeadZone: true
            ))
        }

        gridCells = cells

        // Refresh or clear selected cell after rebuild
        if let selected = selectedCell {
            if let updated = gridCells.first(where: { $0.id == selected.id }) {
                selectedCell = updated
            } else {
                selectedCell = nil
            }
        }

        refreshRepeaterAnnotations()
    }

    /// Incremental update — adds a single point to the grid without full rebuild.
    /// O(1) per point instead of O(n).
    private func updateGridCell(for point: SignalSurveyPointDTO) {
        let hex = HexGrid.axialFromLatLon(
            latitude: point.latitude,
            longitude: point.longitude,
            referenceLatitude: gridReferenceLatitude
        )
        gridBuckets[hex, default: []].append(point)

        let updatedCell = Self.makeGridCell(
            coord: hex,
            points: gridBuckets[hex]!,
            refLat: gridReferenceLatitude
        )

        if let idx = gridCells.firstIndex(where: { $0.id == hex.key }) {
            gridCells[idx] = updatedCell
        } else {
            gridCells.append(updatedCell)
        }

        // Update selected cell if it's the one that changed
        if selectedCell?.id == hex.key {
            selectedCell = updatedCell
        }

        refreshRepeaterAnnotations()
    }

    /// Creates a GridCell from a bucket of points at a hex coordinate.
    private static func makeGridCell(
        coord: HexGrid.AxialCoord,
        points: [SignalSurveyPointDTO],
        refLat: Double
    ) -> GridCell {
        let center = HexGrid.centerLatLon(from: coord, referenceLatitude: refLat)
        let snrValues = points.compactMap(\.snr)
        let rssiValues = points.compactMap(\.rssi)
        let avgSNR = snrValues.isEmpty ? nil : snrValues.reduce(0, +) / Double(snrValues.count)
        let avgRSSI = rssiValues.isEmpty ? nil : Double(rssiValues.reduce(0, +)) / Double(rssiValues.count)
        let timestamps = points.map(\.timestamp).sorted()
        let senders = Array(Set(points.compactMap(\.fromContactName))).sorted()
        let relayNodes = Array(Set(points.flatMap(\.pathNodeHexIDs))).sorted()

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
            latestTimestamp: timestamps.last,
            uniqueSenders: senders,
            uniqueRelayNodes: relayNodes,
            isDeadZone: false
        )
    }

    /// Refreshes repeater annotations from current grid cell relay nodes.
    private func refreshRepeaterAnnotations() {
        let allHexIDs = Set(gridCells.flatMap(\.uniqueRelayNodes))
        mapRepeaterAnnotations = allHexIDs.compactMap { hexID in
            guard let contact = resolveRepeater(hexID: hexID) else { return nil }
            return (hexID: hexID, contact: contact)
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
                allPoints = []
                displayPoints = []
                gridCells = []
                gridBuckets = [:]
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

    /// Determines whether a probe should be sent based on time, distance, and cell-exit.
    private func shouldProbe(location: CLLocation) -> Bool {
        let elapsed = Date().timeIntervalSince(lastProbeTime)

        // Always respect minimum interval
        guard elapsed >= Self.minProbeInterval else { return false }

        // Fire if max interval exceeded (ensure data even when stationary)
        if elapsed >= Self.maxProbeInterval { return true }

        // Fire if distance threshold exceeded
        if probeDistanceMeters > 0, let lastLoc = lastProbeLocation {
            let distance = location.distance(from: lastLoc)
            if distance >= probeDistanceMeters {
                return true
            }
        }

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

    /// Manually sends a single flood trace probe using the current GPS location.
    func sendManualProbe() async {
        guard isActive else {
            probeErrorMessage = "Start a survey first"
            probeErrorHaptic += 1
            return
        }
        guard binaryProtocolService != nil else {
            probeErrorMessage = "Radio not connected"
            probeErrorHaptic += 1
            return
        }
        guard let location = locationServiceRef?.currentLocation else {
            probeErrorMessage = "Waiting for GPS fix"
            probeErrorHaptic += 1
            return
        }
        await sendProbe(location: location)
        probeSuccessHaptic += 1
        probeVisualPulse += 1
        probeErrorMessage = nil
    }

    /// Sends a flood trace probe and updates tracking state.
    private func sendProbe(location: CLLocation) async {
        guard let bps = binaryProtocolService else {
            logger.warning("Probe skipped: binaryProtocolService is nil")
            return
        }

        let tag = UInt32.random(in: 0...UInt32.max)

        // Always increment count and update tracking before the async call
        probeCount += 1
        lastProbeTime = Date()
        lastProbeLocation = location
        let hexCoord = HexGrid.axialFromLatLon(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            referenceLatitude: probeReferenceLatitude
        )
        lastProbeHex = hexCoord
        probeSendLocations.append((
            coordinate: location.coordinate,
            hexCoord: hexCoord,
            time: Date()
        ))

        do {
            _ = try await bps.sendTrace(tag: tag)
            logger.debug("Probe #\(self.probeCount) sent (tag: \(tag))")
        } catch {
            logger.warning("Probe #\(self.probeCount) failed: \(error.localizedDescription)")
        }
    }

    /// Rebuilds dead zone cells from probe history. Called periodically or on grid rebuild.
    func refreshDeadZones() {
        guard visualizationMode == .gridHeatmap else { return }
        let now = Date()
        let dataCellIDs = Set(gridBuckets.keys.map(\.key))
        var changed = false

        for probe in probeSendLocations where now.timeIntervalSince(probe.time) >= Self.deadZoneTimeout {
            let key = probe.hexCoord.key
            guard !dataCellIDs.contains(key) else { continue }

            // Only add if not already present
            if !gridCells.contains(where: { $0.id == key }) {
                let center = HexGrid.centerLatLon(from: probe.hexCoord, referenceLatitude: gridReferenceLatitude)
                gridCells.append(GridCell(
                    id: key,
                    centerLatitude: center.latitude,
                    centerLongitude: center.longitude,
                    averageSNR: nil,
                    averageRSSI: nil,
                    minSNR: nil,
                    maxSNR: nil,
                    packetCount: 0,
                    snrQuality: .unknown,
                    vertices: HexGrid.vertices(for: probe.hexCoord, referenceLatitude: gridReferenceLatitude),
                    earliestTimestamp: nil,
                    latestTimestamp: nil,
                    uniqueSenders: [],
                    uniqueRelayNodes: [],
                    isDeadZone: true
                ))
                changed = true
            }
        }

        // Remove dead zone cells that now have data
        if gridCells.contains(where: { $0.isDeadZone && dataCellIDs.contains($0.id) }) {
            gridCells.removeAll { $0.isDeadZone && dataCellIDs.contains($0.id) }
            changed = true
        }

        _ = changed // Suppress unused warning; mutations to gridCells already trigger observation
    }

    // MARK: - Cell Detail Data Access

    /// Returns the raw survey points for the selected cell, optionally filtered by relay node.
    func pointsForSelectedCell(relayFilter: String? = nil) -> [SignalSurveyPointDTO] {
        guard let cell = selectedCell else { return [] }
        let parts = cell.id.split(separator: "_").compactMap { Int($0) }
        guard parts.count == 2 else { return [] }
        let coord = HexGrid.AxialCoord(q: parts[0], r: parts[1])
        let points = gridBuckets[coord] ?? []
        if let relay = relayFilter {
            return points.filter { $0.pathNodeHexIDs.contains(relay) }
        }
        return points
    }

    /// Computed cell stats filtered to the selected relay, or nil if no filter is active.
    var filteredCellStats: (avgSNR: Double?, avgRSSI: Double?, minSNR: Double?, maxSNR: Double?,
                            packetCount: Int, quality: SNRQuality, latestTimestamp: Date?)? {
        guard selectedRelayFilter != nil else { return nil }
        let points = pointsForSelectedCell(relayFilter: selectedRelayFilter)
        guard !points.isEmpty else { return nil }
        let snrValues = points.compactMap(\.snr)
        let rssiValues = points.compactMap(\.rssi)
        let avgSNR = snrValues.isEmpty ? nil : snrValues.reduce(0, +) / Double(snrValues.count)
        let avgRSSI = rssiValues.isEmpty ? nil : Double(rssiValues.reduce(0, +)) / Double(rssiValues.count)
        let timestamps = points.map(\.timestamp).sorted()
        return (
            avgSNR: avgSNR,
            avgRSSI: avgRSSI,
            minSNR: snrValues.min(),
            maxSNR: snrValues.max(),
            packetCount: points.count,
            quality: SNRQuality(snr: avgSNR),
            latestTimestamp: timestamps.last
        )
    }

    // MARK: - Contact Resolution

    func loadContacts(dataStore: some PersistenceStoreProtocol, deviceID: UUID) async {
        let contacts = (try? await dataStore.fetchContacts(deviceID: deviceID)) ?? []
        allContacts = contacts
        repeaterContacts = contacts.filter { $0.type == .repeater && $0.hasLocation }
        contactsByName = Dictionary(
            contacts.map { ($0.displayName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
