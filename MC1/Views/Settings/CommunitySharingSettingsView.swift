import SwiftUI

/// Settings view for community map sharing preferences — repeater location sharing,
/// contributor identity, and verification.
struct CommunitySharingSettingsView: View {
    @Environment(\.appState) private var appState

    @AppStorage("shareRepeatersEnabled") private var shareRepeatersEnabled = false
    @AppStorage("surveyIncludeDisplayName") private var includeDisplayName = true
    @AppStorage("surveyContributorVerified") private var contributorVerified = false
    @AppStorage("surveyLiveUpload") private var liveUploadPref = false

    @State private var isVerifying = false
    @State private var verificationError: String?
    @State private var showingContributorProfile = false
    @State private var isManualSharing = false
    @State private var manualShareResult: String?
    @State private var hasValidToken = false

    var body: some View {
        List {
            // MARK: Repeater Sharing
            Section {
                Toggle("Share Repeater Locations", isOn: $shareRepeatersEnabled)

                if shareRepeatersEnabled {
                    Button {
                        Task { await manualShareRepeaters() }
                    } label: {
                        HStack {
                            Label("Share Now", systemImage: "arrow.up.circle")
                            Spacer()
                            if isManualSharing {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .disabled(isManualSharing)
                }

                if let result = manualShareResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Repeater Locations")
            } footer: {
                if shareRepeatersEnabled {
                    Text("Your known repeater locations are periodically shared with the community map while the app is open. This works independently of survey mode and requires verification.")
                } else {
                    Text("When enabled, your device's known repeater locations will be periodically shared with the community map to keep it up to date.")
                }
            }

            // MARK: Survey Upload
            Section {
                Toggle("Live Upload", isOn: $liveUploadPref)
            } header: {
                Text("Signal Survey")
            } footer: {
                if liveUploadPref {
                    Text("Each received packet during a survey will be uploaded to the community map in real time.")
                } else {
                    Text("Survey data stays on your device. You can export and upload to the community map after a session from the survey toolbar menu.")
                }
            }

            // MARK: Contributor Identity
            Section {
                Toggle("Include Contact Name", isOn: $includeDisplayName)
                if includeDisplayName {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(appState.connectedDevice?.nodeName ?? "Not connected")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Verified")
                        Spacer()
                        if isVerifying {
                            ProgressView()
                                .controlSize(.small)
                        } else if hasValidToken {
                            Label("Verified", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                                .font(.subheadline)
                        } else if contributorVerified {
                            // Token expired but was previously verified
                            if appState.connectedDevice != nil {
                                Button("Re-verify") {
                                    Task { await performVerification() }
                                }
                                .font(.subheadline)
                            } else {
                                Text("Session expired")
                                    .font(.subheadline)
                                    .foregroundStyle(.orange)
                            }
                        } else if appState.connectedDevice != nil {
                            Button("Verify Now") {
                                Task { await performVerification() }
                            }
                            .font(.subheadline)
                        } else {
                            Text("Connect device to verify")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let verificationError {
                        Text(verificationError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if contributorVerified || hasValidToken {
                        Button {
                            showingContributorProfile = true
                        } label: {
                            Label("My Contributions", systemImage: "person.crop.circle")
                        }
                        .font(.subheadline)
                    }
                }
            } header: {
                Text("Contributor Identity")
            } footer: {
                Text("Your contact name will appear on the community map. Verification uses your device's cryptographic key to prove identity. Anonymous by default.")
            }
        }
        .navigationTitle("Community Sharing")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Check actual token validity on appear
            refreshTokenState()
            // Auto-renew if previously verified but token expired
            if contributorVerified && !hasValidToken && appState.connectedDevice != nil {
                await performVerification()
            }
        }
        .onChange(of: shareRepeatersEnabled) { _, newValue in
            if newValue && !hasValidToken {
                Task {
                    await performVerification()
                    if !hasValidToken {
                        shareRepeatersEnabled = false
                    }
                    appState.updateRepeaterSharing()
                }
            } else {
                appState.updateRepeaterSharing()
            }
        }
        .sheet(isPresented: $showingContributorProfile) {
            ContributorProfileAutoRenewView()
        }
    }

    // MARK: - Token State

    private func refreshTokenState() {
        hasValidToken = ContributorVerificationService().getAuthToken() != nil
    }

    // MARK: - Verification

    private func performVerification() async {
        guard let settingsService = appState.services?.settingsService else {
            verificationError = "Device not connected"
            return
        }

        isVerifying = true
        verificationError = nil
        defer {
            isVerifying = false
            refreshTokenState()
        }

        do {
            let uploadService = SurveyUploadService()
            let contributorID = try await uploadService.getOrCreateContributorID()
            let verificationService = ContributorVerificationService()
            let result = try await verificationService.verify(
                settingsService: settingsService,
                contributorID: contributorID
            )
            contributorVerified = result.verified
            if !result.verified {
                verificationError = "Verification failed"
            } else {
                if let newID = result.newContributorID {
                    await uploadService.updateContributorID(newID)
                }
                if let token = result.authToken {
                    verificationService.storeAuthToken(
                        token, expires: result.authTokenExpires
                    )
                }
            }
        } catch {
            verificationError = error.localizedDescription
        }
    }

    // MARK: - Manual Share

    private func manualShareRepeaters() async {
        isManualSharing = true
        manualShareResult = nil
        defer { isManualSharing = false }

        await appState.performRepeaterShareNow { result in
            manualShareResult = result
        }
    }
}
