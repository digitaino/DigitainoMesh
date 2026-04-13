import SwiftUI
import MapKit

// MARK: - Weather Warning Detail Sheet

/// Detail sheet shown when tapping a weather warning from the Weather tab or map.
struct WeatherWarningDetailSheet: View {
    let warning: MeshWXWarning
    /// Called when the user taps "Open Full Map". Dismisses the sheet and centers the map.
    var onShowOnMap: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appState) private var appState

    @State private var isRequestingDescription = false
    @State private var descriptionError: String?
    /// Polygon coordinate groups for the mini-map preview (one array per polygon shape).
    @State private var polygonCoordGroups: [[CLLocationCoordinate2D]] = []
    /// Bounding rect of all warning polygons, used to frame the mini-map.
    @State private var polygonMapRect: MKMapRect = .world

    var body: some View {
        NavigationStack {
            List {
                headerSection
                detailsSection
                mapPreviewSection
                descriptionSection
            }
            .navigationTitle(warning.typeName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await loadPolygons() }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            HStack {
                Circle()
                    .fill(warningColor)
                    .frame(width: 12, height: 12)
                Text(warning.displayTitle)
                    .font(.headline)
            }

            if let onset = warning.onsetDate, onset > Date() {
                Label(onsetLabel(onset), systemImage: "clock")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }

            if !warning.headline.isEmpty {
                Text(warning.headline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            LabeledContent("Type", value: warning.typeName)
            LabeledContent("Severity", value: warning.severityName)
            if let onset = warning.onsetDate, onset > Date() {
                LabeledContent("Active from", value: formattedDate(onset))
            }
            LabeledContent("Expires", value: expiryText)
            if !warning.zones.isEmpty {
                LabeledContent("Zones", value: zoneSummary)
            }
        }
    }

    @ViewBuilder
    private var mapPreviewSection: some View {
        if !polygonCoordGroups.isEmpty {
            Section {
                // Mini-map showing warning area + radar overlay
                WarningDetailMapView(
                    polygonCoordGroups: polygonCoordGroups,
                    mapRect: polygonMapRect,
                    warningColor: UIColor(warningColor),
                    fillOpacity: warning.isUpcoming ? 0.10 : 0.25,
                    radarFrame: bestRadarFrame
                )
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                if let showOnMap = onShowOnMap {
                    Button {
                        dismiss()
                        showOnMap()
                    } label: {
                        Label("Open Full Map", systemImage: "map")
                    }
                }
            } header: {
                Text("Affected Area")
            }
        } else if onShowOnMap != nil {
            // Polygon data not yet loaded — show button only
            Section {
                Button {
                    dismiss()
                    onShowOnMap?()
                } label: {
                    Label("Open Full Map", systemImage: "map")
                }
            }
        }
    }

    /// Finds the latest radar frame from the region that best covers the warning area.
    private var bestRadarFrame: MeshWXRadarFrame? {
        let center = polygonCoordGroups.flatMap { $0 }
            .reduce(CLLocationCoordinate2D(latitude: 0, longitude: 0)) { acc, coord in
                CLLocationCoordinate2D(latitude: acc.latitude + coord.latitude, longitude: acc.longitude + coord.longitude)
            }
        let count = Double(polygonCoordGroups.flatMap { $0 }.count)
        guard count > 0 else { return nil }
        let avgLat = center.latitude / count
        let avgLon = center.longitude / count

        // Find the region whose bounding box contains the warning center
        var bestRegionID: UInt8?
        for (id, region) in MeshWXRegion.all {
            if avgLat >= region.south && avgLat <= region.north &&
               avgLon >= region.west && avgLon <= region.east {
                bestRegionID = id
                break
            }
        }
        guard let regionID = bestRegionID else { return nil }
        return appState.weatherCache.radarFrames[regionID]?.last
    }

    @ViewBuilder
    private var descriptionSection: some View {
        let descKey = warning.descriptionKey
        if let key = descKey {
            let isPending = appState.weatherCache.isPending("desc:\(key)")
            let description = appState.weatherCache.warningDescriptions[key]

            if let description {
                Section("Description") {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
            } else if isPending {
                Section("Description") {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Requesting…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    if let error = descriptionError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button {
                        Task { await requestDescription() }
                    } label: {
                        Label("Request Description", systemImage: "text.document")
                    }
                    .disabled(isRequestingDescription || appState.connectionState != .ready)
                }
            }
        }
    }

    // MARK: - Polygon Loading

    private func loadPolygons() async {
        var groups: [[CLLocationCoordinate2D]] = []

        if !warning.zones.isEmpty {
            // Zone warning: look up each zone polygon from the store
            let store = ZoneGeometryStore.shared
            if !store.isLoaded {
                // Store not ready — trigger load and wait briefly
                store.loadIfNeeded()
                try? await Task.sleep(for: .milliseconds(500))
            }
            for zone in warning.zones {
                if let code = ZoneGeometryStore.zoneCode(stateIdx: zone.stateIdx, zoneNum: zone.zoneNum) {
                    for poly in store.polygons(for: code) {
                        let coords = (0..<poly.pointCount).map { poly.points()[$0].coordinate }
                        if !coords.isEmpty { groups.append(coords) }
                    }
                }
            }
        } else if warning.vertices.count >= 3 {
            groups = [warning.vertices]
        }

        guard !groups.isEmpty else { return }
        polygonCoordGroups = groups
        polygonMapRect = boundingMapRect(for: groups)
    }

    /// Computes a padded MKMapRect that encompasses all polygon coordinate groups.
    private func boundingMapRect(for coordGroups: [[CLLocationCoordinate2D]]) -> MKMapRect {
        var rect = MKMapRect.null
        for coords in coordGroups {
            for coord in coords {
                let point = MKMapPoint(coord)
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
            }
        }
        // Pad 20% on each side
        let padX = rect.size.width  * 0.2
        let padY = rect.size.height * 0.2
        return rect.insetBy(dx: -padX, dy: -padY)
    }

    // MARK: - Helpers

    private var zoneSummary: String {
        guard !warning.zones.isEmpty else { return "" }
        var byState: [String: Int] = [:]
        let codes = ZoneGeometryStore.shared.stateCodes
        for zone in warning.zones {
            let state = codes.indices.contains(Int(zone.stateIdx))
                ? codes[Int(zone.stateIdx)]
                : "??"
            byState[state, default: 0] += 1
        }
        return byState.sorted { $0.key < $1.key }
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: ", ")
    }

    private func requestDescription() async {
        isRequestingDescription = true
        descriptionError = nil
        let result = await appState.sendWarningDescriptionRequest(for: warning)
        isRequestingDescription = false
        switch result {
        case .sent: break
        case .notConnected:  descriptionError = "Not connected"
        case .botNotFound:   descriptionError = "Set bot contact name in Tools → Weather Log"
        case .noDataChannel: descriptionError = "No weather data channel"
        default:             descriptionError = "Request failed"
        }
    }

    private func onsetLabel(_ onset: Date) -> String {
        let cal = Calendar.current
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let timeStr = formatter.string(from: onset)
        if cal.isDateInToday(onset) {
            return "Starts today at \(timeStr)"
        } else if cal.isDateInTomorrow(onset) {
            return "Starts tomorrow at \(timeStr)"
        } else {
            formatter.dateStyle = .short
            return "Starts \(formatter.string(from: onset))"
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var expiryText: String {
        let remaining = warning.expiryDate.timeIntervalSinceNow
        if remaining <= 0 { return "Expired" }
        let minutes = Int(remaining / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let mins = minutes % 60
        return "\(hours)h \(mins)m"
    }

    private var warningColor: Color { warning.swiftUIColor }
}

// MARK: - Weather Data Inspector

/// Diagnostic view for browsing received MeshWX data region by region.
struct WeatherDataInspector: View {
    let weatherCache: WeatherCache

    @State private var selectedTab = 0 // 0 = radar, 1 = warnings

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Data Type", selection: $selectedTab) {
                    Text("Radar (\(radarRegionCount))").tag(0)
                    Text("Warnings (\(weatherCache.warnings.count))").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if selectedTab == 0 {
                    radarList
                } else {
                    warningList
                }
            }
            .navigationTitle("Weather Data Inspector")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var radarRegionCount: Int {
        weatherCache.radarFrames.count
    }

    // MARK: - Radar List

    private var radarList: some View {
        Group {
            if weatherCache.radarFrames.isEmpty {
                ContentUnavailableView(
                    "No Radar Data",
                    systemImage: "cloud.slash",
                    description: Text("No radar frames have been received yet.")
                )
            } else {
                List {
                    ForEach(sortedRadarRegions, id: \.self) { regionID in
                        if let frames = weatherCache.radarFrames[regionID] {
                            NavigationLink {
                                RadarRegionDetail(
                                    regionID: regionID,
                                    frames: frames
                                )
                            } label: {
                                radarRegionRow(regionID: regionID, frames: frames)
                            }
                        }
                    }
                }
            }
        }
    }

    private var sortedRadarRegions: [UInt8] {
        weatherCache.radarFrames.keys.sorted()
    }

    private func radarRegionRow(regionID: UInt8, frames: [MeshWXRadarFrame]) -> some View {
        let region = MeshWXRegion.all[regionID]
        let latestFrame = frames.last

        return HStack {
            RadarGridThumbnail(frame: latestFrame)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(region?.name ?? "Region \(regionID)")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 8) {
                    Text("\(frames.count) frame(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let frame = latestFrame {
                        Text("\(frame.scaleKm) km/cell")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(timestampText(frame.timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let frame = latestFrame {
                    let nonZero = frame.grid.filter { $0 > 0 }.count
                    let total   = frame.gridSize * frame.gridSize
                    Text("\(nonZero)/\(total) active cells")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Warning List

    private var warningList: some View {
        Group {
            if weatherCache.warnings.isEmpty {
                ContentUnavailableView(
                    "No Warnings",
                    systemImage: "checkmark.shield",
                    description: Text("No weather warnings have been received yet.")
                )
            } else {
                List {
                    ForEach(weatherCache.warnings) { warning in
                        warningRow(warning)
                    }
                }
            }
        }
    }

    private func warningRow(_ warning: MeshWXWarning) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(warningColor(warning))
                    .frame(width: 10, height: 10)
                Text(warning.displayTitle)
                    .font(.subheadline.weight(.medium))
            }
            if !warning.headline.isEmpty {
                Text(warning.headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 12) {
                Text("\(warning.vertices.count) vertices")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("Expires: \(expiryText(warning))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func timestampText(_ unixMinutes: UInt32) -> String {
        let date = Date(timeIntervalSince1970: Double(unixMinutes) * 60)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm 'UTC'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: date)
    }

    private func expiryText(_ warning: MeshWXWarning) -> String {
        let remaining = warning.expiryDate.timeIntervalSinceNow
        if remaining <= 0 { return "Expired" }
        let minutes = Int(remaining / 60)
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private func warningColor(_ warning: MeshWXWarning) -> Color {
        warning.swiftUIColor
    }
}

// MARK: - Radar Region Detail

/// Detail view showing all frames for a single radar region with a large grid visualization.
struct RadarRegionDetail: View {
    let regionID: UInt8
    let frames: [MeshWXRadarFrame]

    @State private var selectedFrameIndex: Int = 0

    private var region: MeshWXRegion? { MeshWXRegion.all[regionID] }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Region info header
                if let region {
                    VStack(spacing: 4) {
                        Text(region.name)
                            .font(.title2.weight(.semibold))
                        Text(String(format: "%.1fN to %.1fN, %.1fW to %.1fW",
                                    region.north, region.south, -region.west, -region.east))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Frame picker
                if frames.count > 1 {
                    Picker("Frame", selection: $selectedFrameIndex) {
                        ForEach(0..<frames.count, id: \.self) { i in
                            Text("Frame \(i)").tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }

                if let frame = currentFrame {
                    // Large grid visualization
                    RadarGridView(frame: frame)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)

                    // Frame metadata
                    VStack(spacing: 8) {
                        LabeledContent("Timestamp", value: timestampText(frame.timestamp))
                        LabeledContent("Scale", value: "\(frame.scaleKm) km/cell")
                        LabeledContent("Frame Seq", value: "\(frame.frameSeq)")
                        LabeledContent("Active Cells", value: "\(frame.grid.filter { $0 > 0 }.count) / \(frame.gridSize * frame.gridSize)")
                        LabeledContent("Max Level", value: "\(frame.grid.max() ?? 0)")
                    }
                    .font(.subheadline)
                    .padding(.horizontal)

                    // Color legend
                    reflectivityLegend
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Region \(regionID)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedFrameIndex = max(0, frames.count - 1)
        }
    }

    private var currentFrame: MeshWXRadarFrame? {
        guard selectedFrameIndex >= 0, selectedFrameIndex < frames.count else { return frames.last }
        return frames[selectedFrameIndex]
    }

    private func timestampText(_ unixMinutes: UInt32) -> String {
        let date = Date(timeIntervalSince1970: Double(unixMinutes) * 60)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm 'UTC'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: date)
    }

    private var reflectivityLegend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Reflectivity Scale")
                .font(.caption.weight(.medium))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(1...14, id: \.self) { level in
                    let color = MeshWXRadarFrame.reflectivityColor(for: UInt8(level))
                    VStack(spacing: 1) {
                        Color(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255)
                            .frame(height: 16)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                        Text("\(level * 5)")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("dBZ")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Radar Grid View (Full Size)

/// Renders a radar grid as a colored view. Supports 16×16, 32×32, and 64×64 grids.
struct RadarGridView: View {
    let frame: MeshWXRadarFrame

    var body: some View {
        Canvas { context, size in
            let gs = frame.gridSize
            let cellWidth  = size.width  / CGFloat(gs)
            let cellHeight = size.height / CGFloat(gs)

            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.black.opacity(0.8))
            )

            for row in 0..<gs {
                for col in 0..<gs {
                    let level = frame.cell(row: row, col: col)
                    guard level > 0 else { continue }
                    let color = MeshWXRadarFrame.reflectivityColor(for: level)
                    let rect = CGRect(
                        x: CGFloat(col) * cellWidth,
                        y: CGFloat(row) * cellHeight,
                        width: cellWidth,
                        height: cellHeight
                    )
                    context.fill(
                        Path(rect),
                        with: .color(Color(
                            red: Double(color.r) / 255,
                            green: Double(color.g) / 255,
                            blue: Double(color.b) / 255
                        ))
                    )
                }
            }

            // Grid lines (skip for 64×64 — too dense)
            if gs <= 32 {
                for i in 0...gs {
                    let x = CGFloat(i) * cellWidth
                    let y = CGFloat(i) * cellHeight
                    context.stroke(
                        Path { path in path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)) },
                        with: .color(.white.opacity(0.15)), lineWidth: 0.5
                    )
                    context.stroke(
                        Path { path in path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)) },
                        with: .color(.white.opacity(0.15)), lineWidth: 0.5
                    )
                }
            }
        }
    }
}

// MARK: - Radar Grid Thumbnail

/// Small thumbnail of a radar grid for list rows. Supports variable grid sizes.
// MARK: - Warning Detail Map View

/// UIViewRepresentable that shows warning polygons with optional radar overlay on an MKMapView.
struct WarningDetailMapView: UIViewRepresentable {
    let polygonCoordGroups: [[CLLocationCoordinate2D]]
    let mapRect: MKMapRect
    let warningColor: UIColor
    let fillOpacity: Double
    let radarFrame: MeshWXRadarFrame?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.isScrollEnabled = true
        mapView.isZoomEnabled = true
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsCompass = false
        mapView.delegate = context.coordinator
        mapView.setVisibleMapRect(mapRect, edgePadding: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16), animated: false)

        // Add radar overlay below warning polygons
        if let frame = radarFrame, let overlay = WeatherRadarOverlay.make(from: frame) {
            mapView.addOverlay(overlay, level: .aboveRoads)
        }

        // Add warning polygons on top
        for coords in polygonCoordGroups {
            var mutableCoords = coords
            let polygon = MKPolygon(coordinates: &mutableCoords, count: mutableCoords.count)
            mapView.addOverlay(polygon, level: .aboveLabels)
        }

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self

        // Update radar overlay if frame changed
        mapView.overlays
            .compactMap { $0 as? WeatherRadarOverlay }
            .forEach { mapView.removeOverlay($0) }
        if let frame = radarFrame, let overlay = WeatherRadarOverlay.make(from: frame) {
            mapView.insertOverlay(overlay, at: 0, level: .aboveRoads)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: WarningDetailMapView

        init(parent: WarningDetailMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let radarOverlay = overlay as? WeatherRadarOverlay {
                return WeatherRadarRenderer(overlay: radarOverlay)
            }
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.fillColor = parent.warningColor.withAlphaComponent(parent.fillOpacity)
                renderer.strokeColor = parent.warningColor
                renderer.lineWidth = 2
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - Radar Grid Thumbnail

struct RadarGridThumbnail: View {
    let frame: MeshWXRadarFrame?

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.black.opacity(0.6))
            )

            guard let frame else { return }

            let gs = frame.gridSize
            let cellWidth  = size.width  / CGFloat(gs)
            let cellHeight = size.height / CGFloat(gs)

            for row in 0..<gs {
                for col in 0..<gs {
                    let level = frame.cell(row: row, col: col)
                    guard level > 0 else { continue }
                    let color = MeshWXRadarFrame.reflectivityColor(for: level)
                    let rect = CGRect(
                        x: CGFloat(col) * cellWidth,
                        y: CGFloat(row) * cellHeight,
                        width: cellWidth,
                        height: cellHeight
                    )
                    context.fill(
                        Path(rect),
                        with: .color(Color(
                            red: Double(color.r) / 255,
                            green: Double(color.g) / 255,
                            blue: Double(color.b) / 255
                        ))
                    )
                }
            }
        }
    }
}
