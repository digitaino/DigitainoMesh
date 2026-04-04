import MC1Services
import SwiftUI

/// Summary sheet shown after stopping a survey session, displaying
/// session stats, coverage breakdown, repeater info, and community map impact.
/// When upload parameters are provided, includes an inline "Upload to Community"
/// button so the user can upload in one tap without extra screens.
struct SurveyCompletionSheet: View {
    let stats: SignalSurveyViewModel.SurveyCompletionStats
    let resolveRepeater: (String) -> String
    var personalRecords: SignalSurveyViewModel.PersonalRecords?

    // Optional upload parameters — when provided, shows inline upload button
    var sessionID: UUID?
    var dataStore: PersistenceStore?
    var deviceID: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var isUploading = false
    @State private var uploadResult: String?
    @State private var uploadError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sessionOverviewSection
                    coverageBreakdownSection
                    if stats.totalUniqueRepeaters > 0 {
                        repeaterStatsSection
                    }
                    if let impact = stats.communityImpact {
                        communityImpactSection(impact)
                    }
                    if sessionID != nil, dataStore != nil {
                        uploadSection
                    }
                }
                .padding()
            }
            .navigationTitle("Survey Complete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Session Overview

    private var sessionOverviewSection: some View {
        infoSection(icon: "clock", iconColor: .blue, title: "Session Overview") {
            statRow(label: "Duration", value: formatDuration(stats.duration), isRecord: personalRecords?.longestDuration == true)
            statRow(label: "Total Packets", value: "\(stats.totalPackets)", isRecord: personalRecords?.mostPackets == true)
            statRow(label: "Cells Logged", value: "\(stats.totalCells)", isRecord: personalRecords?.mostCells == true)
        }
    }

    // MARK: - Coverage Breakdown

    private var coverageBreakdownSection: some View {
        infoSection(icon: "map", iconColor: .green, title: "Coverage Breakdown") {
            coverageRow(label: "Connected (2-way)", count: stats.connectedCells, color: .green, icon: "checkmark.circle.fill", isRecord: personalRecords?.mostConnectedCells == true)
            coverageRow(label: "Mesh Reach", count: stats.meshReachCells, color: .cyan, icon: "arrow.triangle.branch")
            coverageRow(label: "Heard Only", count: stats.heardOnlyCells, color: .orange, icon: "ear.fill")
            if stats.deadZoneCells > 0 {
                coverageRow(label: "Dead Zones", count: stats.deadZoneCells, color: .gray, icon: "xmark.circle.fill")
            }
        }
    }

    // MARK: - Repeater Stats

    private var repeaterStatsSection: some View {
        infoSection(icon: "antenna.radiowaves.left.and.right", iconColor: .purple, title: "Repeater Stats") {
            statRow(label: "Unique Repeaters", value: "\(stats.totalUniqueRepeaters)", isRecord: personalRecords?.mostUniqueRepeaters == true)
            if let best = stats.bestCoverageRepeater {
                statRow(
                    label: "Most Packets",
                    value: "\(resolveRepeater(best.hexID)) — \(best.packetCount)"
                )
            }
            if let best = stats.bestConnectedRepeater {
                statRow(
                    label: "Most 2-Way Cells",
                    value: "\(resolveRepeater(best.hexID)) — \(best.connectedCellCount)"
                )
            }
        }
    }

    // MARK: - Community Map Impact

    private func communityImpactSection(_ impact: SignalSurveyViewModel.SurveyCompletionStats.CommunityImpact) -> some View {
        infoSection(icon: "globe.americas", iconColor: .cyan, title: "Community Map Impact") {
            if impact.newCells > 0 {
                statRow(label: "New Cells", value: "\(impact.newCells)", highlight: true)
            }
            if impact.updatedCells > 0 {
                statRow(label: "Updated Cells", value: "\(impact.updatedCells)")
            }
            if impact.newCells == 0, let age = impact.oldestUpdatedAge {
                statRow(label: "Oldest Cell Updated", value: formatAge(age))
            }
        }
    }

    // MARK: - Upload Section

    private var uploadSection: some View {
        infoSection(icon: "square.and.arrow.up", iconColor: .blue, title: "Community Upload") {
            if isUploading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Uploading...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if let uploadResult {
                Label(uploadResult, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            } else if let uploadError {
                VStack(alignment: .leading, spacing: 8) {
                    Label(uploadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Button("Retry") {
                        Task { await uploadToCommunity() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Share anonymized coverage data with the community map.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await uploadToCommunity() }
                    } label: {
                        Label("Upload to Community Map", systemImage: "globe")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
            }
        }
    }

    // MARK: - Upload Logic

    private func uploadToCommunity() async {
        guard let sessionID, let dataStore else { return }

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

    // MARK: - Helpers

    private func infoSection<Content: View>(
        icon: String,
        iconColor: Color,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title)
                    .font(.headline)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
            }

            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func statRow(label: String, value: String, highlight: Bool = false, isRecord: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if isRecord {
                recordBadge
            }
            Spacer()
            Text(value)
                .font(.subheadline.weight(highlight ? .bold : .medium))
                .foregroundStyle(highlight ? .green : .primary)
        }
    }

    private func coverageRow(label: String, count: Int, color: Color, icon: String, isRecord: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 16)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if isRecord {
                recordBadge
            }
            Spacer()
            Text("\(count)")
                .font(.subheadline.weight(.medium).monospacedDigit())
        }
    }

    private var recordBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "trophy.fill")
                .font(.caption2)
            Text("Record!")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.yellow)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }

    private func formatAge(_ seconds: TimeInterval) -> String {
        let days = Int(seconds) / 86400
        if days > 0 { return "\(days) day\(days == 1 ? "" : "s") ago" }
        let hours = Int(seconds) / 3600
        if hours > 0 { return "\(hours) hour\(hours == 1 ? "" : "s") ago" }
        return "recently"
    }
}
