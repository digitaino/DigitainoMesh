import SwiftUI
import MapKit

// MARK: - WeatherView

/// Main weather section showing MeshWX data received from the weather bot.
struct WeatherView: View {
    @State private var searchQuery = ""

    var body: some View {
        NavigationStack {
            WeatherBody(searchQuery: $searchQuery)
                .searchable(
                    text: $searchQuery,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "City, state (TX), or ICAO code…"
                )
        }
        .liquidGlassToolbarBackground()
    }
}

// MARK: - WeatherBody

/// Inner view with access to search environment values.
private struct WeatherBody: View {
    @Environment(\.appState) private var appState
    @Environment(\.isSearching) private var isSearching
    @Environment(\.dismissSearch) private var dismissSearch

    @Binding var searchQuery: String
    @State private var isRequesting = false
    @State private var requestError: String?
    @State private var isSendingSearch = false
    @State private var searchError: String?

    // MARK: - Search results

    private var cityResults: [(place: WXBundleLoader.Place, pfmPoint: WXBundleLoader.PFMPoint)] {
        WXBundleLoader.searchPlaces(query: searchQuery, limit: 25)
    }

    private var stationResults: [WXBundleLoader.Station] {
        WXBundleLoader.searchStations(query: searchQuery, limit: 10)
    }

    // MARK: - Body

