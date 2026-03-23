import Foundation
import OSLog

/// Creates and polls plan pairing sessions on the DigitainoMesh server.
/// The app creates a session (6-char code), the user enters or scans it on the web,
/// draws a polygon, and the app polls until the polygon is available.
actor PlanSessionService {
    private static let logger = Logger(subsystem: "com.mc1", category: "PlanSession")

    private static let serverBaseURL = SurveyUploadService.serverBaseURL
    private static let apiKey = SurveyUploadService.apiKey

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - DTOs

    private struct CreateSessionResponse: Codable {
        let code: String
        let url: String
        let expiresAt: String
    }

    struct PlanSessionStatus: Codable {
        let code: String
        let status: String
        let polygon: [PolygonVertex]?
    }

    struct PolygonVertex: Codable {
        let latitude: Double
        let longitude: Double
    }

    // MARK: - Create Session

    struct SessionInfo {
        let code: String
        let url: URL
        let expiresAt: String
    }

    /// Create a new pairing session. Returns the code and shareable URL.
    func createSession() async throws -> SessionInfo {
        let url = Self.serverBaseURL.appending(path: "plans/sessions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.logger.error("Failed to create plan session: HTTP \(statusCode) — \(body)")
            throw PlanSessionError.serverError(statusCode: statusCode, message: body)
        }

        let decoded = try JSONDecoder().decode(CreateSessionResponse.self, from: data)
        guard let shareURL = URL(string: decoded.url) else {
            throw URLError(.badURL)
        }

        Self.logger.info("Created plan session: \(decoded.code, privacy: .public)")
        return SessionInfo(code: decoded.code, url: shareURL, expiresAt: decoded.expiresAt)
    }

    // MARK: - Poll Session

    /// Poll for the session status. Returns the polygon vertices when submitted, nil while waiting.
    func pollSession(code: String) async throws -> [PolygonVertex]? {
        let url = Self.serverBaseURL.appending(path: "plans/sessions/\(code)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        switch httpResponse.statusCode {
        case 200:
            let status = try JSONDecoder().decode(PlanSessionStatus.self, from: data)
            if status.status == "submitted", let polygon = status.polygon {
                Self.logger.info("Plan session \(code, privacy: .public) received polygon with \(polygon.count) vertices")
                return polygon
            }
            // Still waiting
            return nil
        case 404, 410:
            // Session expired or not found
            throw PlanSessionError.sessionExpired
        default:
            Self.logger.error("Poll failed: HTTP \(httpResponse.statusCode)")
            throw URLError(.badServerResponse)
        }
    }

    enum PlanSessionError: LocalizedError {
        case sessionExpired
        case serverError(statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .sessionExpired:
                return "Session expired or not found"
            case .serverError(let statusCode, let message):
                let detail = message.isEmpty ? "No details" : message
                return "Server error (HTTP \(statusCode)): \(detail)"
            }
        }
    }
}
