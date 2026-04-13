import SwiftUI
import MapKit
import MC1Services
import os

/// ViewModel for map contact locations
@Observable
@MainActor
final class MapViewModel {

    private static let isoFormatter = ISO8601DateFormatter()

    // MARK: - Properties

    /// All contacts with valid locations
    var contactsWithLocation: [ContactDTO] = []

    /// Loading state
    var isLoading = false

    /// Error message if any
    var errorMessage: String?

    /// Selected contact for detail display
    var selectedContact: ContactDTO?

    /// Selected community cell for detail overlay
    var selectedCommunityCell: SurveyUploadService.CommunityCell?

    /// Camera region for map centering (MKCoordinateRegion for UIKit MKMapView)
    var cameraRegion: MKCoordinateRegion?

    /// Current map style selection
    var mapStyleSelection: MapStyleSelection = .standard

    /// Whether to show contact name labels
    var showLabels = true

    /// Whether the layers menu is showing
    var showingLayersMenu = false

    /// Time filter for "last heard" filtering (contacts)
    var selectedTimeFilter: MapTimeFilter = .allTime

    /// Contacts filtered by the selected time filter
    var filteredContacts: [ContactDTO] {
        guard let maxAge = selectedTimeFilter.maxAge else {
            return contactsWithLocation
        }
        let cutoff = Date().timeIntervalSince1970 - maxAge
        return contactsWithLocation.filter { contact in
            TimeInterval(contact.lastAdvertTimestamp) >= cutoff
        }
    }

    /// Whether the MeshWX weather overlay is active
    var showWeatherOverlay = false

    /// Currently selected weather warning (for detail sheet)
    var selectedWeatherWarning: MeshWXWarning?

    /// Reference to the shared weather cache (set via configure)
    @ObservationIgnored
    private var weatherCache: WeatherCache?

    /// Whether the community signal overlay is active
    var showCommunityOverlay = false {
        didSet {
            if showCommunityOverlay {
                startCommunityRefresh()
            } else {
                communityLoadTask?.cancel()
                communityLoadTask = nil
                communityRefreshTask?.cancel()
                communityRefreshTask = nil
                communityCells = []
                repeaterLocations = []
                allRepeaterLocations = []
                communityRepeaterFilter = nil
                communityCoverageFilter = .all
                communityTimeFilter = .allTime
                selectedCommunityCell = nil
            }
        }
    }

    /// Community signal cells currently loaded for the viewport
    var communityCells: [SurveyUploadService.CommunityCell] = [] {
        didSet { rebuildFilteredCommunityCells() }
    }

    /// Repeater locations loaded from the server for the current viewport (used for pins)
    var repeaterLocations: [SurveyUploadService.RepeaterLocation] = []

    /// All known repeater locations (fetched without bounding box) for polylines to off-screen repeaters
    var allRepeaterLocations: [SurveyUploadService.RepeaterLocation] = []

    /// Coverage filter for the community overlay (All/Active/Passive)
    var communityCoverageFilter: CommunityMapView.CoverageFilter = .all {
        didSet {
            rebuildFilteredCommunityCells()
            refreshCommunityCells()
        }
    }

    /// Time filter for the community overlay (how recent the data must be)
    var communityTimeFilter: MapTimeFilter = .allTime {
        didSet {
            rebuildFilteredCommunityCells()
            refreshCommunityCells()
        }
    }

    /// Optional repeater filter — when set, only cells containing this repeater are shown
    var communityRepeaterFilter: String? {
        didSet {
            rebuildFilteredCommunityCells()
            refreshCommunityCells()
            // Deselect if the selected cell doesn't match the new filter
            if let filter = communityRepeaterFilter, let selected = selectedCommunityCell {
                let rf = filter.uppercased()
                let matches = selected.repeaterHexIDs.contains { id in
                    let uid = id.uppercased()
                    return uid == rf || uid.hasPrefix(rf) || rf.hasPrefix(uid)
                }
                if !matches {
                    selectedCommunityCell = nil
                }
            }
        }
    }

    /// Community cells after applying all filters (cached to avoid recomputation on every SwiftUI body eval)
    private(set) var filteredCommunityCells: [SurveyUploadService.CommunityCell] = []

