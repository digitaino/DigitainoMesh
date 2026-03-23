import Foundation
import OSLog

/// Wraps the self-service API endpoints (`/api/v1/me/*`) for authenticated
/// contributor profile management using a Bearer token from verification.
actor ContributorSelfService {
    private static let logger = Logger(subsystem: "com.mc1", category: "ContributorSelfService")

    private let session: URLSession
    private static let serverBaseURL = SurveyUploadService.serverBaseURL
    private let authToken: String

    init(authToken: String, session: URLSession = .shared) {
        self.authToken = authToken
        self.session = session
    }

    // MARK: - DTOs

    struct MyProfile: Codable {
        let contributorID: String
        let legacyUUID: String?
        let displayName: String?
        let nameVisibleFrom: String?
        let verified: Bool
        let cellCount: Int
        let uploadCount: Int
        let sessionCount: Int
        let firstSeen: String?
        let lastSeen: String?
    }

    struct MyContributions: Codable {
        let contributorID: String
        let sessions: [SessionInfo]
        let totalCells: Int
        let totalPackets: Int
    }

    struct SessionInfo: Codable, Identifiable {
        var id: String { sessionID }
        let sessionID: String
        let cellCount: Int
        let packetCount: Int
        let contributedAt: String?
    }

    struct DeleteResponse: Codable {
        let deletedContributions: Int
        let cellsRemoved: Int
        let cellsUpdated: Int
    }

    struct MySurveyRoute: Codable, Identifiable {
        var id: String
        let contributorID: String
        let waypointCount: Int
        let status: String
        let completedCount: Int
        let skippedCount: Int
        let excludedSurveyed: Bool
        let referenceLatitude: Double
        let planSessionCode: String?
        let createdAt: String
        let startedAt: String?
        let finishedAt: String?
        let updatedAt: String
    }

    private struct MySurveyRoutesResponse: Codable {
        let routes: [MySurveyRoute]
    }

    private struct NameRetroactiveRequest: Codable {
        let applyToAll: Bool
    }

    private struct NameRetroactiveResponse: Codable {
        let contributorID: String
        let nameVisibleFrom: String?
    }

    private struct UpdateDisplayNameRequest: Codable {
        let displayName: String
    }

    private struct UpdateDisplayNameResponse: Codable {
        let contributorID: String
        let displayName: String
    }

    // MARK: - API Calls

    func getMyProfile() async throws -> MyProfile {
        let data = try await performRequest(path: "me/profile", method: "GET")
        return try JSONDecoder().decode(MyProfile.self, from: data)
    }

    func getMyContributions() async throws -> MyContributions {
        let data = try await performRequest(path: "me/contributions", method: "GET")
        return try JSONDecoder().decode(MyContributions.self, from: data)
    }

    func updateDisplayName(_ name: String) async throws {
        let body = try JSONEncoder().encode(UpdateDisplayNameRequest(displayName: name))
        _ = try await performRequest(path: "me/displayname", method: "PUT", body: body)
    }

    func setNameRetroactive(_ applyToAll: Bool) async throws -> String? {
        let body = try JSONEncoder().encode(NameRetroactiveRequest(applyToAll: applyToAll))
        let data = try await performRequest(path: "me/name-retroactive", method: "PUT", body: body)
        let response = try JSONDecoder().decode(NameRetroactiveResponse.self, from: data)
        return response.nameVisibleFrom
    }

    func deleteMyData() async throws -> DeleteResponse {
        let data = try await performRequest(path: "me/data", method: "DELETE")
        return try JSONDecoder().decode(DeleteResponse.self, from: data)
    }

    func getMyRoutes() async throws -> [MySurveyRoute] {
        let data = try await performRequest(path: "me/survey-routes", method: "GET")
        return try JSONDecoder().decode(MySurveyRoutesResponse.self, from: data).routes
    }

    // MARK: - Networking

    private func performRequest(
        path: String,
        method: String,
        body: Data? = nil
    ) async throws -> Data {
        let url = Self.serverBaseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SurveyUploadError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return data
        case 401:
            throw SurveyUploadError.unauthorized
        case 429:
            throw SurveyUploadError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SurveyUploadError.serverError("HTTP \(httpResponse.statusCode): \(body)")
        }
    }
}
