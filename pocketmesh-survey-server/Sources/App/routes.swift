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
    let planController = PlanController()

    // --- Cache policies ---
    // Short (30s): viewport data that changes on survey upload
    let shortCached = api.grouped(CacheControlMiddleware(.shortLived))
    shortCached.get("cells", use: surveyController.getCells)
    shortCached.get("repeaters", use: surveyController.getRepeaters)

    // Medium (5 min): aggregate/slowly changing data
    let mediumCached = api.grouped(CacheControlMiddleware(.mediumLived))
    mediumCached.get("stats", use: surveyController.getStats)

    // MapKit token: cache privately for 30 min (tokens valid ~1 hour)
    api.grouped(CacheControlMiddleware(.custom(maxAge: 1800)))
        .get("mapkit-token", use: surveyController.getMapKitToken)

    // SSE: never cache
    api.grouped(CacheControlMiddleware(.noStore))
        .get("events", use: surveyController.sseEvents)

    // Shared link data: medium cache
    mediumCached.get("routes", ":id", use: shareController.getRoute)
    mediumCached.get("maps", ":id", use: shareController.getRepeaterMap)

    // Shared link web pages
    app.get("r", ":id", use: shareController.serveRoutePage)
    app.get("m", ":id", use: shareController.serveRepeaterMapPage)

    // Authenticated endpoints with stricter rate limit (10 requests per minute)
    // Write endpoints get no-store via the middleware (POST/PUT/DELETE are skipped anyway)
    let writeRateLimit = RateLimitStore(maxRequests: 10, windowSeconds: 60)
    let protected = api
        .grouped(CacheControlMiddleware(.noStore))
        .grouped(RateLimitMiddleware(store: writeRateLimit))
        .grouped(APIKeyMiddleware())
    protected.post("survey", use: surveyController.uploadSurvey)
    protected.delete("contributor", ":contributorID", use: surveyController.deleteContributor)
    protected.put("contributor", ":contributorID", "displayname", use: surveyController.updateDisplayName)
    protected.post("contributor", ":contributorID", "challenge", use: surveyController.requestChallenge)
    protected.post("contributor", ":contributorID", "verify", use: surveyController.verifyChallenge)
    protected.post("admin", "fix-coordinates", use: surveyController.fixCellCoordinates)
    protected.post("admin", "normalize-repeaters", use: surveyController.normalizeRepeaters)

    // Authenticated shared link creation
    protected.post("routes", use: shareController.createRoute)
    protected.post("maps", use: shareController.createRepeaterMap)

    // Plan session creation (authenticated)
    protected.post("plans", "sessions", use: planController.createSession)

    // Plan session polling and polygon submission (public — the code IS the auth)
    let planPublic = api.grouped(CacheControlMiddleware(.noStore))
    planPublic.get("plans", "sessions", ":code", use: planController.getSession)
    planPublic.put("plans", "sessions", ":code", "polygon", use: planController.submitPolygon)

    // Plan web pages
    app.get("plan", use: planController.servePlanPage)
    app.get("plan", ":code", use: planController.servePlanPage)

    // Admin dashboard (protected by Cloudflare Access at the network level)
    app.get("admin") { req -> Response in
        let adminPath = app.directory.publicDirectory + "admin.html"
        return try await req.fileio.asyncStreamFile(at: adminPath)
    }

    // Contributor self-service endpoints (authenticated by session token from verify)
    let selfService = api.grouped("me")
        .grouped(CacheControlMiddleware(.noStore))
        .grouped(ContributorAuthMiddleware())
    selfService.get("profile", use: surveyController.getMyProfile)
    selfService.get("contributions", use: surveyController.getMyContributions)
    selfService.put("displayname", use: surveyController.updateMyDisplayName)
    selfService.put("name-retroactive", use: surveyController.updateNameRetroactive)
    selfService.delete("data", use: surveyController.deleteMyData)

    // Admin API endpoints (no API key — protected by Cloudflare Access)
    let admin = api.grouped("admin").grouped(CacheControlMiddleware(.noStore))
    admin.get("contributors", use: surveyController.getContributors)
    admin.get("contributor", ":id", "sessions", use: surveyController.getContributorSessions)
    admin.delete("contributor", ":id", "session", ":sessionID", use: surveyController.deleteContributorSession)
    admin.get("uploads", use: surveyController.getUploads)
    admin.post("purge-bogus", use: surveyController.purgeBogusContributors)
    admin.put("contributor", ":id", "notes", use: surveyController.updateContributorNotes)
    admin.post("contributors", "merge", use: surveyController.mergeContributors)

    // Admin repeater management
    admin.get("repeaters", use: surveyController.getAdminRepeaters)
    admin.put("repeater", ":id", "hidden", use: surveyController.toggleRepeaterHidden)
    admin.put("repeater", ":id", "notes", use: surveyController.updateRepeaterNotes)
    admin.delete("repeater", ":id", use: surveyController.deleteRepeater)
}
