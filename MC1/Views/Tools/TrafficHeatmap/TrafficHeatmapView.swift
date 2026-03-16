import MapKit
import SwiftUI
import MC1Services

/// Tool view that displays aggregated mesh traffic patterns on a map.
/// Uses MKMapView via UIViewRepresentable for proper annotation clustering,
/// tappable pins with callouts, and polyline segment overlays.
struct TrafficHeatmapView: View {
    @Environment(\.appState) private var appState

    @State private var viewModel = TrafficHeatmapViewModel()
    @State private var selectedBubble: TrafficBubbleAnnotation?
    @State private var detailBubble: TrafficBubbleAnnotation?
    @State private var showingInfo = false

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
                Button {
                    showingInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                timePeriodMenu
            }
        }
        .sheet(isPresented: $showingInfo) {
            TrafficMapInfoSheet()
                .presentationDetents([.medium, .large])
        }
        .task(id: appState.servicesVersion) {
            await loadData()
        }
        .onChange(of: viewModel.selectedPeriodID) {
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
            ForEach(viewModel.availablePeriods) { period in
                Button {
                    viewModel.selectedPeriodID = period.id
                } label: {
                    if period.id == viewModel.selectedPeriodID {
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
        TrafficMapRepresentable(
            annotations: viewModel.bubbleAnnotations,
            segments: viewModel.segmentData,
            mapType: viewModel.mapStyleSelection.mkMapType,
            showsUserLocation: true,
            selectedAnnotation: $selectedBubble,
            cameraRegion: $viewModel.cameraRegion,
            onDetailTap: { bubble in
                detailBubble = bubble
            }
        )
        .ignoresSafeArea()
        .sheet(item: $detailBubble) { bubble in
            RepeaterTrafficDetailSheet(bubble: bubble)
                .presentationDetents([.medium])
        }
    }

    // MARK: - Summary Banner

    private var summaryBanner: some View {
        VStack {
            VStack(spacing: 2) {
                Text(L10n.Tools.Tools.TrafficMap.summary(
                    viewModel.locatedRepeaterCount,
                    viewModel.segmentCount,
                    viewModel.totalPacketsAnalyzed
                ))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)

                if let age = viewModel.formattedOldestAge {
                    Text("Oldest: \(age)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
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
                    onLocationTap: { centerOnUserLocation() },
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

    // MARK: - Actions

    private func centerOnUserLocation() {
        guard let location = appState.locationService.currentLocation else { return }
        viewModel.cameraRegion = MKCoordinateRegion(
            center: location.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
    }
}

// MARK: - Repeater Traffic Detail Sheet

private struct RepeaterTrafficDetailSheet: View {
    let bubble: TrafficBubbleAnnotation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Traffic") {
                    LabeledContent("Packets", value: "\(bubble.packetCount)")

                    if let snr = bubble.averageSNR {
                        LabeledContent("Avg SNR") {
                            Text(String(format: "%.1f dB", snr))
                                .foregroundStyle(bubble.snrQuality.color)
                        }
                    }

                    LabeledContent("Last Seen") {
                        Text(bubble.lastSeen, style: .relative)
                    }
                }

                Section("Identity") {
                    LabeledContent("Public Key") {
                        Text(bubble.publicKey.map { $0.hexString }.joined(separator: " "))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section("Location") {
                    LabeledContent("Latitude") {
                        Text(bubble.coordinate.latitude, format: .number.precision(.fractionLength(6)))
                    }
                    LabeledContent("Longitude") {
                        Text(bubble.coordinate.longitude, format: .number.precision(.fractionLength(6)))
                    }
                }
            }
            .navigationTitle(bubble.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Traffic Map Info Sheet

private struct TrafficMapInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("The traffic map visualizes mesh network activity by showing repeaters and the routes packets travel between them.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Pins") {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Repeater Pins")
                                .font(.subheadline.weight(.medium))
                            Text("Each pin represents a repeater that forwarded packets. The two-character label is the first byte of its public key in hex.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(.cyan)
                    }

                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Clusters")
                                .font(.subheadline.weight(.medium))
                            Text("When repeaters are close together, they group into a numbered cluster. Tap to zoom in and reveal individual pins.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "circle.grid.2x2.fill")
                            .foregroundStyle(.cyan)
                    }
                }

                Section("Pin Colors — Signal Quality (SNR)") {
                    Text("Pin color reflects the average SNR of packets where this repeater was the **last hop** — the one your radio heard directly. Repeaters only seen as intermediate hops show as gray (unknown).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    snrRow(quality: .excellent, label: "Excellent", range: "> 10 dB")
                    snrRow(quality: .good, label: "Good", range: "5 – 10 dB")
                    snrRow(quality: .fair, label: "Fair", range: "0 – 5 dB")
                    snrRow(quality: .poor, label: "Weak", range: "-10 – 0 dB")
                    snrRow(quality: .veryPoor, label: "Marginal", range: "< -10 dB")
                    snrRow(quality: .unknown, label: "Unknown", range: "No direct reception")
                }

                Section("Route Lines") {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Packet Routes")
                                .font(.subheadline.weight(.medium))
                            Text("Lines between pins show the paths packets traveled through the mesh. Thicker, brighter lines indicate more traffic on that link. Line color does not indicate signal quality — we only know the signal of the final hop to your radio.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .foregroundStyle(.cyan)
                    }
                }

                Section("Callouts & Details") {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tap a Pin")
                                .font(.subheadline.weight(.medium))
                            Text("Shows a callout with packet count, SNR, last seen time, and a public key prefix. Tap \"Details\" for the full detail view including coordinates and full public key.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "hand.tap")
                            .foregroundStyle(.blue)
                    }
                }

                Section("Time Period") {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Filter by Time")
                                .font(.subheadline.weight(.medium))
                            Text("Use the clock menu in the toolbar to filter traffic data to a specific time window. Available periods adjust based on how much data you have.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "clock")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Traffic Map Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func snrRow(quality: SNRQuality, label: String, range: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(quality.color)
                .frame(width: 14, height: 14)
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(range)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}
