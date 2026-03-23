import SwiftUI
import CoreLocation

/// Sheet that creates a web pairing session, displays the code,
/// and polls until the web user submits a polygon.
struct WebPairingSheet: View {
    @Bindable var viewModel: SignalSurveyViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var sessionCode: String?
    @State private var sessionURL: URL?
    @State private var errorMessage: String?
    @State private var isCreating = true
    @State private var pollingTask: Task<Void, Never>?

    private let planService = PlanSessionService()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if isCreating {
                    ProgressView("Creating session…")
                        .padding()
                } else if let error = errorMessage {
                    ContentUnavailableView {
                        Label("Connection Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                            .font(.caption)
                    } actions: {
                        Button("Retry") {
                            createSession()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if let code = sessionCode {
                    codeDisplay(code: code)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Draw on Web")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cleanup()
                        dismiss()
                    }
                }
            }
        }
        .task {
            createSession()
        }
        .onDisappear {
            cleanup()
        }
    }

    // MARK: - Code Display

    private func codeDisplay(code: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "display")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Open this link on any device\nand draw your survey area.")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Large code display
            Text(code)
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .tracking(6)
                .padding(.vertical, 8)

            // URL for sharing
            if let url = sessionURL {
                Text(url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            // Share button
            if let url = sessionURL {
                ShareLink(item: url) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            // Polling indicator
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for polygon…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Session Management

    private func createSession() {
        isCreating = true
        errorMessage = nil

        pollingTask?.cancel()
        pollingTask = Task {
            do {
                let info = try await planService.createSession()
                guard !Task.isCancelled else { return }

                sessionCode = info.code
                sessionURL = info.url
                isCreating = false

                // Start polling
                await pollForPolygon(code: info.code)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }

    private func pollForPolygon(code: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }

            do {
                if let vertices = try await planService.pollSession(code: code) {
                    guard !Task.isCancelled else { return }

                    // Convert to CLLocationCoordinate2D and send to view model
                    let coords = vertices.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    }

                    await MainActor.run {
                        viewModel.receiveWebPolygon(coords)
                        dismiss()
                    }
                    return
                }
            } catch is PlanSessionService.PlanSessionError {
                // Session expired
                await MainActor.run {
                    errorMessage = "Session expired. Please try again."
                    sessionCode = nil
                }
                return
            } catch {
                // Transient error, keep polling
                continue
            }
        }
    }

    private func cleanup() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}
