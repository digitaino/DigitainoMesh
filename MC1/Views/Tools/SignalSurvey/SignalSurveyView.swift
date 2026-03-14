import MapKit
import MC1Services
import SwiftUI
import UIKit

struct SignalSurveyView: View {
    @Environment(\.appState) private var appState

    @State private var viewModel = SignalSurveyViewModel()
    @State private var showingSessionList = false
    @State private var showingExportSheet = false
    @AppStorage("surveyProbeEnabled") private var probeEnabledPref = false
    @Namespace private var mapScope

    var body: some View {
        ZStack {
            if viewModel.displayPoints.isEmpty && !viewModel.isActive {
                emptyState
            } else {
                mapContent
                statsOverlay
                bottomOverlay
            }
        }
        .mapScope(mapScope)
        .navigationTitle("Signal Survey")
        .toolbar { toolbarContent }
        .task(id: appState.servicesVersion) {
            guard let dataStore = appState.offlineDataStore,
                  let deviceID = appState.currentDeviceID else { return }
            await viewModel.loadSessions(dataStore: dataStore, deviceID: deviceID)
        }
        .sheet(isPresented: $showingSessionList) {
            sessionListSheet
        }
        .sheet(isPresented: $showingExportSheet) {
            if let sessionID = viewModel.selectedSessionID {
                SignalSurveyExportView(
                    sessionID: sessionID,
                    dataStore: appState.offlineDataStore
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.selectedCell != nil },
            set: { if !$0 { viewModel.selectedCell = nil } }
        )) {
            cellDetailSheet
        }
        .alert("Survey Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .onAppear { viewModel.probeEnabled = probeEnabledPref }
        .onChange(of: probeEnabledPref) { _, newValue in
            viewModel.probeEnabled = newValue
        }
        .onChange(of: viewModel.isActive) { _, isActive in
            UIApplication.shared.isIdleTimerDisabled = isActive
            appState.isSurveyActive = isActive
        }
        .onDisappear {
            // Sync state when navigating away (survey may still be running)
            appState.isSurveyActive = viewModel.isActive
        }
    }

    // MARK: - Map Content

    private var mapContent: some View {
        Map(position: $viewModel.cameraPosition, scope: mapScope) {
            switch viewModel.visualizationMode {
            case .pointCloud:
                ForEach(viewModel.displayPoints) { point in
                    Annotation("", coordinate: CLLocationCoordinate2D(
                        latitude: point.latitude,
                        longitude: point.longitude
                    )) {
                        Circle()
                            .fill(point.snrQuality.color.opacity(0.8))
                            .overlay {
                                Circle()
                                    .strokeBorder(point.snrQuality.color, lineWidth: 1)
                            }
                            .frame(width: 10, height: 10)
                    }
                }

            case .gridHeatmap:
                ForEach(viewModel.gridCells) { cell in
                    let isSelected = viewModel.selectedCell?.id == cell.id
                    MapPolygon(coordinates: cell.vertices)
                        .foregroundStyle(
                            cell.snrQuality.color.opacity(
                                0.2 + 0.5 * min(1, Double(cell.packetCount) / 10.0)
                            )
                        )
                        .stroke(
                            isSelected ? Color.white : cell.snrQuality.color.opacity(0.6),
                            lineWidth: isSelected ? 2 : 0.5
                        )

                    // Invisible tap target at cell center
                    Annotation("", coordinate: CLLocationCoordinate2D(
                        latitude: cell.centerLatitude,
                        longitude: cell.centerLongitude
                    )) {
                        Color.clear
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                            .onTapGesture {
                                if viewModel.selectedCell?.id == cell.id {
                                    viewModel.selectedCell = nil
                                } else {
                                    viewModel.selectedCell = cell
                                }
                            }
                    }
                }
            }

            UserAnnotation()
        }
        .mapStyle(viewModel.mapStyleSelection.mapStyle)
        .ignoresSafeArea()
    }

    // MARK: - Stats Overlay

    private var statsOverlay: some View {
        VStack {
            if viewModel.livePointCount > 0 || viewModel.isActive {
                HStack(spacing: 6) {
                    if viewModel.isActive {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                    }

                    if viewModel.livePointCount > 0 {
                        Text("\(viewModel.livePointCount) pts")
                            .font(.caption.weight(.medium))
                    }

                    if viewModel.isActive && viewModel.probeEnabled {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text("\(viewModel.probeCount)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .liquidGlass(in: .capsule)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .padding(.leading, 16)
    }

    // MARK: - Cell Detail Sheet

    private var cellDetailSheet: some View {
        VStack(spacing: 0) {
            if let cell = viewModel.selectedCell {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "cellularbars", variableValue: cell.snrQuality.barLevel)
                            .foregroundStyle(cell.snrQuality.color)
                            .font(.title2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(cell.snrQuality.qualityLabel)
                                .font(.headline)
                            Text("\(cell.packetCount) packet\(cell.packetCount == 1 ? "" : "s") received")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }

                    Divider()

                    HStack(spacing: 0) {
                        if let snr = cell.averageSNR {
                            cellStatColumn(label: "Avg SNR", value: String(format: "%.1f", snr), unit: "dB")
                        }
                        if let rssi = cell.averageRSSI {
                            cellStatColumn(label: "Avg RSSI", value: String(format: "%.0f", rssi), unit: "dBm")
                        }
                        if let minSNR = cell.minSNR, let maxSNR = cell.maxSNR {
                            cellStatColumn(label: "SNR Range", value: String(format: "%.0f – %.0f", minSNR, maxSNR), unit: "dB")
                        }
                        if let earliest = cell.earliestTimestamp, let latest = cell.latestTimestamp, earliest != latest {
                            let minutes = Int(latest.timeIntervalSince(earliest) / 60)
                            cellStatColumn(label: "Time Span", value: "\(minutes)", unit: "min")
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
        }
        .presentationDetents([.height(160)])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled)
        .presentationCornerRadius(16)
    }

    private func cellStatColumn(label: String, value: String, unit: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bottom Overlay

    private var bottomOverlay: some View {
        VStack(spacing: 0) {
            Spacer()

            // Probe toggle row (above toolbar)
            if viewModel.isActive {
                HStack {
                    Button {
                        probeEnabledPref.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: viewModel.probeEnabled
                                  ? "antenna.radiowaves.left.and.right"
                                  : "antenna.radiowaves.left.and.right.slash")
                                .font(.caption)
                                .foregroundStyle(viewModel.probeEnabled ? .green : .secondary)
                            Text(viewModel.probeEnabled
                                 ? "Probing (\(viewModel.probeCount))"
                                 : "Probe Off")
                                .font(.caption)
                                .foregroundStyle(viewModel.probeEnabled ? .green : .secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .liquidGlass(in: .capsule)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.leading, 16)
                .padding(.bottom, 4)
            }

            mapToolbar
        }
        .overlay(alignment: .bottomTrailing) {
            if viewModel.showingLayersMenu {
                LayersMenu(
                    selection: $viewModel.mapStyleSelection,
                    isPresented: $viewModel.showingLayersMenu
                )
                .padding(.trailing, 16)
                .padding(.bottom, 160)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: viewModel.showingLayersMenu)
    }

    // MARK: - Map Toolbar

    private var mapToolbar: some View {
        HStack {
            surveyToggleButton

            Spacer()

            MapControlsToolbar(
                mapScope: mapScope,
                showingLayersMenu: $viewModel.showingLayersMenu
            ) {
                // Visualization toggle
                Button {
                    viewModel.visualizationMode = viewModel.visualizationMode == .pointCloud
                        ? .gridHeatmap : .pointCloud
                } label: {
                    Image(systemName: viewModel.visualizationMode == .pointCloud
                          ? "square.grid.3x3.fill" : "circle.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Toggle visualization mode")

                // Center on data
                Button {
                    viewModel.centerOnData()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Center on survey data")
            }
        }
    }

    private var surveyToggleButton: some View {
        let isDisabled = appState.services?.surveyService == nil

        return Button {
            Task {
                if viewModel.isActive {
                    guard let service = appState.services?.surveyService else { return }
                    await viewModel.stopSurvey(
                        surveyService: service,
                        locationService: appState.locationService,
                        dataStore: appState.offlineDataStore,
                        deviceID: appState.currentDeviceID
                    )
                } else {
                    guard let service = appState.services?.surveyService else { return }
                    await viewModel.startSurvey(
                        surveyService: service,
                        locationService: appState.locationService,
                        binaryProtocolService: appState.services?.binaryProtocolService
                    )
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: viewModel.isActive
                      ? "stop.fill"
                      : isDisabled ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right")
                Text(viewModel.isActive
                     ? "Stop"
                     : isDisabled ? "Connect to Start" : "Start Survey")
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(
                viewModel.isActive
                ? Color.red
                : isDisabled ? Color.secondary : Color.accentColor
            )
            .clipShape(Capsule())
            .opacity(isDisabled ? 0.6 : 1.0)
        }
        .disabled(isDisabled)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    showingSessionList = true
                } label: {
                    Label("Sessions", systemImage: "list.bullet")
                }

                if viewModel.selectedSessionID != nil && !viewModel.isActive {
                    Button {
                        showingExportSheet = true
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }

                if !viewModel.sessions.isEmpty {
                    Divider()

                    Button {
                        guard let dataStore = appState.offlineDataStore,
                              let deviceID = appState.currentDeviceID else { return }
                        viewModel.selectedSessionID = nil
                        Task {
                            await viewModel.loadAllPoints(dataStore: dataStore, deviceID: deviceID)
                        }
                    } label: {
                        Label("All Sessions", systemImage: "map.fill")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Signal Survey", systemImage: "antenna.radiowaves.left.and.right")
        } description: {
            Text("Start a survey to record signal quality as you move. Each received packet will be tagged with your GPS location to build a coverage map.")
        } actions: {
            if appState.services?.surveyService != nil {
                Button("Start Survey") {
                    Task {
                        guard let service = appState.services?.surveyService else { return }
                        await viewModel.startSurvey(
                            surveyService: service,
                            locationService: appState.locationService,
                            binaryProtocolService: appState.services?.binaryProtocolService
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Connect a radio to start surveying")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !viewModel.sessions.isEmpty {
                Button("Browse Sessions") {
                    showingSessionList = true
                }
            }
        }
    }

    // MARK: - Session List Sheet

    private var sessionListSheet: some View {
        NavigationStack {
            Group {
                if viewModel.sessions.isEmpty {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text("Start a survey to create your first session.")
                    )
                } else {
                    List {
                        ForEach(viewModel.sessions) { session in
                            Button {
                                viewModel.selectedSessionID = session.id
                                if let dataStore = appState.offlineDataStore {
                                    Task {
                                        await viewModel.loadPoints(
                                            dataStore: dataStore,
                                            sessionID: session.id
                                        )
                                    }
                                }
                                showingSessionList = false
                            } label: {
                                sessionRow(session)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    if let dataStore = appState.offlineDataStore {
                                        Task {
                                            await viewModel.deleteSession(
                                                id: session.id,
                                                dataStore: dataStore
                                            )
                                        }
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Survey Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingSessionList = false }
                }
            }
        }
    }

    private func sessionRow(_ session: SurveySessionDTO) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.name ?? "Session")
                .font(.headline)
                .foregroundStyle(.primary)

            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if let endedAt = session.endedAt {
                    let minutes = Int(endedAt.timeIntervalSince(session.startedAt) / 60)
                    Text("\(minutes)m")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Active")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }

                if session.id == viewModel.selectedSessionID {
                    Text("Selected")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}
