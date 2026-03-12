import MapKit
import SwiftUI
import MC1Services

/// Sheet presenting a map view of the aggregated route history for a specific contact.
/// Shows inbound (blue) and outbound (green) DM paths with directional coloring,
/// traffic bubbles on repeaters, and sender/receiver endpoint markers.
struct ContactRouteMapSheet: View {
    @Environment(\.appState) private var appState
    @Environment(\.dismiss) private var dismiss

    let contact: ContactDTO

    @State private var viewModel = ContactRouteMapViewModel()
    @Namespace private var mapScope

    var body: some View {
        NavigationStack {
            ZStack {
                if viewModel.isLoading {
                    ProgressView()
                } else if !viewModel.hasData {
                    noDataState
                } else if !viewModel.hasLocatedRepeaters {
                    noLocatedRepeatersState
                } else {
                    mapContent
                    summaryBanner
                    mapToolbar
                }
            }
            .navigationTitle(L10n.Contacts.Contacts.RouteMap.title)
            .navigationBarTitleDisplayMode(.inline)
            .liquidGlassToolbarBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Localizable.Common.close) { dismiss() }
                }
            }
        }
        .task {
            await loadData()
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        guard let dataStore = appState.offlineDataStore,
              let deviceID = appState.currentDeviceID else { return }
        // Ensure we have a location before loading so lines can connect to the user
        if appState.locationService.currentLocation == nil,
           appState.locationService.isAuthorized {
            try? await appState.locationService.requestCurrentLocation(timeout: .seconds(5))
        }
        await viewModel.load(
            contact: contact,
            dataStore: dataStore,
            deviceID: deviceID,
            userLocation: appState.locationService.currentLocation,
            userName: appState.connectedDevice?.nodeName
                ?? L10n.Chats.Chats.Path.Receiver.you
        )
    }

    // MARK: - Map Content

    private var mapContent: some View {
        Map(position: $viewModel.cameraPosition, scope: mapScope) {
            // Route segments with directional coloring
            ForEach(viewModel.segmentData) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(
                        segmentColor(for: segment),
                        lineWidth: segmentWidth(for: segment)
                    )
            }

            // Repeater bubbles
            ForEach(viewModel.bubbleAnnotations) { bubble in
                Annotation("", coordinate: bubble.coordinate) {
                    TrafficBubbleView(annotation: bubble)
                }
            }

            // Endpoint markers (sender = teal, receiver = blue)
            ForEach(viewModel.endpointAnnotations) { endpoint in
                Marker(
                    endpoint.name,
                    systemImage: endpoint.endpointType == .sender
                        ? "person.fill" : "antenna.radiowaves.left.and.right",
                    coordinate: endpoint.coordinate
                )
                .tint(endpoint.endpointType == .sender ? .teal : .blue)
            }

            UserAnnotation()
        }
        .mapStyle(viewModel.mapStyleSelection.mapStyle)
        .mapScope(mapScope)
        .ignoresSafeArea()
    }

    // MARK: - Segment Styling

    private func segmentColor(for segment: TrafficSegmentData) -> Color {
        switch segment.direction {
        case .inbound: .blue
        case .outbound: .green
        case .bidirectional: .purple
        case .unspecified:
            if let snr = segment.averageSNR {
                SNRQuality(snr: snr).color
            } else {
                .secondary
            }
        }
    }

    private func segmentWidth(for segment: TrafficSegmentData) -> CGFloat {
        // Scale from 2pt (lowest traffic) to 8pt (highest traffic)
        2 + 6 * segment.normalizedFrequency
    }

    // MARK: - Summary Banner

    private var summaryBanner: some View {
        VStack {
            HStack {
                Text(L10n.Contacts.Contacts.RouteMap.summary(
                    viewModel.inboundCount,
                    viewModel.outboundCount,
                    viewModel.locatedRepeaterCount
                ))
            }
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .liquidGlass(in: .capsule)

            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Empty States

    private var noDataState: some View {
        ContentUnavailableView(
            L10n.Contacts.Contacts.RouteMap.Empty.title,
            systemImage: "map",
            description: Text(L10n.Contacts.Contacts.RouteMap.Empty.description)
        )
    }

    private var noLocatedRepeatersState: some View {
        ContentUnavailableView(
            L10n.Contacts.Contacts.RouteMap.NoLocation.title,
            systemImage: "location.slash",
            description: Text(L10n.Contacts.Contacts.RouteMap.NoLocation.description)
        )
    }

    // MARK: - Map Toolbar

    private var mapToolbar: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                MapControlsToolbar(
                    mapScope: mapScope,
                    showingLayersMenu: $viewModel.showingLayersMenu
                ) {
                    // Find Path
                    Button {
                        Task { await findPath() }
                    } label: {
                        if viewModel.isFindingPath {
                            ProgressView()
                                .frame(width: 44, height: 44)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.primary)
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isFindingPath)
                    .accessibilityLabel(L10n.Contacts.Contacts.RouteMap.findPath)

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
                    .accessibilityLabel(L10n.Contacts.Contacts.RouteMap.centerOnData)
                }
            }
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

    // MARK: - Actions

    private func findPath() async {
        guard let contactService = appState.services?.contactService,
              let dataStore = appState.offlineDataStore,
              let deviceID = appState.currentDeviceID else { return }
        await viewModel.findPath(
            for: contact,
            contactService: contactService,
            dataStore: dataStore,
            deviceID: deviceID,
            userLocation: appState.locationService.currentLocation,
            userName: appState.connectedDevice?.nodeName
                ?? L10n.Chats.Chats.Path.Receiver.you
        )
    }
}

// MARK: - Traffic Bubble View (reused from TrafficHeatmapView)

/// Inline SwiftUI view for a repeater traffic bubble annotation.
/// Sized 24–56pt by normalized traffic, colored by SNR quality.
private struct TrafficBubbleView: View {
    let annotation: TrafficBubbleAnnotation

    var body: some View {
        Circle()
            .fill(annotation.snrQuality.color.opacity(0.7))
            .overlay {
                Circle()
                    .strokeBorder(annotation.snrQuality.color, lineWidth: 2)
            }
            .frame(width: bubbleSize, height: bubbleSize)
            .overlay {
                if bubbleSize >= 36 {
                    Text("\(annotation.packetCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
    }

    private var bubbleSize: CGFloat {
        24 + 32 * annotation.normalizedTraffic
    }
}
