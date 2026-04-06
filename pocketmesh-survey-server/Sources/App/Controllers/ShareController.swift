import Fluent
import Vapor
import Foundation

struct ShareController {

    // MARK: - Base62 Short ID Generation

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

    private static let base62Chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    private static let shortIDLength = 7

    /// Generate a random base62 short ID (e.g., "a3Kx9mP").
    private static func generateShortID() -> String {
        String((0..<shortIDLength).map { _ in base62Chars.randomElement()! })
    }

    /// Generate a unique short ID that doesn't collide with existing records.
    private static func uniqueShortID<T: Model>(for modelType: T.Type, on db: Database) async throws -> String where T.IDValue == String {
        for _ in 0..<10 {
            let candidate = generateShortID()
            let existing = try await modelType.find(candidate, on: db)
            if existing == nil { return candidate }
        }
        // Extremely unlikely — 62^7 ≈ 3.5 trillion combinations
        throw Abort(.internalServerError, reason: "Failed to generate unique ID")
    }

    // MARK: - POST /api/v1/routes

    @Sendable
    func createRoute(req: Request) async throws -> CreateSharedRouteResponse {
        let payload = try req.content.decode(CreateSharedRouteRequest.self)

        guard payload.hopCount > 0 else {
            throw Abort(.badRequest, reason: "hopCount must be > 0")
        }
        guard !payload.hops.isEmpty else {
            throw Abort(.badRequest, reason: "hops array must not be empty")
        }
        guard payload.hops.count <= 20 else {
            throw Abort(.badRequest, reason: "Too many hops (max 20)")
        }

        // Validate coordinates
        for hop in payload.hops {
            if let lat = hop.latitude, let lon = hop.longitude {
                guard (-90...90).contains(lat), (-180...180).contains(lon) else {
                    throw Abort(.badRequest, reason: "Invalid coordinates for hop \(hop.hexID)")
                }
            }
        }

        let shortID = try await Self.uniqueShortID(for: SharedRoute.self, on: req.db)
        let now = ISO8601DateFormatter().string(from: Date())

        let encoder = JSONEncoder()
        let hopsData = try encoder.encode(payload.hops)
        let hopsJSON = String(data: hopsData, encoding: .utf8) ?? "[]"

        let route = SharedRoute(
            id: shortID,
            hopCount: payload.hopCount,
            distanceText: payload.distanceText,
            hopsJSON: hopsJSON,
            userLatitude: payload.userLatitude,
            userLongitude: payload.userLongitude,
            userName: payload.userName,
            createdAt: now
        )
        try await route.save(on: req.db)

        let baseURL = Environment.get("BASE_URL") ?? "https://mesh.digitaino.com"
        return CreateSharedRouteResponse(
            id: shortID,
            url: "\(baseURL)/r/\(shortID)"
        )
    }

    // MARK: - GET /api/v1/routes/:id

    @Sendable
    func getRoute(req: Request) async throws -> SharedRouteResponse {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing route ID")
        }

