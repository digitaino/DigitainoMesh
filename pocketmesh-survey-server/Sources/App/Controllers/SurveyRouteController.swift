import Fluent
import Vapor
import Foundation

struct SurveyRouteController {

    // MARK: - ID Generation

    private static let idChars = Array("0123456789ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz")
    private static let idLength = 8

    private static func generateID() -> String {
        String((0..<idLength).map { _ in idChars.randomElement()! })
    }

    private static func uniqueID(on db: Database) async throws -> String {
        for _ in 0..<10 {
            let candidate = generateID()
            let existing = try await SurveyRoute.find(candidate, on: db)
            if existing == nil { return candidate }
        }
        throw Abort(.internalServerError, reason: "Failed to generate unique route ID")
    }

    // MARK: - POST /api/v1/survey-routes

    @Sendable
    func createRoute(req: Request) async throws -> CreateSurveyRouteResponse {
        let payload = try req.content.decode(CreateSurveyRouteRequest.self)

        guard payload.polygon.count >= 3 else {
            throw Abort(.badRequest, reason: "Polygon must have at least 3 vertices")
        }
        guard payload.waypointCount > 0 else {
            throw Abort(.badRequest, reason: "Waypoint count must be positive")
        }

        let id = try await Self.uniqueID(on: req.db)
        let now = ISO8601DateFormatter().string(from: Date())

        let encoder = JSONEncoder()
        let polygonData = try encoder.encode(payload.polygon)
        let polygonJSON = String(data: polygonData, encoding: .utf8) ?? "[]"

        let route = SurveyRoute(
            id: id,
            contributorID: payload.contributorID,
            polygonJSON: polygonJSON,
            waypointCount: payload.waypointCount,
            status: "created",
            excludedSurveyed: payload.excludedSurveyed,
            referenceLatitude: payload.referenceLatitude,
            planSessionCode: payload.planSessionCode,
            createdAt: now,
            updatedAt: now
        )
        try await route.save(on: req.db)

        return CreateSurveyRouteResponse(id: id, status: "created", createdAt: now)
    }

    // MARK: - PUT /api/v1/survey-routes/:id/status

    @Sendable
    func updateStatus(req: Request) async throws -> UpdateSurveyRouteStatusResponse {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing route ID")
        }

        let payload = try req.content.decode(UpdateSurveyRouteStatusRequest.self)

        let validStatuses = ["created", "in_progress", "completed", "abandoned"]
        guard validStatuses.contains(payload.status) else {
            throw Abort(.badRequest, reason: "Invalid status. Must be one of: \(validStatuses.joined(separator: ", "))")
        }

        guard let route = try await SurveyRoute.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Survey route not found")
        }

        let now = ISO8601DateFormatter().string(from: Date())
        route.status = payload.status
        route.updatedAt = now

        if let completedCount = payload.completedCount {
            route.completedCount = completedCount
        }
        if let skippedCount = payload.skippedCount {
            route.skippedCount = skippedCount
        }

        if payload.status == "in_progress" && route.startedAt == nil {
            route.startedAt = now
        }
        if payload.status == "completed" || payload.status == "abandoned" {
            route.finishedAt = now
        }

        try await route.save(on: req.db)

        return UpdateSurveyRouteStatusResponse(id: id, status: route.status, updatedAt: now)
    }

    // MARK: - GET /api/v1/survey-routes/:id

    @Sendable
    func getRoute(req: Request) async throws -> SurveyRouteResponse {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing route ID")
        }

        guard let route = try await SurveyRoute.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Survey route not found")
        }

        return SurveyRouteResponse(
            id: route.id ?? id,
            contributorID: route.contributorID,
            waypointCount: route.waypointCount,
            status: route.status,
            completedCount: route.completedCount,
            skippedCount: route.skippedCount,
            excludedSurveyed: route.excludedSurveyed,
            referenceLatitude: route.referenceLatitude,
            planSessionCode: route.planSessionCode,
            createdAt: route.createdAt,
            startedAt: route.startedAt,
            finishedAt: route.finishedAt,
            updatedAt: route.updatedAt
        )
    }

    // MARK: - GET /api/v1/admin/survey-routes

    @Sendable
    func getAdminRoutes(req: Request) async throws -> AdminSurveyRoutesResponse {
        let routes = try await SurveyRoute.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .all()

        let infos = routes.map { route -> AdminSurveyRouteInfo in
            let vertexCount: Int
            if let data = route.polygonJSON.data(using: .utf8),
               let vertices = try? JSONDecoder().decode([PolygonVertex].self, from: data) {
                vertexCount = vertices.count
            } else {
                vertexCount = 0
            }

            return AdminSurveyRouteInfo(
                id: route.id ?? "",
                contributorID: route.contributorID,
                waypointCount: route.waypointCount,
                status: route.status,
                completedCount: route.completedCount,
                skippedCount: route.skippedCount,
                planSessionCode: route.planSessionCode,
                createdAt: route.createdAt,
                startedAt: route.startedAt,
                finishedAt: route.finishedAt,
                updatedAt: route.updatedAt,
                notes: route.notes,
                vertexCount: vertexCount
            )
        }

        return AdminSurveyRoutesResponse(routes: infos)
    }

    // MARK: - PUT /api/v1/admin/survey-route/:id/notes

    @Sendable
    func updateNotes(req: Request) async throws -> UpdateSurveyRouteNotesResponse {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing route ID")
        }

        let payload = try req.content.decode(UpdateSurveyRouteNotesRequest.self)

        guard let route = try await SurveyRoute.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Survey route not found")
        }

        route.notes = payload.notes
        route.updatedAt = ISO8601DateFormatter().string(from: Date())
        try await route.save(on: req.db)

        return UpdateSurveyRouteNotesResponse(id: id, notes: payload.notes)
    }

    // MARK: - DELETE /api/v1/admin/survey-route/:id

    @Sendable
    func deleteRoute(req: Request) async throws -> DeleteSurveyRouteResponse {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing route ID")
        }

        guard let route = try await SurveyRoute.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Survey route not found")
        }

        try await route.delete(on: req.db)
        return DeleteSurveyRouteResponse(id: id)
    }
}
