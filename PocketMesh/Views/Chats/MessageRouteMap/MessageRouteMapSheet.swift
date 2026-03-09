import CoreLocation
import MapKit
import SwiftUI
import PocketMeshServices

/// Sheet presenting a map view of the geographic route a message took through mesh repeaters.
struct MessageRouteMapSheet: View {
    @Environment(\.appState) private var appState
    @Environment(\.dismiss) private var dismiss

    let message: MessageDTO

    @State private var mapViewModel = MessageRouteMapViewModel()

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
            .navigationTitle(L10n.Chats.Chats.Path.RouteMap.title)
            .navigationBarTitleDisplayMode(.inline)
            .liquidGlassToolbarBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Localizable.Common.close) { dismiss() }
                }
            }
        }
        .task {
            guard let services = appState.services else { return }
            // Ensure we have a location before loading so lines can connect to the user
            if appState.locationService.currentLocation == nil,
               appState.locationService.isAuthorized {
                try? await appState.locationService.requestCurrentLocation(timeout: .seconds(5))
            }
            // Prefer the GPS stored on the message (where user was at send/receive time)
            // over the phone's current location, so route maps show historical position.
            let userLocation: CLLocation? = if let lat = message.userLatitude,
                                               let lon = message.userLongitude {
                CLLocation(latitude: lat, longitude: lon)
            } else {
                appState.locationService.currentLocation
            }
            await mapViewModel.loadRoute(
                message: message,
                services: services,
                deviceID: message.deviceID,
                userLocation: userLocation,
                receiverName: appState.connectedDevice?.nodeName
                    ?? L10n.Chats.Chats.Path.Receiver.you
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
            showLabels: mapViewModel.showLabels,
            pathState: mapViewModel.pathState,
            hashLabels: mapViewModel.hashLabels,
            cameraRegion: $mapViewModel.cameraRegion,
            cameraRegionVersion: mapViewModel.cameraRegionVersion
        )
        .ignoresSafeArea()
    }

    // MARK: - Info Banner

    private var infoBanner: some View {
        VStack {
            HStack {
                Text(L10n.Chats.Chats.Path.RouteMap.hops(mapViewModel.locatedHopCount))

                let unlocatedCount = mapViewModel.totalHopCount - mapViewModel.locatedHopCount
                if unlocatedCount > 0 {
                    Text("•")
                    Label(
                        "\(unlocatedCount) unlocated",
                        systemImage: "location.slash"
                    )
                    .foregroundStyle(.orange)
                }

                if let snr = message.snr {
                    Text("•")
                    Text("SNR \(snr, format: .number.precision(.fractionLength(1))) dB")
                }
            }
            .font(.subheadline.weight(.medium))
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
            L10n.Chats.Chats.Path.RouteMap.Empty.title,
            systemImage: "map",
            description: Text(L10n.Chats.Chats.Path.RouteMap.Empty.description)
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
                    // Labels toggle
                    Button {
                        mapViewModel.showLabels.toggle()
                    } label: {
                        Image(systemName: "character.textbox")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(mapViewModel.showLabels ? .blue : .primary)
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
                    .accessibilityLabel(L10n.Chats.Chats.Path.RouteMap.centerOnRoute)
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
}