    /// Rebuild the filtered community cells from communityCells + all active filters.
    private func rebuildFilteredCommunityCells() {
        var result: [SurveyUploadService.CommunityCell]
        switch communityCoverageFilter {
        case .all: result = communityCells
        case .active: result = communityCells.filter { ($0.activePacketCount ?? 0) > 0 }
        case .passive: result = communityCells.filter { ($0.passivePacketCount ?? 0) > 0 }
        }
        if let filter = communityRepeaterFilter {
            let rf = filter.uppercased()
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
        filteredCommunityCells = result
    }

    /// Repeaters available for filtering: extracted from visible cells with name lookup.
    var communityAvailableRepeaters: [(hexID: String, displayName: String)] {
        let consolidated = CommunityMapView.consolidateHexIDs(communityCells.flatMap(\.repeaterHexIDs))

        // Build name lookup from all known repeater locations (not just viewport)
        let allLocs = allRepeaterLocations.isEmpty ? repeaterLocations : allRepeaterLocations
        let namesByHex = Dictionary(allLocs.map { ($0.hexID.uppercased(), $0.name) },
                                     uniquingKeysWith: { _, new in new })

        return consolidated.sorted().map { hexID in
            let upper = hexID.uppercased()
            let name = namesByHex[upper] ?? namesByHex.first(where: { key, _ in
                key.hasPrefix(upper) || upper.hasPrefix(key)
            })?.value
            let display = (name != nil && !name!.isEmpty) ? "\(name!) (\(hexID))" : hexID
            return (hexID: hexID, displayName: display)
        }
    }

    /// Look up a repeater display name for a hex ID using prefix-aware matching.
    func repeaterDisplayName(for hexID: String) -> String {
        let allLocs = allRepeaterLocations.isEmpty ? repeaterLocations : allRepeaterLocations
        let upper = hexID.uppercased()
        if let loc = allLocs.first(where: { loc in
            let lh = loc.hexID.uppercased()
            return lh == upper || lh.hasPrefix(upper) || upper.hasPrefix(lh)
        }), !loc.name.isEmpty {
            return "\(loc.name) (\(hexID))"
        }
        return hexID
    }

    /// Whether community data is loading
    var isLoadingCommunity = false

    // MARK: - Weather Data

    /// Current weather warnings from cache (only when overlay is active).
    var weatherWarnings: [MeshWXWarning] {
        guard showWeatherOverlay else { return [] }
        return weatherCache?.warnings ?? []
    }

    /// Look up a warning by ID (for tap-to-detail).
    func weatherWarning(for id: UUID) -> MeshWXWarning? {
        weatherCache?.warnings.first { $0.id == id }
    }

    /// Latest radar frames per region from cache (only when overlay is active).
    var weatherRadarFrames: [MeshWXRadarFrame] {
        guard showWeatherOverlay else { return [] }
        guard let cache = weatherCache else { return [] }
        return cache.radarFrames.values.compactMap(\.last)
    }

    // MARK: - Dependencies

    private var dataStore: PersistenceStore?
    private var deviceID: UUID?
    private let uploadService = SurveyUploadService()
    private var communityLoadTask: Task<Void, Never>?
    private var communityRefreshTask: Task<Void, Never>?
    private var lastCommunityRegion: MKCoordinateRegion?
    private static let logger = Logger(subsystem: "com.mc1", category: "MapViewModel")

    // MARK: - Initialization

    init() {}

    /// Configure with services from AppState
    func configure(appState: AppState) {
        self.dataStore = appState.offlineDataStore
        self.deviceID = appState.currentDeviceID
        self.weatherCache = appState.weatherCache
    }

    /// Configure with services (for testing)
    func configure(dataStore: PersistenceStore, deviceID: UUID?) {
        self.dataStore = dataStore
        self.deviceID = deviceID
    }

    // MARK: - Load Contacts

    /// Load contacts with valid locations from the database
    func loadContactsWithLocation() async {
        guard let dataStore, let deviceID else { return }

        isLoading = true
        errorMessage = nil

        do {
            let allContacts = try await dataStore.fetchContacts(deviceID: deviceID)
            contactsWithLocation = allContacts.filter(\.hasLocation)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Map Interaction

    /// Center map on a specific contact
    func centerOnContact(_ contact: ContactDTO) {
        guard contact.hasLocation else { return }

        let coordinate = CLLocationCoordinate2D(
            latitude: contact.latitude,
            longitude: contact.longitude
        )

        // 5000 meters corresponds to roughly 0.045 degrees latitude span
        let span = MKCoordinateSpan(latitudeDelta: 0.045, longitudeDelta: 0.045)
        cameraRegion = MKCoordinateRegion(center: coordinate, span: span)
        selectedContact = contact
    }

    /// Center map on a weather warning polygon's bounding box.
    func centerOnWarning(_ warning: MeshWXWarning) {
        guard !warning.vertices.isEmpty else { return }
        var minLat =  Double.greatestFiniteMagnitude
        var maxLat = -Double.greatestFiniteMagnitude
        var minLon =  Double.greatestFiniteMagnitude
        var maxLon = -Double.greatestFiniteMagnitude
        for v in warning.vertices {
            minLat = min(minLat, v.latitude);  maxLat = max(maxLat, v.latitude)
            minLon = min(minLon, v.longitude); maxLon = max(maxLon, v.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let latDelta = max(0.5, (maxLat - minLat) * 1.5)
        let lonDelta = max(0.5, (maxLon - minLon) * 1.5)
        cameraRegion = MKCoordinateRegion(center: center,
                                          span: MKCoordinateSpan(latitudeDelta: latDelta,
                                                                 longitudeDelta: lonDelta))
    }

    /// Center map to show all filtered contacts
    func centerOnAllContacts() {
        let contacts = filteredContacts
        guard !contacts.isEmpty else {
            cameraRegion = nil
            return
        }

        // Calculate bounding region
        var minLat = Double.greatestFiniteMagnitude
        var maxLat = -Double.greatestFiniteMagnitude
        var minLon = Double.greatestFiniteMagnitude
        var maxLon = -Double.greatestFiniteMagnitude

        for contact in contacts {
            let lat = contact.latitude
            let lon = contact.longitude
            minLat = min(minLat, lat)
            maxLat = max(maxLat, lat)
            minLon = min(minLon, lon)
            maxLon = max(maxLon, lon)
        }

        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        // Clamp spans to valid MKCoordinateSpan bounds (lat: 0-180, lon: 0-360)
        let latDelta = min(180, max(0.01, (maxLat - minLat) * 1.5))
        let lonDelta = min(360, max(0.01, (maxLon - minLon) * 1.5))

        let center = CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon)
        let span = MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)

        cameraRegion = MKCoordinateRegion(center: center, span: span)
    }

    /// Clear selection
    func clearSelection() {
        selectedContact = nil
    }

    // MARK: - Community Overlay

    /// Load community signal cells for the given map region, debounced.
    func loadCommunityCells(for region: MKCoordinateRegion) {
        guard showCommunityOverlay else { return }
        lastCommunityRegion = region

        communityLoadTask?.cancel()
        communityLoadTask = Task {
            // Debounce
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            await fetchCommunityCells(for: region)
        }
    }

    /// Fetch community cells and repeater locations for a region.
    private func fetchCommunityCells(for region: MKCoordinateRegion) async {
        isLoadingCommunity = true
        defer { isLoadingCommunity = false }

        let span = region.span
        let center = region.center
        let minLat = center.latitude - span.latitudeDelta / 2
        let maxLat = center.latitude + span.latitudeDelta / 2
        let minLon = center.longitude - span.longitudeDelta / 2
        let maxLon = center.longitude + span.longitudeDelta / 2

        // Map coverage filter to server parameter
        let coverageParam: String? = {
            switch communityCoverageFilter {
            case .active: return "active"
            case .passive: return "passive"
            case .all: return nil
            }
        }()
        let maxAgeParam: Int? = communityTimeFilter.maxAge.map { Int($0) }

        do {
            async let cellsResult = uploadService.fetchCommunityData(
                minLat: minLat, maxLat: maxLat,
                minLon: minLon, maxLon: maxLon,
                coverage: coverageParam,
                maxAge: maxAgeParam,
                repeater: communityRepeaterFilter
            )
            async let repeatersResult = uploadService.fetchRepeaterLocations(
                minLat: minLat, maxLat: maxLat,
                minLon: minLon, maxLon: maxLon
            )
            let (response, repeaters) = try await (cellsResult, repeatersResult)
            guard !Task.isCancelled else { return }
            communityCells = response.cells
            repeaterLocations = repeaters

            // Refresh selectedCommunityCell from new data so it has current repeaterMetrics
            if let selected = selectedCommunityCell,
               let updated = response.cells.first(where: { $0.id == selected.id }) {
                selectedCommunityCell = updated
            }

            // Fetch all repeater locations once (for polylines to off-screen repeaters + name lookup)
            if allRepeaterLocations.isEmpty {
                Task {
                    do {
                        let all = try await uploadService.fetchRepeaterLocations(
                            minLat: -90, maxLat: 90, minLon: -180, maxLon: 180
                        )
                        guard !Task.isCancelled else { return }
                        allRepeaterLocations = all
                    } catch {
                        Self.logger.warning("Failed to fetch all repeater locations: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.warning("Failed to load community data: \(error.localizedDescription)")
        }
    }

    /// Re-fetch community cells using the last known region when filters change.
    private func refreshCommunityCells() {
        guard showCommunityOverlay, let region = lastCommunityRegion else { return }
        communityLoadTask?.cancel()
        communityLoadTask = Task {
            await fetchCommunityCells(for: region)
        }
    }

    /// Periodically refresh community cells every 15s while the overlay is visible.
    private func startCommunityRefresh() {
        communityRefreshTask?.cancel()
        communityRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                guard let self, let region = self.lastCommunityRegion else { continue }
                await self.fetchCommunityCells(for: region)
            }
        }
    }
}

// MARK: - ContactDTO Location Extension

extension ContactDTO {
    /// The coordinate for MapKit
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: latitude,
            longitude: longitude
        )
    }
}
