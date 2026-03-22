import SwiftUI

/// Wrapper that automatically re-verifies the contributor session if the auth
/// token has expired, then presents `ContributorProfileView` once a valid
/// token is available.
struct ContributorProfileAutoRenewView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var authToken: String?
    @State private var isRenewing = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let authToken {
                ContributorProfileView(authToken: authToken)
            } else if isRenewing {
                NavigationStack {
                    ProgressView("Renewing session…")
                        .navigationTitle("My Contributions")
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
                    .navigationTitle("My Contributions")
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
