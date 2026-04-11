import os
import SwiftUI
import MapKit
import MC1Services

private let logger = Logger(subsystem: "com.mc1", category: "MapView")

/// Map view displaying contacts with their locations
struct MapView: View {
    /// Estimated duration for sheet presentation animation. SwiftUI doesn't provide a completion callback,
    /// so we use this delay before switching to the snapshot to hide the transition from the user.
    private static let sheetPresentationDuration: Duration = .milliseconds(500)

    @Environment(\.appState) private var appState
    @State private var viewModel = MapViewModel()
    @State private var selectedContactForDetail: ContactDTO?
    /// Static snapshot of the map shown while sheets are presented to prevent memory growth from SwiftUI keyboard layout cycles
    @State private var mapSnapshot: UIImage?
    /// Controls when snapshot is shown - delayed until after sheet presents to hide the transition
    @State private var isSnapshotActive = false
    /// Whether the weather data inspector sheet is showing
    @State private var showingWeatherInspector = false
    /// Closure to get snapshot parameters directly from MKMapView (camera + bounds, avoids async binding lag)
    @State private var getSnapshotParams: (() -> (camera: MKMapCamera, size: CGSize)?)?

    var body: some View {
        NavigationStack {
            mapCanvas
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        BLEStatusIndicatorView()
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        refreshButton
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        SignalBarsToolbarItem()
                    }
                }
                .task {
                    appState.locationService.requestPermissionIfNeeded()
                    appState.locationService.requestLocation()
                    viewModel.configure(appState: appState)
                    await viewModel.loadContactsWithLocation()
                    viewModel.centerOnAllContacts()
                }
                .sheet(item: $selectedContactForDetail, onDismiss: clearMapSnapshot) { contact in
                    ContactDetailSheet(
                        contact: contact,
                        onMessage: { navigateToChat(with: contact) }
                    )
                    .presentationDetents([.large])
                }
                .sheet(item: $viewModel.selectedWeatherWarning) { warning in
                    WeatherWarningDetailSheet(warning: warning)
                        .presentationDetents([.medium])
                }
                .sheet(isPresented: $showingWeatherInspector) {
                    WeatherDataInspector(weatherCache: appState.weatherCache)
                        .presentationDetents([.large])
                }
                .liquidGlassToolbarBackground()
        }
    }

    // MARK: - Map Canvas

    private var mapCanvas: some View {
        ZStack {
            mapContent
                .ignoresSafeArea()

            // Floating controls
            VStack {
                HStack {
                    if viewModel.showCommunityOverlay {
                        communityFilterBar
                    } else {
                        contactsTimeFilterBar
                    }
                    Spacer(minLength: 0)
                    if !viewModel.showCommunityOverlay {
                        repeaterFilterBadge
                    }
                }
                .padding(.top, 8)
                Spacer()
                HStack(alignment: .bottom) {
                    communityCellDetailCard
                    Spacer(minLength: 0)
                    mapControls
                }
            }
            .animation(.snappy(duration: 0.25), value: viewModel.selectedCommunityCell?.id)
            .animation(.snappy(duration: 0.25), value: viewModel.communityRepeaterFilter)
            .animation(.snappy(duration: 0.25), value: viewModel.showCommunityOverlay)

            // Layers menu overlay
            if viewModel.showingLayersMenu {
                Button {
                    withAnimation {
                        viewModel.showingLayersMenu = false
                    }
                } label: {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                }
                .buttonStyle(.plain)

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        LayersMenu(
                            selection: $viewModel.mapStyleSelection,
                            isPresented: $viewModel.showingLayersMenu
                        )
                        .padding(.trailing, 72)
                        .padding(.bottom)
                    }
                }
            }
        }
    }

    // MARK: - Map Content

    @ViewBuilder
    private var mapContent: some View {
        if viewModel.filteredContacts.isEmpty && !viewModel.isLoading && !viewModel.showCommunityOverlay {
            emptyState
        } else {
            // Keep MKMapView always in tree to prevent Metal deallocation crashes
            // Hide it with opacity when showing snapshot instead of removing from hierarchy
            let showingSnapshot = isSnapshotActive && mapSnapshot != nil

            ZStack {
                MKMapViewRepresentable(
                    contacts: viewModel.filteredContacts,
                    mapType: viewModel.mapStyleSelection.mkMapType,
                    showLabels: viewModel.showLabels,
                    showsUserLocation: true,
                    communityCells: viewModel.filteredCommunityCells,
                    showCommunityOverlay: viewModel.showCommunityOverlay,
                    selectedCommunityCell: viewModel.selectedCommunityCell,
                    repeaterLocations: viewModel.repeaterLocations,
                    allRepeaterLocations: viewModel.allRepeaterLocations,
                    communityRepeaterFilter: viewModel.communityRepeaterFilter,
                    weatherWarnings: viewModel.weatherWarnings,
                    weatherRadarFrames: viewModel.weatherRadarFrames,
                    showWeatherOverlay: viewModel.showWeatherOverlay,
                    selectedContact: $viewModel.selectedContact,
                    cameraRegion: $viewModel.cameraRegion,
                    onDetailTap: { contact in
                        showContactDetail(contact)
                    },
                    onMessageTap: { contact in
                        navigateToChat(with: contact)
                    },
                    onRegionChanged: { region in
                        viewModel.loadCommunityCells(for: region)
                    },
                    onCommunityCellSelected: { cell in
                        withAnimation(.snappy(duration: 0.25)) {
                            viewModel.selectedCommunityCell = cell
                        }
                    },
                    onRepeaterTapped: { hexID in
                        withAnimation(.snappy(duration: 0.25)) {
                            if viewModel.communityRepeaterFilter == hexID {
                                viewModel.communityRepeaterFilter = nil
                            } else {
                                viewModel.communityRepeaterFilter = hexID
                            }
                        }
                    },
                    onWeatherWarningTapped: { warningID in
                        if let warning = viewModel.weatherWarning(for: warningID) {
                            viewModel.selectedWeatherWarning = warning
                        }
                    },
                    onSnapshotParamsGetter: { getter in
                        Task { @MainActor in
                            await Task.yield()
                            getSnapshotParams = getter
                        }
                    }
                )
                .opacity(showingSnapshot ? 0 : 1)

                if showingSnapshot, let snapshot = mapSnapshot {
                    // Show static snapshot while sheet is presented to prevent memory growth
                    // MKMapView clustering causes unbounded memory growth during keyboard layout cycles
                    // Must ignore safe area to match MKMapView's positioning (UIView fills entire area)
                    Image(uiImage: snapshot)
                        .resizable()
                        .ignoresSafeArea()
                }
            }
            .overlay {
                if viewModel.isLoading {
                    loadingOverlay
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.Map.Map.EmptyState.title, systemImage: "map")
        } description: {
            Text(L10n.Map.Map.EmptyState.description)
        } actions: {
            Button(L10n.Map.Map.Common.refresh) {
                Task {
                    await viewModel.loadContactsWithLocation()
                }
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Loading Overlay

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.1)
            ProgressView()
                .padding()
                .background(.regularMaterial, in: .rect(cornerRadius: 8))
        }
    }

    // MARK: - Map Controls

    private var mapControls: some View {
        MapControlsToolbar(
            onLocationTap: { centerOnUserLocation() },
            showingLayersMenu: $viewModel.showingLayersMenu
        ) {
            weatherOverlayButton
            communityOverlayButton
            labelsToggleButton
            centerAllButton
        }
    }

    private var weatherOverlayButton: some View {
        HStack(spacing: 0) {
            Button {
                viewModel.showWeatherOverlay.toggle()
                #if DEBUG
                // Auto-inject test data on first enable if cache is empty
                if viewModel.showWeatherOverlay && !appState.weatherCache.hasData {
                    appState.weatherCache.injectTestData()
                }
                #endif
            } label: {
                Image(systemName: "cloud.bolt.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(viewModel.showWeatherOverlay ? .blue : .primary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.showWeatherOverlay ? "Hide weather overlay" : "Show weather overlay")

            if viewModel.showWeatherOverlay {
                Button {
                    showingWeatherInspector = true
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(width: 32, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Weather data inspector")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: viewModel.showWeatherOverlay)
    }

    private var communityOverlayButton: some View {
        Button {
            viewModel.showCommunityOverlay.toggle()
            if viewModel.showCommunityOverlay, let region = viewModel.cameraRegion {
                viewModel.loadCommunityCells(for: region)
            }
        } label: {
            Image(systemName: "hexagon.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(viewModel.showCommunityOverlay ? .blue : .primary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.showCommunityOverlay ? "Hide signal overlay" : "Show signal overlay")
    }

    private var labelsToggleButton: some View {
        Button {
            withAnimation {
                viewModel.showLabels.toggle()
            }
        } label: {
            Image(systemName: "character.textbox")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(viewModel.showLabels ? .blue : .primary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.showLabels ? L10n.Map.Map.Controls.hideLabels : L10n.Map.Map.Controls.showLabels)
    }

    private var centerAllButton: some View {
        Button {
            clearSelection()
            viewModel.centerOnAllContacts()
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(viewModel.filteredContacts.isEmpty ? .secondary : .primary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.filteredContacts.isEmpty)
        .accessibilityLabel(L10n.Map.Map.Controls.centerAll)
    }

    // MARK: - Contacts Time Filter Bar

    private var contactsTimeFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(MapTimeFilter.allCases) { filter in
                    Button {
                        withAnimation {
                            viewModel.selectedTimeFilter = filter
                        }
                    } label: {
                        Text(filter.displayName)
                            .font(.caption)
                            .fontWeight(viewModel.selectedTimeFilter == filter ? .semibold : .regular)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                viewModel.selectedTimeFilter == filter
                                    ? AnyShapeStyle(.tint)
                                    : AnyShapeStyle(.ultraThinMaterial)
                            )
                            .foregroundStyle(viewModel.selectedTimeFilter == filter ? .white : .primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Community Filter Bar

    /// Label for the repeater filter button — shows name if available, otherwise hex ID.
    private var repeaterFilterLabel: String {
        guard let filter = viewModel.communityRepeaterFilter else { return "All" }
        if let match = viewModel.communityAvailableRepeaters.first(where: { $0.hexID == filter }) {
            return match.displayName
        }
        return filter
    }

    @ViewBuilder
    private var communityFilterBar: some View {
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
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Refresh Button

    private var refreshButton: some View {
        Button {
            Task {
                await viewModel.loadContactsWithLocation()
            }
        } label: {
            if viewModel.isLoading {
                ProgressView()
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(viewModel.isLoading)
    }

    // MARK: - Repeater Filter Badge

    @ViewBuilder
    private var repeaterFilterBadge: some View {
        if let filter = viewModel.communityRepeaterFilter {
            Button {
                withAnimation(.snappy(duration: 0.25)) {
                    viewModel.communityRepeaterFilter = nil
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption2)
                    Text(viewModel.repeaterDisplayName(for: filter))
                        .font(.caption2)
                        .lineLimit(1)
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.cyan.opacity(0.3), in: Capsule())
                .foregroundStyle(.cyan)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .transition(.scale.combined(with: .opacity))
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
                        withAnimation(.snappy(duration: 0.25)) {
                            viewModel.selectedCommunityCell = nil
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.title3)
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
                                    withAnimation(.snappy(duration: 0.25)) {
                                        if viewModel.communityRepeaterFilter == hexID {
                                            viewModel.communityRepeaterFilter = nil
                                        } else {
                                            viewModel.communityRepeaterFilter = hexID
                                        }
                                    }
                                } label: {
                                    Text(viewModel.repeaterDisplayName(for: hexID))
                                        .font(.caption2)
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
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.leading, 16)
            .padding(.bottom, 4)
            .frame(maxWidth: 300, alignment: .leading)
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

    // MARK: - Actions

    private func selectContact(_ contact: ContactDTO) {
        viewModel.centerOnContact(contact)
    }

    private func clearSelection() {
        viewModel.clearSelection()
    }

    private func navigateToChat(with contact: ContactDTO) {
        clearSelection()
        appState.navigation.navigateToChat(with: contact)
    }

    private func showContactDetail(_ contact: ContactDTO) {
        // Clear selection to prevent MKSmallCalloutView constraint corruption
        viewModel.selectedContact = nil
        // Present sheet immediately so user sees it animating in
        selectedContactForDetail = contact

        // Capture snapshot after sheet animation completes to hide the transition
        Task {
            try? await Task.sleep(for: Self.sheetPresentationDuration)
            // Guard against race condition if sheet was dismissed during delay
            guard selectedContactForDetail != nil else { return }
            await captureMapSnapshot()
            isSnapshotActive = true
        }
    }

    /// Captures a static snapshot of the current map view to display while sheets are presented
    private func captureMapSnapshot() async {
        // Get camera and bounds directly from MKMapView for pixel-perfect match
        // Using camera instead of region avoids MKMapSnapshotter's automatic aspect ratio adjustment
        guard let params = getSnapshotParams?() else { return }

        let options = MKMapSnapshotter.Options()
        options.camera = params.camera
        options.size = params.size
        options.scale = UIScreen.main.scale
        options.mapType = viewModel.mapStyleSelection.mkMapType
        options.showsBuildings = true

        let snapshotter = MKMapSnapshotter(options: options)
        do {
            let snapshot = try await snapshotter.start()
            mapSnapshot = snapshot.image
        } catch {
            logger.warning("Map snapshot capture failed: \(error.localizedDescription)")
            mapSnapshot = nil
        }
    }

    private func clearMapSnapshot() {
        isSnapshotActive = false
        mapSnapshot = nil
    }

    private func centerOnUserLocation() {
        guard let location = appState.locationService.currentLocation else { return }
        let span = MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        viewModel.cameraRegion = MKCoordinateRegion(center: location.coordinate, span: span)
    }
}

// MARK: - Contact Detail Sheet

private struct ContactDetailSheet: View {
    let contact: ContactDTO
    let onMessage: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appState) private var appState

    /// Sheet types for repeater flows
    private enum ActiveSheet: Identifiable, Hashable {
        case telemetryAuth
        case telemetryStatus(RemoteNodeSessionDTO)
        case adminAuth
        case adminSettings(RemoteNodeSessionDTO)
        case roomJoin

        var id: String {
            switch self {
            case .telemetryAuth: "telemetryAuth"
            case .telemetryStatus(let s): "telemetryStatus-\(s.id)"
            case .adminAuth: "adminAuth"
            case .adminSettings(let s): "adminSettings-\(s.id)"
            case .roomJoin: "roomJoin"
            }
        }
    }

    @State private var activeSheet: ActiveSheet?
    @State private var pendingSheet: ActiveSheet?

    var body: some View {
        NavigationStack {
            List {
                // Basic info section
                Section(L10n.Map.Map.Detail.Section.contactInfo) {
                    LabeledContent(L10n.Map.Map.Detail.name, value: contact.displayName)

                    LabeledContent(L10n.Map.Map.Detail.type) {
                        HStack {
                            Image(systemName: typeIconName)
                            Text(typeDisplayName)
                        }
                        .foregroundStyle(typeColor)
                    }

                    if contact.isFavorite {
                        LabeledContent(L10n.Map.Map.Detail.status) {
                            HStack {
                                Image(systemName: "star.fill")
                                Text(L10n.Map.Map.Detail.favorite)
                            }
                            .foregroundStyle(.orange)
                        }
                    }

                    if contact.lastAdvertTimestamp > 0 {
                        LabeledContent(L10n.Map.Map.Detail.lastAdvert) {
                            ConversationTimestamp(date: Date(timeIntervalSince1970: TimeInterval(contact.lastAdvertTimestamp)), font: .body)
                        }
                    }
                }

                // Public key section
                Section("Public Key") {
                    Text(contact.publicKey.hexString(separator: " "))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                // Location section
                Section(L10n.Map.Map.Detail.Section.location) {
                    LabeledContent(L10n.Map.Map.Detail.latitude) {
                        Text(contact.latitude, format: .number.precision(.fractionLength(6)))
                    }

                    LabeledContent(L10n.Map.Map.Detail.longitude) {
                        Text(contact.longitude, format: .number.precision(.fractionLength(6)))
                    }
                }

                // Path info section
                Section(L10n.Map.Map.Detail.Section.networkPath) {
                    if contact.isFloodRouted {
                        LabeledContent(L10n.Map.Map.Detail.routing, value: L10n.Map.Map.Detail.routingFlood)
                    } else {
                        let hopCount = contact.pathHopCount
                        LabeledContent(L10n.Map.Map.Detail.pathLength, value: hopCount == 1 ? L10n.Map.Map.Detail.hopSingular : L10n.Map.Map.Detail.hops(hopCount))
                    }
                }

                // Actions section
                Section {
                    switch contact.type {
                    case .repeater:
                        Button {
                            activeSheet = .telemetryAuth
                        } label: {
                            Label(L10n.Map.Map.Detail.Action.telemetry, systemImage: "chart.line.uptrend.xyaxis")
                        }

                        Button {
                            activeSheet = .adminAuth
                        } label: {
                            Label(L10n.Map.Map.Detail.Action.adminAccess, systemImage: "gearshape.2")
                        }

                    case .room:
                        Button {
                            activeSheet = .roomJoin
                        } label: {
                            Label(L10n.Map.Map.Detail.Action.joinRoom, systemImage: "door.left.hand.open")
                        }

                    case .chat:
                        Button {
                            dismiss()
                            onMessage()
                        } label: {
                            Label(L10n.Map.Map.Detail.Action.sendMessage, systemImage: "message.fill")
                        }
                        .radioDisabled(for: appState.connectionState)
                    }
                }
            }
            .navigationTitle(contact.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Map.Map.Common.done) {
                        dismiss()
                    }
                }
            }
            .sheet(item: $activeSheet, onDismiss: presentPendingSheet) { sheet in
                switch sheet {
                case .telemetryAuth:
                    if let role = RemoteNodeRole(contactType: contact.type) {
                        NodeAuthenticationSheet(
                            contact: contact,
                            role: role,
                            customTitle: L10n.Map.Map.Detail.Action.telemetryAccessTitle
                        ) { session in
                            pendingSheet = .telemetryStatus(session)
                            activeSheet = nil
                        }
                        .presentationSizing(.page)
                    }

                case .telemetryStatus(let session):
                    RepeaterStatusView(session: session)

                case .adminAuth:
                    if let role = RemoteNodeRole(contactType: contact.type) {
                        NodeAuthenticationSheet(contact: contact, role: role) { session in
                            pendingSheet = .adminSettings(session)
                            activeSheet = nil
                        }
                        .presentationSizing(.page)
                    }

                case .adminSettings(let session):
                    NavigationStack {
                        RepeaterSettingsView(session: session)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button(L10n.Map.Map.Common.done) {
                                        activeSheet = nil
                                    }
                                }
                            }
                    }
                    .presentationSizing(.page)

                case .roomJoin:
                    if let role = RemoteNodeRole(contactType: contact.type) {
                        NodeAuthenticationSheet(contact: contact, role: role) { session in
                            activeSheet = nil
                            dismiss()
                            appState.navigation.navigateToRoom(with: session)
                        }
                        .presentationSizing(.page)
                    }
                }
            }
        }
    }

    // MARK: - Sheet Management

    private func presentPendingSheet() {
        if let next = pendingSheet {
            pendingSheet = nil
            activeSheet = next
        }
    }

    // MARK: - Computed Properties

    private var typeIconName: String {
        switch contact.type {
        case .chat:
            "person.fill"
        case .repeater:
            "antenna.radiowaves.left.and.right"
        case .room:
            "person.3.fill"
        }
    }

    private var typeDisplayName: String {
        switch contact.type {
        case .chat:
            L10n.Map.Map.NodeKind.chatContact
        case .repeater:
            L10n.Map.Map.NodeKind.repeater
        case .room:
            L10n.Map.Map.NodeKind.room
        }
    }

    private var typeColor: Color {
        switch contact.type {
        case .chat:
            .blue
        case .repeater:
            .green
        case .room:
            .purple
        }
    }
}

// MARK: - Preview

#Preview("Map with Contacts") {
    MapView()
        .environment(\.appState, AppState())
}

#Preview("Empty Map") {
    MapView()
        .environment(\.appState, AppState())
}
