import SwiftUI

/// Wrapper that automatically re-verifies the contributor session if the auth
/// token has expired, then presents the route list once a valid token is available.
struct MySurveyRoutesSheet: View {
    @Environment(\.appState) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var authToken: String?
    @State private var isRenewing = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let authToken {
                MySurveyRoutesListView(authToken: authToken)
            } else if isRenewing {
                NavigationStack {
                    ProgressView("Renewing session…")
                        .navigationTitle("My Survey Routes")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { dismiss() }
                            }
                        }
                }
            } else if let errorMessage {
                NavigationStack {
                    ContentUnavailableView {
                        Label("Verification Failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") {
                            Task { await renewSession() }
                        }
                        Button("Dismiss", role: .cancel) { dismiss() }
                    }
                    .navigationTitle("My Survey Routes")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
            } else {
                ProgressView("Loading…")
            }
        }
        .task { await checkOrRenew() }
    }

    private func checkOrRenew() async {
        let service = ContributorVerificationService()
        if let token = service.getAuthToken() {
            authToken = token
        } else {
            await renewSession()
        }
    }

    private func renewSession() async {
        guard let settingsService = appState.services?.settingsService else {
            errorMessage = "Device not connected — connect to your radio first."
            return
        }

        isRenewing = true
        errorMessage = nil
        defer { isRenewing = false }

        do {
            let uploadService = SurveyUploadService()
            let contributorID = try await uploadService.getOrCreateContributorID()
            let verificationService = ContributorVerificationService()
            let result = try await verificationService.verify(
                settingsService: settingsService,
                contributorID: contributorID
            )

            guard result.verified else {
                errorMessage = "Verification failed."
                return
            }

            if let newID = result.newContributorID {
                await uploadService.updateContributorID(newID)
            }

            if let token = result.authToken {
                verificationService.storeAuthToken(token, expires: result.authTokenExpires)
                authToken = token
            } else {
                errorMessage = "Server did not issue a session token."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Route List Content

private struct MySurveyRoutesListView: View {
    let authToken: String

    @Environment(\.dismiss) private var dismiss
    @State private var routes: [ContributorSelfService.MySurveyRoute] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading routes…")
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") { Task { await loadRoutes() } }
                    }
                } else if routes.isEmpty {
                    ContentUnavailableView(
                        "No Survey Routes",
                        systemImage: "map",
                        description: Text("Upload a route from the route planner to see it here.")
                    )
                } else {
                    List(routes) { route in
                        routeRow(route)
                    }
                }
            }
            .navigationTitle("My Survey Routes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await loadRoutes() }
    }

    private func routeRow(_ route: ContributorSelfService.MySurveyRoute) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                statusBadge(route.status)
                Spacer()
                Text(route.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Label("\(route.completedCount)/\(route.waypointCount)", systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
                if route.skippedCount > 0 {
                    Text("\(route.skippedCount) skipped")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            HStack {
                Text(formatDate(route.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if route.planSessionCode != nil {
                    Label("Web", systemImage: "display")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Local", systemImage: "hand.draw")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusBadge(_ status: String) -> some View {
        let (label, color): (String, Color) = switch status {
        case "created": ("Created", .cyan)
        case "in_progress": ("In Progress", .yellow)
        case "completed": ("Completed", .green)
        case "abandoned": ("Abandoned", .red)
        default: (status.capitalized, .gray)
        }

        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func formatDate(_ iso8601: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso8601) else { return iso8601 }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }

    private func loadRoutes() async {
        isLoading = true
        errorMessage = nil
        do {
            let service = ContributorSelfService(authToken: authToken)
            routes = try await service.getMyRoutes()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
