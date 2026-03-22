import SwiftUI

/// Self-service view for contributors to manage their identity, display name,
/// and survey data. Requires an auth token from challenge-response verification.
struct ContributorProfileView: View {
    let authToken: String

    @Environment(\.dismiss) private var dismiss
    @State private var profile: ContributorSelfService.MyProfile?
    @State private var contributions: ContributorSelfService.MyContributions?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var editingName = ""
    @State private var isSavingName = false
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false
    @State private var nameRetroactive = false
    @State private var isSavingRetroactive = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading profile...")
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") { Task { await loadProfile() } }
                    }
                } else if let profile {
                    profileContent(profile)
                }
            }
            .navigationTitle("My Contributions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await loadProfile() }
    }

    @ViewBuilder
    private func profileContent(_ profile: ContributorSelfService.MyProfile) -> some View {
        List {
            // Identity Section
            Section("Identity") {
                HStack {
                    Text("Contributor ID")
                    Spacer()
                    Text(String(profile.contributorID.prefix(12)) + "...")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                if let legacy = profile.legacyUUID {
                    HStack {
                        Text("Previous ID")
                        Spacer()
                        Text(String(legacy.prefix(8)) + "...")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Verified")
                    Spacer()
                    if profile.verified {
                        Label("Verified", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.subheadline)
                    } else {
                        Text("Not verified")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                }
            }

            // Display Name Section
            Section {
                HStack {
                    TextField("Display Name", text: $editingName)
                        .textContentType(.name)
                    if isSavingName {
                        ProgressView()
                            .controlSize(.small)
                    } else if !editingName.isEmpty && editingName != (profile.displayName ?? "") {
                        Button("Save") {
                            Task { await saveName() }
                        }
                        .font(.subheadline)
                    }
                }

                if profile.displayName != nil {
                    Toggle("Show name on past contributions", isOn: $nameRetroactive)
                        .onChange(of: nameRetroactive) { _, newValue in
                            Task { await saveRetroactive(newValue) }
                        }
                        .disabled(isSavingRetroactive)
                }
            } header: {
                Text("Display Name")
            } footer: {
                Text("Your name appears on the community map for cells you surveyed. By default, it only shows on future contributions.")
            }

            // Stats Section
            Section("Statistics") {
                statsRow("Cells", value: "\(profile.cellCount)")
                statsRow("Uploads", value: "\(profile.uploadCount)")
                statsRow("Sessions", value: "\(profile.sessionCount)")
                if let firstSeen = profile.firstSeen {
                    statsRow("First Upload", value: formatDate(firstSeen))
                }
                if let lastSeen = profile.lastSeen {
                    statsRow("Last Upload", value: formatDate(lastSeen))
                }
            }

            // Sessions Section
            if let contributions, !contributions.sessions.isEmpty {
                Section("Sessions (\(contributions.sessions.count))") {
                    ForEach(contributions.sessions) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.sessionID == "unknown" ? "No Session ID" : String(session.sessionID.prefix(8)) + "...")
                                    .font(.caption.monospaced())
                                if let date = session.contributedAt {
                                    Text(formatDate(date))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(session.cellCount) cells")
                                    .font(.caption)
                                Text("\(session.packetCount) pkts")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            // Danger Zone
            Section {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    HStack {
                        Spacer()
                        if isDeleting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.red)
                            Text("Deleting...")
                        } else {
                            Label("Delete All My Data", systemImage: "trash")
                        }
                        Spacer()
                    }
                }
                .disabled(isDeleting)
            } footer: {
                Text("Permanently removes all your survey contributions, upload history, and profile. This cannot be undone.")
            }
        }
        .confirmationDialog(
            "Delete All Data?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) {
                Task { await deleteAllData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove all your survey contributions from the community map. This cannot be undone.")
        }
    }

    private func statsRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func formatDate(_ iso8601: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso8601) else { return iso8601 }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Actions

    private func loadProfile() async {
        isLoading = true
        errorMessage = nil
        do {
            let service = ContributorSelfService(authToken: authToken)
            async let profileResult = service.getMyProfile()
            async let contributionsResult = service.getMyContributions()
            let (p, c) = try await (profileResult, contributionsResult)
            profile = p
            contributions = c
            editingName = p.displayName ?? ""
            nameRetroactive = p.nameVisibleFrom == nil && p.displayName != nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func saveName() async {
        guard !editingName.isEmpty else { return }
        isSavingName = true
        do {
            let service = ContributorSelfService(authToken: authToken)
            try await service.updateDisplayName(editingName)
            profile = try await service.getMyProfile()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSavingName = false
    }

    private func saveRetroactive(_ applyToAll: Bool) async {
        isSavingRetroactive = true
        do {
            let service = ContributorSelfService(authToken: authToken)
            let newVisibleFrom = try await service.setNameRetroactive(applyToAll)
            if var p = profile {
                p = ContributorSelfService.MyProfile(
                    contributorID: p.contributorID,
                    legacyUUID: p.legacyUUID,
                    displayName: p.displayName,
                    nameVisibleFrom: newVisibleFrom,
                    verified: p.verified,
                    cellCount: p.cellCount,
                    uploadCount: p.uploadCount,
                    sessionCount: p.sessionCount,
                    firstSeen: p.firstSeen,
                    lastSeen: p.lastSeen
                )
                profile = p
            }
        } catch {
            // Revert toggle
            nameRetroactive.toggle()
            errorMessage = error.localizedDescription
        }
        isSavingRetroactive = false
    }

    private func deleteAllData() async {
        isDeleting = true
        do {
            let service = ContributorSelfService(authToken: authToken)
            _ = try await service.deleteMyData()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isDeleting = false
    }
}
