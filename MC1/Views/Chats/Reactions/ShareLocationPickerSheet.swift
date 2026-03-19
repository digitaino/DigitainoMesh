import SwiftUI
import MapKit
import CoreLocation

/// Map-based location picker for choosing an obfuscated share location.
///
/// Presents a map centered on the user's true position with a 500m radius circle.
/// The user taps anywhere within the circle to place a pin — taps outside are
/// clamped to the circle boundary. The chosen coordinate (not the true one)
/// is sent to the server when sharing.
struct ShareLocationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The true location — center of the 500m circle. Never sent to the server.
    let trueLocation: CLLocationCoordinate2D

    /// Called when the user taps Share. Receives the chosen coordinate,
    /// or nil if they toggled "Include Location" off.
    let onConfirm: (CLLocationCoordinate2D?) -> Void

    // State
    @State private var position: MapCameraPosition
    @State private var selectedCoordinate: CLLocationCoordinate2D
    @State private var includeLocation = true
    @State private var pinMoveTrigger = false

    private static let maxRadiusMeters: CLLocationDistance = 500

    init(
        trueLocation: CLLocationCoordinate2D,
        onConfirm: @escaping (CLLocationCoordinate2D?) -> Void
    ) {
        self.trueLocation = trueLocation
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
                MapReader { proxy in
                    Map(position: $position, interactionModes: [.pan, .zoom]) {
                        // 500m boundary circle
                        MapCircle(center: trueLocation, radius: Self.maxRadiusMeters)
                            .foregroundStyle(.blue.opacity(0.08))
                            .stroke(.blue.opacity(0.4), lineWidth: 2)

                        // Selected pin
                        if includeLocation {
                            Annotation("", coordinate: selectedCoordinate) {
                                pinView
                            }
                        }
                    }
                    .onTapGesture { screenPoint in
                        guard includeLocation,
                              let tapped = proxy.convert(screenPoint, from: .local) else { return }
                        selectedCoordinate = clampToRadius(tapped)
                        pinMoveTrigger.toggle()
                    }
                    .mapControls {
                        MapCompass()
                    }
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
            .sensoryFeedback(.impact(flexibility: .soft), trigger: pinMoveTrigger)
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

                Text("Tap the map to move your shared position within the blue circle. Your actual location is never shared.")
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
                Label("Share Repeater Map", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
        } else {
            Button {
                confirmAndDismiss()
            } label: {
                Label("Share Repeater Map", systemImage: "square.and.arrow.up")
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
