# Security Fix Instructions

Complete these steps **in order**. Each step includes the exact files to modify and what to change.

---

## Step 1: Rotate API Key & Move to .env File

### 1a. Create `.env` file

Create a new file at the project root called `.env` with a **new** API key (the old one is compromised since it was in a public repo):

```
SURVEY_API_KEY=<GENERATE_A_NEW_64_CHAR_HEX_KEY>
```

Generate the new key by running in Terminal:
```bash
openssl rand -hex 32
```

Paste the output as the value.

### 1b. Add `.env` to `.gitignore`

Edit `.gitignore` — add `.env` on a new line so it looks like:

```
data/
.env
```

### 1c. Update `docker-compose.yml`

Replace the hardcoded environment variable with an `env_file` reference. Change:

```yaml
version: '3.8'
services:
  survey-server:
    build: .
    ports:
      - "8420:8080"
    environment:
      - SURVEY_API_KEY=c94393f688d61a3c1193153f5bbe860ee57ca066a256bb812529ee199448ba83
    volumes:
      - ./data:/app/data
    restart: unless-stopped
```

To:

```yaml
version: '3.8'
services:
  survey-server:
    build: .
    ports:
      - "127.0.0.1:8420:8080"
    env_file:
      - .env
    volumes:
      - ./data:/app/data
    restart: unless-stopped
```

