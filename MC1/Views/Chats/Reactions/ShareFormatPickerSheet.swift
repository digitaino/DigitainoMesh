import SwiftUI

/// Format options when sharing routes or repeater maps
enum ShareFormat: String {
    case webLink
    case textOnly
}

/// Compact sheet presenting "Web Link" vs "Text Only" share format options.
struct ShareFormatPickerSheet: View {
    @Environment(\.appState) private var appState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("shareFormatDefault") private var defaultFormat = "webLink"
    @AppStorage("shareRepeatersEnabled") private var shareRepeatersEnabled = false

    /// Track whether the user has ever dismissed this nudge so we only show it once.
    @AppStorage("repeaterSharingNudgeDismissed") private var nudgeDismissed = false

    let onSelect: (ShareFormat) -> Void

    @State private var rememberChoice = false
    @State private var isEnablingSharing = false

    private var currentDefault: ShareFormat {
        ShareFormat(rawValue: defaultFormat) ?? .webLink
    }

    /// Show the nudge only when sharing is off and the user hasn't dismissed it before.
    private var showRepeaterNudge: Bool {
        !shareRepeatersEnabled && !nudgeDismissed
    }

    var body: some View {
        NavigationStack {
            List {
                if showRepeaterNudge {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "antenna.radiowaves.left.and.right.circle")
                                .font(.title2)
                                .foregroundStyle(.cyan)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Improve Shared Maps")
                                    .font(.subheadline.weight(.semibold))
                                Text("Share your repeater locations with the community to make maps and links more accurate for everyone.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button {
                            Task { await enableRepeaterSharing() }
                        } label: {
                            HStack {
                                Label("Enable Repeater Sharing", systemImage: "arrow.up.circle")
                                Spacer()
                                if isEnablingSharing {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(isEnablingSharing)
                    }
                }

                Section {
                    Button {
                        select(.webLink)
                    } label: {
                        formatRow(
                            icon: "globe",
                            title: "Web Link",
                            description: "Upload to server and generate a shareable URL",
                            isDefault: currentDefault == .webLink
                        )
                    }

                    Button {
                        select(.textOnly)
                    } label: {
                        formatRow(
                            icon: "text.quote",
                            title: "Text Only",
                            description: "Insert route description without uploading",
                            isDefault: currentDefault == .textOnly
                        )
                    }
                }

                Section {
                    Toggle("Remember my choice", isOn: $rememberChoice)
                } footer: {
                    Text("Sets the default for future shares. You can change it in Settings > Chats.")
                }
            }
            .navigationTitle("Share Format")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        let shouldDismissNudge = showRepeaterNudge
                        dismiss()
                        // Defer the @AppStorage write so it doesn't race with sheet dismissal
                        if shouldDismissNudge {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                nudgeDismissed = true
                            }
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func select(_ format: ShareFormat) {
        if rememberChoice {
            defaultFormat = format.rawValue
        }
        let shouldDismissNudge = showRepeaterNudge
        dismiss()
        onSelect(format)
        // Defer the @AppStorage write so it doesn't trigger a re-render during
        // sheet dismiss, which races with the parent presenting the next sheet.
        if shouldDismissNudge {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                nudgeDismissed = true
            }
        }
    }

    // MARK: - Enable Repeater Sharing

    private func enableRepeaterSharing() async {
        isEnablingSharing = true
        defer { isEnablingSharing = false }

        // Run verification first
        guard let settingsService = appState.services?.settingsService else {
            // No device connected — just enable the pref, verification will happen later
            shareRepeatersEnabled = true
            appState.updateRepeaterSharing()
            nudgeDismissed = true
            return
        }

        do {
            let uploadService = SurveyUploadService()
            let contributorID = try await uploadService.getOrCreateContributorID()
            let verificationService = ContributorVerificationService()
            let result = try await verificationService.verify(
                settingsService: settingsService,
                contributorID: contributorID
            )

            if result.verified {
                if let newID = result.newContributorID {
                    await uploadService.updateContributorID(newID)
                }
                if let token = result.authToken {
                    verificationService.storeAuthToken(token, expires: result.authTokenExpires)
                }
                UserDefaults.standard.set(true, forKey: "surveyContributorVerified")
                shareRepeatersEnabled = true
                appState.updateRepeaterSharing()
            }
        } catch {
            // Verification failed — enable anyway, it will retry when possible
            shareRepeatersEnabled = true
            appState.updateRepeaterSharing()
        }

        nudgeDismissed = true
    }

    private func formatRow(
        icon: String,
        title: String,
        description: String,
        isDefault: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body)
                    if isDefault {
                        Text("Default")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }
}
