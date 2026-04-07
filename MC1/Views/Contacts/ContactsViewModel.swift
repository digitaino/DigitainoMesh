import CoreLocation
import SwiftUI
import MC1Services

/// Segment for the nodes picker
enum NodeSegment: String, CaseIterable {
    case favorites
    case contacts
    case network

    var localizedTitle: String {
        switch self {
        case .favorites: L10n.Contacts.Contacts.Segment.favorites
        case .contacts: L10n.Contacts.Contacts.Segment.contacts
        case .network: L10n.Contacts.Contacts.Segment.network
        }
    }
}

/// Sort order for nodes list
enum NodeSortOrder: String, CaseIterable {
    case lastHeard
    case name
    case distance

    var localizedTitle: String {
        switch self {
        case .lastHeard: L10n.Contacts.Contacts.Sort.lastHeard
        case .name: L10n.Contacts.Contacts.Sort.name
        case .distance: L10n.Contacts.Contacts.Sort.distance
        }
    }
}

/// ViewModel for contact management
@Observable
@MainActor
final class ContactsViewModel {

    // MARK: - Properties

    /// All contacts
    var contacts: [ContactDTO] = []

    /// Loading state
    var isLoading = false

    /// Whether data has been loaded at least once (prevents empty state flash)
    var hasLoadedOnce = false

    /// Syncing state
    var isSyncing = false

    /// Sync progress (current, total)
    var syncProgress: (Int, Int)?

    /// Error message if any
    var errorMessage: String?

    /// User's current location for distance sorting (optional)
    var userLocation: CLLocation?

    /// Contact ID currently having its favorite status toggled (for loading UI)
    var togglingFavoriteID: UUID?

    // MARK: - Dependencies

    private var dataStore: DataStore?
    private var contactService: ContactService?
    private var advertisementService: AdvertisementService?

    // MARK: - Initialization

    init() {}

    /// Configure with services from AppState
    func configure(appState: AppState) {
        self.dataStore = appState.offlineDataStore
        self.contactService = appState.services?.contactService
        self.advertisementService = appState.services?.advertisementService
    }

    /// Configure with services (for testing)
    func configure(
        dataStore: DataStore,
        contactService: ContactService,
        advertisementService: AdvertisementService? = nil
    ) {
        self.dataStore = dataStore
        self.contactService = contactService
        self.advertisementService = advertisementService
    }

    // MARK: - Load Contacts

    /// Load contacts from local database
    func loadContacts(deviceID: UUID) async {
        guard let dataStore else { return }

        isLoading = true
        errorMessage = nil

        do {
            contacts = try await dataStore.fetchContacts(deviceID: deviceID)
        } catch {
            errorMessage = error.localizedDescription
        }

        hasLoadedOnce = true
        isLoading = false
    }

    // MARK: - Sync Contacts

