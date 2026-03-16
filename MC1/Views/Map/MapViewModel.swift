import SwiftUI
import MapKit
import MC1Services
import os

/// ViewModel for map contact locations
@Observable
@MainActor
final class MapViewModel {

    // MARK: - Properties

    /// All contacts with valid locations
    var contactsWithLocation: [ContactDTO] = []

    /// Loading state
    var isLoading = false

    /// Error message if any
    var errorMessage: String?

    /// Selected contact for detail display
    var selectedContact: ContactDTO?

    /// Camera region for map centering (MKCoordinateRegion for UIKit MKMapView)
    var cameraRegion: MKCoordinateRegion?

    /// Current map style selection
    var mapStyleSelection: MapStyleSelection = .standard

    /// Whether to show contact name labels
    var showLabels = true

    /// Whether the layers menu is showing
    var showingLayersMenu = false

    /// Time filter for "last heard" filtering
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
            }
        }
    }

    /// Community signal cells currently loaded for the viewport
    var communityCells: [SurveyUploadService.CommunityCell] = []

    /// Whether community data is loading
    var isLoadingCommunity = false

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

    /// Fetch community cells for a region (shared by on-demand and periodic refresh).
    private func fetchCommunityCells(for region: MKCoordinateRegion) async {
        isLoadingCommunity = true
        defer { isLoadingCommunity = false }

        let span = region.span
        let center = region.center
        let minLat = center.latitude - span.latitudeDelta / 2
        let maxLat = center.latitude + span.latitudeDelta / 2
        let minLon = center.longitude - span.longitudeDelta / 2
        let maxLon = center.longitude + span.longitudeDelta / 2

        do {
            let response = try await uploadService.fetchCommunityData(
                minLat: minLat, maxLat: maxLat,
                minLon: minLon, maxLon: maxLon
            )
            guard !Task.isCancelled else { return }
            communityCells = response.cells
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.warning("Failed to load community cells: \(error.localizedDescription)")
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
