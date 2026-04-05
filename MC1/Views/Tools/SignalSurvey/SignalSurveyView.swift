import MapKit
import MC1Services
import SwiftUI
import UIKit

struct SignalSurveyView: View {
    @Environment(\.appState) private var appState

    @State private var viewModel = SignalSurveyViewModel()
    @State private var showingSessionList = false
    @State private var showingLifetimeStats = false
    @State private var showingExportSheet = false
    @State private var showingPacketList = false
    @State private var showingSurveySetup = false
    @State private var showingInfoSheet = false
    @State private var showingBatchUpload = false
    @State private var batchSelectedSessions: Set<UUID> = []
    @State private var probePulseScale: CGFloat = 1.0
    @AppStorage("surveyProbeEnabled") private var probeEnabledPref = false
    @AppStorage("surveyProbeFrequency") private var probeFrequencyPref: String = SignalSurveyViewModel.ProbeFrequency.normal.rawValue
    @AppStorage("surveyDeepScan") private var deepScanPref = false
    @AppStorage("surveyLiveUpload") private var liveUploadPref = false
    @AppStorage("surveyDebugMode") private var debugModeEnabled = false
    @AppStorage("surveyIncludeDisplayName") private var includeDisplayName = true
    @AppStorage("surveyContributorVerified") private var contributorVerified = false
    @State private var isVerifying = false
    @State private var verificationError: String?
    @State private var showingContributorProfile = false
    @State private var showingCompletionSummary = false
    @State private var completionSessionID: UUID?
    @State private var showingHistoricalStats: SurveySessionDTO?

