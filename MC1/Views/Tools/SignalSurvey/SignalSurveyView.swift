import MapKit
import MC1Services
import SwiftUI
import UIKit

struct SignalSurveyView: View {
    @Environment(\.appState) private var appState

    @State private var viewModel = SignalSurveyViewModel()
    @State private var showingSessionList = false
    @State private var showingExportSheet = false
    @State private var showingPacketList = false
    @State private var probePulseScale: CGFloat = 1.0
    @AppStorage("surveyProbeEnabled") private var probeEnabledPref = false
    @AppStorage("surveyProbeDistance") private var probeDistancePref: Double = 50
    @Namespace private var mapScope

    var body: some View {
        ZStack {
            if viewModel.allPoints.isEmpty && !viewModel.isActive {
                emptyState
            } else {
                mapContent
                statsOverlay
                mapControlsOverlay
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
            await viewModel.loadContacts(dataStore: dataStore, deviceID: deviceID)

            // Resume if the SurveyService still has an active session (e.g. navigated away and back)
            if let surveyService = appState.services?.surveyService {
                await viewModel.resumeIfActive(
                    surveyService: surveyService,
                    locationService: appState.locationService,
                    binaryProtocolService: appState.services?.binaryProtocolService,
                    dataStore: dataStore,
                    deviceID: deviceID
                )
            }
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
        .sheet(isPresented: $showingPacketList) {
            CellPacketListView(
                points: viewModel.pointsForSelectedCell(relayFilter: viewModel.selectedRelayFilter),
                cellID: viewModel.selectedCell?.coordKey ?? "",
                relayFilter: viewModel.selectedRelayFilter,
                contactsByName: viewModel.contactsByName,
                onNavigateToContact: { contact in
                    showingPacketList = false
                    appState.navigation.navigateToContactDetail(contact)
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $viewModel.selectedMapRepeater) { contact in
            RepeaterDetailSheet(
                contact: contact,
                onNavigateToContact: { contact in
                    viewModel.selectedMapRepeater = nil
                    appState.navigation.navigateToContactDetail(contact)
                }
            )
            .presentationDetents([.medium])
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
        .onAppear {
            viewModel.probeEnabled = probeEnabledPref
            viewModel.probeDistanceMeters = probeDistancePref
        }
        .onChange(of: probeEnabledPref) { _, newValue in
            viewModel.probeEnabled = newValue
        }
        .onChange(of: probeDistancePref) { _, newValue in
            viewModel.probeDistanceMeters = newValue
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
                // All cells rendered unconditionally
                ForEach(viewModel.gridCells) { cell in
                    if cell.isDeadZone {
                        MapPolygon(coordinates: cell.vertices)
                            .foregroundStyle(Color.gray.opacity(0.15))
                            .stroke(Color.gray.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    } else {
                        MapPolygon(coordinates: cell.vertices)
                            .foregroundStyle(
                                cell.snrQuality.color.opacity(
                                    0.2 + 0.5 * min(1, Double(cell.packetCount) / 10.0)
                                )
                            )
                            .stroke(cell.snrQuality.color.opacity(0.6), lineWidth: 0.5)
                    }

                    // Invisible tap target at cell center — oversized for easier tapping
                    Annotation("", coordinate: CLLocationCoordinate2D(
                        latitude: cell.centerLatitude,
                        longitude: cell.centerLongitude
                    )) {
                        Color.clear
                            .frame(width: 60, height: 60)
                            .contentShape(.circle)
                            .onTapGesture {
                                if viewModel.selectedCell?.coordKey == cell.coordKey {
                                    viewModel.selectedCell = nil
                                } else {
                                    viewModel.selectedCell = cell
                                }
                            }
                    }
                }

                // Selected cell highlight rendered on top
                if let selected = viewModel.selectedCell {
                    MapPolygon(coordinates: selected.vertices)
                        .foregroundStyle(
                            selected.isDeadZone
                                ? Color.gray.opacity(0.3)
                                : selected.snrQuality.color.opacity(0.5)
                        )
                        .stroke(Color.white, lineWidth: 3)
                }
            }

            // Repeater annotations
            ForEach(viewModel.mapRepeaterAnnotations, id: \.hexID) { item in
                Annotation(item.contact.displayName, coordinate: CLLocationCoordinate2D(
                    latitude: item.contact.latitude,
                    longitude: item.contact.longitude
                )) {
                    Button {
                        viewModel.selectedMapRepeater = item.contact
                    } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Color.cyan)
                            .clipShape(Circle())
                            .overlay {
                                Circle()
                                    .strokeBorder(Color.white, lineWidth: 1.5)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }

            // Line from selected cell to selected repeater
            if let cell = viewModel.selectedCell,
               let repeater = viewModel.selectedRepeaterContact {
                MapPolyline(coordinates: [
                    CLLocationCoordinate2D(latitude: cell.centerLatitude, longitude: cell.centerLongitude),
                    CLLocationCoordinate2D(latitude: repeater.latitude, longitude: repeater.longitude)
                ])
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
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

    // MARK: - Cell Detail Card (inline)

    @ViewBuilder
    private var cellDetailCard: some View {
        if let cell = viewModel.selectedCell {
            let displayQuality = viewModel.filteredCellStats?.quality ?? cell.snrQuality
            let displayPacketCount = viewModel.filteredCellStats?.packetCount ?? cell.packetCount
            VStack(alignment: .leading, spacing: 8) {
                // Header row with dismiss button
                HStack(spacing: 10) {
                    if cell.isDeadZone {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(.secondary)
                            .font(.title3)
                    } else {
                        Image(systemName: "cellularbars", variableValue: displayQuality.barLevel)
                            .foregroundStyle(displayQuality.color)
                            .font(.title3)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(cell.isDeadZone ? "No Response" : displayQuality.qualityLabel)
                            .font(.subheadline.weight(.semibold))
                        if cell.isDeadZone {
                            Text("Probe sent, no response")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(displayPacketCount) packet\(displayPacketCount == 1 ? "" : "s") received")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button {
                        viewModel.selectedCell = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if !cell.isDeadZone {
                    // Relay filter indicator
                    if let relay = viewModel.selectedRelayFilter {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                                .font(.caption2)
                            Text("via \(relay)")
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Button {
                                viewModel.selectedRelayFilter = nil
                            } label: {
                                Text("Clear")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                        }
                        .foregroundStyle(Color.accentColor)
                    }

                    // Signal stats row (use filtered stats when relay filter is active)
                    HStack(spacing: 0) {
                        if let filtered = viewModel.filteredCellStats {
                            if let snr = filtered.avgSNR {
                                cellStatColumn(label: "Avg SNR", value: String(format: "%.1f", snr), unit: "dB")
                            }
                            if let rssi = filtered.avgRSSI {
                                cellStatColumn(label: "Avg RSSI", value: String(format: "%.0f", rssi), unit: "dBm")
                            }
                            if let minSNR = filtered.minSNR, let maxSNR = filtered.maxSNR {
                                cellStatColumn(label: "SNR Range", value: String(format: "%.0f – %.0f", minSNR, maxSNR), unit: "dB")
                            }
                            if let latest = filtered.latestTimestamp {
                                cellStatColumn(label: "Last Heard", value: relativeTimeString(from: latest), unit: "ago")
                            }
                        } else {
                            if let snr = cell.averageSNR {
                                cellStatColumn(label: "Avg SNR", value: String(format: "%.1f", snr), unit: "dB")
                            }
                            if let rssi = cell.averageRSSI {
                                cellStatColumn(label: "Avg RSSI", value: String(format: "%.0f", rssi), unit: "dBm")
                            }
                            if let minSNR = cell.minSNR, let maxSNR = cell.maxSNR {
                                cellStatColumn(label: "SNR Range", value: String(format: "%.0f – %.0f", minSNR, maxSNR), unit: "dB")
                            }
                            if let latest = cell.latestTimestamp {
                                cellStatColumn(label: "Last Heard", value: relativeTimeString(from: latest), unit: "ago")
                            }
                        }
                    }

                    // View Packets button
                    if cell.packetCount > 0 {
                        Button {
                            showingPacketList = true
                        } label: {
                            HStack {
                                Image(systemName: "list.bullet")
                                    .font(.caption2)
                                let count = viewModel.filteredCellStats?.packetCount ?? cell.packetCount
                                Text("View \(count) Packet\(count == 1 ? "" : "s")")
                                    .font(.caption)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                            }
                            .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }

                    // Relay nodes and senders
                    if !cell.uniqueRelayNodes.isEmpty || !cell.uniqueSenders.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            if !cell.uniqueRelayNodes.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    Label {
                                        Text("Repeater(s) heard")
                                            .font(.caption2)
                                    } icon: {
                                        Image(systemName: "arrow.triangle.swap")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .foregroundStyle(.secondary)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 4) {
                                            ForEach(cell.uniqueRelayNodes, id: \.self) { hexID in
                                                Button {
                                                    if viewModel.selectedRelayFilter == hexID {
                                                        viewModel.selectedRelayFilter = nil
                                                    } else {
                                                        viewModel.selectedRelayFilter = hexID
                                                    }
                                                } label: {
                                                    Text(hexID)
                                                        .font(.system(.caption, design: .monospaced))
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 3)
                                                        .background(
                                                            viewModel.selectedRelayFilter == hexID
                                                                ? Color.accentColor.opacity(0.2)
                                                                : Color.secondary.opacity(0.12)
                                                        )
                                                        .clipShape(Capsule())
                                                        .overlay(
                                                            Capsule().strokeBorder(
                                                                viewModel.selectedRelayFilter == hexID
                                                                    ? Color.accentColor : Color.clear,
                                                                lineWidth: 1
                                                            )
                                                        )
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                            }
                            if !cell.uniqueSenders.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    Label {
                                        Text("Heard from")
                                            .font(.caption2)
                                    } icon: {
                                        Image(systemName: "person.wave.2")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .foregroundStyle(.secondary)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 6) {
                                            ForEach(cell.uniqueSenders, id: \.self) { name in
                                                if let contact = viewModel.contactsByName[name] {
                                                    Button {
                                                        appState.navigation.navigateToContactDetail(contact)
                                                    } label: {
                                                        HStack(spacing: 2) {
                                                            Text(name)
                                                                .font(.caption)
                                                            Image(systemName: "chevron.right")
                                                                .font(.system(size: 8))
                                                        }
                                                        .foregroundStyle(Color.accentColor)
                                                    }
                                                    .buttonStyle(.plain)
                                                } else {
                                                    Text(name)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .liquidGlass(in: .rect(cornerRadius: 16))
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func cellStatColumn(label: String, value: String, unit: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
            if !unit.isEmpty {
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func relativeTimeString(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 { return "\(hours)h" }
        return "\(hours)h \(remainingMinutes)m"
    }

    // MARK: - Map Controls Overlay (Top-Right)

    private var mapControlsOverlay: some View {
        VStack {
            HStack {
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
            .padding(.top, 8)
            Spacer()
        }
        .overlay(alignment: .topTrailing) {
            if viewModel.showingLayersMenu {
                LayersMenu(
                    selection: $viewModel.mapStyleSelection,
                    isPresented: $viewModel.showingLayersMenu
                )
                .padding(.trailing, 16)
                .padding(.top, 240)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: viewModel.showingLayersMenu)
    }

    // MARK: - Bottom Overlay

    private var bottomOverlay: some View {
        VStack(spacing: 8) {
            Spacer()

            cellDetailCard

            // Survey controls (left-aligned)
            VStack(alignment: .leading, spacing: 6) {
                // Filter picker
                if viewModel.livePointCount > 0 || viewModel.isActive {
                    Picker("Filter", selection: $viewModel.surveyFilter) {
                        ForEach(SignalSurveyViewModel.SurveyFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }

                // Probe controls
                if viewModel.isActive {
                    HStack(spacing: 6) {
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
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .liquidGlass(in: .capsule)
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task { await viewModel.sendManualProbe() }
                        } label: {
                            Image(systemName: "wave.3.right")
                                .font(.caption)
                                .foregroundStyle(viewModel.canSendManualProbe ? .orange : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .liquidGlass(in: .capsule)
                                .overlay {
                                    Circle()
                                        .stroke(Color.orange, lineWidth: 2)
                                        .scaleEffect(probePulseScale)
                                        .opacity(probePulseScale > 1 ? 0 : 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(!viewModel.canSendManualProbe)
                        .onChange(of: viewModel.probeVisualPulse) { _, _ in
                            probePulseScale = 1.0
                            withAnimation(.easeOut(duration: 0.6)) {
                                probePulseScale = 2.5
                            }
                            Task {
                                try? await Task.sleep(for: .seconds(0.65))
                                probePulseScale = 1.0
                            }
                        }

                        if viewModel.probeEnabled {
                            Menu {
                                ForEach([25.0, 50.0, 100.0, 200.0], id: \.self) { distance in
                                    Button {
                                        probeDistancePref = distance
                                    } label: {
                                        HStack {
                                            Text("\(Int(distance))m")
                                            if probeDistancePref == distance {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "ruler")
                                        .font(.caption)
                                    Text("\(Int(probeDistancePref))m")
                                        .font(.caption)
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .liquidGlass(in: .capsule)
                            }
                        }
                    }
                }

                if let errorMsg = viewModel.probeErrorMessage {
                    Text(errorMsg)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .transition(.opacity)
                        .task(id: viewModel.probeErrorHaptic) {
                            try? await Task.sleep(for: .seconds(2))
                            viewModel.probeErrorMessage = nil
                        }
                }

                surveyToggleButton
            }
            .sensoryFeedback(.impact(weight: .heavy, intensity: 1.0), trigger: viewModel.probeSuccessHaptic)
            .sensoryFeedback(.error, trigger: viewModel.probeErrorHaptic)
            .padding(.leading, 16)
            .padding(.bottom, 8)
        }
        .animation(.snappy(duration: 0.25), value: viewModel.selectedCell?.coordKey)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
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
