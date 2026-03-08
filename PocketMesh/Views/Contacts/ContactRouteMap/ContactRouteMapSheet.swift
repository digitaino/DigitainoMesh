import MapKit
import SwiftUI
import PocketMeshServices

/// Sheet presenting a map view of the aggregated route history for a specific contact.
/// Shows inbound (blue) and outbound (green) DM paths with directional arrowheads,
/// traffic bubbles on repeaters, and sender/receiver endpoint pins.
struct ContactRouteMapSheet: View {
    @Environment(\.appState) private var appState
    @Environment(\.dismiss) private var dismiss

    let contact: ContactDTO

    @State private var viewModel = ContactRouteMapViewModel()

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
                ToolbarItem(placement: .topBarTrailing) {
                    timePeriodMenu
                }
            }
        }
        .task {
            await loadData()
        }
        .onChange(of: viewModel.selectedPeriod) {
            Task { await loadData() }
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

    // MARK: - Time Period Menu

    private var timePeriodMenu: some View {
        Menu {
            ForEach(TrafficHeatmapViewModel.TimePeriod.allCases, id: \.self) { period in
                Button {
                    viewModel.selectedPeriod = period
                } label: {
                    if period == viewModel.selectedPeriod {
                        Label(period.displayName, systemImage: "checkmark")
                    } else {
                        Text(period.displayName)
                    }
                }
            }
        } label: {
            Label(L10n.Tools.Tools.TrafficMap.timePeriod, systemImage: "clock")
        }
    }

    // MARK: - Map Content

    private var mapContent: some View {
        ContactRouteMapMKMapView(
            bubbleAnnotations: viewModel.bubbleAnnotations,
            endpointAnnotations: viewModel.endpointAnnotations,
            segmentOverlays: viewModel.segmentOverlays,
            mapType: viewModel.mapType,
            showLabels: viewModel.showLabels,
            cameraRegion: $viewModel.cameraRegion,
            cameraRegionVersion: viewModel.cameraRegionVersion
        )
        .ignoresSafeArea()
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
                    onLocationTap: {
                        if let location = appState.locationService.currentLocation {
                            viewModel.cameraRegion = MKCoordinateRegion(
                                center: location.coordinate,
                                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                            )
                            viewModel.cameraRegionVersion += 1
                        } else {
                            appState.locationService.requestLocation()
                        }
                    },
                    showingLayersMenu: $viewModel.showingLayersMenu
                ) {
                    // Labels toggle
                    Button {
                        viewModel.showLabels.toggle()
                    } label: {
                        Image(systemName: "character.textbox")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(viewModel.showLabels ? .blue : .primary)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

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
