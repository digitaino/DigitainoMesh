import Fluent
import FluentSQLiteDriver
import Vapor

func configure(_ app: Application) throws {
    // Access logging (Apache Combined Log Format style) — runs first so it wraps everything
    app.middleware.use(AccessLogMiddleware())

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
    app.migrations.add(AddProbesSent())
    try app.autoMigrate().wait()

    // Register routes
    try routes(app)
}
