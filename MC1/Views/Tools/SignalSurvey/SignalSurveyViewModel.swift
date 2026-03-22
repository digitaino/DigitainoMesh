import CoreLocation
import MapKit
import MC1Services
import OSLog
import Security
import SwiftUI

private let logger = Logger(subsystem: "com.mc1", category: "SignalSurvey")

@MainActor @Observable
final class SignalSurveyViewModel {

    private static let isoFormatter = ISO8601DateFormatter()

    // MARK: - Survey State

    enum SurveyState: Equatable {
        case idle
        case active(sessionID: UUID)
        case loading
    }

    /// Bundled probe frequency presets that pair a distance trigger with a minimum cooldown.
    enum ProbeFrequency: String, CaseIterable, Identifiable {
        case driving = "Driving"
        case dense = "Dense"
        case normal = "Normal"
        case sparse = "Sparse"

        var id: String { rawValue }

        /// Distance threshold in meters before triggering a probe.
        var distanceMeters: Double {
            switch self {
            case .driving: 15
            case .dense: 25
            case .normal: 50
            case .sparse: 100
            }
        }

        /// Minimum seconds between consecutive probes (hard cooldown).
        var minInterval: TimeInterval {
            switch self {
            case .driving: 1
            case .dense: 2
            case .normal: 4
            case .sparse: 8
            }
        }

        /// Maximum seconds before a probe fires regardless of movement.
        var maxInterval: TimeInterval {
            switch self {
            case .driving: 3
            case .dense: 6
            case .normal: 10
            case .sparse: 20
            }
        }

