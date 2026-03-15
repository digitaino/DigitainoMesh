import Fluent
import FluentSQLiteDriver
import Vapor

func configure(_ app: Application) throws {
    // Serve static files from Public/
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // SQLite database (persistent file in data/ volume)
    app.databases.use(.sqlite(.file("data/survey.sqlite")), as: .sqlite)

    // Run migrations
    app.migrations.add(CreateSchema())
    try app.autoMigrate().wait()

    // Register routes
    try routes(app)
}
