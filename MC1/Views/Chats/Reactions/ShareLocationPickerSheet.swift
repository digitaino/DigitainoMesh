import SwiftUI
import MapKit
import CoreLocation

/// Map-based location picker for choosing an obfuscated share location.
///
/// Presents a map centered on the user's true position with a 500m radius circle.
/// A pin is fixed at the screen center — the user pans the map underneath it to
/// choose their shared position. The chosen coordinate (clamped to the 500m circle)
/// is sent to the server when sharing.
struct ShareLocationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The true location — center of the 500m circle. Never sent to the server.
    let trueLocation: CLLocationCoordinate2D

    /// Label for the share button (e.g., "Share Repeater Map" or "Share Route").
    let shareLabel: String

    /// Called when the user taps Share. Receives the chosen coordinate,
    /// or nil if they toggled "Include Location" off.
    let onConfirm: (CLLocationCoordinate2D?) -> Void

    // State
    @State private var position: MapCameraPosition
    @State private var selectedCoordinate: CLLocationCoordinate2D
    @State private var includeLocation = true

    private static let maxRadiusMeters: CLLocationDistance = 500

    init(
        trueLocation: CLLocationCoordinate2D,
        shareLabel: String = "Share Repeater Map",
        onConfirm: @escaping (CLLocationCoordinate2D?) -> Void
    ) {
        self.trueLocation = trueLocation
        self.shareLabel = shareLabel
        self.onConfirm = onConfirm
        _selectedCoordinate = State(initialValue: trueLocation)
        // Show enough area to see the full circle with padding
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: trueLocation,
            latitudinalMeters: 1400,
            longitudinalMeters: 1400
        )))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $position, interactionModes: [.pan, .zoom]) {
                    // 500m boundary circle
                    MapCircle(center: trueLocation, radius: Self.maxRadiusMeters)
                        .foregroundStyle(.blue.opacity(0.08))
                        .stroke(.blue.opacity(0.4), lineWidth: 2)
                }
                .onMapCameraChange(frequency: .continuous) { context in
                    selectedCoordinate = clampToRadius(context.camera.centerCoordinate)
                }
                .mapControls {
                    MapCompass()
                }

                // Fixed center pin overlay (doesn't move with the map)
                if includeLocation {
                    pinView
                }

                // Bottom controls
                VStack {
                    Spacer()
                    controlsOverlay
                }
            }
            .navigationTitle("Choose Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Pin View

    private var pinView: some View {
        ZStack {
            Circle()
                .fill(.blue)
                .frame(width: 20, height: 20)
            Circle()
                .strokeBorder(.white, lineWidth: 2)
                .frame(width: 20, height: 20)
        }
        .shadow(radius: 3)
    }

    // MARK: - Controls Overlay

    private var controlsOverlay: some View {
        VStack(spacing: 12) {
            if includeLocation {
                Text(distanceText)
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            VStack(spacing: 16) {
                Toggle("Include Location", isOn: $includeLocation)

                Text("Pan the map to adjust your shared position within the blue circle. Your actual location is never shared.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                shareButton
            }
            .padding()
            .background {
                if #available(iOS 26.0, *) {
                    Color.clear
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                }
            }
            .modifier(ControlsGlassModifier())
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var shareButton: some View {
        if #available(iOS 26.0, *) {
            Button {
                confirmAndDismiss()
            } label: {
                Label(shareLabel, systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
        } else {
            Button {
                confirmAndDismiss()
            } label: {
                Label(shareLabel, systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Logic

    private func confirmAndDismiss() {
        onConfirm(includeLocation ? selectedCoordinate : nil)
        dismiss()
    }

    private var distanceText: String {
        let d = CLLocation(latitude: selectedCoordinate.latitude, longitude: selectedCoordinate.longitude)
            .distance(from: CLLocation(latitude: trueLocation.latitude, longitude: trueLocation.longitude))
        return "\(Int(d))m from actual position"
    }

    /// Clamp a coordinate to within the 500m radius circle.
    private func clampToRadius(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let tapped = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let center = CLLocation(latitude: trueLocation.latitude, longitude: trueLocation.longitude)
        let distance = tapped.distance(from: center)

        guard distance > Self.maxRadiusMeters else {
            return coordinate // Within bounds
        }

        // Project onto the circle boundary along the center→tap direction
        let fraction = Self.maxRadiusMeters / distance
        let clampedLat = trueLocation.latitude + (coordinate.latitude - trueLocation.latitude) * fraction
        let clampedLon = trueLocation.longitude + (coordinate.longitude - trueLocation.longitude) * fraction
        return CLLocationCoordinate2D(latitude: clampedLat, longitude: clampedLon)
    }
}

// MARK: - Liquid Glass Modifier

private struct ControlsGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            content
        }
    }
}
