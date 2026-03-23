import CoreLocation
import Foundation
import OSLog

/// Manages survey route lifecycle on the DigitainoMesh server.
/// All calls are fire-and-forget from the caller's perspective — failures are logged but never block the local flow.
actor SurveyRouteService {
    private static let logger = Logger(subsystem: "com.mc1", category: "SurveyRoute")

    private static let serverBaseURL = SurveyUploadService.serverBaseURL
    private static let apiKey = SurveyUploadService.apiKey

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - DTOs

    struct PolygonVertex: Codable {
        let latitude: Double
        let longitude: Double
    }

    private struct CreateRequest: Codable {
        let polygon: [PolygonVertex]
        let waypointCount: Int
        let excludedSurveyed: Bool
        let referenceLatitude: Double
        let contributorID: String
        let planSessionCode: String?
    }

    private struct CreateResponse: Codable {
        let id: String
        let status: String
        let createdAt: String
    }

    private struct UpdateStatusRequest: Codable {
        let status: String
        let completedCount: Int?
        let skippedCount: Int?
    }

    private struct UpdateStatusResponse: Codable {
        let id: String
        let status: String
        let updatedAt: String
    }

    // MARK: - Create Route

    /// Upload a survey route to the server. Returns the server-assigned route ID.
    func createRoute(
        polygon: [CLLocationCoordinate2D],
        waypointCount: Int,
        excludedSurveyed: Bool,
        referenceLatitude: Double,
        contributorID: String,
        planSessionCode: String? = nil
    ) async throws -> String {
        let vertices = polygon.map { PolygonVertex(latitude: $0.latitude, longitude: $0.longitude) }
        let payload = CreateRequest(
            polygon: vertices,
            waypointCount: waypointCount,
            excludedSurveyed: excludedSurveyed,
            referenceLatitude: referenceLatitude,
            contributorID: contributorID,
            planSessionCode: planSessionCode
        )

        let encoder = JSONEncoder()
        let body = try encoder.encode(payload)

        let url = Self.serverBaseURL.appending(path: "survey-routes")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = body
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            Self.logger.error("Failed to create survey route: HTTP \(statusCode)")
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(CreateResponse.self, from: data)
        Self.logger.info("Created survey route: \(decoded.id, privacy: .public)")
        return decoded.id
    }

    // MARK: - Update Status

    /// Update the lifecycle status of a survey route on the server.
    func updateStatus(
        routeID: String,
        status: String,
        completedCount: Int? = nil,
        skippedCount: Int? = nil
    ) async throws {
        let payload = UpdateStatusRequest(
            status: status,
            completedCount: completedCount,
            skippedCount: skippedCount
        )

        let encoder = JSONEncoder()
        let body = try encoder.encode(payload)

        let url = Self.serverBaseURL.appending(path: "survey-routes/\(routeID)/status")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = body
        request.timeoutInterval = 15

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            Self.logger.error("Failed to update survey route \(routeID, privacy: .public): HTTP \(statusCode)")
            throw URLError(.badServerResponse)
        }

        Self.logger.info("Updated survey route \(routeID, privacy: .public) → \(status, privacy: .public)")
    }
}
