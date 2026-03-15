import Vapor

func routes(_ app: Application) throws {
    let api = app.grouped("api", "v1")

    let surveyController = SurveyController()

    // Public endpoints (no auth)
    api.get("cells", use: surveyController.getCells)
    api.get("stats", use: surveyController.getStats)

    // Authenticated endpoints
    let protected = api.grouped(APIKeyMiddleware())
    protected.post("survey", use: surveyController.uploadSurvey)
    protected.delete("contributor", ":contributorID", use: surveyController.deleteContributor)
}
