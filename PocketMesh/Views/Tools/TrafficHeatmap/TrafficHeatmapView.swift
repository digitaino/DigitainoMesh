import MapKit
import SwiftUI
import PocketMeshServices

/// Tool view that displays aggregated mesh traffic patterns on a map.
/// Shows bubble annotations on repeaters (sized by traffic volume, colored by signal quality)
/// and weighted route lines between hops.
struct TrafficHeatmapView: View {
    @Environment(\.appState) private var appState

    @State private var viewModel = TrafficHeatmapViewModel()

    var body: some View {
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
        .navigationTitle(L10n.Tools.Tools.trafficMap)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                timePeriodMenu
            }
        }
        .task(id: appState.servicesVersion) {
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
        await viewModel.load(
            dataStore: dataStore,
            deviceID: deviceID,
            userLocation: appState.locationService.currentLocation
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
        TrafficHeatmapMKMapView(
            bubbleAnnotations: viewModel.bubbleAnnotations,
            segmentOverlays: viewModel.segmentOverlays,
            mapType: viewModel.mapType,
            cameraRegion: $viewModel.cameraRegion,
            cameraRegionVersion: viewModel.cameraRegionVersion
        )
        .ignoresSafeArea()
    }

    // MARK: - Summary Banner

    private var summaryBanner: some View {
        VStack {
            Text(L10n.Tools.Tools.TrafficMap.summary(
                viewModel.locatedRepeaterCount,
                viewModel.segmentCount,
                viewModel.totalPacketsAnalyzed
            ))
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
            L10n.Tools.Tools.TrafficMap.noData,
            systemImage: "map",
            description: Text(L10n.Tools.Tools.TrafficMap.noDataDescription)
        )
    }

    private var noLocatedRepeatersState: some View {
        ContentUnavailableView(
            L10n.Tools.Tools.TrafficMap.noLocatedRepeaters,
            systemImage: "location.slash",
            description: Text(L10n.Tools.Tools.TrafficMap.noLocatedRepeatersDescription)
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
                    .accessibilityLabel(L10n.Tools.Tools.TrafficMap.centerOnData)
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
}
