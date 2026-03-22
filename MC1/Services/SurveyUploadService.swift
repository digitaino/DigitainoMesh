import Foundation
import MC1Services
import OSLog
import Security

// MARK: - Errors

enum SurveyUploadError: LocalizedError {
    case networkError(String)
    case unauthorized
    case serverError(String)
    case invalidResponse
    case rateLimited
    case noData

    var errorDescription: String? {
        switch self {
        case .networkError(let message):
            return "Network error: \(message)"
        case .unauthorized:
            return "Unauthorized — invalid API key"
        case .serverError(let message):
            return "Server error: \(message)"
        case .invalidResponse:
            return "Invalid server response"
        case .rateLimited:
            return "Rate limited — try again later"
        case .noData:
            return "No survey data to upload"
        }
    }
}

// MARK: - Service

/// Uploads anonymized signal survey data to the DigitainoMesh community map server
/// and fetches aggregated community data for display.
actor SurveyUploadService {
    private static let logger = Logger(subsystem: "com.mc1", category: "SurveyUpload")

    // MARK: - Configuration

    static let serverBaseURL = URL(string: "https://mesh.digitaino.com/api/v1")!
    static let apiKey: String = {
        guard let key = Bundle.main.infoDictionary?["SurveyAPIKey"] as? String, !key.isEmpty else {
            fatalError("SurveyAPIKey not found in Info.plist — check Secrets.xcconfig")
        }
        return key
    }()

    private static let maxRetries = 3
    private static let baseRetryDelay: Duration = .milliseconds(500)

    // MARK: - Keychain (Contributor ID)

    private static let keychainService = "com.pocketmesh.community"
    private static let keychainAccount = "contributorID"

    // MARK: - DTOs

    struct UploadPayload: Codable {
        let version: String
        let contributorID: String
        let gridType: String
        let cellSizeDegrees: Double
        let referenceLatitude: Double
        let cells: [SurveyExportService.CellData]
        let repeaters: [SurveyExportService.RepeaterInfo]
        /// Session UUIDs included in this upload for server-side deduplication.
        /// Re-uploading the same session replaces previous data instead of accumulating.
        let sessionIDs: [String]?
        /// Optional contact name to associate with this contributor on the community map.
        let displayName: String?
    }

    struct UploadResponse: Codable {
        let accepted: Int
        let message: String?
    }

    struct DeleteContributorResponse: Codable {
        let deletedContributions: Int
        let cellsRemoved: Int
        let cellsUpdated: Int
    }

    struct CommunityCell: Codable, Identifiable {
        var id: String { "\(hexQ)_\(hexR)" }
        let latitude: Double
        let longitude: Double
        let hexQ: Int
        let hexR: Int
        let referenceLatitude: Double
        let averageSNR: Double?
        let packetCount: Int
        let contributionCount: Int
        let repeaterHexIDs: [String]
        let snrQuality: String
        let activePacketCount: Int?
        let passivePacketCount: Int?
        let probesSent: Int?
        let lastUpdated: String?
        let contributorNames: [String]?
    }

    struct CommunityCellsResponse: Codable {
        let cells: [CommunityCell]
        let totalCells: Int
        /// Total cells matching the query before any server-side limit.
        /// When present and greater than totalCells, results were truncated.
        let totalMatching: Int?
    }

    struct CommunityStats: Codable {
        let totalCells: Int
        let totalContributions: Int
        let uniqueRepeaters: Int
        let uniqueContributors: Int
        let lastUpload: String?
    }

    struct RepeaterLocation: Codable, Identifiable {
        var id: String { hexID }
        let hexID: String
        let name: String
        let latitude: Double
        let longitude: Double
    }

    struct RepeatersResponse: Codable {
        let repeaters: [RepeaterLocation]
    }

    // MARK: - Dependencies

    private let session: URLSession

    /// In-memory cache of contributor ID, shared across all instances.
    /// Prevents generating a new UUID on every call if keychain is failing.
    private static let cachedContributorID = ContributorIDCache()

    /// Optional display name to include with uploads. Set from the survey setup sheet.
    var displayName: String?

    /// Set the display name for uploads. Convenience for calling from non-isolated contexts.
    func setDisplayName(_ name: String?) {
        displayName = name
    }

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Upload

    /// Upload survey data to the community map server.
    /// - Parameters:
    ///   - sessionID: The survey session to upload.
    ///   - dataStore: Persistence store for reading survey points.
    ///   - repeaterContacts: Known contacts for resolving repeater hex IDs to names/locations.
    func upload(
        sessionID: UUID,
        dataStore: PersistenceStore,
        repeaterContacts: [ContactDTO] = [],
        probesSentPerCell: [String: Int] = [:],
        deadZoneHexCoords: [(q: Int, r: Int)] = []
    ) async throws -> UploadResponse {
        // Ensure active/passive classification is backfilled before generating cell data.
        // The backfill is idempotent (only touches points with isActiveProbe==false that have
        // control/trace payloadType), so it's safe to always run before upload.
        let backfilled = try await dataStore.backfillActiveProbeFlag()
        Self.logger.info("DEBUG upload: backfill result = \(backfilled) points updated")

        guard let result = try await SurveyExportService.generateCellData(
            sessionID: sessionID,
            dataStore: dataStore,
            includeTimeRange: false,
            repeaterContacts: repeaterContacts,
            probesSentPerCell: probesSentPerCell,
            deadZoneHexCoords: deadZoneHexCoords
        ) else {
            throw SurveyUploadError.noData
        }

        let contributorID = try await getOrCreateContributorID()

        let payload = UploadPayload(
            version: SurveyExportService.formatVersion,
            contributorID: contributorID,
            gridType: "hex",
            cellSizeDegrees: HexGrid.size,
            referenceLatitude: result.referenceLatitude,
            cells: result.cells,
            repeaters: result.repeaters,
            sessionIDs: [sessionID.uuidString],
            displayName: displayName
        )

        Self.logger.info("Upload: \(result.cells.count) cells for session \(sessionID.uuidString.prefix(8))")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(payload)

        let url = Self.serverBaseURL.appending(path: "survey")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = body

        let data = try await performRequest(request)
        let response = try JSONDecoder().decode(UploadResponse.self, from: data)

        Self.logger.info("Uploaded \(response.accepted) cells to community map")
        return response
    }

    /// Upload multiple survey sessions at once, merging their data into a single payload.
    /// This consolidates overlapping hex cells and normalizes repeater hex IDs across sessions.
    /// Session IDs are sent to the server for deduplication — re-uploading replaces previous data.
    func uploadMultipleSessions(
        sessionIDs: [UUID],
        dataStore: PersistenceStore,
        repeaterContacts: [ContactDTO] = [],
        probesSentPerCell: [String: Int] = [:],
        deadZoneHexCoords: [(q: Int, r: Int)] = []
    ) async throws -> UploadResponse {
        let backfilled = try await dataStore.backfillActiveProbeFlag()
        Self.logger.info("Batch upload: backfill updated \(backfilled) points")

        guard let result = try await SurveyExportService.generateCellDataForSessions(
            sessionIDs: sessionIDs,
            dataStore: dataStore,
            repeaterContacts: repeaterContacts,
            probesSentPerCell: probesSentPerCell,
            deadZoneHexCoords: deadZoneHexCoords
        ) else {
            throw SurveyUploadError.noData
        }

        let contributorID = try await getOrCreateContributorID()

        let payload = UploadPayload(
            version: SurveyExportService.formatVersion,
            contributorID: contributorID,
            gridType: "hex",
            cellSizeDegrees: HexGrid.size,
            referenceLatitude: result.referenceLatitude,
            cells: result.cells,
            repeaters: result.repeaters,
            sessionIDs: sessionIDs.map(\.uuidString),
            displayName: displayName
        )

        Self.logger.info("Batch upload: \(result.cells.count) merged cells from \(sessionIDs.count) sessions")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(payload)

        let url = Self.serverBaseURL.appending(path: "survey")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = body

        let data = try await performRequest(request)
        let response = try JSONDecoder().decode(UploadResponse.self, from: data)

        Self.logger.info("Uploaded \(response.accepted) merged cells from \(sessionIDs.count) sessions")
        return response
    }

    // MARK: - Live Upload (per-point)

    /// Upload a single survey point to the community map server in real time.
    /// Converts the point to a 1-cell hex payload and POSTs it immediately.
    /// SessionIDs are included so the server can group contributions by session.
    /// The server skips session dedup for single-cell (live) uploads, allowing accumulation.
    /// Errors are logged but not thrown — live upload is best-effort.
    func uploadLivePoint(
        _ point: SignalSurveyPointDTO,
        referenceLatitude: Double,
        sessionID: UUID? = nil,
        repeaterContacts: [ContactDTO] = []
    ) async {
        let hex = HexGrid.axialFromLatLon(
            latitude: point.latitude,
            longitude: point.longitude,
            referenceLatitude: referenceLatitude
        )
        let center = HexGrid.centerLatLon(from: hex, referenceLatitude: referenceLatitude)
        let isFlood = point.routeType == .flood || point.routeType == .tcFlood

        // Consolidate hex IDs at the source — different pathHashMode sessions may produce
        // different-length hashes for the same repeater (e.g. "0C" vs "0C13")
        let consolidatedHexIDs = SurveyExportService.consolidateHexIDs(point.pathNodeHexIDs)

        let cellData = SurveyExportService.CellData(
            latitude: center.latitude,
            longitude: center.longitude,
            averageSNR: point.snr,
            averageRSSI: point.rssi.map { Double($0) },
            minSNR: point.snr,
            maxSNR: point.snr,
            packetCount: 1,
            routeTypeBreakdown: SurveyExportService.RouteBreakdown(
                flood: isFlood ? 1 : 0,
                direct: isFlood ? 0 : 1
            ),
            timeRange: nil,
            repeaterHexIDs: consolidatedHexIDs,
            hexQ: hex.q,
            hexR: hex.r,
            referenceLatitude: referenceLatitude,
            activePacketCount: point.isActiveProbe ? 1 : nil,
            passivePacketCount: point.isActiveProbe ? nil : 1,
            repeaterMetrics: nil,
            probesSent: nil
        )

        // Resolve repeater info for any path nodes (using consolidated IDs)
        let resolvedRepeaters: [SurveyExportService.RepeaterInfo] = consolidatedHexIDs.compactMap { hexID in
            guard let hashBytes = Data(hexString: hexID) else { return nil }
            guard let contact = RepeaterResolver.bestMatch(
                for: hashBytes, in: repeaterContacts, userLocation: nil
            ) else { return nil }
            guard contact.hasLocation else { return nil }
            return SurveyExportService.RepeaterInfo(
                hexID: hexID,
                name: contact.displayName,
                latitude: contact.latitude,
                longitude: contact.longitude
            )
        }

        do {
            let contributorID = try await getOrCreateContributorID()

            let payload = UploadPayload(
                version: SurveyExportService.formatVersion,
                contributorID: contributorID,
                gridType: "hex",
                cellSizeDegrees: HexGrid.size,
                referenceLatitude: referenceLatitude,
                cells: [cellData],
                repeaters: resolvedRepeaters,
                sessionIDs: sessionID.map { [$0.uuidString] },
                displayName: displayName
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let body = try encoder.encode(payload)

            let url = Self.serverBaseURL.appending(path: "survey")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(Self.apiKey, forHTTPHeaderField: "X-API-Key")
            request.httpBody = body

            _ = try await performRequest(request)
            Self.logger.debug("Live uploaded point to hex (\(hex.q), \(hex.r))")
        } catch {
            Self.logger.warning("Live upload failed: \(error.localizedDescription)")
        }
    }

    /// Upload a dead zone cell (probed but no response) to the community map server.
    /// Called during live upload when a new dead zone is detected.
    func uploadDeadZoneCell(
        hexQ: Int,
        hexR: Int,
        referenceLatitude: Double,
        probesSent: Int,
        sessionID: UUID? = nil
    ) async {
        let center = HexGrid.centerLatLon(
            from: HexGrid.AxialCoord(q: hexQ, r: hexR),
            referenceLatitude: referenceLatitude
        )

        let cellData = SurveyExportService.CellData(
            latitude: center.latitude,
            longitude: center.longitude,
            averageSNR: nil,
            averageRSSI: nil,
            minSNR: nil,
            maxSNR: nil,
            packetCount: 0,
            routeTypeBreakdown: SurveyExportService.RouteBreakdown(flood: 0, direct: 0),
            timeRange: nil,
            repeaterHexIDs: [],
            hexQ: hexQ,
            hexR: hexR,
            referenceLatitude: referenceLatitude,
            activePacketCount: nil,
            passivePacketCount: nil,
            repeaterMetrics: nil,
            probesSent: probesSent
        )

        do {
            let contributorID = try await getOrCreateContributorID()

            let payload = UploadPayload(
                version: SurveyExportService.formatVersion,
                contributorID: contributorID,
                gridType: "hex",
                cellSizeDegrees: HexGrid.size,
                referenceLatitude: referenceLatitude,
                cells: [cellData],
                repeaters: [],
                sessionIDs: sessionID.map { [$0.uuidString] },
                displayName: displayName
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let body = try encoder.encode(payload)

            let url = Self.serverBaseURL.appending(path: "survey")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(Self.apiKey, forHTTPHeaderField: "X-API-Key")
            request.httpBody = body

            _ = try await performRequest(request)
            Self.logger.debug("Live uploaded dead zone at hex (\(hexQ), \(hexR)) with \(probesSent) probes")
        } catch {
            Self.logger.warning("Dead zone upload failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Fetch Community Data

    /// Fetch aggregated community cell data for a map region.
    func fetchCommunityData(
        minLat: Double,
        maxLat: Double,
        minLon: Double,
        maxLon: Double,
        limit: Int? = nil,
        coverage: String? = nil,
        maxAge: Int? = nil,
        repeater: String? = nil
    ) async throws -> CommunityCellsResponse {
        var components = URLComponents(url: Self.serverBaseURL.appending(path: "cells"), resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "minLat", value: String(minLat)),
            URLQueryItem(name: "maxLat", value: String(maxLat)),
            URLQueryItem(name: "minLon", value: String(minLon)),
            URLQueryItem(name: "maxLon", value: String(maxLon)),
        ]
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let coverage {
            queryItems.append(URLQueryItem(name: "coverage", value: coverage))
        }
        if let maxAge {
            queryItems.append(URLQueryItem(name: "maxAge", value: String(maxAge)))
        }
        if let repeater {
            queryItems.append(URLQueryItem(name: "repeater", value: repeater))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw SurveyUploadError.invalidResponse
        }

        let request = URLRequest(url: url)
        let data = try await performRequest(request)
        return try JSONDecoder().decode(CommunityCellsResponse.self, from: data)
    }

    /// Fetch community map statistics.
    func fetchStats() async throws -> CommunityStats {
        let url = Self.serverBaseURL.appending(path: "stats")
        let request = URLRequest(url: url)
        let data = try await performRequest(request)
        return try JSONDecoder().decode(CommunityStats.self, from: data)
    }

    /// Fetch repeater locations for a map region.
    func fetchRepeaterLocations(
        minLat: Double,
        maxLat: Double,
        minLon: Double,
        maxLon: Double
    ) async throws -> [RepeaterLocation] {
        var components = URLComponents(url: Self.serverBaseURL.appending(path: "repeaters"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "minLat", value: String(minLat)),
            URLQueryItem(name: "maxLat", value: String(maxLat)),
            URLQueryItem(name: "minLon", value: String(minLon)),
            URLQueryItem(name: "maxLon", value: String(maxLon)),
        ]

        guard let url = components.url else {
            throw SurveyUploadError.invalidResponse
        }

        let request = URLRequest(url: url)
        let data = try await performRequest(request)
        let response = try JSONDecoder().decode(RepeatersResponse.self, from: data)
        return response.repeaters
    }

    // MARK: - HTTP

    private func performRequest(_ request: URLRequest) async throws -> Data {
        for attempt in 0..<Self.maxRetries {
            let responseData: Data
            let response: URLResponse
            do {
                (responseData, response) = try await session.data(for: request)
            } catch {
                throw SurveyUploadError.networkError(error.localizedDescription)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw SurveyUploadError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200...299:
                return responseData
            case 401:
                throw SurveyUploadError.unauthorized
            case 429:
                let delay = Self.baseRetryDelay * (1 << attempt)
                Self.logger.warning("Rate limited (429), retrying in \(delay) (attempt \(attempt + 1)/\(Self.maxRetries))")
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                continue
            default:
                let body = String(data: responseData, encoding: .utf8) ?? "unknown"
                throw SurveyUploadError.serverError("HTTP \(httpResponse.statusCode): \(body)")
            }
        }

        Self.logger.error("Rate limited after \(Self.maxRetries) retries")
        throw SurveyUploadError.rateLimited
    }

    // MARK: - Delete Contributor Data

    /// Delete all data for this contributor from the community map server.
    /// Returns the server response with counts of removed contributions and cells.
    func deleteContributorData() async throws -> DeleteContributorResponse {
        let contributorID = try await getOrCreateContributorID()

        let url = Self.serverBaseURL.appending(path: "contributor/\(contributorID)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(Self.apiKey, forHTTPHeaderField: "X-API-Key")

        let data = try await performRequest(request)
        let response = try JSONDecoder().decode(DeleteContributorResponse.self, from: data)

        Self.logger.info("Deleted contributor data: \(response.deletedContributions) contributions, \(response.cellsRemoved) cells removed")
        return response
    }

    // MARK: - Contributor ID (Keychain + Memory Cache)

    /// Get or create a persistent contributor UUID.
    /// Uses a process-wide in-memory cache so that even if keychain reads fail
    /// (e.g. entitlement issues in debug builds), we return the same ID for the
    /// lifetime of the app process instead of generating a new UUID per call.
    func getOrCreateContributorID() async throws -> String {
        // Fast path: return cached value
        if let cached = Self.cachedContributorID.value {
            return cached
        }

        // Try to retrieve from keychain
        if let existing = retrieveFromKeychain() {
            Self.cachedContributorID.value = existing
            return existing
        }

        // Generate new UUID, cache it, and attempt to persist to keychain
        let newID = UUID().uuidString
        Self.cachedContributorID.value = newID
        storeInKeychain(newID)
        Self.logger.info("Generated new contributor ID")
        return newID
    }

    /// Update the stored contributor ID after migration to a public-key-based ID.
    /// Updates both the in-memory cache and the Keychain.
    func updateContributorID(_ newID: String) {
        Self.cachedContributorID.value = newID
        storeInKeychain(newID)
        Self.logger.info("Updated contributor ID to public key hash")
    }

    private func retrieveFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        if status != errSecSuccess {
            Self.logger.warning("Keychain read failed with status \(status)")
            return nil
        }

        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    private func storeInKeychain(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }

        // Delete any existing entry
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new entry
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            Self.logger.error("Failed to store contributor ID in keychain: \(status)")
        }
    }
}

// MARK: - Thread-safe in-memory cache for contributor ID

/// A simple thread-safe cache for the contributor ID, shared across all
/// SurveyUploadService instances within the same process. This ensures that
/// even if keychain operations fail, we generate at most one UUID per app launch.
final class ContributorIDCache: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?

    var value: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }
}