        /// Human-readable subtitle for the setup sheet.
        var subtitle: String {
            switch self {
            case .driving: "Every ~15m — driving, fast travel"
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

    /// True while the view is loading sessions and checking for an active survey to resume.
    /// Prevents the empty state from flashing when the view is recreated after back-button navigation.
    var isCheckingForActiveSession = false

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

    /// The currently selected session DTO, if any.
    var selectedSession: SurveySessionDTO? {
        guard let id = selectedSessionID else { return nil }
        return sessions.first { $0.id == id }
    }

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

    // MARK: - Debug Info

    /// Aggregated debug data for the survey debug overlay.
    struct DebugInfo {
        let gpsAccuracy: Double?
        let gpsFixAge: TimeInterval?
        let gpsSpeed: Double?

        let probeCount: Int
        let timeSinceLastProbe: TimeInterval?
        let probeFrequency: ProbeFrequency
        let probeEnabled: Bool
        let deepScanEnabled: Bool
        let nextProbeMaxIn: TimeInterval?

        let totalPoints: Int
        let passivePoints: Int
        let controlPoints: Int
        let tracePoints: Int
        /// 0-hop active responses (direct 2-way proof)
        let directPoints: Int
        /// Multi-hop active responses (mesh reach only)
        let relayedPoints: Int

        let isActive: Bool
        let gridCellCount: Int
        let deadZoneCount: Int
        /// Unique repeaters confirmed via 0-hop response across all cells
        let connectedRepeaters: Int
        /// Unique repeaters only reached via multi-hop across all cells
        let meshReachRepeaters: Int
        let liveUploadCount: Int
        let liveUploadEnabled: Bool
        let eventMonitoringActive: Bool
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
        /// Repeaters confirmed bidirectional via 0-hop discover/trace response (direct 2-way link).
        let connectedRelayNodes: [String]
        /// Repeaters reached via multi-hop trace (mesh reach, but not direct 2-way).
        let meshReachRelayNodes: [String]
        /// Repeaters only heard passively (one-way RX only).
        let heardOnlyRelayNodes: [String]
        let isDeadZone: Bool
        /// Best-gateway SNR from discover responses.
        /// Nil when no discover data is available (passive-only cells use averageSNR).
        let bestGatewaySNR: Double?
        /// Maximum mesh depth reached by active probes in this cell.
        /// Value is (hopCount + 1): 1 = direct reach, 2 = one relay hop, etc.
        /// 0 means no trace responses were received.
        let maxMeshDepth: Int
        /// Number of packets from active probes (bidirectional confirmation) in this cell.
        let activePacketCount: Int
        /// Number of active probe messages sent from this cell. Nil if probing was not active.
        let probesSent: Int?

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

    /// Optional display name to include with uploads (set from survey setup sheet).
    var displayNameForUpload: String?

    /// Upload service instance for live point uploads. Created on demand.
    private var liveUploadService: SurveyUploadService?

    /// Count of points successfully uploaded live in this session.
    private(set) var liveUploadCount: Int = 0

    // MARK: - Community Overlay

    /// Whether the community data overlay is shown on the survey map.
    var showCommunityOverlay: Bool = false {
        didSet {
            if showCommunityOverlay {
                if let region = lastCommunityRegion {
                    loadCommunityCells(for: region)
                }
                startCommunityRefresh()
            } else {
                communityCells = []
                communityRepeaterLocations = []
                selectedCommunityCell = nil
                communityCoverageFilter = .all
                communityRepeaterFilter = nil
                communityTimeFilter = .allTime
                stopCommunityRefresh()
            }
        }
    }

    /// Community cells loaded from the server for the current viewport.
    private(set) var communityCells: [SurveyUploadService.CommunityCell] = []

    /// Repeater locations loaded from the server for the current viewport.
    private(set) var communityRepeaterLocations: [SurveyUploadService.RepeaterLocation] = []

    /// Look up a repeater display name for a hex ID using prefix-aware matching.
    func repeaterDisplayName(for hexID: String) -> String {
        let upper = hexID.uppercased()
        if let loc = communityRepeaterLocations.first(where: { loc in
            let lh = loc.hexID.uppercased()
            return lh == upper || lh.hasPrefix(upper) || upper.hasPrefix(lh)
        }), !loc.name.isEmpty {
            return "\(loc.name) (\(hexID))"
        }
        return hexID
    }

    /// Coverage filter for the community overlay (All/Active/Passive).
    var communityCoverageFilter: CommunityMapView.CoverageFilter = .all

    /// Optional repeater filter for the community overlay layer.
    var communityRepeaterFilter: String?

    /// Time filter for the community overlay (how recent the data must be).
    var communityTimeFilter: MapTimeFilter = .allTime

    /// Repeaters available for filtering: only those referenced in cells AND present in the viewport.
    /// Returns (hexID, displayName) tuples sorted by name, matching the web map behavior.
    var communityAvailableRepeaters: [(hexID: String, displayName: String)] {
        let consolidated = CommunityMapView.consolidateHexIDs(communityCells.flatMap(\.repeaterHexIDs))

        // Build a set of viewport repeater hex IDs (uppercased for prefix matching)
        let viewportIDs = Set(communityRepeaterLocations.map { $0.hexID.uppercased() })

        // Filter to repeaters whose physical location is in the current viewport (prefix-aware)
        let filtered: [String]
        if viewportIDs.isEmpty {
            filtered = consolidated
        } else {
            filtered = consolidated.filter { hexID in
                let uh = hexID.uppercased()
                return viewportIDs.contains(where: { vh in
                    uh == vh || uh.hasPrefix(vh) || vh.hasPrefix(uh)
                })
            }
        }

        // Build name lookup from repeater locations
        let namesByHex = Dictionary(communityRepeaterLocations.map { ($0.hexID.uppercased(), $0.name) },
                                     uniquingKeysWith: { _, new in new })

        return filtered.sorted().map { hexID in
            let upper = hexID.uppercased()
            // Prefix-aware name lookup
            let name = namesByHex[upper] ?? namesByHex.first(where: { key, _ in
                key.hasPrefix(upper) || upper.hasPrefix(key)
            })?.value
            let display = (name != nil && !name!.isEmpty) ? "\(name!) (\(hexID))" : hexID
            return (hexID: hexID, displayName: display)
        }
    }

    /// Community cells after applying coverage and repeater filters.
    var filteredCommunityCells: [SurveyUploadService.CommunityCell] {
        var result: [SurveyUploadService.CommunityCell]
        switch communityCoverageFilter {
        case .all: result = communityCells
        case .active: result = communityCells.filter { ($0.activePacketCount ?? 0) > 0 }
        case .passive: result = communityCells.filter { ($0.passivePacketCount ?? 0) > 0 }
        }
        if let repeater = communityRepeaterFilter {
            let rf = repeater.uppercased()
            result = result.filter { cell in
                cell.repeaterHexIDs.contains { id in
                    let uid = id.uppercased()
                    return uid == rf || uid.hasPrefix(rf) || rf.hasPrefix(uid)
                }
            }
        }
        if let maxAge = communityTimeFilter.maxAge {
            let cutoff = Date().addingTimeInterval(-maxAge)
            result = result.filter { cell in
                guard let dateStr = cell.lastUpdated,
                      let date = Self.isoFormatter.date(from: dateStr) else {
                    return false
                }
                return date >= cutoff
            }
        }
        return result
    }

    /// Upload service for fetching community data.
    private var communityUploadService: SurveyUploadService?
    private var communityRefreshTask: Task<Void, Never>?
    private var communityLoadTask: Task<Void, Never>?
    private var lastCommunityRegion: MKCoordinateRegion?

    /// Load community cells for a given map region (debounced 300ms).
    func loadCommunityCells(for region: MKCoordinateRegion) {
        lastCommunityRegion = region
        guard showCommunityOverlay else { return }

        // Cancel any pending debounced load
        communityLoadTask?.cancel()
        communityLoadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.fetchCommunityCells(for: region)
        }
    }

    /// Fetch community cells immediately (used by debounced load and periodic refresh).
    private func fetchCommunityCells(for region: MKCoordinateRegion) async {
        if communityUploadService == nil {
            communityUploadService = SurveyUploadService()
        }

        let center = region.center
        let span = region.span
        let minLat = center.latitude - span.latitudeDelta / 2
        let maxLat = center.latitude + span.latitudeDelta / 2
        let minLon = center.longitude - span.longitudeDelta / 2
        let maxLon = center.longitude + span.longitudeDelta / 2

        do {
            guard let service = communityUploadService else { return }
            // Map coverage filter to server parameter
            let coverageParam: String? = {
                switch communityCoverageFilter {
                case .active: return "active"
                case .passive: return "passive"
                case .all: return nil
                }
            }()
            let maxAgeParam: Int? = communityTimeFilter.maxAge.map { Int($0) }

            async let cellsResult = service.fetchCommunityData(
                minLat: minLat, maxLat: maxLat,
                minLon: minLon, maxLon: maxLon,
                coverage: coverageParam,
                maxAge: maxAgeParam,
                repeater: communityRepeaterFilter
            )
            async let repeatersResult = service.fetchRepeaterLocations(
                minLat: minLat, maxLat: maxLat,
                minLon: minLon, maxLon: maxLon
            )
            let (response, repeaters) = try await (cellsResult, repeatersResult)
            guard !Task.isCancelled else { return }
            communityCells = response.cells
            communityRepeaterLocations = repeaters
        } catch {
            guard !Task.isCancelled else { return }
            logger.warning("Community overlay fetch failed: \(error.localizedDescription)")
        }
    }

    private func startCommunityRefresh() {
        stopCommunityRefresh()
        communityRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                guard let self, let region = self.lastCommunityRegion else { continue }
                await self.fetchCommunityCells(for: region)
            }
        }
    }

