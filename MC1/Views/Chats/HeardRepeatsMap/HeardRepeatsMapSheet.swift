import MapKit
import SwiftUI
import MC1Services

/// Sheet presenting a map view of heard repeat paths for a single outgoing message.
/// Shows each repeat's return path from repeaters back to the user, with SNR-based
/// coloring on segments and traffic bubbles on repeaters.
struct HeardRepeatsMapSheet: View {
    @Environment(\.appState) private var appState
    @Environment(\.dismiss) private var dismiss

    let repeats: [MessageRepeatDTO]
    let contacts: [ContactDTO]
    let discoveredNodes: [DiscoveredNodeDTO]

    @State private var viewModel = HeardRepeatsMapViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                if viewModel.isLoading {
                    ProgressView()
                } else if !viewModel.hasLocatedRepeaters {
                    noDataState
                } else {
                    mapContent
                    summaryBanner
                    mapToolbar
                }
            }
            .navigationTitle(L10n.Chats.Chats.HeardRepeats.Map.title)
            .navigationBarTitleDisplayMode(.inline)
            .liquidGlassToolbarBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Localizable.Common.close) { dismiss() }
                }
            }
        }
        .task {
            // Ensure we have a location before loading so lines can connect to the user
            if appState.locationService.currentLocation == nil,
               appState.locationService.isAuthorized {
                try? await appState.locationService.requestCurrentLocation(timeout: .seconds(5))
            }
            viewModel.load(
                repeats: repeats,
                contacts: contacts,
                discoveredNodes: discoveredNodes,
                userLocation: appState.locationService.currentLocation,
                userName: appState.connectedDevice?.nodeName
                    ?? L10n.Chats.Chats.Path.Receiver.you
            )
        }
    }

    // MARK: - Map Content

    private var mapContent: some View {
        HeardRepeatsMapMKMapView(
            repeaterAnnotations: viewModel.repeaterAnnotations,
            endpointAnnotations: viewModel.endpointAnnotations,
            lineOverlays: viewModel.lineOverlays,
            mapType: viewModel.mapType,
            pathState: viewModel.pathState,
            lastHopSNR: viewModel.lastHopSNR,
            labelMode: viewModel.labelMode,
            cameraRegion: $viewModel.cameraRegion,
            cameraRegionVersion: viewModel.cameraRegionVersion
        )
        .ignoresSafeArea()
    }

    // MARK: - Summary Banner

    private var summaryBanner: some View {
        VStack {
            HStack(spacing: 4) {
                if viewModel.canCycleRepeats {
                    Button {
                        viewModel.showPreviousRepeat()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }

                if viewModel.selectedRepeatIndex != nil {
                    Text(viewModel.selectedRepeatSummary)
                } else {
                    Text(L10n.Chats.Chats.HeardRepeats.Map.summary(
                        viewModel.repeatCount,
                        viewModel.locatedRepeaterCount
                    ))
                }

                if viewModel.canCycleRepeats {
                    Button {
                        viewModel.showNextRepeat()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .liquidGlass(in: .capsule)
            .animation(.easeInOut(duration: 0.2), value: viewModel.selectedRepeatIndex)

            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Empty State

    private var noDataState: some View {
        ContentUnavailableView(
            L10n.Chats.Chats.HeardRepeats.Map.Empty.title,
            systemImage: "map",
            description: Text(L10n.Chats.Chats.HeardRepeats.Map.Empty.description)
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
                    // Label mode toggle
                    Button {
                        viewModel.labelMode = viewModel.labelMode.next
                    } label: {
                        Image(systemName: viewModel.labelMode.iconName)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(viewModel.labelMode != .hidden ? .blue : .primary)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

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
                    .accessibilityLabel(L10n.Chats.Chats.HeardRepeats.Map.centerOnData)
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
