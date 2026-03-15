import MC1Services
import SwiftUI

struct SignalSurveyExportView: View {
    let sessionID: UUID
    let dataStore: PersistenceStore?

    @Environment(\.dismiss) private var dismiss
    @State private var exportURL: URL?
    @State private var isGenerating = false
    @State private var errorMessage: String?

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
}
