import MapKit
import MC1Services
import SwiftUI

/// Displays aggregated community signal survey data from the DigitainoMesh server.
struct CommunityMapView: View {
    @Environment(\.dismiss) private var dismiss

    /// Coverage filter for active/passive survey data.
    enum CoverageFilter: String, CaseIterable {
        case all = "All"
        case active = "Active"
        case passive = "Passive"
    }

    @State private var cells: [SurveyUploadService.CommunityCell] = []
    @State private var stats: SurveyUploadService.CommunityStats?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedCell: SurveyUploadService.CommunityCell?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showStats = true
    @State private var lastRegion: MKCoordinateRegion?
    @State private var refreshTask: Task<Void, Never>?
    @State private var coverageFilter: CoverageFilter = .all
    @State private var selectedRepeater: String?

    private let uploadService = SurveyUploadService()

    /// All unique repeater hex IDs from current cell data, consolidated by prefix.
    private var availableRepeaters: [String] {
        Self.consolidateHexIDs(cells.flatMap(\.repeaterHexIDs)).sorted()
    }

    /// Consolidates hex IDs that are prefixes of each other, keeping the longest version.
    /// Delegates to the canonical implementation in SurveyExportService.
    static func consolidateHexIDs(_ hexIDs: [String]) -> [String] {
        SurveyExportService.consolidateHexIDs(hexIDs)
    }

