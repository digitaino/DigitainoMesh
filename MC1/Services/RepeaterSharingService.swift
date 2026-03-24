import Foundation
import MC1Services
import MeshCore
import OSLog

/// Periodically shares known repeater locations with the community server
/// when the user has opted in and is verified. Works independently of survey mode.
actor RepeaterSharingService {
    private static let logger = Logger(subsystem: "com.mc1", category: "RepeaterSharing")

    private static let serverBaseURL = SurveyUploadService.serverBaseURL
    static let minimumInterval: TimeInterval = 15 * 60  // 15 minutes

    private var lastSharedFingerprint: String = ""
    private var lastShareDate: Date = .distantPast

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - DTOs

    struct RepeaterPayload: Codable {
        let repeaters: [RepeaterInfo]
    }

    struct RepeaterInfo: Codable {
        let hexID: String
        let name: String
        let latitude: Double
        let longitude: Double
        let lastHeard: String?
    }

    struct RepeaterResponse: Codable {
        let accepted: Int
        let updated: Int
        let created: Int
    }

    // MARK: - Change Detection

    /// Whether enough time has elapsed since the last share.
    func shouldShare() -> Bool {
        Date().timeIntervalSince(lastShareDate) >= Self.minimumInterval
    }

    /// Whether the repeater data has changed since the last share.
    func hasChanges(fingerprint: String) -> Bool {
        fingerprint != lastSharedFingerprint
    }

    /// Record a successful share.
    func recordShare(fingerprint: String) {
        lastSharedFingerprint = fingerprint
        lastShareDate = Date()
    }

    /// Compute a fingerprint from repeater info for change detection.
    static func fingerprint(from repeaters: [RepeaterInfo]) -> String {
        let sorted = repeaters
            .map { "\($0.hexID):\($0.latitude):\($0.longitude):\($0.name):\($0.lastHeard ?? "")" }
            .sorted()
        let joined = sorted.joined(separator: "|")
        // Simple hash — just needs to detect changes, not be cryptographic
        return String(joined.hashValue)
    }

    // MARK: - Networking

    func shareRepeaters(_ repeaters: [RepeaterInfo], authToken: String) async throws -> RepeaterResponse {
        let url = Self.serverBaseURL.appendingPathComponent("me/repeaters")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = RepeaterPayload(repeaters: repeaters)
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SurveyUploadError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            let result = try JSONDecoder().decode(RepeaterResponse.self, from: data)
            Self.logger.info("Shared \(repeaters.count) repeaters: \(result.created) created, \(result.updated) updated")
            return result
        case 401:
            throw SurveyUploadError.unauthorized
        case 429:
            throw SurveyUploadError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SurveyUploadError.serverError("HTTP \(httpResponse.statusCode): \(body)")
        }
    }

    // MARK: - Building Repeater Info from Contacts

    /// Extracts shareable repeater info from contact DTOs.
    /// Only includes repeaters that have valid locations.
    static func repeaterInfos(from contacts: [ContactDTO]) -> [RepeaterInfo] {
        let formatter = ISO8601DateFormatter()
        return contacts
            .filter { $0.type == .repeater && $0.hasLocation }
            .map { contact in
                let hexID = contact.publicKey.prefix(2).hexString()
                let lastHeard: String? = contact.lastAdvertTimestamp > 0
                    ? formatter.string(from: Date(timeIntervalSince1970: TimeInterval(contact.lastAdvertTimestamp)))
                    : nil
                return RepeaterInfo(
                    hexID: hexID,
                    name: contact.name,
                    latitude: contact.latitude,
                    longitude: contact.longitude,
                    lastHeard: lastHeard
                )
            }
    }
}
