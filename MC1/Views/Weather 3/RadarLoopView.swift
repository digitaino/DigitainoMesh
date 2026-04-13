import SwiftUI
import MapKit

// MARK: - RadarLoopView

/// Full-screen radar loop player. Shows a MKMapView zoomed to the radar region
/// with a playback scrubber for cycling through stored frames.
struct RadarLoopView: View {
    let regionID: UInt8
    let frames: [MeshWXRadarFrame]

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var isPlaying = false

    private var region: MeshWXRegion? { MeshWXRegion.all[regionID] }
    private var currentFrame: MeshWXRadarFrame? {
        guard !frames.isEmpty else { return nil }
        return frames[currentIndex]
    }

    init(regionID: UInt8, frames: [MeshWXRadarFrame]) {
        self.regionID = regionID
        self.frames = frames
        // Start at the latest frame
        _currentIndex = State(initialValue: max(0, frames.count - 1))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let region {
                RadarMapView(region: region, frame: currentFrame)
                    .ignoresSafeArea()
            } else {
                Color(.systemBackground).ignoresSafeArea()
                ContentUnavailableView("No Region Data", systemImage: "antenna.radiowaves.left.and.right.slash")
            }

            playbackPanel
                .padding(.horizontal)
                .padding(.bottom, 32)
        }
        .navigationTitle(region.map { "\($0.name) Radar" } ?? "Radar Loop")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onDisappear { isPlaying = false }
    }

    // MARK: - Playback Panel

    private var playbackPanel: some View {
        VStack(spacing: 12) {
            // Timestamp + frame counter + resolution badge
            HStack {
                Label(timestampLabel, systemImage: "clock")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.primary)
                Spacer()
                if let frame = currentFrame {
                    Text("\(frame.gridSize)×\(frame.gridSize)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(frame.gridSize >= 64 ? Color.cyan.opacity(0.2) : Color.secondary.opacity(0.15),
                                    in: Capsule())
                        .foregroundStyle(frame.gridSize >= 64 ? .cyan : .secondary)
                }
                Text("\(currentIndex + 1) of \(frames.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Frame scrubber
            if frames.count > 1 {
                Slider(
                    value: Binding(
                        get: { Double(currentIndex) },
                        set: { newVal in
                            currentIndex = Int(newVal.rounded())
                            isPlaying = false
                        }
                    ),
                    in: 0...Double(frames.count - 1),
                    step: 1
                )
                .tint(.cyan)
            }

            // Transport controls
            HStack(spacing: 32) {
                Button {
                    isPlaying = false
                    if currentIndex > 0 { currentIndex -= 1 }
                } label: {
                    Image(systemName: "backward.frame.fill")
                        .font(.title3)
                }
                .disabled(currentIndex == 0)

                Button {
                    isPlaying.toggle()
                    if isPlaying { scheduleAdvance() }
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .background(.cyan.opacity(0.15), in: Circle())
                }

                Button {
                    isPlaying = false
                    if currentIndex < frames.count - 1 { currentIndex += 1 }
                } label: {
                    Image(systemName: "forward.frame.fill")
                        .font(.title3)
                }
                .disabled(currentIndex == frames.count - 1)
            }

            // Reflectivity legend
            reflectivityLegend
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Reflectivity Legend

    private let legendLevels: [Int] = [1,2,3,4,5,6,7,8,9,10,11,12,13,14]

    private func legendColor(for level: Int) -> Color {
        let c = MeshWXRadarFrame.reflectivityColor(for: UInt8(level))
        return Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }

    private var reflectivityLegend: some View {
        HStack(spacing: 0) {
            ForEach(legendLevels, id: \.self) { level in
                legendColor(for: level)
                    .frame(maxWidth: .infinity)
                    .frame(height: 8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .leading) {
            Text("Light")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .offset(y: 12)
        }
        .overlay(alignment: .trailing) {
            Text("Heavy")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .offset(y: 12)
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    // MARK: - Helpers

    private var timestampLabel: String {
        guard let frame = currentFrame else { return "—" }
        let date = Date(timeIntervalSince1970: Double(frame.timestamp) * 60)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: date)
    }

    private func scheduleAdvance() {
        guard isPlaying else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard isPlaying else { return }
            if currentIndex < frames.count - 1 {
                currentIndex += 1
            } else {
                // Pause briefly at the end before looping
                try? await Task.sleep(for: .milliseconds(1200))
                guard isPlaying else { return }
                currentIndex = 0
            }
            scheduleAdvance()
        }
    }
}

// MARK: - RadarMapView

/// Lightweight UIViewRepresentable showing a single radar frame on a MapKit map.
struct RadarMapView: UIViewRepresentable {
    let region: MeshWXRegion
    let frame: MeshWXRadarFrame?
    var isInteractive: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.mapType = .standard
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsCompass = isInteractive
        mapView.isScrollEnabled = isInteractive
        mapView.isZoomEnabled = isInteractive
        mapView.delegate = context.coordinator

        // Zoom to region bounding box with padding
        let padding: UIEdgeInsets = isInteractive
            ? UIEdgeInsets(top: 40, left: 20, bottom: 20, right: 20)
            : UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        mapView.setVisibleMapRect(regionMapRect, edgePadding: padding, animated: false)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Swap out the radar overlay for the current frame
        mapView.overlays
            .compactMap { $0 as? WeatherRadarOverlay }
            .forEach { mapView.removeOverlay($0) }

        if let frame, let overlay = WeatherRadarOverlay.make(from: frame) {
            mapView.addOverlay(overlay, level: .aboveRoads)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let radarOverlay = overlay as? WeatherRadarOverlay {
                return WeatherRadarRenderer(overlay: radarOverlay)
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }

    // MARK: - Helpers

    private var regionMapRect: MKMapRect {
        let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: region.north, longitude: region.west))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: region.south, longitude: region.east))
        return MKMapRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }
}
