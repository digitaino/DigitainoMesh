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

    // Authenticated endpoints
    let protected = api.grouped(APIKeyMiddleware())
    protected.post("survey", use: surveyController.uploadSurvey)
    protected.delete("contributor", ":contributorID", use: surveyController.deleteContributor)
    protected.post("admin", "fix-coordinates", use: surveyController.fixCellCoordinates)
    protected.post("admin", "normalize-repeaters", use: surveyController.normalizeRepeaters)

    // Authenticated shared link creation
    protected.post("routes", use: shareController.createRoute)
    protected.post("maps", use: shareController.createRepeaterMap)
}
