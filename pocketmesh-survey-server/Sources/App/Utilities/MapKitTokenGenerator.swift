import Crypto
import Foundation

/// Generates short-lived MapKit JS JWT tokens for the web frontend.
///
/// Uses ES256 (P-256 ECDSA with SHA-256) as required by Apple.
/// Credentials are read from environment variables with hardcoded fallbacks.
enum MapKitTokenGenerator {

    // MARK: - Configuration

    private static let teamID = ProcessInfo.processInfo.environment["MAPKIT_TEAM_ID"]
        ?? "RU9VTBSCM5"
    private static let keyID = ProcessInfo.processInfo.environment["MAPKIT_KEY_ID"]
        ?? "WST6ZA6HR2"

    private static let privateKeyPEM = ProcessInfo.processInfo.environment["MAPKIT_PRIVATE_KEY"]
        ?? """
        -----BEGIN PRIVATE KEY-----
        MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQgmmZlBb7ZO2yB81lp
        4g9QEvqFARzy+IsA7ghKpbqZ6bCgCgYIKoZIzj0DAQehRANCAASXreeJuUazHvLa
        WisxttM50vyA01qemajQpmPEZygpyDvNcBak/tUGEmADgWJCqBZ3Ll5vZnos6BE5
        mIwt5RoH
        -----END PRIVATE KEY-----
        """

    /// Token validity duration (24 hours).
    private static let tokenLifetime: TimeInterval = 86400

    // MARK: - Token Generation

    /// Generate a signed MapKit JS JWT token.
    static func generateToken() throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let exp = now + Int(tokenLifetime)

        // JWT Header
        let header = #"{"alg":"ES256","kid":"\#(keyID)","typ":"JWT"}"#

        // JWT Payload — origin restriction can be added if needed
        let payload = #"{"iss":"\#(teamID)","iat":\#(now),"exp":\#(exp)}"#

        // Base64url encode header and payload
        let headerB64 = base64urlEncode(Data(header.utf8))
        let payloadB64 = base64urlEncode(Data(payload.utf8))
        let signingInput = "\(headerB64).\(payloadB64)"

        // Sign with ES256
        let privateKey = try parsePrivateKey()
        let signature = try privateKey.signature(
            for: Data(signingInput.utf8)
        )

        // MapKit JS expects raw (r || s) signature format, not DER
        let signatureB64 = base64urlEncode(signature.rawRepresentation)

        return "\(signingInput).\(signatureB64)"
    }

    // MARK: - Private Helpers

    /// Parse the PEM-encoded P-256 private key.
    private static func parsePrivateKey() throws -> P256.Signing.PrivateKey {
        // Strip PEM headers and whitespace to get raw base64
        let stripped = privateKeyPEM
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let derData = Data(base64Encoded: stripped) else {
            throw MapKitTokenError.invalidPrivateKey
        }

        return try P256.Signing.PrivateKey(derRepresentation: derData)
    }

    /// Base64url encoding (no padding, URL-safe characters).
    private static func base64urlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum MapKitTokenError: Error {
    case invalidPrivateKey
}
