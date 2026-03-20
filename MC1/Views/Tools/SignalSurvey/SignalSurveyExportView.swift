import MC1Services
import SwiftUI

struct SignalSurveyExportView: View {
    let sessionID: UUID
    let dataStore: PersistenceStore?
    var deviceID: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var exportURL: URL?
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var isUploading = false
    @State private var uploadResult: String?
    @State private var uploadError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "square.and.arrow.up.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                if isGenerating {
                    ProgressView("Generating export...")
                } else if let exportURL {
                    VStack(spacing: 12) {
                        Text("Export ready")
                            .font(.headline)

                        Text("Anonymized grid data (~100m cells). No exact GPS, no sender identity, no message content.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        ShareLink(item: exportURL) {
                            Label("Share Survey Data", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)

                        Divider()
                            .padding(.vertical, 4)

                        // Community upload
                        if isUploading {
                            ProgressView("Uploading to community map...")
                        } else if let uploadResult {
                            Label(uploadResult, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.subheadline)
                        } else if let uploadError {
                            VStack(spacing: 6) {
                                Label(uploadError, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                                Button("Retry Upload") {
                                    Task { await uploadToCommunity() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        } else {
                            Button {
                                Task { await uploadToCommunity() }
                            } label: {
                                Label("Upload to Community Map", systemImage: "globe")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                } else {
                    VStack(spacing: 12) {
                        Text("Export Signal Survey")
                            .font(.headline)

                        Text("Generates anonymized, grid-aggregated JSON. No exact GPS coordinates, sender identities, or message content are included.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Button("Generate Export") {
                            Task { await generateExport() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 32)
            .navigationTitle("Export Survey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func generateExport() async {
        guard let dataStore else {
            errorMessage = "Data store not available."
            return
        }

        isGenerating = true
        defer { isGenerating = false }

        let url = await SurveyExportService.generateExport(
            sessionID: sessionID,
            dataStore: dataStore
        )

        if let url {
            exportURL = url
        } else {
            errorMessage = "No data to export or export failed."
        }
    }

    private func uploadToCommunity() async {
        guard let dataStore else {
            uploadError = "Data store not available."
            return
        }

        isUploading = true
        uploadError = nil
        uploadResult = nil
        defer { isUploading = false }

        do {
            // Fetch repeater contacts for resolution (best-effort)
            var repeaterContacts: [ContactDTO] = []
            if let deviceID {
                let allContacts = (try? await dataStore.fetchContacts(deviceID: deviceID)) ?? []
                repeaterContacts = allContacts.filter { $0.type == .repeater }
            }

            // Load stored probe data for dead zone reconstruction
            var probesSentPerCell: [String: Int] = [:]
            var deadZoneHexCoords: [(q: Int, r: Int)] = []
            if let deviceID {
                let sessions = try await dataStore.fetchSurveySessions(deviceID: deviceID)
                if let session = sessions.first(where: { $0.id == sessionID }),
                   let stored = session.probesSentPerCell, !stored.isEmpty {
                    probesSentPerCell = stored

                    // Derive dead zone coords: cells with probes sent but no survey point data
                    let pointCoords = try await dataStore.fetchSurveyPointCoordinates(sessionID: sessionID)
                    let dataCellKeys = Set(pointCoords.map { coord in
                        let hex = HexGrid.axialFromLatLon(
                            latitude: coord.latitude,
                            longitude: coord.longitude,
                            referenceLatitude: HexGrid.fixedReferenceLatitude(for: coord.latitude)
                        )
                        return hex.key
                    })
                    for (key, probes) in stored where probes > 0 && !dataCellKeys.contains(key) {
                        let parts = key.split(separator: "_")
                        if parts.count == 2, let q = Int(parts[0]), let r = Int(parts[1]) {
                            deadZoneHexCoords.append((q: q, r: r))
                        }
                    }
                }
            }

            let service = SurveyUploadService()
            let response = try await service.upload(
                sessionID: sessionID,
                dataStore: dataStore,
                repeaterContacts: repeaterContacts,
                probesSentPerCell: probesSentPerCell,
                deadZoneHexCoords: deadZoneHexCoords
            )
            uploadResult = "\(response.accepted) cells uploaded"
        } catch {
            uploadError = error.localizedDescription
        }
    }
}