    /// Sync contacts from device
    func syncContacts(deviceID: UUID) async {
        guard let contactService else { return }

        isSyncing = true
        syncProgress = nil
        errorMessage = nil

        if let advertisementService {
            await advertisementService.setSyncingContacts(true)
        }
        defer {
            if let advertisementService {
                Task { await advertisementService.setSyncingContacts(false) }
            }
        }

        // Set up progress handler
        await contactService.setSyncProgressHandler { [weak self] current, total in
            Task { @MainActor in
                self?.syncProgress = (current, total)
            }
        }

        do {
            _ = try await contactService.syncContacts(deviceID: deviceID)

            // Reload from database
            await loadContacts(deviceID: deviceID)

            // Clear sync progress
            syncProgress = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        isSyncing = false
    }

    // MARK: - Contact Actions

    /// Toggle favorite status on device and update local state
    func toggleFavorite(contact: ContactDTO) async {
        guard let contactService else { return }

        togglingFavoriteID = contact.id
        defer { togglingFavoriteID = nil }

        do {
            try await contactService.setContactFavorite(contact.id, isFavorite: !contact.isFavorite)

            // Reload to get updated state
            if contacts.contains(where: { $0.id == contact.id }) {
                await loadContacts(deviceID: contact.deviceID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Toggle blocked status
    func toggleBlocked(contact: ContactDTO) async {
        guard let contactService else { return }

        do {
            try await contactService.updateContactPreferences(
                contactID: contact.id,
                isBlocked: !contact.isBlocked
            )

            // Update local list
            await loadContacts(deviceID: contact.deviceID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Update nickname
    func updateNickname(contact: ContactDTO, nickname: String?) async {
        guard let contactService else { return }

        do {
            try await contactService.updateContactPreferences(
                contactID: contact.id,
                nickname: nickname?.isEmpty == true ? nil : nickname
            )

            // Update local list
            await loadContacts(deviceID: contact.deviceID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Delete contact
    func deleteContact(_ contact: ContactDTO) async {
        guard let contactService else {
            errorMessage = L10n.Contacts.Contacts.ViewModel.connectToDelete
            return
        }

        // Remove from UI immediately to avoid race condition with List animation
        let backup = contacts
        contacts.removeAll { $0.id == contact.id }

        do {
            try await contactService.removeContact(
                deviceID: contact.deviceID,
                publicKey: contact.publicKey
            )
        } catch {
            contacts = backup
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Filtering

    /// Returns contacts filtered by segment and sorted
    func filteredContacts(
        searchText: String,
        segment: NodeSegment,
        sortOrder: NodeSortOrder,
        userLocation: CLLocation?
    ) -> [ContactDTO] {
        var result = contacts

        // Always filter by segment first
        switch segment {
        case .favorites:
            result = result.filter(\.isFavorite)
        case .contacts:
            result = result.filter { $0.type == .chat }
        case .network:
            result = result.filter { $0.type == .repeater || $0.type == .room }
        }

        // Then filter by search text within the selected segment
        if !searchText.isEmpty {
            let query = searchText.trimmingCharacters(in: .whitespaces)
            let hexQuery = query.uppercased()
            let looksLikeHex = hexQuery.allSatisfy { $0.isHexDigit } && !hexQuery.isEmpty
            result = result.filter { contact in
                if contact.displayName.localizedStandardContains(query) {
                    return true
                }
                // Only match hex if the query looks like a hex string (avoids false positives)
                if looksLikeHex {
                    return contact.publicKeyHex.contains(hexQuery)
                }
                return false
            }
        }

        // Sort
        result = sorted(result, by: sortOrder, userLocation: userLocation)

        // When query looks like hex, re-sort to put public key matches on top
        // Tier 1: key starts with query, Tier 2: key contains query, Tier 3: name-only match
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            let hexQuery = searchText.trimmingCharacters(in: .whitespaces).uppercased()
            let looksLikeHex = hexQuery.allSatisfy { $0.isHexDigit } && !hexQuery.isEmpty
            if looksLikeHex {
                result.sort { a, b in
                    let aTier = hexMatchTier(for: a, hexQuery: hexQuery)
                    let bTier = hexMatchTier(for: b, hexQuery: hexQuery)
                    if aTier != bTier { return aTier < bTier }
                    return false // preserve existing sort within same tier
                }
            }
        }

        return result
    }

    /// Returns 0 if key starts with hex query, 1 if key contains it, 2 if name-only match
    private func hexMatchTier(for contact: ContactDTO, hexQuery: String) -> Int {
        if contact.publicKeyHex.hasPrefix(hexQuery) { return 0 }
        if contact.publicKeyHex.contains(hexQuery) { return 1 }
        return 2
    }

    /// Sort contacts by the given order
    private func sorted(
        _ contacts: [ContactDTO],
        by order: NodeSortOrder,
        userLocation: CLLocation?
    ) -> [ContactDTO] {
        switch order {
        case .lastHeard:
            return contacts.sorted { $0.lastModified > $1.lastModified }
        case .name:
            return contacts.sorted {
                $0.displayName.localizedCompare($1.displayName) == .orderedAscending
            }
        case .distance:
            guard let userLocation else {
                // No user location, fall back to name sort
                return sorted(contacts, by: .name, userLocation: nil)
            }
            return contacts.sorted { lhs, rhs in
                let lhsHasLocation = lhs.hasLocation
                let rhsHasLocation = rhs.hasLocation

                // Nodes without location sort to bottom
                if lhsHasLocation != rhsHasLocation {
                    return lhsHasLocation
                }

                guard lhsHasLocation && rhsHasLocation else {
                    // Both have no location, sort by name
                    return lhs.displayName.localizedCompare(rhs.displayName) == .orderedAscending
                }

                let lhsLocation = CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
                let rhsLocation = CLLocation(latitude: rhs.latitude, longitude: rhs.longitude)

                return lhsLocation.distance(from: userLocation) < rhsLocation.distance(from: userLocation)
            }
        }
    }

}
