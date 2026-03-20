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
    @State private var showingSurveySetup = false
    @State private var showingCommunityMap = false
    @State private var showingInfoSheet = false
    @State private var showingBatchUpload = false
    @State private var batchSelectedSessions: Set<UUID> = []
    @State private var probePulseScale: CGFloat = 1.0
    @AppStorage("surveyProbeEnabled") private var probeEnabledPref = false
    @AppStorage("surveyProbeFrequency") private var probeFrequencyPref: String = SignalSurveyViewModel.ProbeFrequency.normal.rawValue
    @AppStorage("surveyDeepScan") private var deepScanPref = false
    @AppStorage("surveyLiveUpload") private var liveUploadPref = false
    @AppStorage("surveyDebugMode") private var debugModeEnabled = false
    @Namespace private var mapScope

    var body: some View {
        ZStack {
            if viewModel.allPoints.isEmpty && !viewModel.isActive {
                emptyState
            } else {
                mapContent
                statsOverlay
                debugOverlay
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
            await viewModel.loadProbeChannels(dataStore: dataStore, deviceID: deviceID)

            // Resume if the SurveyService still has an active session (e.g. navigated away and back)
            if let surveyService = appState.services?.surveyService {
                await viewModel.resumeIfActive(
                    surveyService: surveyService,
                    locationService: appState.locationService,
                    binaryProtocolService: appState.services?.binaryProtocolService,
                    messageService: appState.services?.messageService,
                    deviceID: deviceID,
                    pathHashMode: appState.connectedDevice?.pathHashMode ?? 0,
                    dataStore: dataStore
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
                    dataStore: appState.offlineDataStore,
                    deviceID: appState.currentDeviceID
                )
            }
        }
        .sheet(isPresented: $showingBatchUpload) {
            BatchUploadView(
                sessions: viewModel.sessions,
                selectedSessions: $batchSelectedSessions,
                sessionStats: viewModel.sessionStats,
                dataStore: appState.offlineDataStore,
                deviceID: appState.currentDeviceID
            )
        }
        .sheet(isPresented: $showingCommunityMap) {
            CommunityMapView()
        }
        .sheet(isPresented: $showingInfoSheet) {
            SurveyInfoSheet()
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
        .sheet(isPresented: $showingSurveySetup) {
            surveySetupSheet
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
            // Only set values that actually changed to avoid triggering didSet side effects
            // (e.g. restarting the probe loop when navigating back to an active survey).
            if viewModel.probeEnabled != probeEnabledPref {
                viewModel.probeEnabled = probeEnabledPref
            }
            if viewModel.liveUploadEnabled != liveUploadPref {
                viewModel.liveUploadEnabled = liveUploadPref
            }
            if viewModel.deepScanEnabled != deepScanPref {
                viewModel.deepScanEnabled = deepScanPref
            }
            if let freq = SignalSurveyViewModel.ProbeFrequency(rawValue: probeFrequencyPref) {
                viewModel.probeFrequency = freq
            }
        }
        .onChange(of: probeEnabledPref) { _, newValue in
            viewModel.probeEnabled = newValue
        }
        .onChange(of: liveUploadPref) { _, newValue in
            viewModel.liveUploadEnabled = newValue
        }
        .onChange(of: deepScanPref) { _, newValue in
            viewModel.deepScanEnabled = newValue
        }
        .onChange(of: probeFrequencyPref) { _, newValue in
            if let freq = SignalSurveyViewModel.ProbeFrequency(rawValue: newValue) {
                viewModel.probeFrequency = freq
            }
        }
        .onChange(of: viewModel.isActive) { _, isActive in
            UIApplication.shared.isIdleTimerDisabled = isActive
            appState.isSurveyActive = isActive
        }
        .onDisappear {
            // Sync state when navigating away (survey may still be running)
            appState.isSurveyActive = viewModel.isActive
        }
        .onChange(of: viewModel.liveStatus) { _, newStatus in
            appState.surveyLiveStatus = newStatus
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
                // Community overlay cells (faded backdrop, rendered behind user data)
                if viewModel.showCommunityOverlay {
                    ForEach(viewModel.filteredCommunityCells) { cell in
                        let quality = SNRQuality(snr: cell.averageSNR)
                        let vertices = HexGrid.vertices(
                            centerLatitude: cell.latitude,
                            centerLongitude: cell.longitude,
                            referenceLatitude: cell.referenceLatitude
                        )

                        MapPolygon(coordinates: vertices)
                            .foregroundStyle(quality.color.opacity(0.12))
                            .stroke(quality.color.opacity(0.25), style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))

                        Annotation("", coordinate: CLLocationCoordinate2D(
                            latitude: cell.latitude,
                            longitude: cell.longitude
                        )) {
                            Color.clear
                                .frame(width: 60, height: 60)
                                .contentShape(.circle)
                                .onTapGesture {
                                    if viewModel.selectedCommunityCell?.id == cell.id {
                                        viewModel.selectedCommunityCell = nil
                                    } else {
                                        viewModel.selectedCommunityCell = cell
                                        viewModel.selectedCell = nil
                                    }
                                }
                        }
                    }

                    // Community cell selection highlight
                    if let selected = viewModel.selectedCommunityCell {
                        let vertices = HexGrid.vertices(
                            centerLatitude: selected.latitude,
                            centerLongitude: selected.longitude,
                            referenceLatitude: selected.referenceLatitude
                        )
                        MapPolygon(coordinates: vertices)
                            .foregroundStyle(SNRQuality(snr: selected.averageSNR).color.opacity(0.35))
                            .stroke(Color.cyan, lineWidth: 2)
                    }
                }

                // User's own survey cells rendered on top
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
                                viewModel.trackingUserLocation = false
                                viewModel.selectedCommunityCell = nil
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
        .onMapCameraChange(frequency: .onEnd) { context in
            if viewModel.showCommunityOverlay {
                Task { await viewModel.loadCommunityCells(for: context.region) }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Stats Overlay

    private var statsOverlay: some View {
        VStack {
            if viewModel.isActive {
                // Active session indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)

                    if viewModel.livePointCount > 0 {
                        Text("\(viewModel.livePointCount) pts")
                            .font(.caption.weight(.medium))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .liquidGlass(in: .capsule)
            } else if let session = viewModel.selectedSession {
                // Historical session header with close button
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name ?? session.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if let stats = viewModel.sessionStats[session.id] {
                            Text("\(stats.pointCount) pts · \(stats.cellCount) cells")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        guard let dataStore = appState.offlineDataStore,
                              let deviceID = appState.currentDeviceID else { return }
                        viewModel.selectedSessionID = nil
                        Task {
                            await viewModel.loadAllPoints(dataStore: dataStore, deviceID: deviceID)
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .liquidGlass(in: .capsule)
            } else if viewModel.livePointCount > 0 {
                // All sessions view with point count
                HStack(spacing: 6) {
                    Text("\(viewModel.livePointCount) pts")
                        .font(.caption.weight(.medium))
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

    // MARK: - Debug Overlay

    @ViewBuilder
    private var debugOverlay: some View {
        if debugModeEnabled && viewModel.isActive {
            VStack {
                SurveyDebugOverlay(viewModel: viewModel)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 46)
            .padding(.leading, 16)
            .allowsHitTesting(false)
        }
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
                                lastHeardColumn(label: "Last Heard", date: latest, unit: "ago")
                            }
                        } else {
                            if let bestGW = cell.bestGatewaySNR {
                                cellStatColumn(label: "Best Repeater", value: String(format: "%.1f", bestGW), unit: "dB")
                            }
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
                                lastHeardColumn(label: "Last Heard", date: latest, unit: "ago")
                            }
                            if cell.maxMeshDepth > 0 {
                                cellStatColumn(label: "Mesh Reach", value: "\(cell.maxMeshDepth)", unit: cell.maxMeshDepth == 1 ? "hop" : "hops")
                            }
                        }
                    }

                    // Probe success rate (active responses vs probes sent)
                    if let probes = cell.probesSent, probes > 0, cell.activePacketCount > 0 {
                        let active = cell.activePacketCount
                        let rate = min(1.0, Double(active) / Double(probes))
                        let pct = Int(round(rate * 100))
                        let rateColor: Color = pct >= 75 ? .green : pct >= 40 ? .yellow : .red
                        HStack(spacing: 4) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.caption2)
                                .foregroundStyle(rateColor)
                            Text("Probe Success: \(pct)%")
                                .font(.caption)
                                .foregroundStyle(rateColor)
                            Text("(\(active)/\(probes))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
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
                            // Connected repeaters (0-hop direct 2-way link)
                            if !cell.connectedRelayNodes.isEmpty {
                                relayNodeSection(
                                    label: "Connected (2-way)",
                                    icon: "arrow.left.arrow.right",
                                    iconColor: .green,
                                    hexIDs: cell.connectedRelayNodes
                                )
                            }
                            // Mesh reach repeaters (multi-hop, not direct 2-way)
                            if !cell.meshReachRelayNodes.isEmpty {
                                relayNodeSection(
                                    label: "Mesh Reach",
                                    icon: "point.3.connected.trianglepath.dotted",
                                    iconColor: .cyan,
                                    hexIDs: cell.meshReachRelayNodes
                                )
                            }
                            // Heard-only repeaters (passive RX, one-way)
                            if !cell.heardOnlyRelayNodes.isEmpty {
                                relayNodeSection(
                                    label: "Heard (1-way)",
                                    icon: "ear",
                                    iconColor: .secondary,
                                    hexIDs: cell.heardOnlyRelayNodes
                                )
                            }
                            // Legacy fallback: show all relay nodes if no tier split
                            if cell.connectedRelayNodes.isEmpty && cell.meshReachRelayNodes.isEmpty && cell.heardOnlyRelayNodes.isEmpty && !cell.uniqueRelayNodes.isEmpty {
                                relayNodeSection(
                                    label: "Repeater(s)",
                                    icon: "antenna.radiowaves.left.and.right",
                                    iconColor: .secondary,
                                    hexIDs: cell.uniqueRelayNodes
                                )
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

    /// "Last Heard" column that auto-refreshes every second via TimelineView.
    private func lastHeardColumn(label: String, date: Date, unit: String) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            cellStatColumn(label: label, value: relativeTimeString(from: date, now: context.date), unit: unit)
        }
    }

    private func relativeTimeString(from date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 { return "\(hours)h" }
        return "\(hours)h \(remainingMinutes)m"
    }

    /// Reusable relay node section with icon, label, and tappable hex ID chips.
    @ViewBuilder
    private func relayNodeSection(label: String, icon: String, iconColor: Color, hexIDs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(label)
                    .font(.caption2)
            } icon: {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(iconColor)
            }
            .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(hexIDs, id: \.self) { hexID in
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

                    // Track user location
                    Button {
                        viewModel.trackingUserLocation.toggle()
                    } label: {
                        Image(systemName: viewModel.trackingUserLocation
                              ? "location.fill" : "location")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(viewModel.trackingUserLocation ? .blue : .primary)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Track current location")

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

                    // Community overlay toggle
                    Button {
                        viewModel.showCommunityOverlay.toggle()
                    } label: {
                        Image(systemName: viewModel.showCommunityOverlay ? "globe.americas.fill" : "globe.americas")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(viewModel.showCommunityOverlay ? .cyan : .primary)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Toggle community overlay")
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

            communityCellDetailCard

            communityFilterBar

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

                        if viewModel.probeEnabled {
                            Menu {
                                ForEach(SignalSurveyViewModel.ProbeFrequency.allCases) { freq in
                                    Button {
                                        probeFrequencyPref = freq.rawValue
                                    } label: {
                                        HStack {
                                            Text(freq.rawValue)
                                            if viewModel.probeFrequency == freq {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "gauge.with.dots.needle.33percent")
                                        .font(.caption)
                                    Text(viewModel.probeFrequency.rawValue)
                                        .font(.caption)
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .liquidGlass(in: .capsule)
                            }

                            probeChannelMenu
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

                // Start/Stop + Manual Probe buttons
                HStack(spacing: 10) {
                    surveyToggleButton

                    if viewModel.isActive {
                        Button {
                            Task { await viewModel.sendManualProbe() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "wave.3.right")
                                Text("Probe")
                                    .fontWeight(.semibold)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .foregroundStyle(.white)
                            .background(viewModel.canSendManualProbe ? Color.orange : Color.secondary)
                            .clipShape(Capsule())
                            .opacity(viewModel.canSendManualProbe ? 1.0 : 0.6)
                            .overlay {
                                Capsule()
                                    .stroke(Color.orange, lineWidth: 2)
                                    .scaleEffect(probePulseScale)
                                    .opacity(probePulseScale > 1 ? 0 : 1)
                            }
                        }
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
                    }
                }
            }
            .sensoryFeedback(.impact(weight: .heavy, intensity: 1.0), trigger: viewModel.probeSuccessHaptic)
            .sensoryFeedback(.error, trigger: viewModel.probeErrorHaptic)
            .padding(.leading, 16)
            .padding(.bottom, 8)
        }
        .animation(.snappy(duration: 0.25), value: viewModel.selectedCell?.coordKey)
        .animation(.snappy(duration: 0.25), value: viewModel.selectedCommunityCell?.id)
        .animation(.snappy(duration: 0.25), value: viewModel.showCommunityOverlay)
    }

    // MARK: - Community Filter Bar

    @ViewBuilder
    private var communityFilterBar: some View {
        if viewModel.showCommunityOverlay {
            HStack(spacing: 8) {
                Picker("Coverage", selection: $viewModel.communityCoverageFilter) {
                    ForEach(CommunityMapView.CoverageFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)

                Menu {
                    Button {
                        viewModel.communityRepeaterFilter = nil
                    } label: {
                        HStack {
                            Text("All Repeaters")
                            if viewModel.communityRepeaterFilter == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    Divider()

                    ForEach(viewModel.communityAvailableRepeaters, id: \.self) { hexID in
                        Button {
                            viewModel.communityRepeaterFilter = hexID
                        } label: {
                            HStack {
                                Text(hexID)
                                if viewModel.communityRepeaterFilter == hexID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption2)
                        Text(viewModel.communityRepeaterFilter ?? "All")
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(viewModel.communityRepeaterFilter != nil ? .cyan : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(viewModel.communityRepeaterFilter != nil ? Color.cyan.opacity(0.15) : Color.secondary.opacity(0.1))
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Community Cell Detail Card

    @ViewBuilder
    private var communityCellDetailCard: some View {
        if let cell = viewModel.selectedCommunityCell {
            let quality = SNRQuality(snr: cell.averageSNR)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "globe.americas.fill")
                        .foregroundStyle(.cyan)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(quality.qualityLabel)
                            .font(.subheadline.weight(.semibold))
                        Text("Community data")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    communityCellSignalBar(quality: quality)

                    Button {
                        viewModel.selectedCommunityCell = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.title3)
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
                                    if viewModel.communityRepeaterFilter == hexID {
                                        viewModel.communityRepeaterFilter = nil
                                    } else {
                                        viewModel.communityRepeaterFilter = hexID
                                    }
                                } label: {
                                    Text(hexID)
                                        .font(.caption2.monospaced())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            viewModel.communityRepeaterFilter == hexID
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
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func communityCellSignalBar(quality: SNRQuality) -> some View {
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
                    .frame(width: 6, height: CGFloat(4 + i * 3))
            }
        }
    }

    // MARK: - Survey Setup Sheet

    private var surveySetupSheet: some View {
        NavigationStack {
            List {
                // MARK: Passive Mode
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label {
                            Text("Passive")
                                .font(.subheadline.weight(.semibold))
                        } icon: {
                            Image(systemName: "ear")
                                .foregroundStyle(.blue)
                        }
                        Text("Listens for mesh traffic. Shows where you can receive — but hearing a repeater doesn't mean it can hear you back. One-way coverage only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Survey Modes")
                } footer: {
                    Text("Signal quality is shown as hexagonal grid cells (~100m). Each cell is colored by the best repeater SNR when discover data is available, otherwise the average SNR of all packets. Tap any cell for detailed stats.")
                }

                // MARK: Active Mode
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label {
                            Text("Active")
                                .font(.subheadline.weight(.semibold))
                        } icon: {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundStyle(.orange)
                        }
                        Text("Sends a message on a private channel and listens for heard repeats. A 0-hop repeat means the repeater heard you directly AND you heard it back — the real test of 2-way connectivity. Locations with no repeat are dead zones.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    Toggle("Enable Active Probing", isOn: $probeEnabledPref)

                    if probeEnabledPref {
                        HStack {
                            Text("Probe Frequency")
                            Spacer()
                            Menu {
                                ForEach(SignalSurveyViewModel.ProbeFrequency.allCases) { freq in
                                    Button {
                                        probeFrequencyPref = freq.rawValue
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading) {
                                                Text(freq.rawValue)
                                                Text(freq.subtitle)
                                            }
                                            if probeFrequencyPref == freq.rawValue {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Text(SignalSurveyViewModel.ProbeFrequency(rawValue: probeFrequencyPref)?.rawValue ?? "Normal")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Toggle("Deep Scan", isOn: $deepScanPref)

                        if deepScanPref {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.caption)
                                Text("Deep scan sends additional discover + trace probes. This uses more airtime and works best at walking speed or slower.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    if probeEnabledPref {
                        let freq = SignalSurveyViewModel.ProbeFrequency(rawValue: probeFrequencyPref) ?? .normal
                        Text("Probes every ~\(Int(freq.distanceMeters))m of movement (min \(Int(freq.minInterval))s cooldown). Also probes on hex cell boundary crossings and when stationary for \(Int(freq.maxInterval))s. Tap the Probe button on the map at any time to send one manually.")
                    } else {
                        Text("When disabled, the survey only records passively overheard traffic. Enable probing to actively test coverage and detect dead zones.")
                    }
                }

                // MARK: Channel Probe
                if probeEnabledPref {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Label {
                                Text("Channel Probe")
                                    .font(.subheadline.weight(.medium))
                            } icon: {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .foregroundStyle(.cyan)
                            }
                            Text("Sends a message on a private channel during each probe. When a repeater hears your message and relays it back with 0 hops, that's proof of a direct 2-way connection — the most important survey metric.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)

                        if viewModel.availableProbeChannels.isEmpty {
                            HStack {
                                Text("No private channels")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Create") {
                                    guard let channelService = appState.services?.channelService,
                                          let dataStore = appState.offlineDataStore,
                                          let deviceID = appState.currentDeviceID else { return }
                                    Task {
                                        await viewModel.createSurveyChannel(
                                            channelService: channelService,
                                            dataStore: dataStore,
                                            deviceID: deviceID,
                                            maxChannels: appState.connectedDevice?.maxChannels ?? 8
                                        )
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        } else {
                            Picker("Channel", selection: $viewModel.selectedProbeChannel) {
                                Text("None").tag(ChannelDTO?.none)
                                ForEach(viewModel.availableProbeChannels) { channel in
                                    Text(channel.displayName).tag(ChannelDTO?.some(channel))
                                }
                            }

                            Button {
                                guard let channelService = appState.services?.channelService,
                                      let dataStore = appState.offlineDataStore,
                                      let deviceID = appState.currentDeviceID else { return }
                                Task {
                                    await viewModel.createSurveyChannel(
                                        channelService: channelService,
                                        dataStore: dataStore,
                                        deviceID: deviceID,
                                        maxChannels: appState.connectedDevice?.maxChannels ?? 8
                                    )
                                }
                            } label: {
                                Label("Create Survey Channel", systemImage: "plus.circle")
                            }
                        }
                    } footer: {
                        Text("A dedicated private channel avoids cluttering conversations. Required for 2-way connectivity testing — without a channel, probes can only measure passive reception.")
                    }
                }

                // MARK: Community Data
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label {
                            Text("Community Map")
                                .font(.subheadline.weight(.semibold))
                        } icon: {
                            Image(systemName: "globe")
                                .foregroundStyle(.green)
                        }
                        Text("Share your survey data with the DigitainoMesh community to build a crowd-sourced coverage map at mesh.digitaino.com. Data is anonymized — only hex grid cells (~100m), signal stats, and repeater IDs are sent. No exact GPS, device identity, or message content is included.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    Toggle("Live Upload", isOn: $liveUploadPref)

                } footer: {
                    if liveUploadPref {
                        Text("Each received packet will be uploaded to the community map in real time. You can also export and upload a full session later from the toolbar menu.")
                    } else {
                        Text("Data stays on your device. You can export and upload to the community map after the session from the toolbar menu.")
                    }
                }

                // MARK: Debug
                Section {
                    Toggle("Debug Overlay", isOn: $debugModeEnabled)
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Shows real-time GPS, probe, and session diagnostics on the survey map.")
                }
            }
            .navigationTitle("Survey Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingSurveySetup = false }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingInfoSheet = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        showingSurveySetup = false
                        Task {
                            guard let service = appState.services?.surveyService else { return }
                            await viewModel.startSurvey(
                                surveyService: service,
                                locationService: appState.locationService,
                                binaryProtocolService: appState.services?.binaryProtocolService,
                                messageService: appState.services?.messageService,
                                deviceID: appState.currentDeviceID,
                                pathHashMode: appState.connectedDevice?.pathHashMode ?? 0
                            )
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Probe Channel Menu

    private var probeChannelMenu: some View {
        Menu {
            if viewModel.availableProbeChannels.isEmpty {
                Button {
                    guard let channelService = appState.services?.channelService,
                          let dataStore = appState.offlineDataStore,
                          let deviceID = appState.currentDeviceID else { return }
                    Task {
                        await viewModel.createSurveyChannel(
                            channelService: channelService,
                            dataStore: dataStore,
                            deviceID: deviceID,
                            maxChannels: appState.connectedDevice?.maxChannels ?? 8
                        )
                    }
                } label: {
                    Label("Create Survey Channel", systemImage: "plus.circle")
                }
            } else {
                ForEach(viewModel.availableProbeChannels, id: \.id) { channel in
                    Button {
                        viewModel.selectedProbeChannel = channel
                    } label: {
                        HStack {
                            Text(channel.displayName)
                            if viewModel.selectedProbeChannel?.id == channel.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()

                Button {
                    viewModel.selectedProbeChannel = nil
                } label: {
                    HStack {
                        Text("None")
                        if viewModel.selectedProbeChannel == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Divider()

                Button {
                    guard let channelService = appState.services?.channelService,
                          let dataStore = appState.offlineDataStore,
                          let deviceID = appState.currentDeviceID else { return }
                    Task {
                        await viewModel.createSurveyChannel(
                            channelService: channelService,
                            dataStore: dataStore,
                            deviceID: deviceID,
                            maxChannels: appState.connectedDevice?.maxChannels ?? 8
                        )
                    }
                } label: {
                    Label("Create Survey Channel", systemImage: "plus.circle")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.hasProbeChannel
                      ? "bubble.left.and.bubble.right.fill"
                      : "bubble.left.and.bubble.right")
                    .font(.caption)
                if let channel = viewModel.selectedProbeChannel {
                    Text(channel.displayName)
                        .font(.caption)
                        .lineLimit(1)
                } else {
                    Text("Ch")
                        .font(.caption)
                }
            }
            .foregroundStyle(viewModel.hasProbeChannel ? .cyan : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .liquidGlass(in: .capsule)
        }
    }

    private var surveyToggleButton: some View {
        let isDisabled = appState.services?.surveyService == nil

        return Button {
            if viewModel.isActive {
                Task {
                    guard let service = appState.services?.surveyService else { return }
                    await viewModel.stopSurvey(
                        surveyService: service,
                        locationService: appState.locationService,
                        dataStore: appState.offlineDataStore,
                        deviceID: appState.currentDeviceID
                    )
                }
            } else {
                showingSurveySetup = true
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
                        Label("Export Session", systemImage: "square.and.arrow.up")
                    }
                }

                if !viewModel.sessions.isEmpty && !viewModel.isActive {
                    Button {
                        batchSelectedSessions = Set(viewModel.sessions.map(\.id))
                        showingBatchUpload = true
                    } label: {
                        Label("Upload Sessions…", systemImage: "icloud.and.arrow.up")
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

                Divider()

                Button {
                    showingCommunityMap = true
                } label: {
                    Label("Community Map", systemImage: "globe")
                }

                Divider()

                Button {
                    showingInfoSheet = true
                } label: {
                    Label("How It Works", systemImage: "info.circle")
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
                    showingSurveySetup = true
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

                if let stats = viewModel.sessionStats[session.id] {
                    Label("\(stats.pointCount)", systemImage: "wave.3.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Label("\(stats.cellCount)", systemImage: "hexagon")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
// MARK: - Batch Upload View

/// Allows selecting multiple survey sessions for batch upload to the community map.
struct BatchUploadView: View {
    let sessions: [SurveySessionDTO]
    @Binding var selectedSessions: Set<UUID>
    let sessionStats: [UUID: SignalSurveyViewModel.SessionStats]
    let dataStore: PersistenceStore?
    var deviceID: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var isUploading = false
    @State private var uploadResult: String?
    @State private var uploadError: String?
    @State private var showingDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteResult: String?

    private var totalPoints: Int {
        selectedSessions.compactMap { sessionStats[$0]?.pointCount }.reduce(0, +)
    }

    private var totalCells: Int {
        selectedSessions.compactMap { sessionStats[$0]?.cellCount }.reduce(0, +)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Selection summary
                HStack(spacing: 16) {
                    VStack(spacing: 2) {
                        Text("\(selectedSessions.count)")
                            .font(.title2.bold().monospacedDigit())
                        Text("Sessions")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 2) {
                        Text("\(totalPoints)")
                            .font(.title2.bold().monospacedDigit())
                        Text("Points")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 2) {
                        Text("\(totalCells)")
                            .font(.title2.bold().monospacedDigit())
                        Text("Cells")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 12)

                Divider()

                // Session selection list
                List {
                    Section {
                        ForEach(sessions) { session in
                            Button {
                                if selectedSessions.contains(session.id) {
                                    selectedSessions.remove(session.id)
                                } else {
                                    selectedSessions.insert(session.id)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: selectedSessions.contains(session.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedSessions.contains(session.id) ? .blue : .secondary)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.name ?? "Session")
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if let stats = sessionStats[session.id] {
                                        Text("\(stats.pointCount) pts")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Select sessions to upload")
                            Spacer()
                            Button(selectedSessions.count == sessions.count ? "Deselect All" : "Select All") {
                                if selectedSessions.count == sessions.count {
                                    selectedSessions.removeAll()
                                } else {
                                    selectedSessions = Set(sessions.map(\.id))
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
                .listStyle(.insetGrouped)

                // Upload status / button
                VStack(spacing: 12) {
                    if isUploading || isDeleting {
                        ProgressView(isDeleting ? "Deleting server data..." : "Uploading \(selectedSessions.count) session(s)...")
                    } else if let uploadResult {
                        Label(uploadResult, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.subheadline)
                    } else if let deleteResult {
                        Label(deleteResult, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                    } else if let uploadError {
                        VStack(spacing: 6) {
                            Label(uploadError, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                            Button("Retry") {
                                Task { await performUpload() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else {
                        Text("Re-uploading the same sessions replaces previous data (safe to repeat).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Button {
                            Task { await performUpload() }
                        } label: {
                            Label("Upload to Community Map", systemImage: "icloud.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedSessions.isEmpty)
                    }
                }
                .padding()
            }
            .navigationTitle("Upload Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button(role: .destructive) {
                            showingDeleteConfirm = true
                        } label: {
                            Label("Delete My Server Data", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Delete Server Data?", isPresented: $showingDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    Task { await performDelete() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes all your uploaded survey data from the community map server. Your local sessions are not affected. You can re-upload afterward.")
            }
        }
    }

    private func performUpload() async {
        guard let dataStore, !selectedSessions.isEmpty else {
            uploadError = "No sessions selected or data store unavailable."
            return
        }

        isUploading = true
        uploadError = nil
        uploadResult = nil
        deleteResult = nil
        defer { isUploading = false }

        do {
            var repeaterContacts: [ContactDTO] = []
            if let deviceID {
                let allContacts = (try? await dataStore.fetchContacts(deviceID: deviceID)) ?? []
                repeaterContacts = allContacts.filter { $0.type == .repeater }
            }

            let service = SurveyUploadService()
            let response = try await service.uploadMultipleSessions(
                sessionIDs: Array(selectedSessions),
                dataStore: dataStore,
                repeaterContacts: repeaterContacts
            )
            uploadResult = "\(response.accepted) cells uploaded from \(selectedSessions.count) session(s)"
        } catch {
            uploadError = error.localizedDescription
        }
    }

    private func performDelete() async {
        isDeleting = true
        uploadError = nil
        uploadResult = nil
        deleteResult = nil
        defer { isDeleting = false }

        do {
            let service = SurveyUploadService()
            let response = try await service.deleteContributorData()
            deleteResult = "Deleted \(response.deletedContributions) contributions, \(response.cellsRemoved) cells removed"
        } catch {
            uploadError = "Delete failed: \(error.localizedDescription)"
        }
    }
}