    func stopCommunityRefresh() {
        communityRefreshTask?.cancel()
        communityRefreshTask = nil
    }

    /// The community cell tapped by the user (for showing detail overlay).
    var selectedCommunityCell: SurveyUploadService.CommunityCell?

    // MARK: - Active Probing

    /// Whether active probing (node discovery) is enabled during survey.
    var probeEnabled: Bool = false {
        didSet {
            guard probeEnabled != oldValue else { return }
            guard isActive else { return }
            // Notify SurveyService so it classifies incoming packets as active/passive
            if let surveyService = surveyServiceRef {
                Task { await surveyService.setProbingActive(probeEnabled) }
            }
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

    /// When true, probes also send discover + trace in addition to the channel message.
    /// This provides extra mesh depth data but uses more airtime and works best at slower speeds.
    var deepScanEnabled: Bool = false

    private var binaryProtocolService: BinaryProtocolService?
    private var messageServiceRef: MessageService?
    private var channelServiceRef: ChannelService?
    private var locationServiceRef: LocationService?
    private var surveyServiceRef: SurveyService?
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
    /// Incremented each time the probe loop starts. In-flight sendProbe tasks check
    /// this to bail out if a new loop has started since they were spawned.
    private var probeGeneration: Int = 0
    private var lastProbeHex: HexGrid.AxialCoord?
    private(set) var lastProbeTime: Date = .distantPast
    private var lastProbeLocation: CLLocation?
    /// Probe loop reference latitude — fixed 10° band, matching gridReferenceLatitude.
    private var probeReferenceLatitude: Double = 30.0

    /// Locations where probes were sent, for dead zone detection.
    private(set) var probeSendLocations: [(coordinate: CLLocationCoordinate2D, hexCoord: HexGrid.AxialCoord, time: Date)] = []
    /// Per-cell count of probes sent, keyed by hex coordinate key (e.g. "3_-2").
    private(set) var probesSentPerCell: [String: Int] = [:]

    private static let probeCheckInterval: TimeInterval = 2
    /// How long to wait after a probe before marking its cell as a dead zone.
    /// Multi-hop mesh responses can take 10-15s through 3+ relays, so 25s
    /// prevents false dead zones. Late arrivals still clear the dead zone.
    private static let deadZoneTimeout: TimeInterval = 25

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

    // MARK: - Debug Info Computation

    /// Aggregated debug data for the debug overlay. Only computed when debug mode is active.
    var debugInfo: DebugInfo {
        let location = locationServiceRef?.currentLocation

        let gpsAccuracy = location?.horizontalAccuracy
        let gpsFixAge: TimeInterval? = location.map { abs($0.timestamp.timeIntervalSinceNow) }
        let gpsSpeed: Double? = location.flatMap { $0.speed >= 0 ? $0.speed : nil }

        let timeSinceProbe: TimeInterval? = lastProbeTime == .distantPast
            ? nil
            : Date().timeIntervalSince(lastProbeTime)
        let nextProbeMax: TimeInterval? = {
            guard probeEnabled, lastProbeTime != .distantPast else { return nil }
            let elapsed = Date().timeIntervalSince(lastProbeTime)
            return max(0, probeFrequency.maxInterval - elapsed)
        }()

        let activePoints = allPoints.filter(\.isActiveProbe)
        let controlPts = activePoints.filter { $0.payloadType == .control }.count
        let tracePts = activePoints.filter { $0.payloadType == .trace }.count
        let passivePts = allPoints.count - activePoints.count
        let directPts = activePoints.filter { Self.isDirectTwoWay($0) }.count
        let relayedPts = activePoints.count - directPts

        let deadZones = gridCells.filter(\.isDeadZone).count
        let connectedCount = Set(gridCells.flatMap(\.connectedRelayNodes)).count
        let meshReachCount = Set(gridCells.flatMap(\.meshReachRelayNodes)).count

        return DebugInfo(
            gpsAccuracy: gpsAccuracy,
            gpsFixAge: gpsFixAge,
            gpsSpeed: gpsSpeed,
            probeCount: probeCount,
            timeSinceLastProbe: timeSinceProbe,
            probeFrequency: probeFrequency,
            probeEnabled: probeEnabled,
            deepScanEnabled: deepScanEnabled,
            nextProbeMaxIn: nextProbeMax,
            totalPoints: livePointCount,
            passivePoints: passivePts,
            controlPoints: controlPts,
            tracePoints: tracePts,
            directPoints: directPts,
            relayedPoints: relayedPts,
            isActive: isActive,
            gridCellCount: gridCells.count,
            deadZoneCount: deadZones,
            connectedRepeaters: connectedCount,
            meshReachRepeaters: meshReachCount,
            liveUploadCount: liveUploadCount,
            liveUploadEnabled: liveUploadEnabled,
            eventMonitoringActive: surveyServiceRef != nil
        )
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
            probesSentPerCell = [:]
            gridBuckets = [:]
            liveStatus = SurveyLiveStatus()
            selectedSessionID = session.id

            // Store references for probing
            self.binaryProtocolService = binaryProtocolService
            self.messageServiceRef = messageService
            self.deviceID = deviceID
            self.locationServiceRef = locationService
            self.surveyServiceRef = surveyService
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

            // Start probe loop if enabled and sync active state
            if probeEnabled {
                await surveyService.setProbingActive(true)
                if binaryProtocolService != nil {
                    startProbeLoop(locationService: locationService)
                }
            }

            logger.info("Survey started: \(session.id)")
        } catch {
            state = .idle
            errorMessage = error.localizedDescription
            logger.error("Failed to start survey: \(error.localizedDescription)")
        }
    }

    /// Persists in-memory probe data to the database without stopping the session.
    /// Called when the view disappears so that `resumeIfActive()` can restore probe count.
    func persistProbeData(dataStore: PersistenceStore) async {
        guard case .active(let sessionID) = state, !probesSentPerCell.isEmpty else { return }
        try? await dataStore.saveProbesSentPerCell(
            sessionID: sessionID,
            probesSentPerCell: probesSentPerCell
        )
    }

    func stopSurvey(
        surveyService: SurveyService,
        locationService: LocationService,
        dataStore: PersistenceStore?,
        deviceID: UUID?
    ) async {
        guard case .active(let sessionID) = state else { return }

        // Stop probing first
        stopProbeLoop()

        do {
            // Persist probe-sent-per-cell data before clearing it,
            // so dead zones can be reconstructed when loading this session later
            if let dataStore, !probesSentPerCell.isEmpty {
                try? await dataStore.saveProbesSentPerCell(
                    sessionID: sessionID,
                    probesSentPerCell: probesSentPerCell
                )
            }

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
            surveyServiceRef = nil
            self.deviceID = nil
            lastProbeHex = nil
            lastProbeLocation = nil
            probeSendLocations = []
            probesSentPerCell = [:]
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

        // Yield to allow the previous view's .onDisappear persist task to schedule,
        // then re-fetch sessions from DB to get the latest probesSentPerCell.
        await Task.yield()
        await loadSessions(dataStore: dataStore, deviceID: deviceID)
        let session = sessions.first(where: { $0.id == sessionID })
        activeSession = session
        state = .active(sessionID: sessionID)
        selectedSessionID = sessionID

        // Load existing points for this session (pass session to restore probesSentPerCell)
        await loadPoints(dataStore: dataStore, sessionID: sessionID, session: session)

        // Restore probe count from persisted probe-sent-per-cell data
        if !probesSentPerCell.isEmpty {
            probeCount = probesSentPerCell.values.reduce(0, +)
        }

        // Store references for probing
        self.binaryProtocolService = binaryProtocolService
        self.messageServiceRef = messageService
        self.deviceID = deviceID
        self.locationServiceRef = locationService
        self.surveyServiceRef = surveyService
        self.pathHashMode = pathHashMode

        // Re-wire live point handler
        await surveyService.setPointRecordedHandler { [weak self] point in
            await MainActor.run {
                self?.handleNewPoint(point)
            }
        }

        // Resume probe loop if enabled and sync active state
        if probeEnabled {
            await surveyService.setProbingActive(true)
            if binaryProtocolService != nil {
                startProbeLoop(locationService: locationService)
            }
        }

        // Update the live status immediately so the floating indicator shows correct data
        refreshLiveStatus()

        logger.info("Resumed active survey session: \(sessionID), \(self.livePointCount) existing points, \(self.probeCount) probes")
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
            let activeSessionID = activeSession?.id
            let service = liveUploadService ?? SurveyUploadService()
            if liveUploadService == nil {
                liveUploadService = service
                Task { await service.setDisplayName(displayNameForUpload) }
            }
            Task.detached {
                await service.uploadLivePoint(
                    point,
                    referenceLatitude: refLat,
                    sessionID: activeSessionID,
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

        // Follow user location, offset center northward so the current cell
        // sits above the detail card (which covers ~35% of the bottom).
        let span = MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        let offsetCenter = CLLocationCoordinate2D(
            latitude: location.coordinate.latitude - span.latitudeDelta * 0.2,
            longitude: location.coordinate.longitude
        )
        cameraPosition = .region(MKCoordinateRegion(center: offsetCenter, span: span))
    }

    // MARK: - Filtering

    /// Active probe payload types used for probing classification.
    /// `.control` = discover node response (deep scan only).
    /// `.trace` = outbound flood probe (deep scan only).
    /// `.groupText` = channel message heard repeat (primary 2-way proof).
    private static let activePayloadTypes: Set<PayloadType> = [.trace, .control, .groupText]

    /// Whether an active probe point proves direct 2-way connectivity.
    ///
    /// The hop semantics differ by packet type:
    /// - `.control` / `.trace`: hopCount == 0 means the repeater responded directly.
    /// - `.groupText` (heard repeat): hopCount == 1 means the repeater relayed our message
    ///   directly (it's the single hop in the path). hopCount == 0 is impossible for heard
    ///   repeats since there's always at least the relaying repeater in the path.
    private static func isDirectTwoWay(_ point: SignalSurveyPointDTO) -> Bool {
        guard point.isActiveProbe else { return false }
        if point.payloadType == .groupText {
            return point.hopCount == 1
        }
        return point.hopCount == 0
    }

    private func passesFilter(_ point: SignalSurveyPointDTO) -> Bool {
        switch surveyFilter {
        case .all: true
        case .passiveOnly: !point.isActiveProbe
        case .traceOnly: point.isActiveProbe
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

    func loadPoints(dataStore: PersistenceStore, sessionID: UUID, session: SurveySessionDTO? = nil) async {
        do {
            allPoints = try await dataStore.fetchSurveyPoints(sessionID: sessionID)
            livePointCount = allPoints.count

            // Restore probe-sent-per-cell data if available (for dead zone reconstruction)
            if let stored = session?.probesSentPerCell, !stored.isEmpty {
                probesSentPerCell = stored
            }

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
            // Clear single-session probe data so dead zones don't bleed into combined view
            probesSentPerCell = [:]
            applyFilter()
            centerOnData()
        } catch {
            logger.error("Failed to load all points: \(error.localizedDescription)")
        }
    }

    /// Clears all displayed data without loading anything.
    /// Used when dismissing a session selection without wanting to show all sessions.
    func clearSessionData() {
        selectedSessionID = nil
        allPoints = []
        displayPoints = []
        gridCells = []
        gridBuckets = [:]
        livePointCount = 0
        probesSentPerCell = [:]
        selectedCell = nil
        selectedCommunityCell = nil
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
            Self.makeGridCell(coord: coord, points: points, refLat: gridReferenceLatitude, probesSent: probesSentPerCell[coord.key])
        }

        // Add dead zone cells for probed-but-no-response hexes
        let dataCellIDs = Set(cells.map(\.coordKey))
        var addedDeadZones = Set<String>()

        // Live session: use probeSendLocations with timeout check
        if !probeSendLocations.isEmpty {
            let now = Date()
            for probe in probeSendLocations where now.timeIntervalSince(probe.time) >= Self.deadZoneTimeout {
                let key = probe.hexCoord.key
                guard !dataCellIDs.contains(key), !addedDeadZones.contains(key) else { continue }
                addedDeadZones.insert(key)
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
                    connectedRelayNodes: [],
                    meshReachRelayNodes: [],
                    heardOnlyRelayNodes: [],
                    isDeadZone: true,
                    bestGatewaySNR: nil,
                    maxMeshDepth: 0,
                    activePacketCount: 0,
                    probesSent: probesSentPerCell[key]
                ))
            }
        } else if !probesSentPerCell.isEmpty {
            // Restored session: reconstruct dead zones from stored probesSentPerCell
            for (key, probes) in probesSentPerCell where probes > 0 {
                guard !dataCellIDs.contains(key) else { continue }
                let parts = key.split(separator: "_")
                guard parts.count == 2, let q = Int(parts[0]), let r = Int(parts[1]) else { continue }
                let coord = HexGrid.AxialCoord(q: q, r: r)
                let center = HexGrid.centerLatLon(from: coord, referenceLatitude: gridReferenceLatitude)
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
                    vertices: HexGrid.vertices(for: coord, referenceLatitude: gridReferenceLatitude),
                    earliestTimestamp: nil,
                    latestTimestamp: nil,
                    uniqueSenders: [],
                    uniqueRelayNodes: [],
                    connectedRelayNodes: [],
                    meshReachRelayNodes: [],
                    heardOnlyRelayNodes: [],
                    isDeadZone: true,
                    bestGatewaySNR: nil,
                    maxMeshDepth: 0,
                    activePacketCount: 0,
                    probesSent: probes
                ))
            }
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
            points: gridBuckets[hex] ?? [point],
            refLat: gridReferenceLatitude,
            probesSent: probesSentPerCell[hex.key]
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

    /// Compute best-gateway SNR from active probe responses in a cell's points.
    ///
    /// When active probes identify repeaters, the cell color should reflect the
    /// **best** gateway's link quality — having one strong repeater nearby is what
    /// matters, not the average of strong + weak.
    ///
    /// Direct 2-way proof differs by packet type (see `isDirectTwoWay`):
    /// - `.groupText` heard repeat with 1 hop = direct (the repeater is the single hop)
    /// - `.control` / `.trace` with 0 hops = direct
    ///
    /// Returns `(bestGatewaySNR, maxMeshDepth)`.
    /// `bestGatewaySNR` is nil when no direct probe data is available (passive-only cells use averageSNR).
    private static func computeCellQuality(
        points: [SignalSurveyPointDTO]
    ) -> (bestGatewaySNR: Double?, maxMeshDepth: Int) {
        // Best SNR from direct 2-way active probe responses.
        let directProbePoints = points.filter { isDirectTwoWay($0) }
        let bestSNR = directProbePoints.compactMap(\.snr).max()

        // Maximum mesh depth from trace responses.
        // hopCount is the number of relay hops in the return path:
        //   0 = direct response (1 hop away), 1 = one relay (2 hops away), etc.
        // We report depth as hopCount + 1 so the user sees "1" for direct reach.
        let tracePoints = points.filter { $0.payloadType == .trace }
        let maxDepth = tracePoints.isEmpty ? 0 : (tracePoints.map(\.hopCount).max() ?? 0) + 1

        return (bestSNR, maxDepth)
    }

    /// Creates a GridCell from a bucket of points at a hex coordinate.
    private static func makeGridCell(
        coord: HexGrid.AxialCoord,
        points: [SignalSurveyPointDTO],
        refLat: Double,
        probesSent: Int? = nil
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
        // Max valid hex ID is 6 chars (3-byte hash). Anything longer is corrupt data —
        // drop it rather than truncating (a truncated prefix won't merge correctly with
        // the real shorter ID via the consolidation logic below).
        var latestByRelay: [String: Date] = [:]
        for p in points {
            guard let hexID = p.pathNodeHexIDs.last, hexID.count <= 6 else { continue }
            if let existing = latestByRelay[hexID] {
                if p.timestamp > existing { latestByRelay[hexID] = p.timestamp }
            } else {
                latestByRelay[hexID] = p.timestamp
            }
        }

        // Consolidate hex IDs: different hash sizes produce different lengths for the
        // same repeater (e.g. "88" from 1-byte pathNodes vs "8850" from discover response).
        // Keep the **longest** form for better specificity — multi-byte firmware is being
        // rolled out and longer IDs reduce collision risk between repeaters.
        let allIDs = Array(latestByRelay.keys).map { $0.uppercased() }
        var displayIDs: [String] = []
        for id in allIDs {
            let dominated = displayIDs.contains(where: { $0.hasPrefix(id) || id.hasPrefix($0) })
            if dominated {
                // Keep the longer of the two (more specific)
                displayIDs = displayIDs.map { existing in
                    // existing starts with id → existing is longer or equal, keep existing
                    if existing.hasPrefix(id) { return existing }
                    // id starts with existing → id is longer, replace with id
                    if id.hasPrefix(existing) { return id }
                    return existing
                }
            } else {
                displayIDs.append(id)
            }
        }
        displayIDs = Array(Set(displayIDs)) // deduplicate
        var consolidatedLatest: [String: Date] = [:]
        for dID in displayIDs {
            for (rawID, ts) in latestByRelay {
                let rawUp = rawID.uppercased()
                if rawUp == dID || dID.hasPrefix(rawUp) || rawUp.hasPrefix(dID) {
                    consolidatedLatest[dID] = max(consolidatedLatest[dID] ?? .distantPast, ts)
                }
            }
        }
        let relayNodes = consolidatedLatest.sorted { $0.value > $1.value }.map(\.key)

        // Split relay nodes into three tiers:
        //   1. Connected (2-way): direct active probe responses — the repeater heard us
        //      directly and we heard it back. For groupText heard repeats this is hopCount == 1
        //      (the repeater is the single hop). For control/trace this is hopCount == 0.
        //   2. Mesh Reach: multi—hop active responses (deep scan only) — proves mesh
        //      reachability but the repeater may not hear us directly.
        //   3. Heard Only: passive packets — one-way RX, no proof of any return path.
        //
        // Use prefix matching because control/trace packets produce 2-byte IDs while regular
        // packets use 1-byte hashes.
        let directIDs = Set(points
            .filter { Self.isDirectTwoWay($0) }
            .flatMap(\.pathNodeHexIDs))
        let meshReachIDs = Set(points
            .filter { $0.isActiveProbe && !Self.isDirectTwoWay($0) }
            .flatMap(\.pathNodeHexIDs))

        func hexIDMatches(_ relay: String, in idSet: Set<String>) -> Bool {
            let r = relay.uppercased()
            return idSet.contains(where: { id in
                let u = id.uppercased()
                return u == r || u.hasPrefix(r) || r.hasPrefix(u)
            })
        }

        let connected = relayNodes.filter { hexIDMatches($0, in: directIDs) }
        // Mesh reach: appeared in multi-hop responses but NOT in any 0-hop response
        let meshReach = relayNodes.filter { !hexIDMatches($0, in: directIDs) && hexIDMatches($0, in: meshReachIDs) }
        let heardOnly = relayNodes.filter { !hexIDMatches($0, in: directIDs) && !hexIDMatches($0, in: meshReachIDs) }

        // Best-gateway quality: cell color reflects strongest discovered repeater
        let (bestGatewaySNR, maxMeshDepth) = computeCellQuality(points: points)
        let displaySNR = bestGatewaySNR ?? avgSNR
        let activeCount = points.count(where: \.isActiveProbe)

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
            connectedRelayNodes: connected,
            meshReachRelayNodes: meshReach,
            heardOnlyRelayNodes: heardOnly,
            isDeadZone: false,
            bestGatewaySNR: bestGatewaySNR,
            maxMeshDepth: maxMeshDepth,
            activePacketCount: activeCount,
            probesSent: probesSent
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
        probeGeneration += 1

        // Set reference latitude from current location using fixed 10° bands
        if let loc = locationService.currentLocation {
            probeReferenceLatitude = HexGrid.fixedReferenceLatitude(for: loc.coordinate.latitude)
        }

        let generation = probeGeneration
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.probeCheckInterval))
                guard !Task.isCancelled else { break }

                guard let self else { break }
                guard self.isActive, self.probeEnabled else { break }
                guard let locationService = self.locationServiceRef else { break }
                guard let location = locationService.currentLocation else { continue }

                if self.shouldProbe(location: location) {
                    // Fire-and-forget: decouple probe check cadence from probe execution time.
                    // State updates (lastProbeTime, lastProbeHex, etc.) happen synchronously
                    // at the top of sendProbe before any async radio calls, so this is safe.
                    // Generation check ensures stale tasks from a previous loop don't send.
                    Task { [weak self] in
                        guard let self, self.probeGeneration == generation else { return }
                        await self.sendProbe(location: location)
                    }
                }

                // Check for dead zones on every tick — probes that timed out
                // (no response within deadZoneTimeout) should appear as gray cells.
                self.refreshDeadZones()
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

    /// Sends a probe cycle and updates tracking state.
    ///
    /// **Default mode**: Sends a channel message only. A 0-hop heard repeat of this message
    /// is the ground truth for bidirectional connectivity — it proves the repeater heard us
    /// directly and we heard it back.
    ///
    /// **Deep scan mode** (`deepScanEnabled`): Also sends discover + trace requests.
    /// These provide extra data (gateway SNR, mesh depth) but use more airtime and work
    /// best at slower speeds.
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
        probesSentPerCell[hexCoord.key, default: 0] += 1
        probeSendLocations.append((
            coordinate: location.coordinate,
            hexCoord: hexCoord,
            time: Date()
        ))

        // Deep scan: discover first to identify directly-heard repeaters
        if deepScanEnabled {
            do {
                let tag = try await bps.sendNodeDiscoverRequest(filter: 0x04, prefixOnly: true)
                logger.debug("Probe #\(self.probeCount) discover sent (tag: \(tag))")
            } catch {
                logger.warning("Probe #\(self.probeCount) discover failed: \(error.localizedDescription)")
            }
        }

        // Channel message: the primary probe. Generates heard repeats for 2-way proof.
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

        // Deep scan: flood trace to measure mesh depth
        if deepScanEnabled {
            // Brief delay to separate transmissions
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }

            do {
                _ = try await bps.sendTrace(flags: pathHashMode)
                logger.debug("Probe #\(self.probeCount) trace sent")
            } catch {
                logger.warning("Probe #\(self.probeCount) trace failed: \(error.localizedDescription)")
            }
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
                let probes = probesSentPerCell[key]
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
                    connectedRelayNodes: [],
                    meshReachRelayNodes: [],
                    heardOnlyRelayNodes: [],
                    isDeadZone: true,
                    bestGatewaySNR: nil,
                    maxMeshDepth: 0,
                    activePacketCount: 0,
                    probesSent: probes
                ))
                changed = true

                // Live upload dead zone cell
                if liveUploadEnabled, let probes, probes > 0 {
                    let refLat = gridReferenceLatitude
                    let q = probe.hexCoord.q
                    let r = probe.hexCoord.r
                    let sid = activeSession?.id
                    let service = liveUploadService ?? SurveyUploadService()
                    if liveUploadService == nil {
                        liveUploadService = service
                        Task { await service.setDisplayName(displayNameForUpload) }
                    }
                    Task.detached {
                        await service.uploadDeadZoneCell(
                            hexQ: q, hexR: r,
                            referenceLatitude: refLat,
                            probesSent: probes,
                            sessionID: sid
                        )
                    }
                }
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
            // Match on the directly heard repeater (last in path chain).
            // Use prefix matching because consolidated hex IDs may be longer
            // than the 1-byte hash in pathNodeHexIDs (e.g. filter "07D3" should match point with "07").
            let r = relay.uppercased()
            return points.filter { point in
                guard let last = point.pathNodeHexIDs.last else { return false }
                let u = last.uppercased()
                return u == r || u.hasPrefix(r) || r.hasPrefix(u)
            }
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
