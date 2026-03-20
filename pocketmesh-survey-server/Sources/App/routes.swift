import Vapor

func routes(_ app: Application) throws {
    // Serve index.html for the root path (FileMiddleware only handles /index.html)
    app.get { req -> Response in
        let indexPath = app.directory.publicDirectory + "index.html"
        return try await req.fileio.asyncStreamFile(at: indexPath)
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

    // Admin dashboard (protected by Cloudflare Access at the network level)
    app.get("admin") { req -> Response in
        let adminPath = app.directory.publicDirectory + "admin.html"
        return try await req.fileio.asyncStreamFile(at: adminPath)
    }

    // Admin API endpoints (no API key — protected by Cloudflare Access)
    let admin = api.grouped("admin")
    admin.get("contributors", use: surveyController.getContributors)
    admin.get("contributor", ":id", "sessions", use: surveyController.getContributorSessions)
    admin.delete("contributor", ":id", "session", ":sessionID", use: surveyController.deleteContributorSession)
    admin.get("uploads", use: surveyController.getUploads)
    admin.post("purge-bogus", use: surveyController.purgeBogusContributors)
}