    /// Cells filtered by the active/passive coverage filter and repeater filter.
    private var filteredCells: [SurveyUploadService.CommunityCell] {
        var result: [SurveyUploadService.CommunityCell]
        switch coverageFilter {
        case .all: result = cells
        case .active: result = cells.filter { ($0.activePacketCount ?? 0) > 0 }
        case .passive: result = cells.filter { ($0.passivePacketCount ?? 0) > 0 }
        }
        if let repeater = selectedRepeater {
            let rf = repeater.uppercased()
            result = result.filter { cell in
                cell.repeaterHexIDs.contains { id in
                    let uid = id.uppercased()
                    return uid == rf || uid.hasPrefix(rf) || rf.hasPrefix(uid)
                }
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            ZStack {
                mapContent

                if isLoading && cells.isEmpty {
                    ProgressView("Loading community data...")
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }

                if let errorMessage, cells.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "globe.badge.chevron.backward")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task { await loadData() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                }

                VStack {
                    if showStats, let stats {
                        statsBar(stats)
                    }
                    Spacer()
                    if let selectedCell {
                        cellDetail(selectedCell)
                    }
                }
            }
            .navigationTitle("Community Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showStats.toggle()
                    } label: {
                        Image(systemName: showStats ? "chart.bar.fill" : "chart.bar")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    HStack(spacing: 8) {
                        Picker("Coverage", selection: $coverageFilter) {
                            ForEach(CoverageFilter.allCases, id: \.self) { filter in
                                Text(filter.rawValue).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 200)

                        repeaterMenu
                    }
                }
            }
            .task {
                await loadData()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                lastRegion = context.region
                Task { await loadCellsForRegion(context.region) }
            }
            .onAppear {
                // Auto-refresh every 15s so live uploads appear quickly
                refreshTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(15))
                        guard !Task.isCancelled, let region = lastRegion else { continue }
                        await loadCellsForRegion(region)
                    }
                }
            }
            .onDisappear {
                refreshTask?.cancel()
                refreshTask = nil
            }
        }
    }

    // MARK: - Repeater Filter Menu

    private var repeaterMenu: some View {
        Menu {
            Button {
                selectedRepeater = nil
            } label: {
                HStack {
                    Text("All Repeaters")
                    if selectedRepeater == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            ForEach(availableRepeaters, id: \.self) { hexID in
                Button {
                    selectedRepeater = hexID
                } label: {
                    HStack {
                        Text(hexID)
                        if selectedRepeater == hexID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                Text(selectedRepeater ?? "All")
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(selectedRepeater != nil ? .cyan : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(selectedRepeater != nil ? Color.cyan.opacity(0.15) : Color.secondary.opacity(0.1))
            )
        }
    }

    // MARK: - Map

    private var mapContent: some View {
        Map(position: $cameraPosition) {
            ForEach(filteredCells) { cell in
                let quality = SNRQuality(snr: cell.averageSNR)
                let vertices = HexGrid.vertices(
                    centerLatitude: cell.latitude,
                    centerLongitude: cell.longitude,
                    referenceLatitude: cell.referenceLatitude
                )

                MapPolygon(coordinates: vertices)
                    .foregroundStyle(
                        quality.color.opacity(
                            0.2 + 0.5 * min(1, Double(cell.contributionCount) / 5.0)
                        )
                    )
                    .stroke(quality.color.opacity(0.6), lineWidth: 0.5)

                Annotation("", coordinate: CLLocationCoordinate2D(
                    latitude: cell.latitude,
                    longitude: cell.longitude
                )) {
                    Color.clear
                        .frame(width: 60, height: 60)
                        .contentShape(.circle)
                        .onTapGesture {
                            if selectedCell?.id == cell.id {
                                selectedCell = nil
                            } else {
                                selectedCell = cell
                            }
                        }
                }
            }

            if let selected = selectedCell {
                let vertices = HexGrid.vertices(
                    centerLatitude: selected.latitude,
                    centerLongitude: selected.longitude,
                    referenceLatitude: selected.referenceLatitude
                )
                MapPolygon(coordinates: vertices)
                    .foregroundStyle(SNRQuality(snr: selected.averageSNR).color.opacity(0.5))
                    .stroke(Color.white, lineWidth: 3)
            }
        }
        .mapStyle(.standard)
    }

    // MARK: - Stats Bar

    private func statsBar(_ stats: SurveyUploadService.CommunityStats) -> some View {
        HStack(spacing: 16) {
            statItem(value: "\(stats.totalCells)", label: "Cells")
            statItem(value: "\(stats.totalContributions)", label: "Uploads")
            statItem(value: "\(stats.uniqueRepeaters)", label: "Repeaters")
            statItem(value: "\(stats.uniqueContributors)", label: "Users")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Signal Quality Bar

    private func signalQualityBar(quality: SNRQuality) -> some View {
        let level: Int = {
            switch quality {
            case .excellent: return 5
            case .good: return 4
            case .fair: return 3
            case .poor: return 2
            case .veryPoor: return 1
            case .unknown: return 0
            }
        }()

        return HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i <= level ? quality.color : Color.secondary.opacity(0.2))
                    .frame(width: 8, height: CGFloat(4 + i * 3))
            }
        }
    }

    // MARK: - Cell Detail

    private func cellDetail(_ cell: SurveyUploadService.CommunityCell) -> some View {
        let quality = SNRQuality(snr: cell.averageSNR)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label {
                    Text("Cell Detail")
                        .font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: "hexagon.fill")
                        .foregroundStyle(quality.color)
                }

                Spacer()

                signalQualityBar(quality: quality)

                Spacer()

                Button {
                    selectedCell = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    if let snr = cell.averageSNR {
                        Label(String(format: "%.1f dB SNR", snr), systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption)
                    }
                    Label("\(cell.packetCount) packets", systemImage: "number")
                        .font(.caption)
                    if let active = cell.activePacketCount, let passive = cell.passivePacketCount,
                       active > 0 || passive > 0 {
                        HStack(spacing: 6) {
                            if active > 0 {
                                Text("\(active) active")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                            if passive > 0 {
                                Text("\(passive) passive")
                                    .font(.caption2)
                                    .foregroundStyle(.yellow)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Label("\(cell.contributionCount) contributions", systemImage: "person.2")
                        .font(.caption)
                    if !cell.repeaterHexIDs.isEmpty {
                        Label("\(cell.repeaterHexIDs.count) repeater(s)", systemImage: "point.3.filled.connected.trianglepath.dotted")
                            .font(.caption)
                    }
                }
            }

            if !cell.repeaterHexIDs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(cell.repeaterHexIDs, id: \.self) { hexID in
                            Button {
                                if selectedRepeater == hexID {
                                    selectedRepeater = nil
                                } else {
                                    selectedRepeater = hexID
                                }
                            } label: {
                                Text(hexID)
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        selectedRepeater == hexID
                                            ? Color.cyan.opacity(0.35)
                                            : Color.cyan.opacity(0.15),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }

    // MARK: - Data Loading

    private func loadData() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            stats = try await uploadService.fetchStats()
        } catch {
            errorMessage = error.localizedDescription
        }

        // Load initial cells for a wide area
        do {
            let response = try await uploadService.fetchCommunityData(
                minLat: -90, maxLat: 90,
                minLon: -180, maxLon: 180,
                limit: 5000
            )
            cells = response.cells
        } catch {
            if errorMessage == nil {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadCellsForRegion(_ region: MKCoordinateRegion) async {
        let center = region.center
        let span = region.span
        let minLat = center.latitude - span.latitudeDelta / 2
        let maxLat = center.latitude + span.latitudeDelta / 2
        let minLon = center.longitude - span.longitudeDelta / 2
        let maxLon = center.longitude + span.longitudeDelta / 2

        do {
            let response = try await uploadService.fetchCommunityData(
                minLat: minLat, maxLat: maxLat,
                minLon: minLon, maxLon: maxLon
            )
            cells = response.cells
        } catch {
            // Silently fail for viewport updates — initial data still visible
        }
    }
}
