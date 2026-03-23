import Fluent
import Vapor
import Foundation

struct PlanController {

    // MARK: - Code Generation

    /// Characters for plan session codes. Excludes I, L, O to avoid confusion with 1, l, 0.
    private static let codeChars = Array("0123456789ABCDEFGHJKMNPQRSTUVWXYZ")
    private static let codeLength = 6

    /// Generate a random 6-character alphanumeric code.
    private static func generateCode() -> String {
        String((0..<codeLength).map { _ in codeChars.randomElement()! })
    }

    /// Generate a unique code that doesn't collide with existing sessions.
    private static func uniqueCode(on db: Database) async throws -> String {
        for _ in 0..<10 {
            let candidate = generateCode()
            let existing = try await PlanSession.find(candidate, on: db)
            if existing == nil { return candidate }
        }
        throw Abort(.internalServerError, reason: "Failed to generate unique code")
    }

    // MARK: - HTML Escaping

    private static func jsonForScript(_ json: String) -> String {
        json
            .replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "<!--", with: "<\\!--")
    }

    // MARK: - POST /api/v1/plans/sessions

    @Sendable
    func createSession(req: Request) async throws -> CreatePlanSessionResponse {
        // Clean up expired sessions opportunistically
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        let nowString = isoFormatter.string(from: now)
        try await PlanSession.query(on: req.db)
            .filter(\.$expiresAt < nowString)
            .delete()

        let code = try await Self.uniqueCode(on: req.db)
        let expiresAt = now.addingTimeInterval(3600) // 1 hour

        let session = PlanSession(
            id: code,
            status: "waiting",
            createdAt: isoFormatter.string(from: now),
            expiresAt: isoFormatter.string(from: expiresAt)
        )
        try await session.save(on: req.db)

        let baseURL = Environment.get("BASE_URL") ?? "https://mesh.digitaino.com"
        return CreatePlanSessionResponse(
            code: code,
            url: "\(baseURL)/plan/\(code)",
            expiresAt: isoFormatter.string(from: expiresAt)
        )
    }

    // MARK: - GET /api/v1/plans/sessions/:code

    @Sendable
    func getSession(req: Request) async throws -> PlanSessionResponse {
        guard let code = req.parameters.get("code") else {
            throw Abort(.badRequest, reason: "Missing session code")
        }

        guard let session = try await PlanSession.find(code, on: req.db) else {
            throw Abort(.notFound, reason: "Session not found")
        }

        // Check expiry
        let isoFormatter = ISO8601DateFormatter()
        if let expiresAt = isoFormatter.date(from: session.expiresAt), expiresAt < Date() {
            try await session.delete(on: req.db)
            throw Abort(.gone, reason: "Session expired")
        }

        let polygon: [PolygonVertex]?
        if let json = session.polygonJSON, let data = json.data(using: .utf8) {
            polygon = try? JSONDecoder().decode([PolygonVertex].self, from: data)
        } else {
            polygon = nil
        }

        return PlanSessionResponse(
            code: session.id ?? code,
            status: session.status,
            polygon: polygon
        )
    }

    // MARK: - PUT /api/v1/plans/sessions/:code/polygon

    @Sendable
    func submitPolygon(req: Request) async throws -> SubmitPolygonResponse {
        guard let code = req.parameters.get("code") else {
            throw Abort(.badRequest, reason: "Missing session code")
        }

        let payload = try req.content.decode(SubmitPolygonRequest.self)

        guard payload.polygon.count >= 3 else {
            throw Abort(.badRequest, reason: "Polygon must have at least 3 vertices")
        }
        guard payload.polygon.count <= 50 else {
            throw Abort(.badRequest, reason: "Too many vertices (max 50)")
        }

        // Validate coordinates
        for vertex in payload.polygon {
            guard (-90...90).contains(vertex.latitude), (-180...180).contains(vertex.longitude) else {
                throw Abort(.badRequest, reason: "Invalid coordinates")
            }
        }

        guard let session = try await PlanSession.find(code, on: req.db) else {
            throw Abort(.notFound, reason: "Session not found")
        }

        // Check expiry
        let isoFormatter = ISO8601DateFormatter()
        if let expiresAt = isoFormatter.date(from: session.expiresAt), expiresAt < Date() {
            try await session.delete(on: req.db)
            throw Abort(.gone, reason: "Session expired")
        }

        guard session.status == "waiting" else {
            throw Abort(.conflict, reason: "Polygon already submitted")
        }

        let encoder = JSONEncoder()
        let polygonData = try encoder.encode(payload.polygon)
        session.polygonJSON = String(data: polygonData, encoding: .utf8)
        session.status = "submitted"
        try await session.save(on: req.db)

        return SubmitPolygonResponse(status: "submitted")
    }

    // MARK: - GET /api/v1/admin/plan-sessions

    @Sendable
    func getAdminPlanSessions(req: Request) async throws -> AdminPlanSessionsResponse {
        let sessions = try await PlanSession.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .all()

        let now = Date()
        let isoFormatter = ISO8601DateFormatter()

        let infos = sessions.map { session -> AdminPlanSessionInfo in
            let vertexCount: Int?
            if let json = session.polygonJSON, let data = json.data(using: .utf8),
               let vertices = try? JSONDecoder().decode([PolygonVertex].self, from: data) {
                vertexCount = vertices.count
            } else {
                vertexCount = nil
            }

            let isExpired: Bool
            if let expiresAt = isoFormatter.date(from: session.expiresAt) {
                isExpired = expiresAt < now
            } else {
                isExpired = false
            }

            return AdminPlanSessionInfo(
                code: session.id ?? "",
                status: session.status,
                vertexCount: vertexCount,
                createdAt: session.createdAt,
                expiresAt: session.expiresAt,
                isExpired: isExpired
            )
        }

        return AdminPlanSessionsResponse(sessions: infos)
    }

    // MARK: - DELETE /api/v1/admin/plan-session/:code

    @Sendable
    func deletePlanSession(req: Request) async throws -> DeletePlanSessionResponse {
        guard let code = req.parameters.get("code") else {
            throw Abort(.badRequest, reason: "Missing session code")
        }
        guard let session = try await PlanSession.find(code, on: req.db) else {
            throw Abort(.notFound, reason: "Plan session not found")
        }
        try await session.delete(on: req.db)
        return DeletePlanSessionResponse(code: code)
    }

    // MARK: - GET /plan and /plan/:code — Serve web page

    @Sendable
    func servePlanPage(req: Request) async throws -> Response {
        let code = req.parameters.get("code") ?? ""
        let html = Self.planPageHTML(code: code)
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/html; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(string: html))
    }

    // MARK: - HTML Template

    private static func planPageHTML(code: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Plan Survey Route — DigitainoMesh</title>
            <link rel="stylesheet" href="/style.css" />
            <link rel="stylesheet" href="/plan.css" />
            <script>const INITIAL_CODE = '\(Self.jsonForScript(code))';</script>
            <script src="/plan.js"></script>
            <script src="https://cdn.apple-mapkit.com/mk/5.x.x/mapkit.core.js"
                    crossorigin async
                    data-callback="initPlanMap"
                    data-libraries="map,annotations,overlays"></script>
        </head>
        <body>
            <div id="map"></div>
            <div id="plan-panel">
                <div id="code-entry" style="display:none">
                    <h2>Plan Survey Route</h2>
                    <p>Enter the code shown in PocketMesh to link this session.</p>
                    <div class="code-input-row">
                        <input type="text" id="code-input" maxlength="6" placeholder="ABC123" autocomplete="off" spellcheck="false" />
                        <button id="code-submit" onclick="submitCode()">Connect</button>
                    </div>
                    <div id="code-error" class="error-text"></div>
                </div>
                <div id="draw-mode" style="display:none">
                    <h2>Draw Survey Area</h2>
                    <p id="draw-instructions">Click on the map to place polygon corners. Close the polygon by clicking the first point or pressing Done.</p>
                    <div id="vertex-count"></div>
                    <div class="draw-controls">
                        <button class="draw-btn secondary" onclick="undoVertex()">Undo</button>
                        <button class="draw-btn secondary" onclick="clearPolygon()">Clear</button>
                        <button class="draw-btn primary" id="done-btn" onclick="finishPolygon()" disabled>Done</button>
                    </div>
                </div>
                <div id="send-mode" style="display:none">
                    <h2>Send to Device</h2>
                    <p id="send-summary"></p>
                    <div class="draw-controls">
                        <button class="draw-btn secondary" onclick="editPolygon()">Edit</button>
                        <button class="draw-btn primary" id="send-btn" onclick="sendPolygon()">Send to Device</button>
                    </div>
                    <div id="send-status"></div>
                </div>
                <div id="success-mode" style="display:none">
                    <h2>Sent!</h2>
                    <p>The survey area has been sent to your device. Return to PocketMesh to review your route.</p>
                </div>
                <div class="plan-footer">
                    <a href="https://mesh.digitaino.com">DigitainoMesh</a>
                </div>
            </div>
        </body>
        </html>
        """
    }
}
