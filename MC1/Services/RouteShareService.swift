import Foundation
import OSLog

/// Uploads shared route and repeater map data to the DigitainoMesh server
/// and returns short URLs for sharing.
actor RouteShareService {
    private static let logger = Logger(subsystem: "com.mc1", category: "RouteShare")

    // Uses the same server and API key as SurveyUploadService
    private static let serverBaseURL = SurveyUploadService.serverBaseURL
    private static let apiKey = SurveyUploadService.apiKey

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - DTOs

    struct RouteHop: Codable {
        let hexID: String
        let name: String?
        let latitude: Double?
        let longitude: Double?
    }

    private struct CreateRouteRequest: Codable {
        let hopCount: Int
        let distanceText: String?
        let hops: [RouteHop]
        let userLatitude: Double?
        let userLongitude: Double?
        let userName: String?
    }

    private struct CreateRouteResponse: Codable {
        let id: String
        let url: String
    }

    struct RepeaterInfo: Codable {
        let hexID: String
        let name: String?
        let latitude: Double?
        let longitude: Double?
        let heardCount: Int
        let avgSNR: Double?
        let avgRSSI: Double?
    }

    struct RepeatPath: Codable {
        let hops: [String]
        let snr: Double?
    }

    private struct CreateMapRequest: Codable {
        let repeaters: [RepeaterInfo]
        let paths: [RepeatPath]?
        let userLatitude: Double?
        let userLongitude: Double?
        let userName: String?
    }

    private struct CreateMapResponse: Codable {
        let id: String
        let url: String
    }

    // MARK: - Share Route

    /// Upload route data and return the share URL.
    /// Returns nil if the upload fails (caller should still use the offline "RX via" text).
    func shareRoute(
        hopCount: Int,
        distanceText: String?,
        hops: [RouteHop],
        userLatitude: Double? = nil,
        userLongitude: Double? = nil,
        userName: String? = nil
    ) async -> URL? {
        let payload = CreateRouteRequest(
            hopCount: hopCount,
            distanceText: distanceText,
            hops: hops,
            userLatitude: userLatitude,
            userLongitude: userLongitude,
            userName: userName
        )

        do {
            let data = try await post(path: "routes", body: payload)
            let response = try JSONDecoder().decode(CreateRouteResponse.self, from: data)
            Self.logger.info("Shared route: \(response.url, privacy: .public)")
            return URL(string: response.url)
        } catch {
            Self.logger.error("Failed to share route: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Share Repeater Map

    /// Upload heard repeaters data and return the share URL.
    /// Returns nil if the upload fails.
    func shareRepeaterMap(repeaters: [RepeaterInfo], paths: [RepeatPath]? = nil, userLatitude: Double? = nil, userLongitude: Double? = nil, userName: String? = nil) async -> URL? {
        let payload = CreateMapRequest(repeaters: repeaters, paths: paths, userLatitude: userLatitude, userLongitude: userLongitude, userName: userName)

        do {
            let data = try await post(path: "maps", body: payload)
            let response = try JSONDecoder().decode(CreateMapResponse.self, from: data)
            Self.logger.info("Shared repeater map: \(response.url, privacy: .public)")
            return URL(string: response.url)
        } catch {
            Self.logger.error("Failed to share repeater map: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Share Path

    private struct CreatePathRequest: Codable {
        let hops: [RouteHop]
        let userLatitude: Double?
        let userLongitude: Double?
        let userName: String?
        /// When true, the server trusts the client's hop data as-is and skips
        /// server-side resolution against the community repeater database.
        let clientResolved: Bool?
    }

    private struct CreatePathResponse: Codable {
        let id: String
        let url: String
    }

    /// Upload a hex path (no sender/receiver, no distance) and return the share URL.
    /// Returns nil if the upload fails.
    func sharePath(
        hops: [RouteHop],
        userLatitude: Double? = nil,
        userLongitude: Double? = nil,
        userName: String? = nil
    ) async -> URL? {
        let payload = CreatePathRequest(
            hops: hops,
            userLatitude: userLatitude,
            userLongitude: userLongitude,
            userName: userName,
            clientResolved: true
        )

        do {
            let data = try await post(path: "paths", body: payload)
            let response = try JSONDecoder().decode(CreatePathResponse.self, from: data)
            Self.logger.info("Shared path: \(response.url, privacy: .public)")
            return URL(string: response.url)
        } catch {
            Self.logger.error("Failed to share path: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - HTTP

    private func post<T: Encodable>(path: String, body: T) async throws -> Data {
        let url = Self.serverBaseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            Self.logger.error("Share upload failed: HTTP \(httpResponse.statusCode) — \(body, privacy: .public)")
            throw URLError(.badServerResponse)
        }

        return data
    }
}
