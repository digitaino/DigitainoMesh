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
    /// Prevents the empty state from flashing when the view is first created.
    var isCheckingForActiveSession = true

    var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    /// Whether the active survey is temporarily paused (stops recording packets but keeps session open).
    var isPaused: Bool = false

    // MARK: - Map State

    var cameraPosition: MapCameraPosition = .automatic

    /// The region that `SurveyMapRepresentable` should animate to.
    /// Set via `setCameraRegion(_:)` instead of assigning `cameraPosition` directly.
    /// Cleared by the representable after applying to avoid re-centering on every SwiftUI update.
    var targetRegion: MKCoordinateRegion?

    /// Set camera position to a region, updating both the SwiftUI `cameraPosition`
    /// and the UIKit `targetRegion` so `SurveyMapRepresentable` can apply it.
    func setCameraRegion(_ region: MKCoordinateRegion) {
        cameraPosition = .region(region)
        targetRegion = region
    }

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

    // MARK: - Survey Completion

    /// Stats computed when a survey session stops, shown in the completion summary sheet.
    struct SurveyCompletionStats {
        let duration: TimeInterval
        let totalPackets: Int
        let totalCells: Int
        // Coverage breakdown
        let connectedCells: Int
        let meshReachCells: Int
        let heardOnlyCells: Int
        let deadZoneCells: Int
        // Repeater stats
        let totalUniqueRepeaters: Int
        let bestCoverageRepeater: (hexID: String, packetCount: Int)?
        let bestConnectedRepeater: (hexID: String, connectedCellCount: Int)?
        // Community map impact (nil if no community data loaded)
        let communityImpact: CommunityImpact?

        struct CommunityImpact {
            let newCells: Int
            let updatedCells: Int
            let oldestUpdatedAge: TimeInterval?
        }

        /// Reconstruct from a persisted DTO (for viewing historical session stats).
        init(from dto: SurveyCompletionStatsDTO) {
            self.duration = dto.duration
            self.totalPackets = dto.totalPackets
            self.totalCells = dto.totalCells
            self.connectedCells = dto.connectedCells
            self.meshReachCells = dto.meshReachCells
            self.heardOnlyCells = dto.heardOnlyCells
            self.deadZoneCells = dto.deadZoneCells
            self.totalUniqueRepeaters = dto.totalUniqueRepeaters
            self.bestCoverageRepeater = dto.bestCoverageRepeaterHexID.map {
                ($0, dto.bestCoverageRepeaterPacketCount ?? 0)
            }
            self.bestConnectedRepeater = dto.bestConnectedRepeaterHexID.map {
                ($0, dto.bestConnectedRepeaterCellCount ?? 0)
            }
            if let newCells = dto.communityNewCells {
                self.communityImpact = CommunityImpact(
                    newCells: newCells,
                    updatedCells: dto.communityUpdatedCells ?? 0,
                    oldestUpdatedAge: dto.communityOldestUpdatedAge
                )
            } else {
                self.communityImpact = nil
            }
        }

        /// Memberwise init for direct construction.
        init(
            duration: TimeInterval, totalPackets: Int, totalCells: Int,
            connectedCells: Int, meshReachCells: Int, heardOnlyCells: Int, deadZoneCells: Int,
            totalUniqueRepeaters: Int,
            bestCoverageRepeater: (hexID: String, packetCount: Int)?,
            bestConnectedRepeater: (hexID: String, connectedCellCount: Int)?,
            communityImpact: CommunityImpact?
        ) {
            self.duration = duration
            self.totalPackets = totalPackets
            self.totalCells = totalCells
            self.connectedCells = connectedCells
            self.meshReachCells = meshReachCells
            self.heardOnlyCells = heardOnlyCells
            self.deadZoneCells = deadZoneCells
            self.totalUniqueRepeaters = totalUniqueRepeaters
            self.bestCoverageRepeater = bestCoverageRepeater
            self.bestConnectedRepeater = bestConnectedRepeater
            self.communityImpact = communityImpact
        }
    }

    var surveyCompletionStats: SurveyCompletionStats?

    /// Personal records broken by the most recent survey.
    var personalRecords: PersonalRecords?

    /// Which stats are new personal records for the current completion.
    struct PersonalRecords: Equatable {
        var longestDuration: Bool = false
        var mostPackets: Bool = false
        var mostCells: Bool = false
        var mostConnectedCells: Bool = false
        var mostUniqueRepeaters: Bool = false

        var hasAny: Bool {
            longestDuration || mostPackets || mostCells || mostConnectedCells || mostUniqueRepeaters
        }
    }

    /// Convert the ViewModel's SurveyCompletionStats to a Codable DTO for persistence.
    func statsDTO(from stats: SurveyCompletionStats) -> SurveyCompletionStatsDTO {
        SurveyCompletionStatsDTO(
            duration: stats.duration,
            totalPackets: stats.totalPackets,
            totalCells: stats.totalCells,
            connectedCells: stats.connectedCells,
            meshReachCells: stats.meshReachCells,
            heardOnlyCells: stats.heardOnlyCells,
            deadZoneCells: stats.deadZoneCells,
            totalUniqueRepeaters: stats.totalUniqueRepeaters,
            bestCoverageRepeaterHexID: stats.bestCoverageRepeater?.hexID,
            bestCoverageRepeaterPacketCount: stats.bestCoverageRepeater?.packetCount,
            bestConnectedRepeaterHexID: stats.bestConnectedRepeater?.hexID,
            bestConnectedRepeaterCellCount: stats.bestConnectedRepeater?.connectedCellCount,
            communityNewCells: stats.communityImpact?.newCells,
            communityUpdatedCells: stats.communityImpact?.updatedCells,
            communityOldestUpdatedAge: stats.communityImpact?.oldestUpdatedAge
        )
    }

    /// Compare current stats against all historical sessions to find personal records.
    func computePersonalRecords(current: SurveyCompletionStatsDTO) -> PersonalRecords {
        let historical = sessions.compactMap(\.completionStats)
        guard !historical.isEmpty else {
            // First session with stats — everything is a record
            return PersonalRecords(
                longestDuration: true, mostPackets: true, mostCells: true,
                mostConnectedCells: true, mostUniqueRepeaters: true
            )
        }
        var records = PersonalRecords()
        if current.duration > (historical.map(\.duration).max() ?? 0) { records.longestDuration = true }
        if current.totalPackets > (historical.map(\.totalPackets).max() ?? 0) { records.mostPackets = true }
        if current.totalCells > (historical.map(\.totalCells).max() ?? 0) { records.mostCells = true }
        if current.connectedCells > (historical.map(\.connectedCells).max() ?? 0) { records.mostConnectedCells = true }
        if current.totalUniqueRepeaters > (historical.map(\.totalUniqueRepeaters).max() ?? 0) { records.mostUniqueRepeaters = true }
        return records
    }

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

    // MARK: - Mesh Connectivity Score

    /// Per-repeater mesh connectivity metrics computed from trace (Deep Scan) data.
    /// Measures how well a repeater connects to the broader mesh from a given cell.
    struct RepeaterMeshScore: Identifiable {
        let hexID: String
        /// Number of unique downstream nodes reachable through this repeater via trace paths.
        let reachableNodes: Int
        /// Maximum trace depth (hops) achieved through this repeater.
        let maxDepth: Int
        /// Average SNR across all trace path hops through this repeater.
        let avgPathSNR: Double?
        /// Composite score: reachableNodes * (1 + normalized SNR bonus).
        /// Higher = better mesh gateway.
        let score: Double

        var id: String { hexID }
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
        /// Hex ID of the repeater with the best gateway SNR.
        let bestGatewayHexID: String?
        /// Maximum mesh depth reached by active probes in this cell.
        /// Value is (hopCount + 1): 1 = direct reach, 2 = one relay hop, etc.
        /// 0 means no trace responses were received.
        let maxMeshDepth: Int
        /// Number of packets from active probes (bidirectional confirmation) in this cell.
        let activePacketCount: Int
        /// Number of active probe messages sent from this cell. Nil if probing was not active.
        let probesSent: Int?
        /// Average TX SNR (how well repeaters heard us) across points with txSnr data.
        let averageTxSNR: Double?
        /// Best TX SNR from any direct 2-way repeater in this cell.
        /// More meaningful than the average when multiple repeaters have different TX quality.
        let bestTxSNR: Double?
        /// Minimum TX SNR observed in this cell.
        let minTxSNR: Double?
        /// Maximum TX SNR observed in this cell.
        let maxTxSNR: Double?
        /// Per-repeater mesh connectivity scores from trace (Deep Scan) data.
        /// Sorted by score descending — first entry is the best mesh gateway.
        /// Empty when no trace data exists (non-deep-scan sessions).
        let meshScores: [RepeaterMeshScore]

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

    /// Programmatically select and center on a specific grid cell by coordinate key.
    /// Used when navigating from chat messages back to the survey map.
    func focusOnCell(coordKey: String, latitude: Double, longitude: Double) {
        trackingUserLocation = false
        if let cell = gridCells.first(where: { $0.coordKey == coordKey }) {
            selectedCell = cell
            setCameraRegion(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: cell.centerLatitude, longitude: cell.centerLongitude),
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
            ))
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
                allRepeaterLocations = []
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

    /// All known repeater locations (fetched without bounding box) for polylines to off-screen repeaters.
    private(set) var allRepeaterLocations: [SurveyUploadService.RepeaterLocation] = []

    /// Look up a repeater display name for a hex ID using prefix-aware matching.
    func repeaterDisplayName(for hexID: String) -> String {
        let allLocs = allRepeaterLocations.isEmpty ? communityRepeaterLocations : allRepeaterLocations
        let upper = hexID.uppercased()
        if let loc = allLocs.first(where: { loc in
            let lh = loc.hexID.uppercased()
            return lh == upper || lh.hasPrefix(upper) || upper.hasPrefix(lh)
        }), !loc.name.isEmpty {
            return "\(loc.name) (\(hexID))"
        }
        return hexID
    }

    /// Coverage filter for the community overlay (All/Active/Passive).
    var communityCoverageFilter: CommunityMapView.CoverageFilter = .all {
        didSet { refreshCommunityCells() }
    }

    /// Optional repeater filter for the community overlay layer.
    var communityRepeaterFilter: String? {
        didSet { refreshCommunityCells() }
    }

    /// Time filter for the community overlay (how recent the data must be).
    var communityTimeFilter: MapTimeFilter = .allTime {
        didSet { refreshCommunityCells() }
    }

    /// Repeaters available for filtering: those referenced by visible cells (not filtered by viewport location).
    /// Returns (hexID, displayName) tuples sorted by name, matching the web map behavior.
    var communityAvailableRepeaters: [(hexID: String, displayName: String)] {
        let consolidated = CommunityMapView.consolidateHexIDs(communityCells.flatMap(\.repeaterHexIDs))

        // Build name lookup from all known repeater locations (not just viewport)
        let allLocs = allRepeaterLocations.isEmpty ? communityRepeaterLocations : allRepeaterLocations
        let namesByHex = Dictionary(allLocs.map { ($0.hexID.uppercased(), $0.name) },
                                     uniquingKeysWith: { _, new in new })

        return consolidated.sorted().map { hexID in
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

            // Refresh selectedCommunityCell from new data so it has current repeaterMetrics
            if let selected = selectedCommunityCell,
               let updated = response.cells.first(where: { $0.id == selected.id }) {
                selectedCommunityCell = updated
            }

            // Fetch all repeater locations once (for polylines to off-screen repeaters + name lookup)
            if allRepeaterLocations.isEmpty {
                Task {
                    do {
                        let all = try await service.fetchRepeaterLocations(
                            minLat: -90, maxLat: 90, minLon: -180, maxLon: 180
                        )
                        guard !Task.isCancelled else { return }
                        allRepeaterLocations = all
                    } catch {
                        logger.warning("Failed to fetch all repeater locations: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            logger.warning("Community overlay fetch failed: \(error.localizedDescription)")
        }
    }

    /// Re-fetch community cells using the last known region when filters change.
    private func refreshCommunityCells() {
        guard showCommunityOverlay, let region = lastCommunityRegion else { return }
        communityLoadTask?.cancel()
        communityLoadTask = Task { [weak self] in
            await self?.fetchCommunityCells(for: region)
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

    /// Compute stats from the current grid cells for the survey completion summary.
    /// Should be called right after `stopSurvey()` while grid data is still loaded.
    func computeCompletionStats(session: SurveySessionDTO) -> SurveyCompletionStats {
        let duration: TimeInterval
        if let endedAt = session.endedAt {
            duration = endedAt.timeIntervalSince(session.startedAt)
        } else {
            duration = Date().timeIntervalSince(session.startedAt)
        }

        let totalPackets = gridCells.reduce(0) { $0 + $1.packetCount }

        // Coverage breakdown — classify each cell by its best connectivity tier
        let connectedCells = gridCells.count(where: { !$0.connectedRelayNodes.isEmpty })
        let meshReachCells = gridCells.count(where: {
            $0.connectedRelayNodes.isEmpty && !$0.meshReachRelayNodes.isEmpty
        })
        let heardOnlyCells = gridCells.count(where: {
            $0.connectedRelayNodes.isEmpty && $0.meshReachRelayNodes.isEmpty && !$0.heardOnlyRelayNodes.isEmpty
        })
        let deadZoneCells = gridCells.count(where: \.isDeadZone)

        // Repeater stats — aggregate across all cells
        var allUniqueRepeaters = Set<String>()
        var repeaterPacketCounts: [String: Int] = [:]
        var repeaterConnectedCellCounts: [String: Int] = [:]

        for cell in gridCells {
            for relay in cell.uniqueRelayNodes {
                allUniqueRepeaters.insert(relay)
            }
            // Count packets per repeater by looking at each cell's relay nodes
            // (this is an approximation — we attribute the cell's packet count to each relay)
            for relay in cell.connectedRelayNodes {
                repeaterPacketCounts[relay, default: 0] += cell.activePacketCount
                repeaterConnectedCellCounts[relay, default: 0] += 1
            }
            for relay in cell.heardOnlyRelayNodes {
                repeaterPacketCounts[relay, default: 0] += cell.packetCount - cell.activePacketCount
            }
        }

        let bestCoverage = repeaterPacketCounts.max(by: { $0.value < $1.value })
        let bestConnected = repeaterConnectedCellCounts.max(by: { $0.value < $1.value })

        // Community map impact
        let communityImpact: SurveyCompletionStats.CommunityImpact?
        if !communityCells.isEmpty {
            let communityKeys = Set(communityCells.map { "\($0.hexQ)_\($0.hexR)" })
            let userKeys = Set(gridCells.map(\.coordKey))
            let newCells = userKeys.subtracting(communityKeys).count
            let updatedCells = userKeys.intersection(communityKeys).count

            // Find oldest updated cell's community data age
            var oldestAge: TimeInterval?
            for cell in communityCells {
                let key = "\(cell.hexQ)_\(cell.hexR)"
                if userKeys.contains(key),
                   let dateStr = cell.lastUpdated,
                   let date = Self.isoFormatter.date(from: dateStr) {
                    let age = Date().timeIntervalSince(date)
                    if oldestAge == nil || age > oldestAge! {
                        oldestAge = age
                    }
                }
            }

            communityImpact = .init(
                newCells: newCells,
                updatedCells: updatedCells,
                oldestUpdatedAge: oldestAge
            )
        } else {
            communityImpact = nil
        }

        return SurveyCompletionStats(
            duration: duration,
            totalPackets: totalPackets,
            totalCells: gridCells.count,
            connectedCells: connectedCells,
            meshReachCells: meshReachCells,
            heardOnlyCells: heardOnlyCells,
            deadZoneCells: deadZoneCells,
            totalUniqueRepeaters: allUniqueRepeaters.count,
            bestCoverageRepeater: bestCoverage.map { ($0.key, $0.value) },
            bestConnectedRepeater: bestConnected.map { ($0.key, $0.value) },
            communityImpact: communityImpact
        )
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
            locationService.startContinuousUpdates { [weak self] _ in
                // Location updates flow through LocationService.currentLocation
                // which the SurveyService's locationProvider reads.
                // When "My Cell" tracking is on, also re-center the map on each GPS update.
                Task { @MainActor in
                    guard let self, self.trackingUserLocation else { return }
                    self.updateTrackedCell()
                }
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

    /// Temporarily pauses an active survey — stops probing and ignores incoming packets.
    /// The session remains open so it can be resumed without data loss.
    func pauseSurvey(surveyService: SurveyService) async {
        guard isActive, !isPaused else { return }
        isPaused = true
        stopProbeLoop()
        await surveyService.setProbingActive(false)
        logger.info("Survey paused")
    }

    /// Resumes a paused survey — re-enables probing and packet recording.
    func resumeSurvey(
        surveyService: SurveyService,
        locationService: LocationService
    ) async {
        guard isActive, isPaused else { return }
        isPaused = false
        if probeEnabled {
            await surveyService.setProbingActive(true)
            if binaryProtocolService != nil {
                startProbeLoop(locationService: locationService)
            }
        }
        logger.info("Survey resumed")
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
            isPaused = false

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
    /// Also handles BLE reconnection: if the ViewModel is already active but the new
    /// SurveyService doesn't know about the session, re-associate it.
    func resumeIfActive(
        surveyService: SurveyService,
        locationService: LocationService,
        binaryProtocolService: BinaryProtocolService? = nil,
        messageService: MessageService? = nil,
        deviceID: UUID,
        pathHashMode: UInt8 = 0,
        dataStore: PersistenceStore
    ) async {
        // If ViewModel is already active but the new service doesn't have the session
        // (BLE reconnection scenario), re-associate the session with the new service.
        if isActive, case .active(let existingSessionID) = state {
            if await surveyService.currentSessionID == nil {
                let resumed = await surveyService.resumeSession(id: existingSessionID)
                if resumed {
                    // Re-wire references to the new service instances
                    self.binaryProtocolService = binaryProtocolService
                    self.messageServiceRef = messageService
                    self.locationServiceRef = locationService
                    self.surveyServiceRef = surveyService
                    self.pathHashMode = pathHashMode

                    // Re-wire live point handler
                    await surveyService.setPointRecordedHandler { [weak self] point in
                        await MainActor.run {
                            self?.handleNewPoint(point)
                        }
                    }

                    // Resume probe loop if enabled
                    if probeEnabled {
                        await surveyService.setProbingActive(true)
                        if binaryProtocolService != nil {
                            startProbeLoop(locationService: locationService)
                        }
                    }

                    logger.info("Re-wired active survey to new service after BLE reconnection: \(existingSessionID)")
                } else {
                    // Session no longer exists or was ended — clean up ViewModel state
                    stopProbeLoop()
                    locationService.stopContinuousUpdates()
                    state = .idle
                    activeSession = nil
                    isPaused = false
                    self.binaryProtocolService = nil
                    self.messageServiceRef = nil
                    self.channelServiceRef = nil
                    self.locationServiceRef = nil
                    self.surveyServiceRef = nil
                    self.deviceID = nil
                    liveStatus = SurveyLiveStatus()
                    logger.warning("Survey session \(existingSessionID) no longer open after reconnection — stopped survey")
                }
            }
            return
        }

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
        guard !isPaused else { return }
        logger.debug("handleNewPoint called, total: \(self.livePointCount + 1)")
        livePointCount += 1
        allPoints.append(point)

        // Set reference latitude on first point BEFORE any grid operations,
        // so the hex coordinate system is stable from the very first cell.
        // Uses fixed 10° bands so all clients produce identical grids.
        if livePointCount == 1 {
            gridReferenceLatitude = HexGrid.fixedReferenceLatitude(for: point.latitude)
            setCameraRegion(MKCoordinateRegion(
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

        // Follow user location, offset center southward so the user's actual
        // position appears in the visible area above the detail card.
        // The detail card covers ~40% of the bottom, so the visible center is at ~30%
        // from the top. Shifting the map center south by 0.35× the span places the
        // user location at roughly 1/3 from the top of the screen.
        let span = MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        let offsetCenter = CLLocationCoordinate2D(
            latitude: location.coordinate.latitude - span.latitudeDelta * 0.35,
            longitude: location.coordinate.longitude
        )
        setCameraRegion(MKCoordinateRegion(center: offsetCenter, span: span))
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
            // Fast path: use pre-computed completion stats when available
            if let cs = session.completionStats {
                stats[session.id] = SessionStats(pointCount: cs.totalPackets, cellCount: cs.totalCells)
                continue
            }
            // Slow path: legacy sessions without completion stats — compute from coordinates
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
            Self.makeGridCell(coord: coord, points: points, refLat: gridReferenceLatitude, probesSent: probesSentPerCell[coord.key], allContacts: allContacts)
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
                    bestGatewayHexID: nil,
                    maxMeshDepth: 0,
                    activePacketCount: 0,
                    probesSent: probesSentPerCell[key],
                    averageTxSNR: nil,
                    bestTxSNR: nil,
                    minTxSNR: nil,
                    maxTxSNR: nil,
                    meshScores: []
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
                    bestGatewayHexID: nil,
                    maxMeshDepth: 0,
                    activePacketCount: 0,
                    probesSent: probes,
                    averageTxSNR: nil,
                    bestTxSNR: nil,
                    minTxSNR: nil,
                    maxTxSNR: nil,
                    meshScores: []
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
            probesSent: probesSentPerCell[hex.key],
            allContacts: allContacts
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
    /// Returns `(bestGatewaySNR, bestGatewayHexID, maxMeshDepth)`.
    /// `bestGatewaySNR` is nil when no direct probe data is available (passive-only cells use averageSNR).
    private static func computeCellQuality(
        points: [SignalSurveyPointDTO]
    ) -> (bestGatewaySNR: Double?, bestGatewayHexID: String?, maxMeshDepth: Int) {
        // Best SNR from direct 2-way active probe responses.
        let directProbePoints = points.filter { isDirectTwoWay($0) }
        let bestPoint = directProbePoints.max(by: { ($0.snr ?? -.infinity) < ($1.snr ?? -.infinity) })
        let bestSNR = bestPoint?.snr
        let bestHexID = bestPoint?.pathNodeHexIDs.last

        // Maximum mesh depth from trace responses.
        // hopCount is the number of relay hops in the return path:
        //   0 = direct response (1 hop away), 1 = one relay (2 hops away), etc.
        // We report depth as hopCount + 1 so the user sees "1" for direct reach.
        let tracePoints = points.filter { $0.payloadType == .trace }
        let maxDepth = tracePoints.isEmpty ? 0 : (tracePoints.map(\.hopCount).max() ?? 0) + 1

        return (bestSNR, bestHexID, maxDepth)
    }

    /// Computes per-repeater mesh connectivity scores from trace (Deep Scan) data.
    ///
    /// For each connected repeater, this measures:
    /// - **Reachable nodes**: unique downstream nodes seen in trace paths that include this repeater
    /// - **Max depth**: deepest trace path through this repeater
    /// - **Avg path SNR**: average SNR across all hops in trace paths through this repeater
    /// - **Score**: `reachableNodes × (1 + normalizedSNR)` where SNR is normalized to 0–1
    ///   using the range [-20, +20] dB. This balances reach breadth with signal quality.
    private static func computeMeshScores(
        points: [SignalSurveyPointDTO],
        connectedIDs: Set<String>,
        canonicalize: (String) -> String
    ) -> [RepeaterMeshScore] {
        let tracePoints = points.filter { $0.payloadType == .trace && $0.pathNodeHexIDs.count >= 2 }
        guard !tracePoints.isEmpty else { return [] }

        // For each connected repeater, gather metrics from trace paths that include it.
        // A connected repeater is our direct gateway — trace paths going through it
        // show which downstream nodes are reachable via that gateway.
        struct Accumulator {
            var downstreamNodes: Set<String> = []
            var maxDepth: Int = 0
            var snrValues: [Double] = []
        }

        var accumulators: [String: Accumulator] = [:]

        for point in tracePoints {
            let canonicalPath = point.pathNodeHexIDs.map { canonicalize($0) }
            let depth = point.hopCount + 1

            // Find which connected repeaters appear in this trace path.
            // The first node in the path is typically the direct gateway.
            for (idx, nodeID) in canonicalPath.enumerated() {
                let isConnected = connectedIDs.contains(nodeID) ||
                    connectedIDs.contains(where: { cid in
                        let u = cid.uppercased(), n = nodeID.uppercased()
                        if u.count < n.count { return n.hasPrefix(u) && u.count == 2 }
                        if n.count < u.count { return u.hasPrefix(n) && n.count == 2 }
                        return false
                    })
                guard isConnected else { continue }

                var acc = accumulators[nodeID] ?? Accumulator()
                // All other nodes in the path are downstream of this gateway
                for (otherIdx, otherID) in canonicalPath.enumerated() where otherIdx != idx {
                    acc.downstreamNodes.insert(otherID)
                }
                acc.maxDepth = max(acc.maxDepth, depth)
                if let snr = point.snr {
                    acc.snrValues.append(snr)
                }
                accumulators[nodeID] = acc
            }
        }

        // Normalize SNR to [0, 1] using range [-20, +20] dB
        func normalizedSNR(_ snr: Double) -> Double {
            min(max((snr + 20) / 40.0, 0), 1)
        }

        return accumulators.map { (hexID, acc) in
            let avgSNR = acc.snrValues.isEmpty ? nil : acc.snrValues.reduce(0, +) / Double(acc.snrValues.count)
            let snrBonus = avgSNR.map { normalizedSNR($0) } ?? 0.5
            let score = Double(acc.downstreamNodes.count) * (1.0 + snrBonus)
            return RepeaterMeshScore(
                hexID: hexID,
                reachableNodes: acc.downstreamNodes.count,
                maxDepth: acc.maxDepth,
                avgPathSNR: avgSNR,
                score: score
            )
        }.sorted { $0.score > $1.score }
    }

    /// Creates a GridCell from a bucket of points at a hex coordinate.
    private static func makeGridCell(
        coord: HexGrid.AxialCoord,
        points: [SignalSurveyPointDTO],
        refLat: Double,
        probesSent: Int? = nil,
        allContacts: [ContactDTO] = []
    ) -> GridCell {
        let center = HexGrid.centerLatLon(from: coord, referenceLatitude: refLat)
        let snrValues = points.compactMap(\.snr)
        let rssiValues = points.compactMap(\.rssi)
        let txSnrValues = points.compactMap(\.txSnr)
        let avgSNR = snrValues.isEmpty ? nil : snrValues.reduce(0, +) / Double(snrValues.count)
        let avgRSSI = rssiValues.isEmpty ? nil : Double(rssiValues.reduce(0, +)) / Double(rssiValues.count)
        let avgTxSNR = txSnrValues.isEmpty ? nil : txSnrValues.reduce(0, +) / Double(txSnrValues.count)
        // Best TX SNR from direct 2-way points — more meaningful than the average
        // when multiple repeaters have varying TX quality.
        let directTxSnrValues = points.filter { isDirectTwoWay($0) }.compactMap(\.txSnr)
        let bestTxSNR = directTxSnrValues.max()
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
        // same repeater (e.g. "0C" from 1-byte pathNodes vs "0C13" from discover response).
        //
        // Strategy: resolve each short hex ID against the full contacts list to determine
        // the canonical longer form. This prevents merging "0C" into "0CB3" when the actual
        // node is "0C13" — the contact resolver uses recency and proximity to pick the
        // correct match. If no contact resolves, fall back to unambiguous prefix matching
        // within the cell data only.
        let allIDs = Array(latestByRelay.keys).map { $0.uppercased() }

        // Only consider repeaters for hex ID resolution — rooms and chat contacts
        // should never appear as relay nodes in the signal survey.
        let repeaterContacts = allContacts.filter { $0.type == .repeater }

        // Build a mapping from short IDs to their contact-resolved canonical form.
        // For each short ID, resolve against known repeater contacts; if the resolved
        // contact's public key prefix (at a longer length) exists among the cell IDs,
        // use that. Otherwise, extend the short ID to a 2-byte prefix from the contact's
        // public key.
        var canonicalMap: [String: String] = [:] // short ID → canonical longer ID
        for id in allIDs {
            // Only try to extend IDs that are short (1-byte = 2 chars)
            guard id.count == 2 else { continue }
            guard let hashBytes = Data(hexString: id) else { continue }
            guard let contact = RepeaterResolver.bestMatch(for: hashBytes, in: repeaterContacts, userLocation: nil) else { continue }
            // Use 2-byte prefix (4 hex chars) from the matched contact's public key
            let prefix2 = contact.publicKey.prefix(2).map { String(format: "%02X", $0) }.joined()
            // Only create mapping if the 2-byte prefix is actually different (longer)
            if prefix2.uppercased() != id {
                canonicalMap[id] = prefix2.uppercased()
            }
        }

        // Identify hex IDs that resolve to non-repeater contacts (rooms, chats).
        // These should be excluded from the relay node list — rooms can appear in
        // pathNodeHexIDs from discover responses but aren't meaningful relay nodes.
        // We check each unique ID (both short and long) against the full contacts list.
        // An ID is excluded only if it matches a non-repeater AND does not also match
        // a repeater (to handle shared prefixes safely).
        var nonRepeaterIDs = Set<String>()
        for id in allIDs {
            guard let hashBytes = Data(hexString: id) else { continue }
            // Check if this ID matches any repeater
            let matchesRepeater = RepeaterResolver.bestMatch(for: hashBytes, in: repeaterContacts, userLocation: nil) != nil
            if !matchesRepeater {
                // Check if it matches a non-repeater contact
                if let contact = RepeaterResolver.bestMatch(for: hashBytes, in: allContacts, userLocation: nil),
                   contact.type != .repeater {
                    nonRepeaterIDs.insert(id)
                }
            }
        }

        // Now consolidate: group raw IDs by their canonical form, skipping non-repeaters
        var canonicalLatest: [String: Date] = [:]
        for (rawID, ts) in latestByRelay {
            let rawUp = rawID.uppercased()
            // Skip IDs known to be non-repeater contacts
            if nonRepeaterIDs.contains(rawUp) { continue }
            // Determine the canonical ID for this raw ID
            let canonical: String
            if let resolved = canonicalMap[rawUp] {
                // Short ID was resolved via contacts → use the 2-byte form
                canonical = resolved
            } else if rawUp.count == 2 {
                // Short ID couldn't be resolved — check if any longer ID in the
                // cell data starts with it. Only merge if exactly one match.
                let longerMatches = allIDs.filter { $0.hasPrefix(rawUp) && $0 != rawUp && !nonRepeaterIDs.contains($0) }
                if longerMatches.count == 1 {
                    canonical = longerMatches[0]
                } else {
                    // Ambiguous or no match — keep the short form
                    canonical = rawUp
                }
            } else {
                canonical = rawUp
            }
            // Also check if the canonical form itself is a non-repeater
            if nonRepeaterIDs.contains(canonical) { continue }
            canonicalLatest[canonical] = max(canonicalLatest[canonical] ?? .distantPast, ts)
        }
        let relayNodes = canonicalLatest.sorted { $0.value > $1.value }.map(\.key)

        // Split relay nodes into three tiers:
        //   1. Connected (2-way): direct active probe responses — the repeater heard us
        //      directly and we heard it back. For groupText heard repeats this is hopCount == 1
        //      (the repeater is the single hop). For control/trace this is hopCount == 0.
        //   2. Mesh Reach: multi—hop active responses (deep scan only) — proves mesh
        //      reachability but the repeater may not hear us directly.
        //   3. Heard Only: passive packets — one-way RX, no proof of any return path.
        //
        // For 2-way (connected), only consider the LAST path node — the repeater that
        // directly relayed back to us. Using all path nodes would falsely mark upstream
        // hops as directly connected.
        //
        // Canonicalize the raw hex IDs from points using the same contact-based resolution
        // so that a 1-byte "0C" from a direct probe response correctly maps to "0C13"
        // instead of ambiguously matching "0CB3".
        func canonicalize(_ hexID: String) -> String {
            let up = hexID.uppercased()
            return canonicalMap[up] ?? up
        }

        let directIDs = Set(points
            .filter { Self.isDirectTwoWay($0) }
            .compactMap { $0.pathNodeHexIDs.last.map { canonicalize($0) } })
        // For mesh reach, all path nodes are relevant — any repeater in a multi-hop
        // active response is mesh-reachable.
        let meshReachIDs = Set(points
            .filter { $0.isActiveProbe && !Self.isDirectTwoWay($0) }
            .flatMap { $0.pathNodeHexIDs.map { canonicalize($0) } })

        /// Check if a relay node's hex ID matches any ID in a set.
        /// Both relay and set IDs should already be canonicalized, so exact matching
        /// is the primary check. Prefix matching is still used as a fallback for IDs
        /// that couldn't be resolved via contacts.
        func hexIDMatches(_ relay: String, in idSet: Set<String>) -> Bool {
            let r = relay.uppercased()
            if idSet.contains(r) { return true }
            // Fallback: short↔long prefix matching for unresolved IDs
            return idSet.contains(where: { id in
                let u = id.uppercased()
                if u.count < r.count { return r.hasPrefix(u) && u.count == 2 }
                if r.count < u.count { return u.hasPrefix(r) && r.count == 2 }
                return false
            })
        }

        let connected = relayNodes.filter { hexIDMatches($0, in: directIDs) }
        // Mesh reach: appeared in multi-hop responses but NOT in any 0-hop response
        let meshReach = relayNodes.filter { !hexIDMatches($0, in: directIDs) && hexIDMatches($0, in: meshReachIDs) }
        let heardOnly = relayNodes.filter { !hexIDMatches($0, in: directIDs) && !hexIDMatches($0, in: meshReachIDs) }

        // Best-gateway quality: cell color reflects strongest discovered repeater
        let (bestGatewaySNR, bestGatewayHexID, maxMeshDepth) = computeCellQuality(points: points)
        let displaySNR = bestGatewaySNR ?? avgSNR
        let activeCount = points.count(where: \.isActiveProbe)

        // Per-repeater mesh connectivity scores from trace data.
        // For each connected repeater, measure how well it connects to the broader mesh:
        // - How many unique downstream nodes are reachable through trace paths including it
        // - Maximum trace depth through it
        // - Average SNR across trace hops through it
        let meshScores = computeMeshScores(points: points, connectedIDs: directIDs, canonicalize: canonicalize)

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
            bestGatewayHexID: bestGatewayHexID,
            maxMeshDepth: maxMeshDepth,
            activePacketCount: activeCount,
            probesSent: probesSent,
            averageTxSNR: avgTxSNR,
            bestTxSNR: bestTxSNR,
            minTxSNR: txSnrValues.min(),
            maxTxSNR: txSnrValues.max(),
            meshScores: meshScores
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
        setCameraRegion(MKCoordinateRegion(center: center, span: span))
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
        setCameraRegion(MKCoordinateRegion(center: center, span: span))
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
    /// **Active mode**: Sends a channel message. A 0-hop heard repeat of this message is
    /// the ground truth for bidirectional connectivity — it proves the repeater heard us
    /// directly and we heard it back. No TX signal data is collected in this mode.
    ///
    /// **Deep Scan mode** (`deepScanEnabled`): Also sends a discover request and a flood
    /// trace. Discover responses provide TX SNR (how well repeaters hear us). Traces map
    /// multi-hop paths and mesh depth. Uses more airtime; best at slower speeds.
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

        // Deep scan: discover request + flood trace for TX signal quality and mesh depth.
        // Discover responses include snrIn (TX SNR — how well repeaters hear us).
        // Traces map multi-hop paths and mesh depth beyond direct reach.
        // Both use extra airtime, so they're gated behind the Deep Scan toggle.
        if deepScanEnabled {
            // Brief delay to separate transmissions
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }

            do {
                let tag = try await bps.sendNodeDiscoverRequest(filter: 0x04, prefixOnly: true)
                logger.debug("Probe #\(self.probeCount) discover sent (tag: \(tag))")
            } catch {
                logger.warning("Probe #\(self.probeCount) discover failed: \(error.localizedDescription)")
            }

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
                    bestGatewayHexID: nil,
                    maxMeshDepth: 0,
                    activePacketCount: 0,
                    probesSent: probes,
                    averageTxSNR: nil,
                    bestTxSNR: nil,
                    minTxSNR: nil,
                    maxTxSNR: nil,
                    meshScores: []
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
    var filteredCellStats: (avgSNR: Double?, avgRSSI: Double?, avgTxSNR: Double?, minSNR: Double?, maxSNR: Double?,
                            minTxSNR: Double?, maxTxSNR: Double?,
                            packetCount: Int, quality: SNRQuality, latestTimestamp: Date?)? {
        guard selectedRelayFilter != nil else { return nil }
        let points = pointsForSelectedCell(relayFilter: selectedRelayFilter)
        guard !points.isEmpty else { return nil }
        let snrValues = points.compactMap(\.snr)
        let rssiValues = points.compactMap(\.rssi)
        let txSnrValues = points.compactMap(\.txSnr)
        let avgSNR = snrValues.isEmpty ? nil : snrValues.reduce(0, +) / Double(snrValues.count)
        let avgRSSI = rssiValues.isEmpty ? nil : Double(rssiValues.reduce(0, +)) / Double(rssiValues.count)
        let avgTxSNR = txSnrValues.isEmpty ? nil : txSnrValues.reduce(0, +) / Double(txSnrValues.count)
        let timestamps = points.map(\.timestamp).sorted()
        return (
            avgSNR: avgSNR,
            avgRSSI: avgRSSI,
            avgTxSNR: avgTxSNR,
            minSNR: snrValues.min(),
            maxSNR: snrValues.max(),
            minTxSNR: txSnrValues.min(),
            maxTxSNR: txSnrValues.max(),
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
