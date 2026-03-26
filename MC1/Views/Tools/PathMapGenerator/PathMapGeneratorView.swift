import MapKit
import SwiftUI

/// Tool for generating path maps from manually-entered hex IDs.
/// Users enter comma or space-separated hex IDs and the tool resolves them
/// against local contacts/discovered nodes to display a route map.
struct PathMapGeneratorView: View {
    @Environment(\.appState) private var appState

    @State private var viewModel = PathMapGeneratorViewModel()

    var body: some View {
        VStack(spacing: 0) {
            inputSection
            mapSection
        }
        .navigationTitle("Path Map")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Link Copied", isPresented: $viewModel.showShareConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            if let url = viewModel.shareURL {
                Text(url.absoluteString)
            }
        }
    }

    // MARK: - Input Section

    private var inputSection: some View {
        VStack(spacing: 12) {
            TextField("Hex IDs (e.g., A3, 7F42, B5C9)", text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .lineLimit(2...4)

            HStack(spacing: 12) {
                Button {
                    Task {
                        let userLocation = appState.locationService.currentLocation
                        guard let services = appState.services else { return }
                        let deviceID = appState.connectedDevice?.id ?? UUID()
                        await viewModel.generateMap(
                            services: services,
                            deviceID: deviceID,
                            userLocation: userLocation
                        )
                    }
                } label: {
                    Label("Generate", systemImage: "map")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.isInputValid)

                if viewModel.hexPath != nil {
                    Button {
                        Task {
                            let location = appState.locationService.currentLocation
                            await viewModel.sharePath(
                                userLatitude: location?.coordinate.latitude,
                                userLongitude: location?.coordinate.longitude,
                                userName: appState.connectedDevice?.nodeName
                            )
                            if let url = viewModel.shareURL {
                                UIPasteboard.general.string = url.absoluteString
                            }
                        }
                    } label: {
                        if viewModel.isSharing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.canShare)
                }
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
    }

    // MARK: - Map Section

    @ViewBuilder
    private var mapSection: some View {
        if viewModel.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let mapVM = viewModel.mapViewModel, mapVM.hasLocatedHops {
            ZStack {
                MessageRouteMapMKMapView(
                    repeaterAnnotations: mapVM.repeaterAnnotations,
                    endpointAnnotations: mapVM.endpointAnnotations,
                    lineOverlays: mapVM.lineOverlays,
                    mapType: mapVM.mapType,
                    pathState: mapVM.pathState,
                    labelMode: mapVM.labelMode,
                    cameraRegion: Binding(
                        get: { mapVM.cameraRegion },
                        set: { mapVM.cameraRegion = $0 }
                    ),
                    cameraRegionVersion: mapVM.cameraRegionVersion
                )
                .ignoresSafeArea()

                infoBanner(mapVM)
                mapToolbar(mapVM)
            }
        } else if viewModel.hexPath != nil {
            ContentUnavailableView(
                "No Located Repeaters",
                systemImage: "map",
                description: Text("None of the nodes in this path have known locations on your device.")
            )
        } else {
            ContentUnavailableView(
                "Path Map Generator",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("Enter comma or space-separated hex IDs to visualize a path on the map.")
            )
        }
    }

    // MARK: - Info Banner

    private func infoBanner(_ mapVM: SharedRouteMapViewModel) -> some View {
        VStack {
            HStack {
                Text("\(mapVM.locatedHopCount) of \(mapVM.totalHopCount) hops located")
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

    // MARK: - Map Toolbar

    private func mapToolbar(_ mapVM: SharedRouteMapViewModel) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                MapControlsToolbar(
                    onLocationTap: {
                        if let location = appState.locationService.currentLocation {
                            mapVM.cameraRegion = MKCoordinateRegion(
                                center: location.coordinate,
                                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                            )
                            mapVM.cameraRegionVersion += 1
                        } else {
                            appState.locationService.requestLocation()
                        }
                    },
                    showingLayersMenu: Binding(
                        get: { mapVM.showingLayersMenu },
                        set: { mapVM.showingLayersMenu = $0 }
                    )
                ) {
                    // Label mode toggle
                    Button {
                        mapVM.labelMode = mapVM.labelMode.next
                    } label: {
                        Image(systemName: mapVM.labelMode.iconName)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(mapVM.labelMode != .hidden ? .blue : .primary)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

                    // Center on route
                    Button {
                        mapVM.centerOnRoute()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Center on route")
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if mapVM.showingLayersMenu {
                LayersMenu(
                    selection: Binding(
                        get: { mapVM.mapStyleSelection },
                        set: { mapVM.mapStyleSelection = $0 }
                    ),
                    isPresented: Binding(
                        get: { mapVM.showingLayersMenu },
                        set: { mapVM.showingLayersMenu = $0 }
                    )
                )
                .padding(.trailing, 16)
                .padding(.bottom, 160)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: mapVM.showingLayersMenu)
    }
}
