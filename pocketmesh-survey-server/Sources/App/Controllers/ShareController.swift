import Fluent
import Vapor
import Foundation

struct ShareController {

    // MARK: - Base62 Short ID Generation

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
        let title = "\(route.hopCount) hop\(route.hopCount == 1 ? "" : "s") via \(hopsList)\(distanceHTML)"

        // Encode route data as JSON for the page script
        let routeData = SharedRouteResponse(
            id: route.id ?? id,
            hopCount: route.hopCount,
            distanceText: route.distanceText,
            hops: hops,
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

        let title = "\(map.repeaterCount) repeater\(map.repeaterCount == 1 ? "" : "s") heard"

        let mapData = SharedRepeaterMapResponse(
            id: map.id ?? id,
            repeaterCount: map.repeaterCount,
            repeaters: repeaters,
            paths: paths,
            userLatitude: map.userLatitude,
            userLongitude: map.userLongitude,
            createdAt: map.createdAt
        )
        let encoder = JSONEncoder()
        let mapJSON = String(data: try encoder.encode(mapData), encoding: .utf8) ?? "{}"

        let html = Self.repeaterMapPageHTML(title: title, mapJSON: mapJSON)
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/html; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(string: html))
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
            <script>const SHARE_DATA = \(routeJSON); const SHARE_TYPE = 'route';</script>
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
                    <h2>Shared Route</h2>
                    <span id="panel-toggle">▲</span>
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
            <script>const SHARE_DATA = \(mapJSON); const SHARE_TYPE = 'repeaterMap';</script>
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
                    <h2>Heard Repeaters</h2>
                    <span id="panel-toggle">▲</span>
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
}
