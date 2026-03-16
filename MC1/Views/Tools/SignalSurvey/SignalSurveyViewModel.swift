import CoreLocation
import MapKit
import MC1Services
import OSLog
import Security
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

    /// Bundled probe frequency presets that pair a distance trigger with a minimum cooldown.
    enum ProbeFrequency: String, CaseIterable, Identifiable {
        case dense = "Dense"
        case normal = "Normal"
        case sparse = "Sparse"

        var id: String { rawValue }

        /// Distance threshold in meters before triggering a probe.
        var distanceMeters: Double {
            switch self {
            case .dense: 25
            case .normal: 50
            case .sparse: 100
            }
        }

        /// Minimum seconds between consecutive probes (hard cooldown).
        var minInterval: TimeInterval {
            switch self {
            case .dense: 2
            case .normal: 4
            case .sparse: 8
            }
        }

        /// Maximum seconds before a probe fires regardless of movement.
        var maxInterval: TimeInterval {
            switch self {
            case .dense: 6
            case .normal: 10
            case .sparse: 20
            }
        }

        /// Human-readable subtitle for the setup sheet.
        var subtitle: String {
            switch self {
            case .dense: "Every ~25m — walking, slow cycling"
            case .normal: "Every ~50m — e-bike, jogging"
            case .sparse: "Every ~100m — driving, fast cycling"
            }
        }
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

    /// Per-session stats for the session list.
    struct SessionStats {
        let pointCount: Int
        let cellCount: Int
    }
    private(set) var sessionStats: [UUID: SessionStats] = [:]

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
        /// Hex coordinate key (e.g. "0_5") — stable across updates.
        let coordKey: String
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
        /// Best-gateway SNR from discover responses.
        /// Nil when no discover data is available (passive-only cells use averageSNR).
        let bestGatewaySNR: Double?
        /// Number of trace responses received in this cell (mesh reachability indicator).
        let traceResponseCount: Int

        /// Composite identity: coordKey + packetCount so ForEach detects content changes.
        var id: String { "\(coordKey)_\(packetCount)" }

        static func == (lhs: GridCell, rhs: GridCell) -> Bool {
            lhs.coordKey == rhs.coordKey &&
            lhs.packetCount == rhs.packetCount &&
            lhs.averageSNR == rhs.averageSNR &&
            lhs.bestGatewaySNR == rhs.bestGatewaySNR &&
            lhs.snrQuality == rhs.snrQuality &&
            lhs.isDeadZone == rhs.isDeadZone
        }
    }

    /// The currently selected hex cell (tapped by user or auto-tracked).
    var selectedCell: GridCell? {
        didSet {
            if selectedCell?.coordKey != oldValue?.coordKey {
                selectedRelayFilter = nil
            }
            // Restore camera when dismissing cell card
            if selectedCell == nil, let saved = savedCameraPosition {
                cameraPosition = saved
                savedCameraPosition = nil
            }
        }
    }

    /// When enabled, auto-selects the grid cell at the user's current GPS location
    /// and follows the camera as they move. Disabled by manual cell tap.
    var trackingUserLocation = false {
        didSet {
            if trackingUserLocation {
                updateTrackedCell()
            }
        }
    }

    /// Optional filter: show stats for only packets via this relay within the selected cell.
    var selectedRelayFilter: String? {
        didSet {
            if selectedRelayFilter != nil {
                zoomToFitCellAndRepeater()
            } else if let saved = savedCameraPosition {
                cameraPosition = saved
                savedCameraPosition = nil
            }
        }
    }

    /// Saved camera position before zoom-to-fit, restored on clearing relay filter.
    private var savedCameraPosition: MapCameraPosition?

    /// Persistent grid buckets for incremental updates during live survey.
    private var gridBuckets: [HexGrid.AxialCoord: [SignalSurveyPointDTO]] = [:]
    /// Reference latitude for hex grid Mercator correction.
    /// Uses fixed 10° bands (via HexGrid.fixedReferenceLatitude) so all clients
    /// produce identical cells at the same location.
    private var gridReferenceLatitude: Double = 30.0

    // MARK: - Live Community Upload

    /// Whether each survey point is uploaded to the community map in real time.
    var liveUploadEnabled: Bool = false

    /// Upload service instance for live point uploads. Created on demand.
    private var liveUploadService: SurveyUploadService?

    /// Count of points successfully uploaded live in this session.
    private(set) var liveUploadCount: Int = 0

    // MARK: - Active Probing

    /// Whether active probing (node discovery) is enabled during survey.
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

    /// Number of probes sent in the current session.
    private(set) var probeCount: Int = 0

    /// Active probe frequency preset controlling distance trigger and cooldown intervals.
    var probeFrequency: ProbeFrequency = .normal

    private var binaryProtocolService: BinaryProtocolService?
    private var messageServiceRef: MessageService?
    private var channelServiceRef: ChannelService?
    private var locationServiceRef: LocationService?
    private var deviceID: UUID?
    /// Path hash mode from device config, used for flood trace flags.
    private var pathHashMode: UInt8 = 0

    // MARK: - Probe Channel Selection

    /// Available private channels for probe messaging.
    private(set) var availableProbeChannels: [ChannelDTO] = []

    /// The channel selected for sending probe messages. Nil = no channel probing.
    var selectedProbeChannel: ChannelDTO? {
        didSet {
            // Persist selection across sessions
            if let index = selectedProbeChannel?.index {
                UserDefaults.standard.set(Int(index), forKey: "surveyProbeChannelIndex")
            } else {
                UserDefaults.standard.removeObject(forKey: "surveyProbeChannelIndex")
            }
        }
    }

    /// Whether channel-based probing is available (a private channel is selected).
    var hasProbeChannel: Bool { selectedProbeChannel != nil }
    private var probeTask: Task<Void, Never>?
    private var lastProbeHex: HexGrid.AxialCoord?
    private var lastProbeTime: Date = .distantPast
    private var lastProbeLocation: CLLocation?
    /// Probe loop reference latitude — fixed 10° band, matching gridReferenceLatitude.
    private var probeReferenceLatitude: Double = 30.0

    /// Locations where probes were sent, for dead zone detection.
    private(set) var probeSendLocations: [(coordinate: CLLocationCoordinate2D, hexCoord: HexGrid.AxialCoord, time: Date)] = []

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

    /// Whether a manual probe is currently in-flight (prevents rapid-tap queuing).
    private var isManualProbing = false

    /// Whether a manual probe can be sent right now.
    var canSendManualProbe: Bool {
        isActive && !isManualProbing && binaryProtocolService != nil && locationServiceRef?.currentLocation != nil
    }

    // MARK: - Contact & Repeater Resolution

    /// Live status for the floating survey indicator (relayed to AppState by the View).
    private(set) var liveStatus = SurveyLiveStatus()

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
        binaryProtocolService: BinaryProtocolService? = nil,
        messageService: MessageService? = nil,
        deviceID: UUID? = nil,
        pathHashMode: UInt8 = 0
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
            liveUploadCount = 0
            probeCount = 0
            probeSendLocations = []
            gridBuckets = [:]
            liveStatus = SurveyLiveStatus()
            selectedSessionID = session.id

            // Store references for probing
            self.binaryProtocolService = binaryProtocolService
            self.messageServiceRef = messageService
            self.deviceID = deviceID
            self.locationServiceRef = locationService
            self.pathHashMode = pathHashMode

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
            messageServiceRef = nil
            channelServiceRef = nil
            locationServiceRef = nil
            self.deviceID = nil
            lastProbeHex = nil
            lastProbeLocation = nil
            probeSendLocations = []
            liveStatus = SurveyLiveStatus()

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
        messageService: MessageService? = nil,
        deviceID: UUID,
        pathHashMode: UInt8 = 0,
        dataStore: PersistenceStore
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
        self.messageServiceRef = messageService
        self.deviceID = deviceID
        self.locationServiceRef = locationService
        self.pathHashMode = pathHashMode

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

        // Set reference latitude on first point BEFORE any grid operations,
        // so the hex coordinate system is stable from the very first cell.
        // Uses fixed 10° bands so all clients produce identical grids.
        if livePointCount == 1 {
            gridReferenceLatitude = HexGrid.fixedReferenceLatitude(for: point.latitude)
            cameraPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))
        }

        // Check if this point passes the current filter
        if passesFilter(point) {
            displayPoints.append(point)

            if visualizationMode == .gridHeatmap {
                updateGridCell(for: point)
            }
        }

        // Update live session stats for the session list
        if case .active(let sessionID) = state {
            sessionStats[sessionID] = SessionStats(
                pointCount: livePointCount,
                cellCount: gridCells.count
            )
        }

        // Live upload to community map if enabled
        if liveUploadEnabled {
            let refLat = gridReferenceLatitude
            let contacts = repeaterContacts
            let service = liveUploadService ?? SurveyUploadService()
            if liveUploadService == nil { liveUploadService = service }
            Task.detached {
                await service.uploadLivePoint(
                    point,
                    referenceLatitude: refLat,
                    repeaterContacts: contacts
                )
                await MainActor.run { [weak self] in
                    self?.liveUploadCount += 1
                }
            }
        }

        refreshLiveStatus()
    }

    /// Updates the lightweight live status (point count + cell quality at user's GPS location).
    private func refreshLiveStatus() {
        var status = SurveyLiveStatus()
        status.pointCount = livePointCount

        if let location = locationServiceRef?.currentLocation {
            let hex = HexGrid.axialFromLatLon(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                referenceLatitude: gridReferenceLatitude
            )
            if let cell = gridCells.first(where: { $0.coordKey == hex.key }) {
                status.currentCellQuality = cell.snrQuality
                status.currentCellPacketCount = cell.packetCount
                status.isDeadZone = cell.isDeadZone
                status.topRepeaterHexID = cell.uniqueRelayNodes.first
            }
        }

        liveStatus = status

        // Auto-select cell at user location when tracking mode is on
        if trackingUserLocation {
            updateTrackedCell()
        }
    }

    /// Selects the grid cell at the user's current GPS location and follows it with the camera.
    private func updateTrackedCell() {
        guard let location = locationServiceRef?.currentLocation else { return }
        let hex = HexGrid.axialFromLatLon(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            referenceLatitude: gridReferenceLatitude
        )
        let cell = gridCells.first(where: { $0.coordKey == hex.key })

        // Only update selection if cell changed (avoids re-triggering didSet constantly)
        if cell?.coordKey != selectedCell?.coordKey {
            selectedCell = cell
        } else if let cell {
            // Same cell but data may have updated — refresh it
            selectedCell = cell
        }

        // Follow user location
        cameraPosition = .region(MKCoordinateRegion(
            center: location.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        ))
    }

    // MARK: - Filtering

    /// Active probe payload types: trace (legacy) and control (discover node responses).
    private static let activePayloadTypes: Set<PayloadType> = [.trace, .control]

    private func passesFilter(_ point: SignalSurveyPointDTO) -> Bool {
        switch surveyFilter {
        case .all: true
        case .passiveOnly: !Self.activePayloadTypes.contains(point.payloadType)
        case .traceOnly: Self.activePayloadTypes.contains(point.payloadType)
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
            await loadSessionStats(dataStore: dataStore)
        } catch {
            logger.error("Failed to load sessions: \(error.localizedDescription)")
        }
    }

    /// Loads lightweight per-session stats (point count + cell count) for the session list.
    private func loadSessionStats(dataStore: PersistenceStore) async {
        var stats: [UUID: SessionStats] = [:]
        for session in sessions {
            do {
                let pointCount = try await dataStore.countSurveyPoints(sessionID: session.id)
                let coords = try await dataStore.fetchSurveyPointCoordinates(sessionID: session.id)
                let refLat = HexGrid.fixedReferenceLatitude(for: coords.first?.latitude ?? gridReferenceLatitude)
                let uniqueCells = Set(coords.map {
                    HexGrid.axialFromLatLon(latitude: $0.latitude, longitude: $0.longitude, referenceLatitude: refLat).key
                })
                stats[session.id] = SessionStats(pointCount: pointCount, cellCount: uniqueCells.count)
            } catch {
                logger.error("Failed to load stats for session \(session.id): \(error.localizedDescription)")
            }
        }
        sessionStats = stats
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

        // Use fixed 10° band reference latitude so all clients produce identical grids
        let avgLat = allPoints.map(\.latitude).reduce(0, +) / Double(allPoints.count)
        gridReferenceLatitude = HexGrid.fixedReferenceLatitude(for: avgLat)

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
        let dataCellIDs = Set(cells.map(\.coordKey))
        for probe in probeSendLocations where now.timeIntervalSince(probe.time) >= Self.deadZoneTimeout {
            let key = probe.hexCoord.key
            guard !dataCellIDs.contains(key) else { continue }
            let center = HexGrid.centerLatLon(from: probe.hexCoord, referenceLatitude: gridReferenceLatitude)
            cells.append(GridCell(
                coordKey: key,
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
                isDeadZone: true,
                bestGatewaySNR: nil,
                traceResponseCount: 0
            ))
        }

        gridCells = cells

        // Refresh or clear selected cell after rebuild
        if let selected = selectedCell {
            if let updated = gridCells.first(where: { $0.coordKey == selected.coordKey }) {
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

        if let idx = gridCells.firstIndex(where: { $0.coordKey == hex.key }) {
            gridCells[idx] = updatedCell
        } else {
            gridCells.append(updatedCell)
        }

        // Update selected cell if it's the one that changed
        if selectedCell?.coordKey == hex.key {
            selectedCell = updatedCell
        }

        refreshRepeaterAnnotations()
    }

    /// Compute best-gateway SNR from discover responses in a cell's points.
    ///
    /// When discover probes identify repeaters, the cell color should reflect the
    /// **best** gateway's link quality — having one strong repeater nearby is what
    /// matters, not the average of strong + weak. Trace response count is returned
    /// separately as a mesh reachability indicator.
    ///
    /// Returns `(bestGatewaySNR, traceResponseCount)`.
    /// `bestGatewaySNR` is nil when no discover data is available (passive-only cells use averageSNR).
    private static func computeCellQuality(
        points: [SignalSurveyPointDTO]
    ) -> (bestGatewaySNR: Double?, traceResponseCount: Int) {
        let discoverPoints = points.filter { $0.payloadType == .control }
        let traceCount = points.count(where: { $0.payloadType == .trace })

        // Best SNR from discover responses (strongest gateway wins)
        let bestSNR = discoverPoints.compactMap(\.snr).max()

        return (bestSNR, traceCount)
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
        // Only show the 0-hop (directly heard) repeater — the last node in each path chain.
        // Sort by most recently heard first (newest on the left in the UI).
        var latestByRelay: [String: Date] = [:]
        for p in points {
            guard let hexID = p.pathNodeHexIDs.last else { continue }
            if let existing = latestByRelay[hexID] {
                if p.timestamp > existing { latestByRelay[hexID] = p.timestamp }
            } else {
                latestByRelay[hexID] = p.timestamp
            }
        }
        let relayNodes = latestByRelay.sorted { $0.value > $1.value }.map(\.key)

        // Best-gateway quality: cell color reflects strongest discovered repeater
        let (bestGatewaySNR, traceResponseCount) = computeCellQuality(points: points)
        let displaySNR = bestGatewaySNR ?? avgSNR

        return GridCell(
            coordKey: coord.key,
            centerLatitude: center.latitude,
            centerLongitude: center.longitude,
            averageSNR: avgSNR,
            averageRSSI: avgRSSI,
            minSNR: snrValues.min(),
            maxSNR: snrValues.max(),
            packetCount: points.count,
            snrQuality: SNRQuality(snr: displaySNR),
            vertices: HexGrid.vertices(for: coord, referenceLatitude: refLat),
            earliestTimestamp: timestamps.first,
            latestTimestamp: timestamps.last,
            uniqueSenders: senders,
            uniqueRelayNodes: relayNodes,
            isDeadZone: false,
            bestGatewaySNR: bestGatewaySNR,
            traceResponseCount: traceResponseCount
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

    /// Zooms the map to fit the selected cell and the resolved repeater annotation.
    /// Saves the current camera position so it can be restored when the relay filter is cleared.
    private func zoomToFitCellAndRepeater() {
        guard let cell = selectedCell else { return }
        guard let repeater = selectedRepeaterContact else { return }

        // Save current position before zooming (only if not already saved)
        if savedCameraPosition == nil {
            savedCameraPosition = cameraPosition
        }

        let cellCoord = CLLocationCoordinate2D(latitude: cell.centerLatitude, longitude: cell.centerLongitude)
        let repeaterCoord = CLLocationCoordinate2D(latitude: repeater.latitude, longitude: repeater.longitude)

        let minLat = min(cellCoord.latitude, repeaterCoord.latitude)
        let maxLat = max(cellCoord.latitude, repeaterCoord.latitude)
        let minLon = min(cellCoord.longitude, repeaterCoord.longitude)
        let maxLon = max(cellCoord.longitude, repeaterCoord.longitude)

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: min(180, (maxLat - minLat) * 2.0 + 0.003),
            longitudeDelta: min(360, (maxLon - minLon) * 2.0 + 0.003)
        )
        withAnimation(.easeInOut(duration: 0.5)) {
            cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
        }
    }

    // MARK: - Session Management

    func deleteSession(id: UUID, dataStore: PersistenceStore) async {
        do {
            try await dataStore.deleteSurveySession(id: id)
            sessions.removeAll { $0.id == id }
            sessionStats.removeValue(forKey: id)
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

    /// Starts the periodic probe loop that sends node discovery requests.
    private func startProbeLoop(locationService: LocationService) {
        stopProbeLoop()

        // Set reference latitude from current location using fixed 10° bands
        if let loc = locationService.currentLocation {
            probeReferenceLatitude = HexGrid.fixedReferenceLatitude(for: loc.coordinate.latitude)
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
        let freq = probeFrequency

        // Cell exit bypasses cooldown — ensures at least one probe per cell
        let currentHex = HexGrid.axialFromLatLon(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            referenceLatitude: probeReferenceLatitude
        )
        if let lastHex = lastProbeHex, currentHex != lastHex {
            return true
        }

        // All other triggers respect minimum interval
        guard elapsed >= freq.minInterval else { return false }

        // Fire if max interval exceeded (ensure data even when stationary)
        if elapsed >= freq.maxInterval { return true }

        // Fire if distance threshold exceeded
        if let lastLoc = lastProbeLocation {
            let distance = location.distance(from: lastLoc)
            if distance >= freq.distanceMeters {
                return true
            }
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
        guard !isManualProbing else { return }
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

        // Immediate feedback before the blocking async work
        isManualProbing = true
        probeSuccessHaptic += 1
        probeVisualPulse += 1
        probeErrorMessage = nil

        await sendProbe(location: location)
        isManualProbing = false
    }

    /// Sends a discover + channel message + flood trace probe cycle and updates tracking state.
    ///
    /// 1. Discover (lightweight broadcast): identifies which repeaters hear us directly + link SNR.
    /// 2. Channel message: flood-routed text that generates heard repeats for mesh coverage measurement.
    /// 3. Brief delay to separate transmissions.
    /// 4. Flood trace (no path = flood): floods through the mesh to measure reach/connectivity.
    private func sendProbe(location: CLLocation) async {
        guard let bps = binaryProtocolService else {
            logger.warning("Probe skipped: binaryProtocolService is nil")
            return
        }

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

        // 1. Discover: identify directly-heard repeaters
        do {
            let tag = try await bps.sendNodeDiscoverRequest(filter: 0x04, prefixOnly: true)
            logger.debug("Probe #\(self.probeCount) discover sent (tag: \(tag))")
        } catch {
            logger.warning("Probe #\(self.probeCount) discover failed: \(error.localizedDescription)")
        }

        // 2. Channel message: generates heard repeats for mesh coverage measurement
        if let ms = messageServiceRef, let deviceID, let channel = selectedProbeChannel {
            do {
                let probeText = "~\(probeCount)"
                _ = try await ms.sendChannelMessage(
                    text: probeText,
                    channelIndex: channel.index,
                    deviceID: deviceID
                )
                logger.debug("Probe #\(self.probeCount) channel msg sent on ch\(channel.index)")
            } catch {
                logger.warning("Probe #\(self.probeCount) channel msg failed: \(error.localizedDescription)")
            }
        }

        // 3. Brief delay to separate transmissions
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }

        // 4. Flood trace: measure mesh reach from this location
        do {
            _ = try await bps.sendTrace(flags: pathHashMode)
            logger.debug("Probe #\(self.probeCount) trace sent")
        } catch {
            logger.warning("Probe #\(self.probeCount) trace failed: \(error.localizedDescription)")
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
            if !gridCells.contains(where: { $0.coordKey == key }) {
                let center = HexGrid.centerLatLon(from: probe.hexCoord, referenceLatitude: gridReferenceLatitude)
                gridCells.append(GridCell(
                    coordKey: key,
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
                    isDeadZone: true,
                    bestGatewaySNR: nil,
                    traceResponseCount: 0
                ))
                changed = true
            }
        }

        // Remove dead zone cells that now have data
        if gridCells.contains(where: { $0.isDeadZone && dataCellIDs.contains($0.coordKey) }) {
            gridCells.removeAll { $0.isDeadZone && dataCellIDs.contains($0.coordKey) }
            changed = true
        }

        _ = changed // Suppress unused warning; mutations to gridCells already trigger observation
    }

    // MARK: - Cell Detail Data Access

    /// Returns the raw survey points for the selected cell, optionally filtered by relay node.
    func pointsForSelectedCell(relayFilter: String? = nil) -> [SignalSurveyPointDTO] {
        guard let cell = selectedCell else { return [] }
        let parts = cell.coordKey.split(separator: "_").compactMap { Int($0) }
        guard parts.count == 2 else { return [] }
        let coord = HexGrid.AxialCoord(q: parts[0], r: parts[1])
        let points = gridBuckets[coord] ?? []
        if let relay = relayFilter {
            // Match on the directly heard repeater (last in path chain)
            return points.filter { $0.pathNodeHexIDs.last == relay }
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

    // MARK: - Probe Channel Management

    /// Loads available private channels and restores the previously selected probe channel.
    func loadProbeChannels(dataStore: PersistenceStore, deviceID: UUID) async {
        do {
            let channels = try await dataStore.fetchChannels(deviceID: deviceID)
            // Only offer non-public channels that are configured
            availableProbeChannels = channels.filter { !$0.isPublicChannel }
        } catch {
            logger.error("Failed to load probe channels: \(error.localizedDescription)")
        }

        // Restore previous selection
        let savedIndex = UserDefaults.standard.integer(forKey: "surveyProbeChannelIndex")
        if savedIndex > 0 {
            selectedProbeChannel = availableProbeChannels.first(where: { $0.index == UInt8(savedIndex) })
        }
    }

    /// Creates a dedicated "Survey" channel on the first available slot with a random secret.
    func createSurveyChannel(
        channelService: ChannelService,
        dataStore: PersistenceStore,
        deviceID: UUID,
        maxChannels: UInt8
    ) async {
        // Find first available slot (skip 0 = public)
        let usedSlots = Set(availableProbeChannels.map(\.index))
        guard let slot = (1..<maxChannels).first(where: { !usedSlots.contains($0) && $0 != 0 }) else {
            errorMessage = "No available channel slots"
            return
        }

        // Generate random 16-byte secret
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let secret = Data(bytes)

        do {
            try await channelService.setChannelWithSecret(
                deviceID: deviceID,
                index: slot,
                name: "Survey",
                secret: secret
            )
            // Reload channels and select the new one
            await loadProbeChannels(dataStore: dataStore, deviceID: deviceID)
            selectedProbeChannel = availableProbeChannels.first(where: { $0.index == slot })
            logger.info("Created survey probe channel on slot \(slot)")
        } catch {
            errorMessage = "Failed to create channel: \(error.localizedDescription)"
            logger.error("Failed to create survey channel: \(error.localizedDescription)")
        }
    }
}