        guard let route = try await SharedRoute.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Route not found")
        }

        let hops: [SharedRouteHop]
        if let data = route.hopsJSON.data(using: .utf8) {
            hops = (try? JSONDecoder().decode([SharedRouteHop].self, from: data)) ?? []
        } else {
            hops = []
        }

        return SharedRouteResponse(
            id: route.id ?? id,
            hopCount: route.hopCount,
            distanceText: route.distanceText,
            hops: hops,
            userLatitude: route.userLatitude,
            userLongitude: route.userLongitude,
            userName: route.userName,
            createdAt: route.createdAt
        )
    }

    // MARK: - POST /api/v1/maps

    @Sendable
    func createRepeaterMap(req: Request) async throws -> CreateSharedRepeaterMapResponse {
        let payload = try req.content.decode(CreateSharedRepeaterMapRequest.self)

        guard !payload.repeaters.isEmpty else {
            throw Abort(.badRequest, reason: "repeaters array must not be empty")
        }
        guard payload.repeaters.count <= 100 else {
            throw Abort(.badRequest, reason: "Too many repeaters (max 100)")
        }

        // Validate coordinates
        for repeater in payload.repeaters {
            if let lat = repeater.latitude, let lon = repeater.longitude {
                guard (-90...90).contains(lat), (-180...180).contains(lon) else {
                    throw Abort(.badRequest, reason: "Invalid coordinates for repeater \(repeater.hexID)")
                }
            }
        }

        let shortID = try await Self.uniqueShortID(for: SharedRepeaterMap.self, on: req.db)
        let now = ISO8601DateFormatter().string(from: Date())

        let encoder = JSONEncoder()
        let repeatersData = try encoder.encode(payload.repeaters)
        let repeatersJSON = String(data: repeatersData, encoding: .utf8) ?? "[]"

        var pathsJSON: String? = nil
        if let paths = payload.paths, !paths.isEmpty {
            let pathsData = try encoder.encode(paths)
            pathsJSON = String(data: pathsData, encoding: .utf8)
        }

        let map = SharedRepeaterMap(
            id: shortID,
            repeaterCount: payload.repeaters.count,
            repeatersJSON: repeatersJSON,
            pathsJSON: pathsJSON,
            userLatitude: payload.userLatitude,
            userLongitude: payload.userLongitude,
            userName: payload.userName,
            createdAt: now
        )
        try await map.save(on: req.db)

        let baseURL = Environment.get("BASE_URL") ?? "https://mesh.digitaino.com"
        return CreateSharedRepeaterMapResponse(
            id: shortID,
            url: "\(baseURL)/m/\(shortID)"
        )
    }

    // MARK: - GET /api/v1/maps/:id

    @Sendable
    func getRepeaterMap(req: Request) async throws -> SharedRepeaterMapResponse {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing map ID")
        }

        guard let map = try await SharedRepeaterMap.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Map not found")
        }

        let repeaters: [SharedRepeaterInfo]
        if let data = map.repeatersJSON.data(using: .utf8) {
            repeaters = (try? JSONDecoder().decode([SharedRepeaterInfo].self, from: data)) ?? []
        } else {
            repeaters = []
        }

        let paths: [SharedRepeatPath]?
        if let pathsStr = map.pathsJSON, let data = pathsStr.data(using: .utf8) {
            paths = try? JSONDecoder().decode([SharedRepeatPath].self, from: data)
        } else {
            paths = nil
        }

        return SharedRepeaterMapResponse(
            id: map.id ?? id,
            repeaterCount: map.repeaterCount,
            repeaters: repeaters,
            paths: paths,
            userLatitude: map.userLatitude,
            userLongitude: map.userLongitude,
            userName: map.userName,
            createdAt: map.createdAt
        )
    }

    // MARK: - GET /r/:id — Serve route web page

    @Sendable
    func serveRoutePage(req: Request) async throws -> Response {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest)
        }

        guard let route = try await SharedRoute.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Route not found")
        }

        let hops: [SharedRouteHop]
        if let data = route.hopsJSON.data(using: .utf8) {
            hops = (try? JSONDecoder().decode([SharedRouteHop].self, from: data)) ?? []
        } else {
            hops = []
        }

        let hopsList = hops.map { $0.hexID }.joined(separator: ", ")
        let distanceHTML = route.distanceText.map { " · \($0)" } ?? ""
        let rawTitle = "\(route.hopCount) hop\(route.hopCount == 1 ? "" : "s") via \(hopsList)\(distanceHTML)"
        let title = Self.htmlEscape(rawTitle)

        // Encode route data as JSON for the page script
        let routeData = SharedRouteResponse(
            id: route.id ?? id,
            hopCount: route.hopCount,
            distanceText: route.distanceText,
            hops: hops,
            userLatitude: route.userLatitude,
            userLongitude: route.userLongitude,
            userName: route.userName,
            createdAt: route.createdAt
        )
        let encoder = JSONEncoder()
        let routeJSON = String(data: try encoder.encode(routeData), encoding: .utf8) ?? "{}"

        let html = Self.routePageHTML(title: title, routeJSON: routeJSON)
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/html; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(string: html))
    }

    // MARK: - GET /m/:id — Serve repeater map web page

    @Sendable
    func serveRepeaterMapPage(req: Request) async throws -> Response {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest)
        }

        guard let map = try await SharedRepeaterMap.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Map not found")
        }

        let repeaters: [SharedRepeaterInfo]
        if let data = map.repeatersJSON.data(using: .utf8) {
            repeaters = (try? JSONDecoder().decode([SharedRepeaterInfo].self, from: data)) ?? []
        } else {
            repeaters = []
        }

        let paths: [SharedRepeatPath]?
        if let pathsStr = map.pathsJSON, let data = pathsStr.data(using: .utf8) {
            paths = try? JSONDecoder().decode([SharedRepeatPath].self, from: data)
        } else {
            paths = nil
        }

        let title = Self.htmlEscape("\(map.repeaterCount) repeater\(map.repeaterCount == 1 ? "" : "s") heard")

        let mapData = SharedRepeaterMapResponse(
            id: map.id ?? id,
            repeaterCount: map.repeaterCount,
            repeaters: repeaters,
            paths: paths,
            userLatitude: map.userLatitude,
            userLongitude: map.userLongitude,
            userName: map.userName,
            createdAt: map.createdAt
        )
        let encoder = JSONEncoder()
        let mapJSON = String(data: try encoder.encode(mapData), encoding: .utf8) ?? "{}"

        let html = Self.repeaterMapPageHTML(title: title, mapJSON: mapJSON)
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/html; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(string: html))
    }

    // MARK: - GET /api/v1/admin/shared-links

    @Sendable
    func getAdminSharedLinks(req: Request) async throws -> AdminSharedLinksResponse {
        let routes = try await SharedRoute.query(on: req.db).all()
        let maps = try await SharedRepeaterMap.query(on: req.db).all()
        let paths = try await SharedPath.query(on: req.db).all()

        var links: [AdminSharedLinkInfo] = []

        for route in routes {
            links.append(AdminSharedLinkInfo(
                id: route.id ?? "",
                type: "route",
                userName: route.userName,
                itemCount: route.hopCount,
                distanceText: route.distanceText,
                createdAt: route.createdAt
            ))
        }

        for map in maps {
            links.append(AdminSharedLinkInfo(
                id: map.id ?? "",
                type: "map",
                userName: map.userName,
                itemCount: map.repeaterCount,
                distanceText: nil,
                createdAt: map.createdAt
            ))
        }

        for path in paths {
            links.append(AdminSharedLinkInfo(
                id: path.id ?? "",
                type: "path",
                userName: path.userName,
                itemCount: path.hopCount,
                distanceText: nil,
                createdAt: path.createdAt
            ))
        }

        links.sort { $0.createdAt > $1.createdAt }

        return AdminSharedLinksResponse(links: links)
    }

    // MARK: - DELETE /api/v1/admin/shared-route/:id

    @Sendable
    func deleteSharedRoute(req: Request) async throws -> DeleteSharedLinkResponse {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing route ID")
        }
        guard let route = try await SharedRoute.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Shared route not found")
        }
        try await route.delete(on: req.db)
        return DeleteSharedLinkResponse(id: id, type: "route")
    }

    // MARK: - DELETE /api/v1/admin/shared-map/:id

    @Sendable
    func deleteSharedMap(req: Request) async throws -> DeleteSharedLinkResponse {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing map ID")
        }
        guard let map = try await SharedRepeaterMap.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Shared map not found")
        }
        try await map.delete(on: req.db)
        return DeleteSharedLinkResponse(id: id, type: "map")
    }

    // MARK: - POST /api/v1/paths

    @Sendable
    func createPath(req: Request) async throws -> CreateSharedPathResponse {
        let payload = try req.content.decode(CreateSharedPathRequest.self)

        guard !payload.hops.isEmpty else {
            throw Abort(.badRequest, reason: "hops array must not be empty")
        }
        guard payload.hops.count <= 20 else {
            throw Abort(.badRequest, reason: "Too many hops (max 20)")
        }

        // Validate coordinates
        for hop in payload.hops {
            if let lat = hop.latitude, let lon = hop.longitude {
                guard (-90...90).contains(lat), (-180...180).contains(lon) else {
                    throw Abort(.badRequest, reason: "Invalid coordinates for hop \(hop.hexID)")
                }
            }
        }

        // When the iOS client has already performed anchor-aware resolution (including
        // user corrections for ambiguous repeaters), trust the client's data as-is.
        // Only perform server-side resolution for web/public path creation.
        var resolvedHops = payload.hops
        if payload.clientResolved != true {
            // Server-side resolution: fill in missing locations from community repeater database.
            // The DB stores 4-char hex IDs (2 bytes from public key prefix), so we need to handle:
            // - Exact match: input hex == stored hex (e.g. "F1CE" == "F1CE")
            // - Prefix match: input is shorter and stored hex starts with it (e.g. "F1" matches "F1CE")
            // - Reverse prefix: input is longer and starts with stored hex (e.g. "F1CE3A" matches "F1CE")
            // - Public key prefix match: for 6+ char IDs, match against full public key
            let allRepeaters = try await RepeaterLocation.query(on: req.db)
                .group(.or) { group in
                    group.filter(\.$hidden == nil)
                    group.filter(\.$hidden == false)
                }
                .all()

            for i in 0..<resolvedHops.count {
                if resolvedHops[i].latitude == nil || resolvedHops[i].longitude == nil {
                    let hexID = resolvedHops[i].hexID.uppercased()

                    // Find best match: exact > prefix > reverse prefix > public key prefix
                    let match = allRepeaters.first { $0.hexID.uppercased() == hexID }
                        ?? allRepeaters.first { $0.hexID.uppercased().hasPrefix(hexID) }
                        ?? allRepeaters.first { hexID.hasPrefix($0.hexID.uppercased()) }
                        ?? (hexID.count >= 6
                            ? allRepeaters.first { ($0.publicKey ?? "").uppercased().hasPrefix(hexID) }
                            : nil)

                    if let repeater = match {
                        resolvedHops[i] = SharedRouteHop(
                            hexID: resolvedHops[i].hexID,
                            name: resolvedHops[i].name ?? repeater.name,
                            latitude: repeater.latitude,
                            longitude: repeater.longitude
                        )
                    }
                }
            }
        }

        let shortID = try await Self.uniqueShortID(for: SharedPath.self, on: req.db)
        let now = ISO8601DateFormatter().string(from: Date())

        let encoder = JSONEncoder()
        let hopsData = try encoder.encode(resolvedHops)
        let hopsJSON = String(data: hopsData, encoding: .utf8) ?? "[]"

        let path = SharedPath(
            id: shortID,
            hopCount: resolvedHops.count,
            hopsJSON: hopsJSON,
            userLatitude: payload.userLatitude,
            userLongitude: payload.userLongitude,
            userName: payload.userName,
            createdAt: now
        )
        try await path.save(on: req.db)

        let baseURL = Environment.get("BASE_URL") ?? "https://mesh.digitaino.com"
        return CreateSharedPathResponse(
            id: shortID,
            url: "\(baseURL)/p/\(shortID)"
        )
    }

    // MARK: - GET /api/v1/paths/:id

    @Sendable
    func getPath(req: Request) async throws -> SharedPathResponse {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing path ID")
        }

        guard let path = try await SharedPath.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Path not found")
        }

        let hops: [SharedRouteHop]
        if let data = path.hopsJSON.data(using: .utf8) {
            hops = (try? JSONDecoder().decode([SharedRouteHop].self, from: data)) ?? []
        } else {
            hops = []
        }

        return SharedPathResponse(
            id: path.id ?? id,
            hopCount: path.hopCount,
            hops: hops,
            userLatitude: path.userLatitude,
            userLongitude: path.userLongitude,
            userName: path.userName,
            createdAt: path.createdAt
        )
    }

    // MARK: - GET /p/:id — Serve path web page

    @Sendable
    func servePathPage(req: Request) async throws -> Response {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest)
        }

        guard let path = try await SharedPath.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Path not found")
        }

        let hops: [SharedRouteHop]
        if let data = path.hopsJSON.data(using: .utf8) {
            hops = (try? JSONDecoder().decode([SharedRouteHop].self, from: data)) ?? []
        } else {
            hops = []
        }

        let hopsList = hops.map { $0.hexID }.joined(separator: ", ")
        let rawTitle = "\(path.hopCount) hop\(path.hopCount == 1 ? "" : "s"): \(hopsList)"
        let title = Self.htmlEscape(rawTitle)

        let pathData = SharedPathResponse(
            id: path.id ?? id,
            hopCount: path.hopCount,
            hops: hops,
            userLatitude: path.userLatitude,
            userLongitude: path.userLongitude,
            userName: path.userName,
            createdAt: path.createdAt
        )
        let encoder = JSONEncoder()
        let pathJSON = String(data: try encoder.encode(pathData), encoding: .utf8) ?? "{}"

        let html = Self.pathPageHTML(title: title, pathJSON: pathJSON)
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/html; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(string: html))
    }

    // MARK: - GET /path — Path creator web page

    @Sendable
    func servePathCreatorPage(req: Request) async throws -> Response {
        let html = Self.pathCreatorPageHTML()
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/html; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(string: html))
    }

    // MARK: - POST /api/v1/public/paths — Public path creation (no API key, rate-limited)

    @Sendable
    func createPublicPath(req: Request) async throws -> CreateSharedPathResponse {
        // Reuse the same logic as authenticated createPath
        try await createPath(req: req)
    }

    // MARK: - DELETE /api/v1/admin/shared-path/:id

    @Sendable
    func deleteSharedPath(req: Request) async throws -> DeleteSharedLinkResponse {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing path ID")
        }
        guard let path = try await SharedPath.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Shared path not found")
        }
        try await path.delete(on: req.db)
        return DeleteSharedLinkResponse(id: id, type: "path")
    }

    // MARK: - HTML Templates

    private static func routePageHTML(title: String, routeJSON: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(title) — DigitainoMesh</title>
            <link rel="stylesheet" href="/style.css" />
            <link rel="stylesheet" href="/share.css" />
            <script>const SHARE_DATA = \(Self.jsonForScript(routeJSON)); const SHARE_TYPE = 'route';</script>
            <script src="/share.js"></script>
            <script src="https://cdn.apple-mapkit.com/mk/5.x.x/mapkit.core.js"
                    crossorigin async
                    data-callback="initShareMap"
                    data-libraries="map,annotations,overlays"></script>
        </head>
        <body>
            <div id="map"></div>
            <div id="share-panel">
                <div id="panel-header" onclick="togglePanel()">
                    <h2>Shared Route</h2><span id="panel-summary"></span>
                    <div style="display:flex;align-items:center;gap:8px">
                        <button id="cell-toggle" class="cell-toggle-btn active" onclick="event.stopPropagation();toggleCellOverlay()" title="Toggle community signal overlay">📶</button>
                        <span id="panel-toggle">▲</span>
                    </div>
                </div>
                <div id="panel-body">
                    <div id="route-summary"></div>
                    <div id="hop-list"></div>
                    <div class="share-footer">
                        Shared via <a href="https://mesh.digitaino.com">DigitainoMesh</a>
                    </div>
                </div>
            </div>
        </body>
        </html>
        """
    }

    private static func repeaterMapPageHTML(title: String, mapJSON: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(title) — DigitainoMesh</title>
            <link rel="stylesheet" href="/style.css" />
            <link rel="stylesheet" href="/share.css" />
            <script>const SHARE_DATA = \(Self.jsonForScript(mapJSON)); const SHARE_TYPE = 'repeaterMap';</script>
            <script src="/share.js"></script>
            <script src="https://cdn.apple-mapkit.com/mk/5.x.x/mapkit.core.js"
                    crossorigin async
                    data-callback="initShareMap"
                    data-libraries="map,annotations,overlays"></script>
        </head>
        <body>
            <div id="map"></div>
            <div id="share-panel">
                <div id="panel-header" onclick="togglePanel()">
                    <h2>Heard Repeaters</h2><span id="panel-summary"></span>
                    <div style="display:flex;align-items:center;gap:8px">
                        <button id="cell-toggle" class="cell-toggle-btn active" onclick="event.stopPropagation();toggleCellOverlay()" title="Toggle community signal overlay">📶</button>
                        <span id="panel-toggle">▲</span>
                    </div>
                </div>
                <div id="panel-body">
                    <div id="repeat-nav" style="display:none">
                        <button class="nav-btn" onclick="prevRepeat()">‹</button>
                        <span id="repeat-nav-label"></span>
                        <button class="nav-btn" onclick="nextRepeat()">›</button>
                    </div>
                    <div id="route-summary"></div>
                    <div id="hop-list"></div>
                    <div class="share-footer">
                        Shared via <a href="https://mesh.digitaino.com">DigitainoMesh</a>
                    </div>
                </div>
            </div>
        </body>
        </html>
        """
    }

    private static func pathPageHTML(title: String, pathJSON: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(title) — DigitainoMesh</title>
            <link rel="stylesheet" href="/style.css" />
            <link rel="stylesheet" href="/share.css" />
            <script>const SHARE_DATA = \(Self.jsonForScript(pathJSON)); const SHARE_TYPE = 'path';</script>
            <script src="/share.js"></script>
            <script src="https://cdn.apple-mapkit.com/mk/5.x.x/mapkit.core.js"
                    crossorigin async
                    data-callback="initShareMap"
                    data-libraries="map,annotations,overlays"></script>
        </head>
        <body>
            <div id="map"></div>
            <div id="share-panel">
                <div id="panel-header" onclick="togglePanel()">
                    <h2>Shared Path</h2><span id="panel-summary"></span>
                    <div style="display:flex;align-items:center;gap:8px">
                        <button id="cell-toggle" class="cell-toggle-btn active" onclick="event.stopPropagation();toggleCellOverlay()" title="Toggle community signal overlay">📶</button>
                        <span id="panel-toggle">▲</span>
                    </div>
                </div>
                <div id="panel-body">
                    <div id="route-summary"></div>
                    <div id="hop-list"></div>
                    <div class="share-footer">
                        Shared via <a href="https://mesh.digitaino.com">DigitainoMesh</a>
                    </div>
                </div>
            </div>
        </body>
        </html>
        """
    }

    private static func pathCreatorPageHTML() -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Path Map — DigitainoMesh</title>
            <link rel="stylesheet" href="/style.css" />
            <link rel="stylesheet" href="/share.css" />
            <style>
                #creator-panel {
                    position: fixed;
                    top: 16px;
                    left: 16px;
                    right: 16px;
                    max-width: 420px;
                    margin: 0 auto;
                    background: rgba(15, 15, 15, 0.92);
                    backdrop-filter: blur(20px);
                    -webkit-backdrop-filter: blur(20px);
                    border: 1px solid rgba(255, 255, 255, 0.1);
                    border-radius: 16px;
                    padding: 20px;
                    z-index: 1000;
                    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
                }
                #creator-panel h2 {
                    font-size: 16px;
                    font-weight: 600;
                    margin: 0 0 4px 0;
                    color: #fff;
                }
                #creator-panel .subtitle {
                    font-size: 12px;
                    color: #888;
                    margin-bottom: 14px;
                }
                #hex-input {
                    width: 100%;
                    padding: 10px 12px;
                    background: rgba(255, 255, 255, 0.06);
                    border: 1px solid rgba(255, 255, 255, 0.12);
                    border-radius: 8px;
                    color: #e5e5e5;
                    font-family: 'SF Mono', SFMono-Regular, Menlo, monospace;
                    font-size: 14px;
                    outline: none;
                    resize: vertical;
                    min-height: 48px;
                    text-transform: uppercase;
                }
                #hex-input::placeholder { color: #555; text-transform: none; }
                #hex-input:focus { border-color: rgba(34, 211, 238, 0.5); }
                .btn-row {
                    display: flex;
                    gap: 8px;
                    margin-top: 12px;
                }
                .btn {
                    flex: 1;
                    padding: 10px 16px;
                    border: none;
                    border-radius: 8px;
                    font-size: 14px;
                    font-weight: 600;
                    cursor: pointer;
                    transition: opacity 0.15s;
                }
                .btn:disabled { opacity: 0.4; cursor: not-allowed; }
                .btn-primary {
                    background: #22d3ee;
                    color: #000;
                }
                .btn-primary:hover:not(:disabled) { opacity: 0.85; }
                .btn-secondary {
                    background: rgba(255, 255, 255, 0.08);
                    border: 1px solid rgba(255, 255, 255, 0.12);
                    color: #e5e5e5;
                }
                .btn-secondary:hover:not(:disabled) { background: rgba(255, 255, 255, 0.15); }
                #status-msg {
                    margin-top: 10px;
                    font-size: 12px;
                    color: #888;
                    min-height: 18px;
                }
                #status-msg.error { color: #ef4444; }
                #status-msg.success { color: #22c55e; }
                #result-link {
                    display: none;
                    margin-top: 12px;
                    padding: 10px 12px;
                    background: rgba(34, 211, 238, 0.08);
                    border: 1px solid rgba(34, 211, 238, 0.25);
                    border-radius: 8px;
                }
                #result-link a {
                    color: #22d3ee;
                    text-decoration: none;
                    font-size: 13px;
                    word-break: break-all;
                }
                #result-link a:hover { text-decoration: underline; }
                #result-link .copy-hint {
                    font-size: 11px;
                    color: #666;
                    margin-top: 4px;
                }
                @media (max-width: 640px) {
                    #creator-panel { top: 8px; left: 8px; right: 8px; padding: 16px; }
                }
            </style>
        </head>
        <body>
            <div id="map" style="opacity:0.3"></div>
            <div id="creator-panel">
                <h2>Path Map</h2>
                <div class="subtitle">Enter hex IDs separated by commas or spaces to create a shareable path map.</div>
                <textarea id="hex-input" rows="2" placeholder="A3, 7F42, B5C9, DE"></textarea>
                <div class="btn-row">
                    <button class="btn btn-primary" id="generate-btn" disabled onclick="generatePath()">Generate Map</button>
                </div>
                <div id="status-msg"></div>
                <div id="result-link">
                    <a id="path-url" href="#" target="_blank"></a>
                    <div class="copy-hint" id="copy-hint">Click to open · link copied to clipboard</div>
                </div>
            </div>
            <script>
                const hexInput = document.getElementById('hex-input');
                const generateBtn = document.getElementById('generate-btn');
                const statusMsg = document.getElementById('status-msg');
                const resultLink = document.getElementById('result-link');
                const pathUrl = document.getElementById('path-url');

                // Validate input: 2+ hex tokens (2-64 hex chars each)
                function parseHexIDs(text) {
                    const tokens = text.trim().split(/[\\s,]+/).filter(t => t.length > 0);
                    const hexPattern = /^[0-9a-fA-F]+$/;
                    const valid = tokens.filter(t => hexPattern.test(t) && t.length >= 2 && t.length <= 64
                        && (t.length <= 6 || t.length === 64));
                    return valid.length >= 2 ? valid : null;
                }

                hexInput.addEventListener('input', function() {
                    const ids = parseHexIDs(this.value);
                    generateBtn.disabled = !ids;
                    // Hide previous result when editing
                    resultLink.style.display = 'none';
                    statusMsg.textContent = '';
                    statusMsg.className = '';
                });

                async function generatePath() {
                    const ids = parseHexIDs(hexInput.value);
                    if (!ids) return;

                    generateBtn.disabled = true;
                    statusMsg.textContent = 'Creating path map...';
                    statusMsg.className = '';
                    resultLink.style.display = 'none';

                    try {
                        const hops = ids.map(id => ({ hexID: id.toUpperCase() }));
                        const res = await fetch('/api/v1/public/paths', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({ hops: hops })
                        });

                        if (!res.ok) {
                            const err = await res.json().catch(() => ({}));
                            throw new Error(err.reason || 'Failed to create path');
                        }

                        const data = await res.json();
                        statusMsg.textContent = ids.length + ' hops · link created';
                        statusMsg.className = 'success';
                        pathUrl.href = data.url;
                        pathUrl.textContent = data.url;
                        resultLink.style.display = 'block';

                        // Copy to clipboard
                        if (navigator.clipboard) {
                            navigator.clipboard.writeText(data.url).catch(() => {});
                        }
                    } catch (e) {
                        statusMsg.textContent = e.message;
                        statusMsg.className = 'error';
                    } finally {
                        generateBtn.disabled = !parseHexIDs(hexInput.value);
                    }
                }

                // Allow Enter to submit (Shift+Enter for newline)
                hexInput.addEventListener('keydown', function(e) {
                    if (e.key === 'Enter' && !e.shiftKey) {
                        e.preventDefault();
                        if (!generateBtn.disabled) generatePath();
                    }
                });
            </script>
            <script src="https://cdn.apple-mapkit.com/mk/5.x.x/mapkit.core.js"
                    crossorigin async
                    data-callback="initCreatorMap"
                    data-libraries="map"></script>
            <script>
                // Minimal background map for visual appeal
                function initCreatorMap() {
                    mapkit.init({
                        authorizationCallback: function(done) {
                            fetch('/api/v1/mapkit-token')
                                .then(r => r.text()).then(t => done(t))
                                .catch(() => {});
                        }
                    });
                    new mapkit.Map('map', {
                        colorScheme: mapkit.Map.ColorSchemes.Dark,
                        mapType: mapkit.Map.MapTypes.MutedStandard,
                        showsCompass: mapkit.FeatureVisibility.Hidden,
                        showsZoomControl: false,
                        showsMapTypeControl: false,
                        isScrollEnabled: false,
                        isZoomEnabled: false,
                        isRotateEnabled: false,
                        center: new mapkit.Coordinate(30.27, -97.74),
                        cameraDistance: 200000
                    });
                }
            </script>
        </body>
        </html>
        """
    }
}
