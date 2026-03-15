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

/// Uploads anonymized signal survey data to the PocketMesh community map server
/// and fetches aggregated community data for display.
actor SurveyUploadService {
    private static let logger = Logger(subsystem: "com.mc1", category: "SurveyUpload")

    // MARK: - Configuration

    static let serverBaseURL = URL(string: "https://mesh.digitaino.com/api/v1")!
    static let apiKey = "c94393f688d61a3c1193153f5bbe860ee57ca066a256bb812529ee199448ba83"

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
    }

    struct UploadResponse: Codable {
        let accepted: Int
        let message: String?
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
    }

    struct CommunityCellsResponse: Codable {
        let cells: [CommunityCell]
        let totalCells: Int
    }

    struct CommunityStats: Codable {
        let totalCells: Int
        let totalContributions: Int
        let uniqueRepeaters: Int
        let uniqueContributors: Int
        let lastUpload: String?
    }

    // MARK: - Dependencies

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Upload

    /// Upload survey data to the community map server.
    func upload(sessionID: UUID, dataStore: PersistenceStore) async throws -> UploadResponse {
        guard let result = try await SurveyExportService.generateCellData(
            sessionID: sessionID,
            dataStore: dataStore,
            includeTimeRange: false
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
            cells: result.cells
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

        let data = try await performRequest(request)
        let response = try JSONDecoder().decode(UploadResponse.self, from: data)

        Self.logger.info("Uploaded \(response.accepted) cells to community map")
        return response
    }

    // MARK: - Fetch Community Data

    /// Fetch aggregated community cell data for a map region.
    func fetchCommunityData(
        minLat: Double,
        maxLat: Double,
        minLon: Double,
        maxLon: Double,
        limit: Int = 5000
    ) async throws -> CommunityCellsResponse {
        var components = URLComponents(url: Self.serverBaseURL.appending(path: "cells"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "minLat", value: String(minLat)),
            URLQueryItem(name: "maxLat", value: String(maxLat)),
            URLQueryItem(name: "minLon", value: String(minLon)),
            URLQueryItem(name: "maxLon", value: String(maxLon)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]

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

    // MARK: - Contributor ID (Keychain)

    /// Get or create a persistent contributor UUID stored in the Keychain.
    private func getOrCreateContributorID() async throws -> String {
        // Try to retrieve existing
        if let existing = try retrieveFromKeychain() {
            return existing
        }

        // Generate new UUID
        let newID = UUID().uuidString
        try storeInKeychain(newID)
        Self.logger.info("Generated new contributor ID")
        return newID
    }

    private func retrieveFromKeychain() throws -> String? {
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

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    private func storeInKeychain(_ value: String) throws {
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
