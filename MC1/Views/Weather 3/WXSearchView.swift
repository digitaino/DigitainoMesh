import SwiftUI
import CoreLocation

// MARK: - WXSearchView

/// Search UI for selecting a city or airport to request NWS weather data.
/// City search uses places.json (~30k US Census places) mapped to nearest pfm_point.
/// Airport search uses stations.json (ICAO codes) also mapped to nearest pfm_point.
struct WXSearchView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var isSending = false
    @State private var sentFeedback: SentFeedback?

    enum SentFeedback: Identifiable {
        case success(String)
        case failure(String)
        var id: Int { switch self { case .success: 0; case .failure: 1 } }
    }

    private var cityResults: [(place: WXBundleLoader.Place, pfmPoint: WXBundleLoader.PFMPoint)] {
        WXBundleLoader.searchPlaces(query: query, limit: 30)
    }

    private var stationResults: [WXBundleLoader.Station] {
        WXBundleLoader.searchStations(query: query, limit: 20)
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    ContentUnavailableView {
                        Label("Find a Forecast", systemImage: "magnifyingglass")
                    } description: {
                        Text("Type a city, state, or airport ICAO code to request a forecast from the weather bot.")
                    }
                    .listRowBackground(Color.clear)
                } else if cityResults.isEmpty && stationResults.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .listRowBackground(Color.clear)
                } else {
                    if !cityResults.isEmpty {
                        Section("Cities") {
                            ForEach(cityResults, id: \.place.id) { result in
                                cityRow(result.place, pfmPoint: result.pfmPoint)
                            }
                        }
                    }
                    if !stationResults.isEmpty {
                        Section("Airports (ICAO)") {
                            ForEach(stationResults) { station in
                                stationRow(station)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "City, state (TX), or ICAO code…")
            .navigationTitle("Request Forecast")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if isSending {
                    ZStack {
                        Color.black.opacity(0.3).ignoresSafeArea()
                        ProgressView("Sending…")
                            .padding()
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        .alert(item: $sentFeedback) { feedback in
            switch feedback {
            case .success(let name):
                Alert(
                    title: Text("Request Sent"),
                    message: Text("A forecast request for \(name) was sent on #meshwx. Data will appear within a few minutes if a MeshWX bot is active."),
                    dismissButton: .default(Text("OK")) { dismiss() }
                )
            case .failure(let reason):
                Alert(
                    title: Text("Request Failed"),
                    message: Text(reason),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    // MARK: - Rows

    private func cityRow(_ place: WXBundleLoader.Place, pfmPoint: WXBundleLoader.PFMPoint) -> some View {
        Button {
            Task { await sendRequest(name: place.displayName, pfmPointIndex: pfmPoint.id) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("NWS \(pfmPoint.wfo) · \(pfmPoint.zone)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
        .disabled(isSending || appState.connectionState != .ready)
    }

    private func stationRow(_ station: WXBundleLoader.Station) -> some View {
        Button {
            Task { await sendStationRequest(for: station) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(station.id)
                        .font(.subheadline.weight(.semibold).monospaced())
                        .foregroundStyle(.primary)
                    Text("—")
                        .foregroundStyle(.tertiary)
                    Text(station.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Text(station.state)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .disabled(isSending || appState.connectionState != .ready)
    }

    // MARK: - Actions

    private func sendRequest(name: String, pfmPointIndex: Int) async {
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }

        let result = await appState.sendWeatherDataRequest(pfmPointIndex: pfmPointIndex)
        switch result {
        case .sent:
            sentFeedback = .success(name)
        case .notConnected:
            sentFeedback = .failure("Not connected to a LoRa device.")
        case .noDataChannel:
            sentFeedback = .failure("Request failed. Check that you're on the #meshwx channel.")
        case .botNotFound:
            sentFeedback = .failure("Weather bot not configured. Set the bot contact name in Tools → Weather Log.")
        case .noLocation, .rateLimited:
            sentFeedback = .failure("Request could not be sent. Try again in a moment.")
        }
    }

    private func sendStationRequest(for station: WXBundleLoader.Station) async {
        guard !isSending else { return }

        let coord = CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)
        guard let nearest = WXBundleLoader.nearestPFMPoint(to: coord) else {
            sentFeedback = .failure("pfm_points.json not loaded. Check that bundle files were added to the MC1 target.")
            return
        }

        await sendRequest(name: "\(station.id) — \(station.name)", pfmPointIndex: nearest.id)
    }
}

// MARK: - Preview

#Preview {
    WXSearchView()
        .environment(\.appState, AppState())
}