    var body: some View {
        ZStack {
            if viewModel.isCheckingForActiveSession && viewModel.allPoints.isEmpty && !viewModel.isActive {
                Color.clear // Placeholder while loading — avoids empty state flash
            } else if viewModel.allPoints.isEmpty && !viewModel.isActive && !viewModel.showCommunityOverlay {
                emptyState
            } else {
                mapContent
                statsOverlay
                debugOverlay
                mapControlsOverlay
                bottomOverlay

                // Community-only mode: show action buttons when no session data
                // Hide when a community cell is selected to avoid overlap with detail card
                if viewModel.allPoints.isEmpty && !viewModel.isActive && viewModel.selectedCommunityCell == nil {
                    communityModeOverlay
                }

            }
        }
        .navigationTitle("Signal Survey")
        .navigationBarBackButtonHidden(isShowingMapSubState)
        .toolbar {
            if isShowingMapSubState {
                ToolbarItem(placement: .navigation) {
                    Button {
                        returnToDashboard()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .fontWeight(.semibold)
                                .imageScale(.medium)
                            Text("Signal Survey")
                        }
                    }
                }
            }
            toolbarContent
        }
        .task(id: appState.servicesVersion) {
            guard let dataStore = appState.offlineDataStore,
                  let deviceID = appState.currentDeviceID else { return }

            // Prevent the empty state from showing while we check for an active session
            viewModel.isCheckingForActiveSession = true
            defer { viewModel.isCheckingForActiveSession = false }

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
                deviceID: appState.currentDeviceID,
                probesSentPerCell: viewModel.probesSentPerCell,
                deadZoneHexCoords: viewModel.gridCells.filter(\.isDeadZone).compactMap { cell in
                    let parts = cell.coordKey.split(separator: "_")
                    guard parts.count == 2, let q = Int(parts[0]), let r = Int(parts[1]) else { return nil }
                    return (q: q, r: r)
                },
                displayName: includeDisplayName ? appState.connectedDevice?.nodeName : nil
            )
        }
        .sheet(isPresented: $showingInfoSheet) {
            SurveyInfoSheet()
        }
        .sheet(isPresented: $showingContributorProfile) {
            ContributorProfileAutoRenewView()
        }
        .fullScreenCover(isPresented: $showingCompletionSummary, onDismiss: {
            viewModel.surveyCompletionStats = nil
            viewModel.personalRecords = nil
            completionSessionID = nil
        }) {
            if let stats = viewModel.surveyCompletionStats {
                SurveyCompletionSheet(
                    stats: stats,
                    resolveRepeater: { viewModel.repeaterDisplayName(for: $0) },
                    personalRecords: viewModel.personalRecords,
                    sessionID: completionSessionID,
                    dataStore: appState.offlineDataStore,
                    deviceID: appState.currentDeviceID
                )
            }
        }
        .fullScreenCover(item: $showingHistoricalStats) { session in
            if let statsDTO = session.completionStats {
                SurveyCompletionSheet(
                    stats: SignalSurveyViewModel.SurveyCompletionStats(from: statsDTO),
                    resolveRepeater: { viewModel.repeaterDisplayName(for: $0) }
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
            viewModel.stopCommunityRefresh()

            // Persist probe data so resumeIfActive() can restore probe count
            // when the view is recreated after back-button navigation.
            if viewModel.isActive, let dataStore = appState.offlineDataStore {
                Task { await viewModel.persistProbeData(dataStore: dataStore) }
            }
        }
        .onChange(of: viewModel.liveStatus) { _, newStatus in
            var enriched = newStatus
            // Merge live signal bars from SignalBarsService best repeater
            if let best = appState.signalBarsService.repeaters.first {
                enriched.bestRepeaterRxQuality = best.rxQuality
                if case .measured(let quality) = best.txState {
                    enriched.bestRepeaterTxQuality = quality
                }
                enriched.bestRepeaterName = best.name ?? best.id
            }
            appState.surveyLiveStatus = enriched
        }

    }

    // MARK: - Map Content

    private var mapContent: some View {
        SurveyMapRepresentable(
            gridCells: viewModel.gridCells,
            displayPoints: viewModel.displayPoints,
            visualizationMode: viewModel.visualizationMode,
            selectedCell: viewModel.selectedCell,
            communityCells: viewModel.filteredCommunityCells,
            showCommunityOverlay: viewModel.showCommunityOverlay,
            selectedCommunityCell: viewModel.selectedCommunityCell,
            communityRepeaterLocations: viewModel.communityRepeaterLocations,
            allRepeaterLocations: viewModel.allRepeaterLocations,
            communityRepeaterFilter: viewModel.communityRepeaterFilter,
            repeaterAnnotations: viewModel.mapRepeaterAnnotations,
            selectedMapRepeater: viewModel.selectedMapRepeater,
            selectedRepeaterContact: viewModel.selectedRepeaterContact,
            mapStyleSelection: viewModel.mapStyleSelection,
            showsUserLocation: true,
            trackingUserLocation: viewModel.trackingUserLocation,
            targetRegion: $viewModel.targetRegion,
            onCellSelected: { cell in
                viewModel.trackingUserLocation = false
                viewModel.selectedCommunityCell = nil
                viewModel.selectedCell = cell
            },
            onCommunityCellSelected: { cell in
                viewModel.selectedCell = nil
                viewModel.selectedCommunityCell = cell
            },
            onRepeaterTapped: { contact in
                viewModel.selectedMapRepeater = contact
            },
            onRegionChanged: { region in
                if viewModel.showCommunityOverlay {
                    viewModel.loadCommunityCells(for: region)
                }
            },
            onTrackingStopped: {
                viewModel.trackingUserLocation = false
            }
        )
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

                    Divider()
                        .frame(height: 14)

                    Button {
                        viewModel.trackingUserLocation = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: viewModel.trackingUserLocation ? "location.fill" : "location")
                                .font(.caption2)
                            Text("My Cell")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(viewModel.trackingUserLocation ? .blue : .primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
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
                        viewModel.clearSessionData()
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

                    Button {
                        viewModel.clearSessionData()
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
            let displayRxSNR = viewModel.filteredCellStats?.avgSNR ?? cell.averageSNR
            // TX signal is only meaningful for directly connected repeaters.
            // Mesh reach and heard-only repeaters relay through intermediaries,
            // so their TX SNR doesn't represent the direct link to the user.
            let isFilteredRepeaterDirect: Bool = {
                guard let relay = viewModel.selectedRelayFilter else { return true }
                let r = relay.uppercased()
                return cell.connectedRelayNodes.contains { node in
                    let u = node.uppercased()
                    return u == r || u.hasPrefix(r) || r.hasPrefix(u)
                }
            }()
            let displayTxSNR: Double? = {
                guard isFilteredRepeaterDirect else { return nil }
                // When a relay filter is active, use only the filtered TX data (don't
                // fall back to the unfiltered cell average — that would mix repeaters).
                if let filtered = viewModel.filteredCellStats {
                    return filtered.avgTxSNR
                }
                // When no filter is active, show the best direct TX SNR rather than the
                // average across all repeaters — this answers "how well does my best
                // repeater hear me from here?" which is the meaningful data point.
                return cell.bestTxSNR ?? cell.averageTxSNR
            }()
            let displayTxQuality = SNRQuality(snr: displayTxSNR)
            VStack(alignment: .leading, spacing: 8) {
                // Header: quality + packet count + dismiss
                HStack(spacing: 8) {
                    if cell.isDeadZone {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(cell.isDeadZone ? "No Response" : displayQuality.qualityLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(cell.isDeadZone ? .secondary : displayQuality.color)
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
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
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
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .foregroundStyle(Color.accentColor)
                    }

                    // Detect whether this cell has Deep Scan data (TX SNR or trace data).
                    // This drives whether we show the two-column RX/TX layout or RX-only.
                    let hasDeepScanData = cell.averageTxSNR != nil || cell.maxMeshDepth > 0 || !cell.meshScores.isEmpty

                    if hasDeepScanData {
                        // Two-column RX / TX signal section (Deep Scan data available)
                        HStack(alignment: .top, spacing: 0) {
                            signalColumn(
                                label: "RX Signal",
                                arrowName: "arrow.down",
                                snr: displayRxSNR,
                                quality: displayQuality,
                                rssi: {
                                    if let src = viewModel.filteredCellStats { return src.avgRSSI }
                                    return cell.averageRSSI
                                }(),
                                snrRange: {
                                    if let src = viewModel.filteredCellStats {
                                        guard let lo = src.minSNR, let hi = src.maxSNR else { return nil }
                                        return (lo, hi)
                                    }
                                    guard let lo = cell.minSNR, let hi = cell.maxSNR else { return nil }
                                    return (lo, hi)
                                }()
                            )

                            Rectangle()
                                .fill(.quaternary)
                                .frame(width: 0.5)
                                .padding(.vertical, 4)

                            signalColumn(
                                label: "TX Signal",
                                arrowName: "arrow.up",
                                snr: displayTxSNR,
                                quality: displayTxQuality,
                                rssi: nil,
                                snrRange: {
                                    guard isFilteredRepeaterDirect else { return nil }
                                    if let src = viewModel.filteredCellStats {
                                        guard let lo = src.minTxSNR, let hi = src.maxTxSNR else { return nil }
                                        return (lo, hi)
                                    }
                                    guard let lo = cell.minTxSNR, let hi = cell.maxTxSNR else { return nil }
                                    return (lo, hi)
                                }(),
                                unknownReason: {
                                    guard displayTxQuality == .unknown else { return nil }
                                    if !isFilteredRepeaterDirect {
                                        return "Not direct — TX only applies to 2-way links"
                                    }
                                    if cell.connectedRelayNodes.isEmpty {
                                        return "Waiting for discover response"
                                    }
                                    return "Repeats confirmed — TX data from discover responses"
                                }()
                            )
                        }
                    } else {
                        // Single-column RX signal (no Deep Scan data)
                        signalColumn(
                            label: "RX Signal",
                            arrowName: "arrow.down",
                            snr: displayRxSNR,
                            quality: displayQuality,
                            rssi: {
                                if let src = viewModel.filteredCellStats { return src.avgRSSI }
                                return cell.averageRSSI
                            }(),
                            snrRange: {
                                if let src = viewModel.filteredCellStats {
                                    guard let lo = src.minSNR, let hi = src.maxSNR else { return nil }
                                    return (lo, hi)
                                }
                                guard let lo = cell.minSNR, let hi = cell.maxSNR else { return nil }
                                return (lo, hi)
                            }()
                        )
                    }

                    // Shared detail rows
                    VStack(spacing: 3) {
                        if let filtered = viewModel.filteredCellStats {
                            if let latest = filtered.latestTimestamp {
                                lastHeardRow(label: "Last Heard", date: latest)
                            }
                        } else {
                            if let bestGW = cell.bestGatewaySNR {
                                let hexLabel = cell.bestGatewayHexID.map { " (\($0))" } ?? ""
                                detailRow(label: "Best Repeater", value: String(format: "%.1f dB", bestGW) + hexLabel)
                            }
                            if let latest = cell.latestTimestamp {
                                lastHeardRow(label: "Last Heard", date: latest)
                            }
                            if cell.maxMeshDepth > 0 {
                                detailRow(label: "Mesh Reach", value: "\(cell.maxMeshDepth) \(cell.maxMeshDepth == 1 ? "hop" : "hops")")
                            }
                        }

                        // Probe success rate
                        if let probes = cell.probesSent, probes > 0, cell.activePacketCount > 0 {
                            let successCount = min(cell.activePacketCount, probes)
                            let rate = Double(successCount) / Double(probes)
                            let pct = Int(round(rate * 100))
                            let rateColor: Color = pct >= 75 ? .green : pct >= 40 ? .yellow : .red
                            detailRow(label: "Probe Success", value: "\(pct)% (\(successCount)/\(probes))", valueColor: rateColor)
                        }
                    }

                    // Mesh Gateway section (Deep Scan only)
                    if let bestGateway = cell.meshScores.first, viewModel.selectedRelayFilter == nil {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "point.3.connected.trianglepath.dotted")
                                    .font(.caption2)
                                    .foregroundStyle(.cyan)
                                Text("Best Mesh Gateway")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 12) {
                                VStack(spacing: 1) {
                                    Text(bestGateway.hexID)
                                        .font(.system(.caption, design: .monospaced, weight: .medium))
                                    Text("Repeater")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }

                                VStack(spacing: 1) {
                                    Text("\(bestGateway.reachableNodes)")
                                        .font(.system(.caption, design: .monospaced, weight: .medium))
                                    Text("Nodes")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }

                                VStack(spacing: 1) {
                                    Text("\(bestGateway.maxDepth)")
                                        .font(.system(.caption, design: .monospaced, weight: .medium))
                                    Text(bestGateway.maxDepth == 1 ? "Hop" : "Hops")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }

                                if let avgSNR = bestGateway.avgPathSNR {
                                    VStack(spacing: 1) {
                                        Text(String(format: "%.1f", avgSNR))
                                            .font(.system(.caption, design: .monospaced, weight: .medium))
                                            .foregroundStyle(SNRQuality(snr: avgSNR).color)
                                        Text("Path SNR")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 4)
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
                            .padding(.vertical, 6)
                            .foregroundStyle(Color.accentColor)
                            .contentShape(Rectangle())
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
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 6)
                                                        .foregroundStyle(Color.accentColor)
                                                        .contentShape(Rectangle())
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
            .fixedSize(horizontal: false, vertical: true)
            .liquidGlass(in: .rect(cornerRadius: 16))
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Signal column for the two-column RX/TX layout.
    /// Horizontal: bars on left, stacked stats on right — fills width, saves height.
    private func signalColumn(
        label: String, arrowName: String,
        snr: Double?, quality: SNRQuality,
        rssi: Double?, snrRange: (min: Double, max: Double)?,
        unknownReason: String? = nil
    ) -> some View {
        HStack(spacing: 6) {
            // Signal bars (or placeholder)
            if quality != .unknown {
                Image(systemName: "cellularbars", variableValue: quality.barLevel)
                    .foregroundStyle(quality.color)
                    .font(.system(size: 22))
                    .overlay(alignment: .topLeading) {
                        Image(systemName: arrowName)
                            .font(.system(size: 5, weight: .black))
                            .foregroundStyle(quality.color)
                            .offset(x: -1, y: -1)
                    }
            } else {
                Image(systemName: "cellularbars", variableValue: 0)
                    .foregroundStyle(.quaternary)
                    .font(.system(size: 22))
            }

            // Stacked stats
            VStack(alignment: .leading, spacing: 1) {
                // Label
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)

                if quality != .unknown {
                    // Quality + SNR on one line
                    HStack(spacing: 3) {
                        Text(quality.qualityLabel)
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundStyle(quality.color)
                        if let snr {
                            Text(String(format: "%.1f", snr))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    // RSSI
                    if let rssi {
                        Text(String(format: "RSSI %.0f dBm", rssi))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    // SNR range
                    if let range = snrRange {
                        Text(String(format: "%.0f–%.0f dB", range.min, range.max))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                } else if let reason = unknownReason {
                    Text(reason)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("—")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(label: String, value: String, valueColor: Color = .primary) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(valueColor)
        }
    }

    private func lastHeardRow(label: String, date: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            detailRow(label: label, value: relativeTimeString(from: date, now: context.date) + " ago")
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
                HStack(spacing: 6) {
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
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
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
                                .contentShape(Capsule())
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
                    onLocationTap: { viewModel.trackingUserLocation.toggle() },
                    isTrackingLocation: viewModel.trackingUserLocation,
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

            // Floating badge to clear repeater filter (visible when filter active but no cell selected)
            if viewModel.communityRepeaterFilter != nil && viewModel.selectedCommunityCell == nil {
                HStack {
                    Button {
                        viewModel.communityRepeaterFilter = nil
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.caption2)
                            Text(viewModel.repeaterDisplayName(for: viewModel.communityRepeaterFilter!))
                                .font(.caption2)
                                .lineLimit(1)
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.cyan.opacity(0.3), in: Capsule())
                        .foregroundStyle(.cyan)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .transition(.scale.combined(with: .opacity))
            }

            communityFilterBar

            // Survey controls — single horizontal toolbar row
            if !viewModel.allPoints.isEmpty || viewModel.isActive {
            HStack(spacing: 8) {
                // Start/Stop button
                surveyToggleButton

                if viewModel.isActive {
                    // Pause/Resume button
                    Button {
                        Task {
                            guard let surveyService = appState.services?.surveyService else { return }
                            if viewModel.isPaused {
                                await viewModel.resumeSurvey(
                                    surveyService: surveyService,
                                    locationService: appState.locationService
                                )
                            } else {
                                await viewModel.pauseSurvey(surveyService: surveyService)
                            }
                        }
                    } label: {
                        Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
                    }
                    .tint(viewModel.isPaused ? .green : .yellow)
                    .modifier(GlassButtonStyleModifier())
                }

                // Filter menu pill
                if viewModel.livePointCount > 0 || viewModel.isActive {
                    surveyFilterMenu
                }

                if viewModel.isActive {
                    Spacer(minLength: 0)

                    // Probe settings menu — combines toggle, frequency, channel
                    probeSettingsMenu

                    // Manual Probe button
                    Button {
                        Task { await viewModel.sendManualProbe() }
                    } label: {
                        Image(systemName: "wave.3.right")
                            .overlay {
                                Circle()
                                    .stroke(Color.orange, lineWidth: 2)
                                    .scaleEffect(probePulseScale)
                                    .opacity(probePulseScale > 1 ? 0 : 1)
                            }
                    }
                    .tint(.orange)
                    .modifier(GlassButtonStyleModifier())
                    .disabled(!viewModel.canSendManualProbe || viewModel.isPaused)
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
            .sensoryFeedback(.impact(weight: .heavy, intensity: 1.0), trigger: viewModel.probeSuccessHaptic)
            .sensoryFeedback(.error, trigger: viewModel.probeErrorHaptic)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .overlay(alignment: .top) {
                if let errorMsg = viewModel.probeErrorMessage {
                    Text(errorMsg)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .liquidGlass(in: .capsule)
                        .offset(y: -24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: viewModel.probeErrorHaptic) {
                            try? await Task.sleep(for: .seconds(2))
                            viewModel.probeErrorMessage = nil
                        }
                }
            }
            } // end survey controls if
        }
        .animation(.snappy(duration: 0.25), value: viewModel.selectedCell?.coordKey)
        .animation(.snappy(duration: 0.25), value: viewModel.selectedCommunityCell?.id)
        .animation(.snappy(duration: 0.25), value: viewModel.showCommunityOverlay)
    }

    /// Label for the repeater filter button — shows name if available, otherwise hex ID.
    private var repeaterFilterLabel: String {
        guard let filter = viewModel.communityRepeaterFilter else { return "All" }
        // Look up name from available repeaters
        if let match = viewModel.communityAvailableRepeaters.first(where: { $0.hexID == filter }) {
            return match.displayName
        }
        return filter
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

                    ForEach(viewModel.communityAvailableRepeaters, id: \.hexID) { repeater in
                        Button {
                            viewModel.communityRepeaterFilter = repeater.hexID
                        } label: {
                            HStack {
                                Text(repeater.displayName)
                                if viewModel.communityRepeaterFilter == repeater.hexID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption2)
                        Text(repeaterFilterLabel)
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

                Menu {
                    ForEach(MapTimeFilter.allCases) { filter in
                        Button {
                            viewModel.communityTimeFilter = filter
                        } label: {
                            HStack {
                                Text(filter.displayName)
                                if viewModel.communityTimeFilter == filter {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text(viewModel.communityTimeFilter.displayName)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(viewModel.communityTimeFilter != .allTime ? .cyan : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(viewModel.communityTimeFilter != .allTime ? Color.cyan.opacity(0.15) : Color.secondary.opacity(0.1))
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

    /// Look up per-repeater metrics for the active filter in a cell.
    private func filteredRepeaterMetric(for cell: SurveyUploadService.CommunityCell) -> SurveyUploadService.RepeaterMetric? {
        guard let filter = viewModel.communityRepeaterFilter,
              let metrics = cell.repeaterMetrics else { return nil }
        let rf = filter.uppercased()
        return metrics.first { m in
            let mh = m.hexID.uppercased()
            return mh == rf || mh.hasPrefix(rf) || rf.hasPrefix(mh)
        }
    }

    @ViewBuilder
    private var communityCellDetailCard: some View {
        if let cell = viewModel.selectedCommunityCell {
            let repeaterMetric = filteredRepeaterMetric(for: cell)
            let displaySNR = repeaterMetric?.averageSNR ?? cell.averageSNR
            let displayPackets = repeaterMetric?.packetCount ?? cell.packetCount
            let quality = SNRQuality(snr: displaySNR)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "globe.americas.fill")
                        .foregroundStyle(.cyan)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(quality.qualityLabel)
                            .font(.subheadline.weight(.semibold))
                        if repeaterMetric != nil {
                            Text(viewModel.repeaterDisplayName(for: viewModel.communityRepeaterFilter!))
                                .font(.caption)
                                .foregroundStyle(.cyan)
                        } else {
                            Text("Community data")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    communityCellSignalBar(quality: quality)

                    Button {
                        viewModel.selectedCommunityCell = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let snr = displaySNR {
                            Label(String(format: "%.1f dB SNR", snr), systemImage: "antenna.radiowaves.left.and.right")
                                .font(.caption)
                        }
                        Label("\(displayPackets) packets", systemImage: "number")
                            .font(.caption)
                        if repeaterMetric == nil,
                           let active = cell.activePacketCount, let passive = cell.passivePacketCount,
                           active > 0 || passive > 0 {
                            HStack(spacing: 6) {
                                if active > 0 && viewModel.communityCoverageFilter != .passive {
                                    Text("\(active) active")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                                if passive > 0 && viewModel.communityCoverageFilter != .active {
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
                                    Text(viewModel.repeaterDisplayName(for: hexID))
                                        .font(.caption2)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(
                                            viewModel.communityRepeaterFilter == hexID
                                                ? Color.cyan.opacity(0.35)
                                                : Color.cyan.opacity(0.15),
                                            in: Capsule()
                                        )
                                        .contentShape(Capsule())
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

        return HStack(alignment: .bottom, spacing: 2) {
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

                // MARK: Contributor Identity
                Section {
                    Toggle("Include Contact Name", isOn: $includeDisplayName)
                    if includeDisplayName {
                        HStack {
                            Text("Name")
                            Spacer()
                            Text(appState.connectedDevice?.nodeName ?? "Not connected")
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Verified")
                            Spacer()
                            if isVerifying {
                                ProgressView()
                                    .controlSize(.small)
                            } else if contributorVerified {
                                Label("Verified", systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(.green)
                                    .font(.subheadline)
                            } else if appState.connectedDevice != nil {
                                Button("Verify Now") {
                                    Task { await performVerification() }
                                }
                                .font(.subheadline)
                            } else {
                                Text("Connect device to verify")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let verificationError {
                            Text(verificationError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        if contributorVerified {
                            Button {
                                showingContributorProfile = true
                            } label: {
                                Label("My Contributions", systemImage: "person.crop.circle")
                            }
                            .font(.subheadline)
                        }
                    }
                } footer: {
                    Text("Your contact name will appear on the community map. Verification uses your device's cryptographic key to prove identity. Anonymous by default.")
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
                        // Set display name for uploads before starting
                        viewModel.displayNameForUpload = includeDisplayName ? appState.connectedDevice?.nodeName : nil
                        Task {
                            // Auto-verify if name enabled, device connected, and not yet verified
                            if includeDisplayName && !contributorVerified && appState.services?.settingsService != nil {
                                await performVerification()
                            }

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

    // MARK: - Contributor Verification

    private func performVerification() async {
        guard let settingsService = appState.services?.settingsService else {
            verificationError = "Device not connected"
            return
        }

        isVerifying = true
        verificationError = nil
        defer { isVerifying = false }

        do {
            let uploadService = SurveyUploadService()
            let contributorID = try await uploadService.getOrCreateContributorID()
            let verificationService = ContributorVerificationService()
            let result = try await verificationService.verify(
                settingsService: settingsService,
                contributorID: contributorID
            )
            contributorVerified = result.verified
            if !result.verified {
                verificationError = "Verification failed"
            } else {
                // If migrated, update stored contributor ID to public key hash
                if let newID = result.newContributorID {
                    await uploadService.updateContributorID(newID)
                }
                // Store auth token for self-service API access
                if let token = result.authToken {
                    verificationService.storeAuthToken(
                        token, expires: result.authTokenExpires
                    )
                }
            }
        } catch {
            verificationError = error.localizedDescription
        }
    }

    // MARK: - Survey Filter Menu

    private var surveyFilterMenu: some View {
        Menu {
            ForEach(SignalSurveyViewModel.SurveyFilter.allCases, id: \.self) { filter in
                Button {
                    viewModel.surveyFilter = filter
                } label: {
                    HStack {
                        Text(filter.rawValue)
                        if viewModel.surveyFilter == filter {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: filterIconName)
                    .font(.caption)
                Text(viewModel.surveyFilter.rawValue)
                    .font(.caption)
            }
            .foregroundStyle(viewModel.surveyFilter == .all ? Color.secondary : Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .liquidGlass(in: .capsule)
        }
    }

    private var filterIconName: String {
        switch viewModel.surveyFilter {
        case .all: "line.3.horizontal.decrease.circle"
        case .passiveOnly: "ear"
        case .traceOnly: "antenna.radiowaves.left.and.right"
        }
    }

    // MARK: - Probe Settings Menu (combined toggle + frequency + channel)

    private var probeSettingsMenu: some View {
        Menu {
            // Probe toggle
            Button {
                probeEnabledPref.toggle()
            } label: {
                Label(
                    viewModel.probeEnabled ? "Disable Probing" : "Enable Probing",
                    systemImage: viewModel.probeEnabled
                        ? "antenna.radiowaves.left.and.right.slash"
                        : "antenna.radiowaves.left.and.right"
                )
            }

            if viewModel.probeEnabled {
                Divider()

                // Frequency
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
                    Label("Frequency: \(viewModel.probeFrequency.rawValue)", systemImage: "gauge.with.dots.needle.33percent")
                }

                // Channel (inline submenu)
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
                    if let channel = viewModel.selectedProbeChannel {
                        Label("Channel: \(channel.displayName)", systemImage: "bubble.left.and.bubble.right.fill")
                    } else {
                        Label("Channel: None", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.probeEnabled
                      ? "antenna.radiowaves.left.and.right"
                      : "antenna.radiowaves.left.and.right.slash")
                    .font(.caption)
                if viewModel.probeEnabled {
                    Text("\(viewModel.probeCount)")
                        .font(.system(.caption, design: .monospaced))
                }
            }
            .foregroundStyle(viewModel.probeEnabled ? .green : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .liquidGlass(in: .capsule)
        }
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
                    let wasLiveUpload = viewModel.liveUploadEnabled
                    let session = viewModel.activeSession
                    await viewModel.stopSurvey(
                        surveyService: service,
                        locationService: appState.locationService,
                        dataStore: appState.offlineDataStore,
                        deviceID: appState.currentDeviceID
                    )
                    if let session {
                        let stats = viewModel.computeCompletionStats(session: session)
                        viewModel.surveyCompletionStats = stats
                        // Persist stats and compute personal records
                        let dto = viewModel.statsDTO(from: stats)
                        viewModel.personalRecords = viewModel.computePersonalRecords(current: dto)
                        if let dataStore = appState.offlineDataStore {
                            try? await dataStore.saveCompletionStats(sessionID: session.id, stats: dto)
                            // Reload sessions so the saved stats appear in session list
                            await viewModel.loadSessions(dataStore: dataStore, deviceID: session.deviceID)
                        }
                        // Pass session ID so the completion sheet can offer inline upload
                        if !wasLiveUpload {
                            completionSessionID = session.id
                        }
                        showingCompletionSummary = true
                    }
                }
            } else {
                showingSurveySetup = true
            }
        } label: {
            if viewModel.isActive {
                Image(systemName: "stop.fill")
            } else {
                Label(
                    isDisabled ? "Connect to Start" : "Start Survey",
                    systemImage: isDisabled
                        ? "antenna.radiowaves.left.and.right.slash"
                        : "antenna.radiowaves.left.and.right"
                )
                .fontWeight(.semibold)
            }
        }
        .tint(viewModel.isActive ? .red : (isDisabled ? .secondary : .accentColor))
        .modifier(GlassButtonStyleModifier())
        .disabled(isDisabled)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 0) {
                if !viewModel.sessions.isEmpty {
                    Button {
                        showingSessionList = true
                    } label: {
                        Label("Sessions", systemImage: "list.bullet")
                    }
                }

                if !viewModel.sessions.isEmpty && !viewModel.isActive {
                    Button {
                        batchSelectedSessions = Set(viewModel.sessions.map(\.id))
                        showingBatchUpload = true
                    } label: {
                        Label("Upload", systemImage: "icloud.and.arrow.up")
                    }
                }

                Menu {
                if viewModel.selectedSessionID != nil && !viewModel.isActive {
                    Button {
                        showingExportSheet = true
                    } label: {
                        Label("Export Session", systemImage: "square.and.arrow.up")
                    }
                }

                if !viewModel.sessions.isEmpty {
                    Button {
                        guard let dataStore = appState.offlineDataStore,
                              let deviceID = appState.currentDeviceID else { return }
                        viewModel.selectedSessionID = nil
                        Task {
                            await viewModel.loadAllPoints(dataStore: dataStore, deviceID: deviceID)
                        }
                    } label: {
                        Label("Show All Sessions on Map", systemImage: "map.fill")
                    }

                    Button {
                        viewModel.clearSessionData()
                    } label: {
                        Label("Clear Map", systemImage: "eye.slash")
                    }

                    Divider()
                }

                if contributorVerified {
                    Button {
                        showingContributorProfile = true
                    } label: {
                        Label("My Contributions", systemImage: "person.crop.circle")
                    }

                    Divider()
                }

                Button {
                    showingSurveySetup = true
                } label: {
                    Label("Survey Settings", systemImage: "gearshape")
                }

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

        ToolbarItem(placement: .topBarTrailing) {
            SignalBarsToolbarItem(showDuringSurvey: true)
        }
    }

    // MARK: - Sub-State Navigation

    /// True when the view is showing a map sub-state that should return to the
    /// dashboard (empty state) before navigating back to Tools.
    /// Only applies when browsing community data or viewing a past session
    /// without an active survey running.
    private var isShowingMapSubState: Bool {
        !viewModel.isActive
        && (viewModel.showCommunityOverlay || !viewModel.allPoints.isEmpty)
    }

    /// Return to the empty-state dashboard by clearing map sub-state.
    private func returnToDashboard() {
        withAnimation {
            viewModel.showCommunityOverlay = false
            viewModel.clearSessionData()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer()
                    .frame(height: 20)

                // Hero
                VStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)

                    Text("Signal Survey")
                        .font(.title2.weight(.bold))

                    Text("Map your mesh coverage by walking around. Each received packet is tagged with GPS to build a heat map of signal quality.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }

                // Primary action
                if appState.services?.surveyService != nil {
                    Button {
                        showingSurveySetup = true
                    } label: {
                        Label("Start Survey", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: 260)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Label("Connect a radio to start surveying", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Secondary actions
                VStack(spacing: 0) {
                    if !viewModel.sessions.isEmpty {
                        Button {
                            showingSessionList = true
                        } label: {
                            HStack {
                                Label("Past Sessions", systemImage: "list.bullet")
                                Spacer()
                                Text("\(viewModel.sessions.count)")
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .padding(.leading, 52)
                    }

                    Button {
                        viewModel.showCommunityOverlay = true
                    } label: {
                        HStack {
                            Label("Community Map", systemImage: "globe.americas")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .padding(.leading, 52)

                    Button {
                        showingInfoSheet = true
                    } label: {
                        HStack {
                            Label("How It Works", systemImage: "info.circle")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Community-Only Mode Overlay

    /// Floating action buttons shown when the map is visible but no session data is loaded
    /// (i.e. the user is browsing community data only).
    private var communityModeOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                if appState.services?.surveyService != nil {
                    Button {
                        showingSurveySetup = true
                    } label: {
                        Label("Start Survey", systemImage: "play.fill")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if !viewModel.sessions.isEmpty {
                    Button {
                        showingSessionList = true
                    } label: {
                        Label("Sessions", systemImage: "list.bullet")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            // Extra bottom padding when community filter bar is visible to avoid overlap
            .padding(.bottom, viewModel.showCommunityOverlay ? 60 : 16)
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
                        // Summary header
                        sessionListSummaryHeader
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)

                        ForEach(viewModel.sessions) { session in
                            Button {
                                viewModel.selectedSessionID = session.id
                                if let dataStore = appState.offlineDataStore {
                                    Task {
                                        await viewModel.loadPoints(
                                            dataStore: dataStore,
                                            sessionID: session.id,
                                            session: session
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
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingLifetimeStats = true
                    } label: {
                        Image(systemName: "chart.bar.xaxis")
                    }
                    .disabled(viewModel.sessions.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingSessionList = false }
                }
            }
            .sheet(isPresented: $showingLifetimeStats) {
                LifetimeStatsView(
                    sessions: viewModel.sessions,
                    sessionStats: viewModel.sessionStats
                )
            }
        }
    }

    private var sessionListSummaryHeader: some View {
        let sessions = viewModel.sessions
        let totalSessions = sessions.count
        let totalPackets = viewModel.sessionStats.values.reduce(0) { $0 + $1.pointCount }
        let totalCells = viewModel.sessionStats.values.reduce(0) { $0 + $1.cellCount }
        let totalSeconds = sessions.compactMap { s -> TimeInterval? in
            guard let ended = s.endedAt else { return nil }
            return ended.timeIntervalSince(s.startedAt)
        }.reduce(0, +)

        let hours = totalSeconds / 3600
        let timeStr: String = if hours >= 1 {
            String(format: "%.1f hrs", hours)
        } else {
            "\(Int(totalSeconds / 60)) min"
        }

        return HStack(spacing: 4) {
            Text("\(totalSessions) sessions")
            Text("·").foregroundStyle(.quaternary)
            Text("\(totalPackets) packets")
            Text("·").foregroundStyle(.quaternary)
            Text("\(totalCells) cells")
            Text("·").foregroundStyle(.quaternary)
            Text(timeStr)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func sessionRow(_ session: SurveySessionDTO) -> some View {
        HStack {
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

            Spacer()

            if session.completionStats != nil {
                Button {
                    showingHistoricalStats = session
                } label: {
                    Image(systemName: "chart.bar.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Glass Button Style (iOS 26+)

/// Applies `.buttonStyle(.glass)` on iOS 26+ with a `.borderedProminent` fallback.
private struct GlassButtonStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.borderedProminent)
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
    var probesSentPerCell: [String: Int] = [:]
    var deadZoneHexCoords: [(q: Int, r: Int)] = []
    var displayName: String?

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
            await service.setDisplayName(displayName)
            let response = try await service.uploadMultipleSessions(
                sessionIDs: Array(selectedSessions),
                dataStore: dataStore,
                repeaterContacts: repeaterContacts,
                probesSentPerCell: probesSentPerCell,
                deadZoneHexCoords: deadZoneHexCoords
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

