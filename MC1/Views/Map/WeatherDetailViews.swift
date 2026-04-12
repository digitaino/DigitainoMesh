import SwiftUI
import MapKit

// MARK: - Weather Warning Detail Sheet

/// Detail sheet shown when tapping a weather warning polygon on the map.
struct WeatherWarningDetailSheet: View {
    let warning: MeshWXWarning

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Circle()
                            .fill(warningColor)
                            .frame(width: 12, height: 12)
                        Text(warning.displayTitle)
                            .font(.headline)
                    }

                    if !warning.headline.isEmpty {
                        Text(warning.headline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Details") {
                    LabeledContent("Type", value: warning.typeName)
                    LabeledContent("Severity", value: warning.severityName)
                    LabeledContent("Expires", value: expiryText)
                    LabeledContent("Vertices", value: "\(warning.vertices.count)")
                }

                Section("Polygon Coordinates") {
                    ForEach(Array(warning.vertices.enumerated()), id: \.offset) { index, vertex in
                        LabeledContent("V\(index)") {
                            Text(String(format: "%.4f, %.4f", vertex.latitude, vertex.longitude))
                                .font(.caption.monospaced())
                        }
                    }
                }
            }
            .navigationTitle(warning.typeName)
            .navigationBarTitleDisplayMode(.inline)
        }
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

    private func timestampText(_ minutes: UInt16) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        return String(format: "%02d:%02d UTC", hours, mins)
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

    private func timestampText(_ minutes: UInt16) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        return String(format: "%02d:%02d UTC", hours, mins)
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