Note: the port binding also changed to `127.0.0.1:8420:8080` to only listen on localhost (fixes issue #8 from the audit — prevents LAN bypass of Cloudflare).

---

## Step 2: Remove Hardcoded MapKit Private Key

### 2a. Update `Sources/App/Utilities/MapKitTokenGenerator.swift`

Remove all three hardcoded fallback values. The env vars must be required, not optional with fallbacks. Replace the configuration section:

```swift
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
```

With:

```swift
private static let teamID = ProcessInfo.processInfo.environment["MAPKIT_TEAM_ID"]
private static let keyID = ProcessInfo.processInfo.environment["MAPKIT_KEY_ID"]
private static let privateKeyPEM = ProcessInfo.processInfo.environment["MAPKIT_PRIVATE_KEY"]
```

These are now all `String?` optionals.

### 2b. Update `generateToken()` to guard on missing config

Replace the `generateToken()` method:

```swift
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
```

Note two changes: (1) guards on all three env vars, (2) adds `"origin":"https://mesh.digitaino.com"` to the JWT payload.

### 2c. Update `parsePrivateKey` to accept a parameter

Change:

```swift
private static func parsePrivateKey() throws -> P256.Signing.PrivateKey {
    let stripped = privateKeyPEM
```

To:

```swift
private static func parsePrivateKey(pem: String) throws -> P256.Signing.PrivateKey {
    let stripped = pem
```

### 2d. Add new error case

Replace:

```swift
enum MapKitTokenError: Error {
    case invalidPrivateKey
}
```

With:

```swift
enum MapKitTokenError: Error {
    case invalidPrivateKey
    case missingEnvironmentVariable(String)
}
```

### 2e. Add MapKit credentials to `.env`

Append to the `.env` file you created in Step 1:

```
MAPKIT_TEAM_ID=RU9VTBSCM5
MAPKIT_KEY_ID=WST6ZA6HR2
MAPKIT_PRIVATE_KEY=-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQgmmZlBb7ZO2yB81lp\n4g9QEvqFARzy+IsA7ghKpbqZ6bCgCgYIKoZIzj0DAQehRANCAASXreeJuUazHvLa\nWisxttM50vyA01qemajQpmPEZygpyDvNcBak/tUGEmADgWJCqBZ3Ll5vZnos6BE5\nmIwt5RoH\n-----END PRIVATE KEY-----
```

**Important:** After these fixes are deployed, you should **rotate this MapKit key** in your Apple Developer account since it was exposed in the public repo. Replace the values in `.env` with the new credentials.

---

## Step 3: Scrub Git History

After committing steps 1 and 2, run BFG Repo Cleaner to remove the leaked secrets from all prior commits.

**This must be done from Terminal, not Xcode:**

```bash
# Install BFG if not already installed
brew install bfg

# From the project root
cd /Users/digitaino/Documents/PocketMesh/pocketmesh-survey-server

# Create a file listing the secret strings to scrub
cat > /tmp/secrets-to-scrub.txt << 'EOF'
c94393f688d61a3c1193153f5bbe860ee57ca066a256bb812529ee199448ba83
RU9VTBSCM5
WST6ZA6HR2
MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQgmmZlBb7ZO2yB81lp
mmZlBb7ZO2yB81lp4g9QEvqFARzy+IsA7ghKpbqZ6bCgCgYIKoZIzj0DAQehRANCAASXreeJuUazHvLaWisxttM50vyA01qemajQpmPEZygpyDvNcBak/tUGEmADgWJCqBZ3Ll5vZnos6BE5mIwt5RoH
EOF

# Run BFG to replace those strings in all history
bfg --replace-text /tmp/secrets-to-scrub.txt

# Clean up
git reflog expire --expire=now --all && git gc --prune=now --aggressive

# Force push to both remotes (required after history rewrite)
git push origin --force --all
git push upstream --force --all

# Clean up temp file
rm /tmp/secrets-to-scrub.txt
```

**Warning:** Force-pushing rewrites history for all collaborators. Coordinate with anyone else working on this repo.

---

## Step 5: Add Application-Level Rate Limiting

### 5a. Create `Sources/App/Middleware/RateLimitMiddleware.swift`

Create a new file with this content:

```swift
import Vapor
import Foundation

/// Simple in-memory rate limiter using a sliding window per IP address.
actor RateLimitStore {
    struct Entry {
        var timestamps: [Date]
    }

    private var entries: [String: Entry] = [:]
    private let maxRequests: Int
    private let windowSeconds: TimeInterval

    init(maxRequests: Int, windowSeconds: TimeInterval) {
        self.maxRequests = maxRequests
        self.windowSeconds = windowSeconds
    }

    /// Returns `true` if the request should be allowed, `false` if rate-limited.
    func allow(key: String) -> Bool {
        let now = Date()
        let cutoff = now.addingTimeInterval(-windowSeconds)

        var entry = entries[key] ?? Entry(timestamps: [])
        entry.timestamps = entry.timestamps.filter { $0 > cutoff }

        if entry.timestamps.count >= maxRequests {
            entries[key] = entry
            return false
        }

        entry.timestamps.append(now)
        entries[key] = entry
        return true
    }

    /// Periodic cleanup of expired entries to prevent memory growth.
    func cleanup() {
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        for (key, entry) in entries {
            let filtered = entry.timestamps.filter { $0 > cutoff }
            if filtered.isEmpty {
                entries.removeValue(forKey: key)
            } else {
                entries[key] = Entry(timestamps: filtered)
            }
        }
    }
}

struct RateLimitMiddleware: AsyncMiddleware {
    let store: RateLimitStore

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        // Use X-Forwarded-For (from Cloudflare) or fall back to peer address
        let clientIP = request.headers.first(name: "CF-Connecting-IP")
            ?? request.headers.first(name: "X-Forwarded-For")?.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces)
            ?? request.peerAddress?.description
            ?? "unknown"

        let allowed = await store.allow(key: clientIP)

        guard allowed else {
            throw Abort(.tooManyRequests, reason: "Rate limit exceeded. Try again later.")
        }

        return try await next.respond(to: request)
    }
}
```

### 5b. Register rate limit middleware in `Sources/App/configure.swift`

Add rate limit stores as properties and register middleware. Replace the entire file:

```swift
import Fluent
import FluentSQLiteDriver
import Vapor

func configure(_ app: Application) throws {
    // Serve static files from Public/
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // Rate limiting: public endpoints — 60 requests per minute per IP
    let publicRateLimit = RateLimitStore(maxRequests: 60, windowSeconds: 60)
    app.middleware.use(RateLimitMiddleware(store: publicRateLimit))

    // Allow large survey uploads (up to 10MB)
    app.routes.defaultMaxBodySize = "10mb"

    // SQLite database (persistent file in data/ volume)
    app.databases.use(.sqlite(.file("data/survey.sqlite")), as: .sqlite)

    // Run migrations
    app.migrations.add(CreateSchema())
    app.migrations.add(AddRepeaterLocations())
    app.migrations.add(AddSharedLinks())
    app.migrations.add(AddActivePassiveCounts())
    app.migrations.add(AddSessionTracking())
    app.migrations.add(AddRepeaterMapPaths())
    app.migrations.add(AddRepeaterMetrics())
    app.migrations.add(AddRepeaterLastHeard())
    app.migrations.add(AddRouteUserLocation())
    try app.autoMigrate().wait()

    // Register routes
    try routes(app)
}
```

### 5c. Add a stricter rate limit for upload/write endpoints in `Sources/App/routes.swift`

Replace the full file:

```swift
import Vapor

func routes(_ app: Application) throws {
    app.get { req -> Response in
        req.redirect(to: "/index.html")
    }

    let api = app.grouped("api", "v1")

    let surveyController = SurveyController()
    let shareController = ShareController()

    // Public endpoints (no auth)
    api.get("cells", use: surveyController.getCells)
    api.get("repeaters", use: surveyController.getRepeaters)
    api.get("stats", use: surveyController.getStats)
    api.get("mapkit-token", use: surveyController.getMapKitToken)
    api.get("events", use: surveyController.sseEvents)

    // Public shared link data endpoints
    api.get("routes", ":id", use: shareController.getRoute)
    api.get("maps", ":id", use: shareController.getRepeaterMap)

    // Public shared link web pages
    app.get("r", ":id", use: shareController.serveRoutePage)
    app.get("m", ":id", use: shareController.serveRepeaterMapPage)

    // Authenticated endpoints with stricter rate limit (10 requests per minute)
    let writeRateLimit = RateLimitStore(maxRequests: 10, windowSeconds: 60)
    let protected = api
        .grouped(RateLimitMiddleware(store: writeRateLimit))
        .grouped(APIKeyMiddleware())
    protected.post("survey", use: surveyController.uploadSurvey)
    protected.delete("contributor", ":contributorID", use: surveyController.deleteContributor)
    protected.post("admin", "fix-coordinates", use: surveyController.fixCellCoordinates)
    protected.post("admin", "normalize-repeaters", use: surveyController.normalizeRepeaters)

    // Authenticated shared link creation
    protected.post("routes", use: shareController.createRoute)
    protected.post("maps", use: shareController.createRepeaterMap)
}
```

---

## Step 6: Fix XSS in ShareController HTML Templates

### 6a. Add an HTML-escaping helper

Add this at the top of `Sources/App/Controllers/ShareController.swift`, inside the struct (e.g., right after the `base62Chars` line):

```swift
// MARK: - HTML Escaping

/// Escape a string for safe inclusion in HTML content and attributes.
private static func htmlEscape(_ string: String) -> String {
    string
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

/// Escape a JSON string for safe embedding inside an HTML <script> tag.
/// Prevents "</script>" injection and HTML entity edge cases.
private static func jsonForScript(_ json: String) -> String {
    json
        .replacingOccurrences(of: "</", with: "<\\/")
        .replacingOccurrences(of: "<!--", with: "<\\!--")
}
```

### 6b. Update `serveRoutePage` — escape the title

In the `serveRoutePage` method, change:

```swift
let hopsList = hops.map { $0.hexID }.joined(separator: ", ")
let distanceHTML = route.distanceText.map { " · \($0)" } ?? ""
let title = "\(route.hopCount) hop\(route.hopCount == 1 ? "" : "s") via \(hopsList)\(distanceHTML)"
```

To:

```swift
let hopsList = hops.map { $0.hexID }.joined(separator: ", ")
let distanceHTML = route.distanceText.map { " · \($0)" } ?? ""
let rawTitle = "\(route.hopCount) hop\(route.hopCount == 1 ? "" : "s") via \(hopsList)\(distanceHTML)"
let title = Self.htmlEscape(rawTitle)
```

### 6c. Update `routePageHTML` — escape the JSON in the script tag

In the `routePageHTML` method, change:

```swift
<script>const SHARE_DATA = \(routeJSON); const SHARE_TYPE = 'route';</script>
```

To:

```swift
<script>const SHARE_DATA = \(Self.jsonForScript(routeJSON)); const SHARE_TYPE = 'route';</script>
```

### 6d. Update `serveRepeaterMapPage` — escape the title

In the `serveRepeaterMapPage` method, change:

```swift
let title = "\(map.repeaterCount) repeater\(map.repeaterCount == 1 ? "" : "s") heard"
```

To:

```swift
let title = Self.htmlEscape("\(map.repeaterCount) repeater\(map.repeaterCount == 1 ? "" : "s") heard")
```

### 6e. Update `repeaterMapPageHTML` — escape the JSON in the script tag

In the `repeaterMapPageHTML` method, change:

```swift
<script>const SHARE_DATA = \(mapJSON); const SHARE_TYPE = 'repeaterMap';</script>
```

To:

```swift
<script>const SHARE_DATA = \(Self.jsonForScript(mapJSON)); const SHARE_TYPE = 'repeaterMap';</script>
```

---

## Post-Deploy Checklist

After deploying these changes:

1. **Update the iOS app** to use the new API key
2. **Rotate the MapKit key** in your Apple Developer account (the old one is public)
3. **Verify** the server starts and all endpoints work
4. **Test** a shared route page (`/r/...`) to confirm no rendering regressions
5. Consider adding Cloudflare WAF rate-limiting rules as an additional layer (Dashboard → Security → WAF → Rate limiting rules):
   - `/api/v1/survey` — 10 requests per minute per IP
   - `/api/v1/*` — 120 requests per minute per IP
   - `/api/v1/events` — 5 requests per minute per IP (SSE connections)
