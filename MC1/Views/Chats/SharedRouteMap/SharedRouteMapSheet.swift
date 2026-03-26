import CoreLocation
import MapKit
import SwiftUI
import MC1Services

/// Sheet presenting a map view of a shared route parsed from message text.
struct SharedRouteMapSheet: View {
    @Environment(\.appState) private var appState
    @Environment(\.dismiss) private var dismiss

    let sharedRoute: SharedRoute
    var hexPath: HexPath?

    @State private var mapViewModel = SharedRouteMapViewModel()
    @State private var isSharing = false
    @State private var shareURL: URL?
    @State private var showShareConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                if mapViewModel.isLoading {
                    ProgressView()
                } else if !mapViewModel.hasLocatedHops {
                    emptyState
                } else {
                    mapContent
                    infoBanner
                    mapToolbar
                }
            }
            .navigationTitle(hexPath != nil ? "Path Map" : "Shared Route")
            .navigationBarTitleDisplayMode(.inline)
            .liquidGlassToolbarBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Localizable.Common.close) { dismiss() }
                }
                if hexPath != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await sharePathToServer() }
                        } label: {
                            if isSharing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                        .disabled(isSharing || mapViewModel.isLoading)
                    }
                }
            }
            .alert("Link Copied", isPresented: $showShareConfirmation) {
                Button("OK", role: .cancel) {}
            } message: {
                if let url = shareURL {
                    Text(url.absoluteString)
                }
            }
        }
        .task {
            guard let services = appState.services else { return }
            let userLocation = appState.locationService.currentLocation
            await mapViewModel.loadRoute(
                sharedRoute: sharedRoute,
                services: services,
                deviceID: appState.connectedDevice?.id ?? UUID(),
                userLocation: userLocation
            )
        }
    }

    // MARK: - Map Content

    private var mapContent: some View {
        MessageRouteMapMKMapView(
            repeaterAnnotations: mapViewModel.repeaterAnnotations,
            endpointAnnotations: mapViewModel.endpointAnnotations,
            lineOverlays: mapViewModel.lineOverlays,
            mapType: mapViewModel.mapType,
            pathState: mapViewModel.pathState,
            labelMode: mapViewModel.labelMode,
            cameraRegion: $mapViewModel.cameraRegion,
            cameraRegionVersion: mapViewModel.cameraRegionVersion
        )
        .ignoresSafeArea()
    }

    // MARK: - Info Banner

    private var infoBanner: some View {
        VStack {
            HStack {
                Text("\(mapViewModel.locatedHopCount) of \(mapViewModel.totalHopCount) hops located")

                if let distance = sharedRoute.distanceText {
                    Text("•")
                    Text(distance)
                }
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

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView(
            "No Located Repeaters",
            systemImage: "map",
            description: Text("None of the repeaters in this shared route have known locations on your device.")
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
                            mapViewModel.cameraRegion = MKCoordinateRegion(
                                center: location.coordinate,
                                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                            )
                            mapViewModel.cameraRegionVersion += 1
                        } else {
                            appState.locationService.requestLocation()
                        }
                    },
                    showingLayersMenu: $mapViewModel.showingLayersMenu
                ) {
                    // Label mode toggle
                    Button {
                        mapViewModel.labelMode = mapViewModel.labelMode.next
                    } label: {
                        Image(systemName: mapViewModel.labelMode.iconName)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(mapViewModel.labelMode != .hidden ? .blue : .primary)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

                    // Center on route
                    Button {
                        mapViewModel.centerOnRoute()
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
            if mapViewModel.showingLayersMenu {
                LayersMenu(
                    selection: $mapViewModel.mapStyleSelection,
                    isPresented: $mapViewModel.showingLayersMenu
                )
                .padding(.trailing, 16)
                .padding(.bottom, 160)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: mapViewModel.showingLayersMenu)
    }

    // MARK: - Share

    private func sharePathToServer() async {
        guard let hexPath else { return }
        isSharing = true
        defer { isSharing = false }

        let hops = hexPath.hexIDs.enumerated().map { index, hexID -> RouteShareService.RouteHop in
            let matched = mapViewModel.repeaterAnnotations.first { annotation in
                guard let pathInfo = mapViewModel.pathState[annotation.annotationID] else { return false }
                return pathInfo.hopIndex == index + 1
            }
            if let annotation = matched {
                return RouteShareService.RouteHop(
                    hexID: hexID,
                    name: annotation.title,
                    latitude: annotation.coordinate.latitude,
                    longitude: annotation.coordinate.longitude
                )
            } else {
                return RouteShareService.RouteHop(hexID: hexID, name: nil, latitude: nil, longitude: nil)
            }
        }

        let location = appState.locationService.currentLocation
        let service = RouteShareService()
        let url = await service.sharePath(
            hops: hops,
            userLatitude: location?.coordinate.latitude,
            userLongitude: location?.coordinate.longitude,
            userName: appState.connectedDevice?.nodeName
        )

        if let url {
            shareURL = url
            UIPasteboard.general.string = url.absoluteString
            showShareConfirmation = true
        }
    }
}
