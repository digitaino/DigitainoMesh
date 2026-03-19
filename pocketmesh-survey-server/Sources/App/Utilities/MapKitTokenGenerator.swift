import Crypto
import Foundation

/// Generates short-lived MapKit JS JWT tokens for the web frontend.
///
/// Uses ES256 (P-256 ECDSA with SHA-256) as required by Apple.
/// Credentials are read from environment variables (no hardcoded fallbacks).
enum MapKitTokenGenerator {

    // MARK: - Configuration

    private static let teamID = ProcessInfo.processInfo.environment["MAPKIT_TEAM_ID"]
    private static let keyID = ProcessInfo.processInfo.environment["MAPKIT_KEY_ID"]
    private static let privateKeyPEM = ProcessInfo.processInfo.environment["MAPKIT_PRIVATE_KEY"]

    /// Token validity duration (24 hours).
    private static let tokenLifetime: TimeInterval = 86400

    // MARK: - Token Generation

    /// Generate a signed MapKit JS JWT token.
    static func generateToken() throws -> String {
        guard let teamID else {
            throw MapKitTokenError.missingEnvironmentVariable("MAPKIT_TEAM_ID")
        }
        guard let keyID else {
            throw MapKitTokenError.missingEnvironmentVariable("MAPKIT_KEY_ID")
        }
        guard let privateKeyPEM else {
            throw MapKitTokenError.missingEnvironmentVariable("MAPKIT_PRIVATE_KEY")
        }

        let now = Int(Date().timeIntervalSince1970)
        let exp = now + Int(tokenLifetime)

        // JWT Header
        let header = #"{"alg":"ES256","kid":"\#(keyID)","typ":"JWT"}"#

        // JWT Payload with origin restriction
        let payload = #"{"iss":"\#(teamID)","iat":\#(now),"exp":\#(exp),"origin":"https://mesh.digitaino.com"}"#

        // Base64url encode header and payload
        let headerB64 = base64urlEncode(Data(header.utf8))
        let payloadB64 = base64urlEncode(Data(payload.utf8))
        let signingInput = "\(headerB64).\(payloadB64)"

        // Sign with ES256
        let privateKey = try parsePrivateKey(pem: privateKeyPEM)
        let signature = try privateKey.signature(
            for: Data(signingInput.utf8)
        )

        // MapKit JS expects raw (r || s) signature format, not DER
        let signatureB64 = base64urlEncode(signature.rawRepresentation)

        return "\(signingInput).\(signatureB64)"
    }

    // MARK: - Private Helpers

    /// Parse the PEM-encoded P-256 private key.
    private static func parsePrivateKey(pem: String) throws -> P256.Signing.PrivateKey {
        // Strip PEM headers and whitespace to get raw base64.
        // env_file passes literal "\n" (two chars), so replace those too.
        let stripped = pem
            .replacingOccurrences(of: "\\n", with: "\n")
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
    case missingEnvironmentVariable(String)
}