    var body: some View {
        Group {
            if isSearching {
                searchResultsList
            } else if appState.weatherCache.hasData {
                weatherList
            } else {
                emptyState
            }
        }
        .navigationTitle("Weather")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                BLEStatusIndicatorView()
            }
            ToolbarItem(placement: .topBarTrailing) {
                requestButton
            }
            ToolbarItem(placement: .topBarTrailing) {
                SignalBarsToolbarItem()
            }
        }
        .alert("Request Failed", isPresented: Binding(
            get: { requestError != nil },
            set: { if !$0 { requestError = nil } }
        )) {
            Button("OK", role: .cancel) { requestError = nil }
        } message: {
            Text(requestError ?? "")
        }
    }

    // MARK: - Search Results List

    private var searchResultsList: some View {
        List {
            if let error = searchError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
            }

            if searchQuery.isEmpty {
                ContentUnavailableView {
                    Label("Find a Forecast", systemImage: "magnifyingglass")
                } description: {
                    Text("Type a city, state, or airport ICAO code.")
                }
                .listRowBackground(Color.clear)
            } else if cityResults.isEmpty && stationResults.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
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
        .overlay {
            if isSendingSearch {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    ProgressView("Sending…")
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func cityRow(_ place: WXBundleLoader.Place, pfmPoint: WXBundleLoader.PFMPoint) -> some View {
        Button {
            Task { await sendForecastRequest(name: place.displayName, pfmPointIndex: pfmPoint.id) }
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
        .disabled(isSendingSearch || appState.connectionState != .ready)
    }

    private func stationRow(_ station: WXBundleLoader.Station) -> some View {
        Button {
            Task { await sendStationRequest(for: station) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
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
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
        .disabled(isSendingSearch || appState.connectionState != .ready)
    }

    // MARK: - Weather Data List

    private var weatherList: some View {
        List {
            if !appState.weatherCache.observations.isEmpty {
                observationsSection
            }
            if !appState.weatherCache.warnings.isEmpty {
                warningsSection
            }
            if !appState.weatherCache.forecasts.isEmpty {
                forecastsSection
            }
            if !appState.weatherCache.radarFrames.isEmpty {
                radarSection
            }
            statusSection
        }
    }

    // MARK: - Observations Section

    private var observationsSection: some View {
        Section {
            ForEach(sortedObservationKeys, id: \.self) { key in
                if let obs = appState.weatherCache.observations[key] {
                    ObservationRow(observation: obs)
                }
            }
        } header: {
            HStack {
                Image(systemName: "thermometer.medium")
                    .foregroundStyle(.orange)
                Text("Current Conditions (\(appState.weatherCache.observations.count))")
            }
        }
    }

    private var sortedObservationKeys: [String] {
        appState.weatherCache.observations.keys.sorted()
    }

    // MARK: - Warnings Section

    private var warningsSection: some View {
        Section {
            ForEach(sortedWarnings) { warning in
                WarningRow(warning: warning)
            }
        } header: {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Active Warnings (\(appState.weatherCache.warnings.count))")
            }
        }
    }

    private var sortedWarnings: [MeshWXWarning] {
        appState.weatherCache.warnings.sorted { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            return a.expiryDate < b.expiryDate
        }
    }

    // MARK: - Forecasts Section

    private var forecastsSection: some View {
        Section {
            ForEach(sortedForecastKeys, id: \.self) { key in
                if let forecast = appState.weatherCache.forecasts[key] {
                    ForecastRow(forecast: forecast)
                }
            }
        } header: {
            HStack {
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(.orange)
                Text("Forecasts (\(appState.weatherCache.forecasts.count))")
            }
        }
    }

    private var sortedForecastKeys: [Int] {
        appState.weatherCache.forecasts.keys.sorted()
    }

    // MARK: - Radar Section

    private var radarSection: some View {
        Section {
            ForEach(sortedRadarRegions, id: \.self) { regionID in
                if let frames = appState.weatherCache.radarFrames[regionID], !frames.isEmpty {
                    NavigationLink {
                        RadarLoopView(regionID: regionID, frames: frames)
                    } label: {
                        RadarRegionRow(regionID: regionID, frames: frames)
                    }
                }
            }
        } header: {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.blue)
                Text("Radar Coverage (\(appState.weatherCache.radarFrames.count) region\(appState.weatherCache.radarFrames.count == 1 ? "" : "s"))")
            }
        }
    }

    private var sortedRadarRegions: [UInt8] {
        appState.weatherCache.radarFrames.keys.sorted()
    }

    // MARK: - Status Section

    private var statusSection: some View {
        Section("Data Status") {
            if let location = appState.locationService.currentLocation,
               let region = MeshWXRegion.region(for: location.coordinate) {
                LabeledContent("Your Region", value: region.name)
            }
            LabeledContent("Active Warnings", value: "\(appState.weatherCache.warnings.count)")
            LabeledContent("Radar Regions", value: "\(appState.weatherCache.radarFrames.count)")
            LabeledContent("Messages Received", value: "\(appState.weatherCache.messageLog.count)")

            Button {
                Task { await requestUpdate() }
            } label: {
                HStack {
                    if isRequesting {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isRequesting ? "Requesting…" : "Request Update")
                }
            }
            .disabled(isRequesting || appState.connectionState != .ready)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Weather Data", systemImage: "cloud.slash")
        } description: {
            Text("Weather data is broadcast automatically when you join the **#meshwx** channel and a MeshWX bot is active on the mesh.\n\nSearch for a city or airport above to request a specific forecast.")
        } actions: {
            Button("Request Update") {
                Task { await requestUpdate() }
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Toolbar

    private var requestButton: some View {
        Button {
            Task { await requestUpdate() }
        } label: {
            if isRequesting {
                ProgressView().scaleEffect(0.8)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(isRequesting || appState.connectionState != .ready)
    }

    // MARK: - Actions

    private func sendForecastRequest(name: String, pfmPointIndex: Int) async {
        guard !isSendingSearch else { return }
        isSendingSearch = true
        defer { isSendingSearch = false }
        searchError = nil

        let result = await appState.sendWeatherDataRequest(pfmPointIndex: pfmPointIndex)
        switch result {
        case .sent:
            dismissSearch()
        case .botNotFound:
            searchError = "Weather bot not yet discovered. Wait for a broadcast on #meshwx first."
        case .notConnected:
            searchError = "Not connected to a LoRa device."
        case .noDataChannel:
            searchError = "Join the #meshwx channel on your device first."
        case .noLocation, .rateLimited:
            searchError = "Could not send request. Try again in a moment."
        }
    }

    private func sendStationRequest(for station: WXBundleLoader.Station) async {
        let coord = CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)
        guard let nearest = WXBundleLoader.nearestPFMPoint(to: coord) else {
            searchError = "Could not resolve nearest forecast point."
            return
        }
        await sendForecastRequest(name: "\(station.id) — \(station.name)", pfmPointIndex: nearest.id)
    }

    private func requestUpdate() async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }

        let result = await appState.sendWeatherRefreshRequest()
        switch result {
        case .sent, .rateLimited, .notConnected, .botNotFound:
            break
        case .noDataChannel:
            requestError = "Join the #meshwx channel on your LoRa device to receive weather data."
        case .noLocation:
            requestError = "Enable location access so the app can request weather for your region."
        }
    }
}

// MARK: - Warning Row

private struct WarningRow: View {
    let warning: MeshWXWarning

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(warningColor)
                    .frame(width: 10, height: 10)
                Text(warning.displayTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                expiryBadge
            }

            if !warning.headline.isEmpty {
                Text(warning.headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text("\(warning.vertices.count) vertices")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var expiryBadge: some View {
        let remaining = warning.expiryDate.timeIntervalSinceNow
        let text: String
        let color: Color

        if remaining <= 0 {
            text = "Expired"
            color = .secondary
        } else if remaining < 1800 {
            let mins = Int(remaining / 60)
            text = "\(mins)m"
            color = .orange
        } else {
            let hours = Int(remaining / 3600)
            let mins = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
            text = "\(hours)h \(mins)m"
            color = .secondary
        }

        return Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
    }

    private var warningColor: Color { warning.swiftUIColor }
}

// MARK: - Radar Region Row

private struct RadarRegionRow: View {
    let regionID: UInt8
    let frames: [MeshWXRadarFrame]

    private var region: MeshWXRegion? { MeshWXRegion.all[regionID] }
    private var latestFrame: MeshWXRadarFrame? { frames.last }

    var body: some View {
        HStack(spacing: 12) {
            RadarGridThumbnail(frame: latestFrame)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(region?.name ?? "Region \(regionID)")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 8) {
                    Text("\(frames.count) frame\(frames.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let frame = latestFrame {
                        Text(timestampText(frame.timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        let activeCells = frame.grid.filter { $0 > 0 }.count
                        if activeCells > 0 {
                            Text("\(activeCells)/256 cells")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func timestampText(_ minutes: UInt16) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        return String(format: "%02d:%02dZ", hours, mins)
    }
}

// MARK: - Forecast Row

private struct ForecastRow: View {
    let forecast: MeshWXForecast

    private var locationName: String {
        if let idx = forecast.pfmPointIndex {
            let points = WXBundleLoader.allPFMPoints
            if idx < points.count { return points[idx].name }
        }
        return "Forecast"
    }

    private var wfoLabel: String {
        if let idx = forecast.pfmPointIndex {
            let points = WXBundleLoader.allPFMPoints
            if idx < points.count {
                let p = points[idx]
                return "\(p.wfo) · \(p.zone)"
            }
        }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(locationName)
                        .font(.subheadline.weight(.semibold))
                    if !wfoLabel.isEmpty {
                        Text(wfoLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(forecast.issuedHoursAgo == 0 ? "Just now" : "\(forecast.issuedHoursAgo)h ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(forecast.periods.prefix(7).enumerated()), id: \.offset) { _, period in
                        ForecastPeriodCell(period: period, receivedAt: forecast.receivedAt)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Forecast Period Cell

private struct ForecastPeriodCell: View {
    let period: MeshWXForecast.Period
    let receivedAt: Date

    private var dayLabel: String {
        let cal = Calendar.current
        guard let date = cal.date(byAdding: .day, value: Int(period.periodID), to: receivedAt) else {
            return "Day \(period.periodID)"
        }
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(dayLabel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()

            Image(systemName: period.skySystemImage)
                .font(.title3)
                .foregroundStyle(period.skyColor)
                .frame(height: 22)

            if let high = period.highF {
                Text("\(high)°")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            } else if let low = period.lowF {
                Text("\(low)°")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if period.precipPct > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 8))
                    Text("\(period.precipPct)%")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.cyan)
            } else {
                Color.clear.frame(height: 14)
            }

            if period.windSpeedMph > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "wind")
                        .font(.system(size: 7))
                    Text("\(period.windSpeedMph)")
                        .font(.system(size: 9).weight(.medium))
                    Text(period.windDirName)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
            } else {
                Color.clear.frame(height: 13)
            }
        }
        .frame(minWidth: 52)
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Observation Row

private struct ObservationRow: View {
    let observation: MeshWXObservation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: station name + timestamp
            HStack {
                Text(observation.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(observation.timestampLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            // Sky icon + temp + feels-like
            HStack(spacing: 12) {
                Image(systemName: observation.skySystemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("\(observation.tempF)°F")
                            .font(.title3.weight(.semibold))
                        if observation.feelsLikeDelta != 0 {
                            Text("Feels \(observation.feelsLikeF)°")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(observation.skyName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Wind column
                VStack(alignment: .trailing, spacing: 2) {
                    if observation.windSpeedMph == 0 && observation.windDir == 8 {
                        Text("Calm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 3) {
                            Image(systemName: "wind")
                                .font(.caption2)
                            Text("\(observation.windSpeedMph) mph \(observation.windDirName)")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                        if observation.hasGust {
                            Text("Gusts \(observation.windGustMph) mph")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            // Detail row: dewpoint · visibility · pressure · humidity
            HStack(spacing: 10) {
                detailChip(label: "Dew", value: "\(observation.dewpointF)°")
                detailChip(label: "Vis", value: "\(observation.visibilityMi) mi")
                detailChip(label: "Pres", value: String(format: "%.2f\"", observation.pressureInHg))
                detailChip(label: "RH", value: "\(observation.relativeHumidityPct)%")
            }
        }
        .padding(.vertical, 4)
    }

    private func detailChip(label: String, value: String) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11).weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview

#Preview {
    WeatherView()
        .environment(\.appState, AppState())
}
