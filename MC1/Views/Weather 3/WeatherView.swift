import SwiftUI
import MapKit
import TipKit

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
                    prompt: "City, state, or ICAO code…"
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
    @State private var showingRadarPicker = false
    @State private var showingInfo = false
    @State private var selectedWarningDetail: MeshWXWarning?
    @State private var noticeTask: Task<Void, Never>?
    @State private var showWarnings = true
    @State private var showAllWarnings = false
    @State private var showNowcasts = true
    @State private var showFavorites = true
    @State private var showRequested = true
    @State private var showBroadcasts = true
    @State private var scrollToICAO: String?
    @State private var scrollToPlaceIndex: Int?

    // Card pager selections
    @State private var selectedFavoriteCard: String?
    @State private var selectedRequestedCard: String?
    @State private var selectedBroadcastCard: String?
    @State private var selectedRadarRegion: UInt8?
    @State private var favCardHeight: CGFloat = 200
    @State private var requestedCardHeight: CGFloat = 200
    @State private var broadcastCardHeight: CGFloat = 200

    @AppStorage("wxFavoriteICAOs") private var favoriteICAOsRaw: String = ""
    @AppStorage("wxFavoritePlaces") private var favoritePlacesRaw: String = ""
    @AppStorage("wxPreferredWFO") private var preferredWFO: String = ""

    private var favoriteICAOs: Set<String> {
        Set(favoriteICAOsRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    private var favoritePlaceIndices: Set<Int> {
        Set(favoritePlacesRaw.split(separator: ",").compactMap { Int($0) })
    }

    // MARK: - Search results

    private var cityResults: [(place: WXBundleLoader.Place, pfmPoint: WXBundleLoader.PFMPoint)] {
        WXBundleLoader.searchPlaces(query: searchQuery, limit: 25).map { r in
            (r.place, r.pfmPoint)
        }
    }

    private var stationResults: [WXBundleLoader.Station] {
        WXBundleLoader.searchStations(query: searchQuery, limit: 10)
    }

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if isSearching {
                    searchResultsList
                } else if appState.weatherCache.hasData {
                    weatherList
                } else {
                    emptyState
                }
            }
            .onChange(of: scrollToICAO) { _, newICAO in
                guard let newICAO else { return }
                Task { @MainActor in
                    let cardID = "s:\(newICAO)"
                    var scrollTarget = "section:requested"
                    if favoriteICAOs.contains(newICAO) {
                        showFavorites = true
                        selectedFavoriteCard = nil
                        scrollTarget = "section:favorites"
                    } else if stationGroups.first(where: { $0.icao == newICAO && !$0.isRequested }) != nil
                              && !favoriteICAOs.contains(newICAO) {
                        showBroadcasts = true
                        selectedBroadcastCard = nil
                        scrollTarget = "section:broadcasts"
                    } else {
                        showRequested = true
                        selectedRequestedCard = nil
                    }
                    // Let section expand and layout, then set selection + scroll
                    try? await Task.sleep(for: .milliseconds(200))
                    if scrollTarget == "section:favorites" {
                        selectedFavoriteCard = cardID
                    } else if scrollTarget == "section:broadcasts" {
                        selectedBroadcastCard = cardID
                    } else {
                        selectedRequestedCard = cardID
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo(scrollTarget, anchor: .top)
                    }
                    scrollToICAO = nil
                }
            }
            .onChange(of: scrollToPlaceIndex) { _, newIdx in
                guard let newIdx else { return }
                Task { @MainActor in
                    showRequested = true
                    selectedRequestedCard = nil
                    // Let section expand and layout, then set selection + scroll
                    try? await Task.sleep(for: .milliseconds(200))
                    selectedRequestedCard = "c:place:\(newIdx)"
                    try? await Task.sleep(for: .milliseconds(200))
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo("section:requested", anchor: .top)
                    }
                    scrollToPlaceIndex = nil
                }
            }
        }
        // Radar picker disabled for now
        // .sheet(isPresented: $showingRadarPicker) {
        //     RadarRegionPickerView()
        // }
        .sheet(isPresented: $showingInfo) {
            WXInfoSheet()
        }
        .sheet(item: $selectedWarningDetail) { warning in
            let hasMap = warning.vertices.count >= 3 || !warning.zones.isEmpty
            WeatherWarningDetailSheet(warning: warning, onShowOnMap: hasMap ? {
                selectedWarningDetail = nil
                appState.navigation.navigateToMapWarning(warning)
            } : nil)
        }
        .navigationTitle("Weather")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                BLEStatusIndicatorView()
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    appState.wxAviationUsesF.toggle()
                } label: {
                    Text(appState.wxAviationUsesF ? "°F" : "°C")
                        .font(.subheadline.weight(.semibold))
                }
                Button { showingInfo = true } label: {
                    Image(systemName: "info.circle")
                }
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
        .overlay(alignment: .bottom) {
            if let notice = appState.weatherCache.notAvailableNotice {
                HStack(spacing: 8) {
                    Image(systemName: "slash.circle")
                        .foregroundStyle(.secondary)
                    Text(notice)
                        .font(.subheadline)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35), value: appState.weatherCache.notAvailableNotice)
        .onChange(of: appState.weatherCache.notAvailableNotice) { _, newValue in
            guard newValue != nil else { return }
            noticeTask?.cancel()
            noticeTask = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                appState.weatherCache.clearNotAvailableNotice()
            }
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

    private func cityRow(_ place: WXBundleLoader.Place, pfmPoint: WXBundleLoader.PFMPoint?) -> some View {
        Button {
            if let pfmPoint {
                Task { await sendCityObservationRequest(pfmPoint: pfmPoint, place: place) }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    if let pfmPoint, !pfmPoint.zone.isEmpty {
                        Text("\(pfmPoint.wfo) · \(pfmPoint.zone)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
        .disabled(isSendingSearch || appState.connectionState != .ready || pfmPoint == nil)
    }

    private func stationRow(_ station: WXBundleLoader.Station) -> some View {
        Button {
            Task { await sendObservationRequest(icao: station.id) }
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

    // MARK: - Station Groups

    /// Observations keyed by ICAO code (extracted from locationIDBytes for station-type obs).
    private var observationsByICAO: [String: MeshWXObservation] {
        appState.weatherCache.observations.values.reduce(into: [:]) { dict, obs in
            guard obs.locationType == 2,
                  obs.locationIDBytes.count >= 4,
                  let icao = String(bytes: obs.locationIDBytes.prefix(4), encoding: .ascii)?
                      .trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
                  !icao.isEmpty else { return }
            dict[icao] = obs
        }
    }

    /// City/zone observations not tied to a METAR station ICAO code.
    /// Includes zone-type (RWR) and PFM-point-type (echoed on-demand) observations.
    private var cityObservations: [MeshWXObservation] {
        let favPlaces = favoritePlaceIndices
        return appState.weatherCache.observations.values
            .filter { ($0.isZone || $0.isPlace || $0.locationType == 6)
                      && !favPlaces.contains($0.placeIndex ?? -1) }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    private var favoriteCityObservations: [MeshWXObservation] {
        let favPlaces = favoritePlaceIndices
        return appState.weatherCache.observations.values
            .filter { $0.isPlace && favPlaces.contains($0.placeIndex ?? -1) }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    /// Pending city observation request keys (wx:place:, wx:zone:, wx:pfm:).
    private var pendingZoneKeys: [String] {
        appState.weatherCache.pendingKeys
            .filter { $0.hasPrefix("wx:place:") || $0.hasPrefix("wx:zone:") || $0.hasPrefix("wx:pfm:") }
            .sorted()
    }

    /// Extends explicit forecastOrigins with proximity links for unlinked auto-broadcast forecasts.
    /// For each forecast not already linked to a station, finds the nearest observed station.
    private var forecastToICAO: [String: String] {
        var result = appState.weatherCache.forecastOrigins
        let obsByICAO = observationsByICAO
        guard !obsByICAO.isEmpty else { return result }
        let pfmPoints = WXBundleLoader.allPFMPoints
        let observedStations = WXBundleLoader.allStations.filter { obsByICAO[$0.id] != nil }
        guard !observedStations.isEmpty else { return result }
        for (key, forecast) in appState.weatherCache.forecasts where result[key] == nil {
            // Only auto-link PFM-point forecasts to stations (not place forecasts)
            guard let pfmIdx = forecast.pfmPointIndex, pfmIdx < pfmPoints.count else { continue }
            let coord = pfmPoints[pfmIdx].coordinate
            if let nearest = observedStations.min(by: { a, b in
                squaredDist(a.latitude, a.longitude, coord.latitude, coord.longitude) <
                squaredDist(b.latitude, b.longitude, coord.latitude, coord.longitude)
            }) {
                result[key] = nearest.id
            }
        }
        return result
    }

    private func squaredDist(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let dLat = lat2 - lat1; let dLon = lon2 - lon1
        return dLat * dLat + dLon * dLon
    }

    private var stationGroups: [StationGroup] {
        let obsByICAO = observationsByICAO
        let fcastToICAO = forecastToICAO
        var icaos: Set<String> = []
        icaos.formUnion(obsByICAO.keys)
        icaos.formUnion(appState.weatherCache.tafs.keys)
        icaos.formUnion(fcastToICAO.values)
        for key in appState.weatherCache.pendingKeys {
            if key.hasPrefix("metar:") { icaos.insert(String(key.dropFirst(6))) }
            else if key.hasPrefix("taf:") { icaos.insert(String(key.dropFirst(4))) }
            else if key.hasPrefix("forecast:") {
                let fKey = String(key.dropFirst(9))
                if let icao = fcastToICAO[fKey] { icaos.insert(icao) }
            }
        }
        // Unavailable keys also keep stations visible (e.g. after timeout)
        for key in appState.weatherCache.unavailableKeys.keys {
            if key.hasPrefix("metar:") { icaos.insert(String(key.dropFirst(6))) }
            else if key.hasPrefix("taf:") { icaos.insert(String(key.dropFirst(4))) }
            else if key.hasPrefix("forecast:") {
                let fKey = String(key.dropFirst(9))
                if let icao = fcastToICAO[fKey] { icaos.insert(icao) }
            }
        }
        // Always include favorites so their cards are present for on-demand requests
        icaos.formUnion(favoriteICAOs)
        let favs = favoriteICAOs
        return icaos.map { icao in
            let obs = obsByICAO[icao]
            let taf = appState.weatherCache.tafs[icao]
            let origin = fcastToICAO.first(where: { $0.value == icao })
            let linked: (key: String, forecast: MeshWXForecast)? = origin.flatMap { entry in
                appState.weatherCache.forecasts[entry.key].map { (entry.key, $0) }
            }
            let pendingForecast = origin.map {
                appState.weatherCache.isPending("forecast:\($0.key)")
            } ?? false
            let requested = appState.weatherCache.isRequested("metar:\(icao)")
                         || appState.weatherCache.isRequested("taf:\(icao)")
                         || (origin.map { appState.weatherCache.isRequested("forecast:\($0.key)") } ?? false)
            return StationGroup(
                icao: icao,
                obs: obs, taf: taf,
                linkedForecast: linked,
                pendingObs: appState.weatherCache.isPending("metar:\(icao)"),
                pendingTAF: appState.weatherCache.isPending("taf:\(icao)"),
                pendingForecast: pendingForecast,
                obsUnavailable: appState.weatherCache.isUnavailable("metar:\(icao)"),
                tafUnavailable: appState.weatherCache.isUnavailable("taf:\(icao)"),
                forecastUnavailable: origin.map {
                    appState.weatherCache.isUnavailable("forecast:\($0.key)")
                } ?? false,
                isRequested: requested
            )
        }
        .sorted { a, b in
            let aFav = favs.contains(a.icao)
            let bFav = favs.contains(b.icao)
            if aFav != bFav { return aFav }
            // Favorites: alphabetical (stable — cards don't jump when new data arrives).
            // Non-favorites: most recently received first.
            if aFav { return a.icao < b.icao }
            return mostRecentReceivedDate(a) > mostRecentReceivedDate(b)
        }
    }

    private func mostRecentReceivedDate(_ group: StationGroup) -> Date {
        var date = Date.distantPast
        if let obs = group.obs { date = max(date, obs.receivedAt) }
        if let taf = group.taf { date = max(date, taf.receivedAt) }
        if let (_, fc) = group.linkedForecast { date = max(date, fc.receivedAt) }
        // Pending-only stations (no data yet) should sort first — treat as "just now"
        if date == .distantPast && (group.pendingObs || group.pendingTAF || group.pendingForecast) {
            return Date()
        }
        return date
    }

    private var favoriteGroups:  [StationGroup] { stationGroups.filter {  favoriteICAOs.contains($0.icao) } }
    private var requestedGroups: [StationGroup] { stationGroups.filter { !favoriteICAOs.contains($0.icao) &&  $0.isRequested } }
    private var broadcastGroups: [StationGroup] { stationGroups.filter { !favoriteICAOs.contains($0.icao) && !$0.isRequested } }

    /// Forecasts not linked to any station or city card.
    private var unlinkedForecasts: [(key: String, forecast: MeshWXForecast)] {
        let linked = forecastToICAO
        return appState.weatherCache.forecasts
            .filter { linked[$0.key] == nil && !$0.key.hasPrefix("place:") }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, forecast: $0.value) }
    }

    // MARK: - Bot Status Section

    private var botSection: some View {
        Section {
            switch appState.discoveryState {
            case .idle:
                if !appState.joinedWXBotChannels.isEmpty {
                    ForEach(Array(appState.joinedWXBotChannels).sorted(), id: \.self) { channel in
                        joinedBotRow(channel)
                    }
                }
                Button {
                    Task { await appState.scanForWeatherBots() }
                } label: {
                    Label(appState.joinedWXBotChannels.isEmpty ? "Scan for Weather Bots" : "Scan Again",
                          systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(appState.connectionState != .ready)

            case .scanning(let remaining):
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.8)
                    Text("Scanning… \(remaining)s remaining")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

            case .done:
                if !appState.joinedWXBotChannels.isEmpty {
                    ForEach(Array(appState.joinedWXBotChannels).sorted(), id: \.self) { channel in
                        joinedBotRow(channel)
                    }
                }
                if appState.weatherCache.discoveredBots.isEmpty && appState.joinedWXBotChannels.isEmpty {
                    Text("No bots found").foregroundStyle(.secondary)
                } else {
                    ForEach(appState.weatherCache.discoveredBots.values
                        .filter { !appState.joinedWXBotChannels.contains($0.channelName) }
                        .sorted(by: { $0.channelName < $1.channelName }),
                            id: \.channelName) { bot in
                        discoveredBotRow(bot)
                    }
                }
                Button {
                    Task { await appState.scanForWeatherBots() }
                } label: {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                }
                .font(.subheadline)
                .disabled(appState.connectionState != .ready)
            }
        } header: {
            Text("Weather Bot")
        } footer: {
            if let lastAt = appState.weatherCache.lastWXDataAt {
                Text("Last data received \(lastAt, style: .relative) ago")
            } else if !appState.joinedWXBotChannels.isEmpty {
                Text("No data received yet this session")
            }
        }
    }

    private func joinedBotRow(_ channelName: String) -> some View {
        let beacon = appState.weatherCache.discoveredBots[channelName]
        return HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(beacon?.displayName ?? "#\(channelName)")
                    .font(.subheadline.weight(.medium))
                Text("#\(channelName)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await appState.leaveWXBotDataChannel(channelName) }
            } label: {
                Label("Leave", systemImage: "minus.circle")
            }
        }
    }

    private func discoveredBotRow(_ bot: MeshWXBeacon) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.circle")
                .foregroundStyle(.cyan)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.displayName)
                    .font(.subheadline.weight(.medium))
                Text("#\(bot.channelName)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(bot.capabilitySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await appState.joinWXBotDataChannel(bot) }
            } label: {
                Text("Join")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.cyan.opacity(0.15), in: Capsule())
                    .foregroundStyle(.cyan)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Weather Data List

    private var weatherList: some View {
        List {
            // Active Warnings / Upcoming Watches — always first
            warningsSection

            // Nowcasts — urgent tactical forecasts, shown just below warnings
            if !appState.weatherCache.nowcasts.isEmpty {
                nowcastsSection
            }

            // Favorites — unified card pager (stations + cities)
            let favItems: [WeatherCardItem] = favoriteGroups.map { .station($0) }
                + favoriteCityObservations.map { .city($0) }
            if !favItems.isEmpty {
                cardPagerSection(
                    title: "Favorites", icon: "star.fill",
                    items: favItems,
                    selection: $selectedFavoriteCard,
                    cardHeight: $favCardHeight,
                    isExpanded: $showFavorites
                )
                .id("section:favorites")
            }

            // Your Requests — unified card pager (stations + cities) + pending rows
            let cityObs = cityObservations
            let pendingCities = pendingZoneKeys
            let requestedItems: [WeatherCardItem] = requestedGroups.map { .station($0) }
                + cityObs.map { .city($0) }
            let totalRequested = requestedItems.count + pendingCities.count
            if totalRequested > 0 {
                if !requestedItems.isEmpty {
                    cardPagerSection(
                        title: "Your Requests", icon: "arrow.up.message",
                        items: requestedItems,
                        selection: $selectedRequestedCard,
                        cardHeight: $requestedCardHeight,
                        isExpanded: $showRequested
                    )
                    .id("section:requested")
                } else {
                    groupSeparator(title: "Your Requests", count: totalRequested,
                                   icon: "arrow.up.message", isExpanded: $showRequested)
                    .id("section:requested")
                }
                if showRequested {
                    ForEach(pendingCities, id: \.self) { _ in
                        PendingRow(label: "Awaiting city weather…")
                    }
                }
            }

            // Broadcasts — horizontal card pager for station groups + other sections below
            let broadcastStationCount = broadcastGroups.count
            let extraBroadcastCount = 0
                + (unlinkedForecasts.isEmpty ? 0 : 1)
                + (appState.weatherCache.outlooks.isEmpty ? 0 : 1)
                + (appState.weatherCache.stormReports.isEmpty ? 0 : 1)
                + (appState.weatherCache.rainObservations.isEmpty ? 0 : 1)
                + (appState.weatherCache.warningsNear.isEmpty ? 0 : 1)
                + (appState.weatherCache.fireWeathers.isEmpty ? 0 : 1)
                + (appState.weatherCache.dailyClimate == nil ? 0 : 1)
            let totalBroadcastCount = broadcastStationCount + extraBroadcastCount
                + (appState.weatherCache.radarFrames.isEmpty ? 0 : 1)
            if totalBroadcastCount > 0 {
                // Broadcast cards (pager)
                let broadcastItems: [WeatherCardItem] = broadcastGroups.map { .station($0) }
                if !broadcastItems.isEmpty {
                    cardPagerSection(
                        title: "Broadcasts", icon: "dot.radiowaves.left.and.right",
                        items: broadcastItems,
                        selection: $selectedBroadcastCard,
                        cardHeight: $broadcastCardHeight,
                        isExpanded: $showBroadcasts
                    )
                    .id("section:broadcasts")
                } else {
                    groupSeparator(title: "Broadcasts", count: totalBroadcastCount,
                                   icon: "dot.radiowaves.left.and.right", isExpanded: $showBroadcasts)
                    .id("section:broadcasts")
                }

                if showBroadcasts {
                    if !unlinkedForecasts.isEmpty { unlinkedForecastsSection }
                    if !appState.weatherCache.outlooks.isEmpty { outlooksSection }
                    if !appState.weatherCache.stormReports.isEmpty { stormReportsSection }
                    if !appState.weatherCache.rainObservations.isEmpty { rainObsSection }
                    if !appState.weatherCache.warningsNear.isEmpty { warningsNearSection }
                    if !appState.weatherCache.fireWeathers.isEmpty { fireWeatherSection }
                    if appState.weatherCache.dailyClimate != nil { dailyClimateSection }

                    // Radar disabled for now
                    // if !appState.weatherCache.radarFrames.isEmpty {
                    //     radarCardPagerSection
                    // }
                }
            }

            statusSection
            botSection
        }
        .listSectionSpacing(.compact)
    }

    // MARK: - Station Card Pager Section

    @ViewBuilder
    private func cardPagerSection(
        title: String, icon: String,
        items: [WeatherCardItem],
        selection: Binding<String?>,
        cardHeight: Binding<CGFloat>,
        isExpanded: Binding<Bool>
    ) -> some View {
        Section {
            if isExpanded.wrappedValue {
                VStack(spacing: 6) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(items) { item in
                                Group {
                                    switch item {
                                    case .station(let group):
                                        StationPageCard(group: group, isFavorite: favoriteICAOs.contains(group.icao))
                                    case .city(let obs):
                                        CityObservationCard(observation: obs)
                                            .padding(.horizontal, 12)
                                    }
                                }
                                .containerRelativeFrame(.horizontal)
                                .frame(maxHeight: .infinity, alignment: .top)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                    .scrollPosition(id: selection)
                    .scrollIndicators(.hidden)
                    .frame(height: cardHeight.wrappedValue + 16)
                    .onPreferenceChange(CardHeightKey.self) { newHeight in
                        if newHeight > 0 && newHeight > cardHeight.wrappedValue {
                            cardHeight.wrappedValue = newHeight
                        }
                    }

                    // Page dots
                    if items.count > 1 {
                        HStack(spacing: 6) {
                            ForEach(items) { item in
                                Circle()
                                    .fill(selection.wrappedValue == item.id ? Color.primary : Color.secondary.opacity(0.4))
                                    .frame(width: 7, height: 7)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                .listRowSeparator(.hidden)
                .onAppear {
                    if selection.wrappedValue == nil {
                        selection.wrappedValue = items.first?.id
                    }
                }
                .onChange(of: items.map(\.id)) { _, newIDs in
                    if let sel = selection.wrappedValue, !newIDs.contains(sel) {
                        selection.wrappedValue = newIDs.first
                    }
                }
            }
        } header: {
            Button {
                withAnimation { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon).font(.footnote)
                    Text(title).font(.subheadline.weight(.semibold)).textCase(nil)
                    Text("(\(items.count))").font(.subheadline).foregroundStyle(.secondary).textCase(nil)
                    Spacer()
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.footnote)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }



    // MARK: - Radar Card Pager Section

    @ViewBuilder
    private var radarCardPagerSection: some View {
        let regions = sortedRadarRegions

        Section {
            TabView(selection: $selectedRadarRegion) {
                ForEach(regions, id: \.self) { regionID in
                    if let frames = appState.weatherCache.radarFrames[regionID], !frames.isEmpty {
                        NavigationLink {
                            RadarLoopView(regionID: regionID, frames: frames)
                        } label: {
                            RadarMiniCard(regionID: regionID)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 36)
                        .tag(Optional(regionID))
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: regions.count > 1 ? .always : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .automatic))
            .frame(height: 310)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            .listRowSeparator(.hidden)
            .onAppear {
                if selectedRadarRegion == nil {
                    selectedRadarRegion = regions.first
                }
            }
        } header: {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.blue)
                Text("Radar (\(regions.count) region\(regions.count == 1 ? "" : "s"))")
                if let sel = selectedRadarRegion, let region = MeshWXRegion.all[sel] {
                    Text("· \(region.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
                Spacer()
                Button {
                    showingRadarPicker = true
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func groupSeparator(title: String, count: Int, icon: String, isExpanded: Binding<Bool>) -> some View {
        Section {
        } header: {
            Button {
                withAnimation { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon).font(.footnote)
                    Text(title).font(.subheadline.weight(.semibold)).textCase(nil)
                    Text("(\(count))").font(.subheadline).foregroundStyle(.secondary).textCase(nil)
                    Spacer()
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.footnote)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func stationSection(_ group: StationGroup) -> some View {
        StationCard(group: group, isFavorite: favoriteICAOs.contains(group.icao))
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { clearStation(group) }
                    label: { Label("Clear", systemImage: "trash") }
            }
            .id(group.icao)
    }

    private func clearStation(_ group: StationGroup) {
        // Remove from favorites first so the section structure updates atomically with the data removal.
        // This prevents UICollectionView section-count inconsistency on rapid deletes and eliminates
        // the "empty favorite card with no way to dismiss it" state.
        if favoriteICAOs.contains(group.icao) {
            var favs = favoriteICAOs
            favs.remove(group.icao)
            favoriteICAOsRaw = favs.sorted().joined(separator: ",")
        }
        if let obs = group.obs { appState.weatherCache.removeObservation(key: obs.locationKey) }
        if let (fKey, _) = group.linkedForecast { appState.weatherCache.removeForecast(key: fKey) }
        if group.taf != nil { appState.weatherCache.removeTAF(icao: group.icao) }
    }

    // MARK: - Unlinked Forecasts Section

    private var unlinkedForecastsSection: some View {
        Section {
            ForEach(unlinkedForecasts, id: \.key) { item in
                ForecastRow(forecast: item.forecast)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            appState.weatherCache.removeForecast(key: item.key)
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                    .contextMenu {
                        if item.forecast.pfmPointIndex != nil {
                            Section("Request More Data") {
                                Button { } label: { Label("Hazard Outlook", systemImage: "calendar.badge.exclamationmark") }
                                    .disabled(true)
                                Button { } label: { Label("Storm Reports", systemImage: "tornado") }
                                    .disabled(true)
                                Button { } label: { Label("Precipitation Reports", systemImage: "cloud.rain.fill") }
                                    .disabled(true)
                                Button { } label: { Label("Warnings Near Location", systemImage: "location.circle.fill") }
                                    .disabled(true)
                            }
                            Divider()
                        }
                        Button(role: .destructive) {
                            appState.weatherCache.removeForecast(key: item.key)
                        } label: { Label("Delete Forecast", systemImage: "trash") }
                    }
            }
        } header: {
            HStack {
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(.orange)
                Text("Forecasts (\(unlinkedForecasts.count))")
            }
        }
    }

    // MARK: - Warnings Section

    private var activeWarnings: [MeshWXWarning] {
        appState.weatherCache.warnings
            .filter { !$0.isUpcoming }
            .sorted { a, b in
                if a.severity != b.severity { return a.severity > b.severity }
                return a.expiryDate < b.expiryDate
            }
    }

    private var upcomingWarnings: [MeshWXWarning] {
        appState.weatherCache.warnings
            .filter { $0.isUpcoming }
            .sorted { a, b in
                let aOnset = a.onsetDate ?? Date.distantFuture
                let bOnset = b.onsetDate ?? Date.distantFuture
                return aOnset < bOnset
            }
    }

    // MARK: - Location-Based Warning Filtering

    private var userPFMPoint: WXBundleLoader.PFMPoint? {
        guard let location = appState.locationService.currentLocation else { return nil }
        return WXBundleLoader.nearestPFMPoint(to: location.coordinate)
    }

    private var autoDetectedWFO: String? {
        guard let pfm = userPFMPoint, !pfm.wfo.isEmpty else { return nil }
        return pfm.wfo
    }

    private var effectiveWFO: String? {
        if !preferredWFO.isEmpty { return preferredWFO }
        return autoDetectedWFO
    }

    private var wfoFilterLabel: String {
        if preferredWFO.isEmpty {
            if let wfo = autoDetectedWFO {
                return "Near Me (\(wfo))"
            }
            return "Near Me"
        }
        if let pfm = WXBundleLoader.allPFMPoints.first(where: { $0.wfo == preferredWFO }) {
            return "\(preferredWFO) · \(pfm.name)"
        }
        return preferredWFO
    }

    private var zoneToWFO: [String: String] {
        var map: [String: String] = [:]
        for pfm in WXBundleLoader.allPFMPoints where !pfm.zone.isEmpty && !pfm.wfo.isEmpty {
            map[pfm.zone] = pfm.wfo
        }
        return map
    }

    private func warningWFO(_ warning: MeshWXWarning) -> String? {
        if !warning.office.isEmpty { return warning.office }
        let lookup = zoneToWFO
        for zone in warning.zones {
            if let code = ZoneGeometryStore.zoneCode(stateIdx: zone.stateIdx, zoneNum: zone.zoneNum),
               let wfo = lookup[code] {
                return wfo
            }
        }
        return nil
    }

    private var availableWarningWFOs: [String] {
        guard let userZone = userPFMPoint?.zone, userZone.count >= 2 else { return [] }
        let statePrefix = String(userZone.prefix(2))
        var wfos = Set<String>()
        for pfm in WXBundleLoader.allPFMPoints {
            if pfm.zone.hasPrefix(statePrefix) && !pfm.wfo.isEmpty {
                wfos.insert(pfm.wfo)
            }
        }
        return wfos.sorted()
    }

    private var userCoordinate: CLLocationCoordinate2D? {
        appState.locationService.currentLocation?.coordinate
    }

    private var canFilterByLocation: Bool { effectiveWFO != nil }

    private func isWarningLocal(_ warning: MeshWXWarning) -> Bool {
        guard let wfo = effectiveWFO else { return false }
        if let warningWfo = warningWFO(warning), warningWfo == wfo {
            return true
        }
        if let coord = userCoordinate, warning.vertices.count >= 3 {
            return Self.pointInPolygon(coord, vertices: warning.vertices)
        }
        return false
    }

    private static func pointInPolygon(
        _ point: CLLocationCoordinate2D,
        vertices: [CLLocationCoordinate2D]
    ) -> Bool {
        let n = vertices.count
        guard n >= 3 else { return false }
        var inside = false
        var j = n - 1
        for i in 0..<n {
            let vi = vertices[i]
            let vj = vertices[j]
            if (vi.latitude > point.latitude) != (vj.latitude > point.latitude),
               point.longitude < (vj.longitude - vi.longitude) *
                   (point.latitude - vi.latitude) / (vj.latitude - vi.latitude) + vi.longitude {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    private var localWarnings: [MeshWXWarning] {
        activeWarnings.filter { isWarningLocal($0) } + upcomingWarnings.filter { isWarningLocal($0) }
    }

    private var otherWarnings: [MeshWXWarning] {
        activeWarnings.filter { !isWarningLocal($0) } + upcomingWarnings.filter { !isWarningLocal($0) }
    }

    private var localUpcomingCount: Int {
        upcomingWarnings.filter { isWarningLocal($0) }.count
    }

    private var otherUpcomingCount: Int {
        upcomingWarnings.filter { !isWarningLocal($0) }.count
    }

    private func wfoDisplayName(_ code: String) -> String {
        if let pfm = WXBundleLoader.allPFMPoints.first(where: { $0.wfo == code }) {
            return "\(code) · \(pfm.name)"
        }
        return code
    }

    // MARK: - Warnings Section UI

    @ViewBuilder
    private var warningsSection: some View {
        let allWarnings = activeWarnings + upcomingWarnings
        if !allWarnings.isEmpty {
            if canFilterByLocation {
                Section {
                    if showWarnings {
                        if localWarnings.isEmpty {
                            Text("No warnings for your area")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .listRowBackground(Color.clear)
                        } else {
                            ForEach(localWarnings) { warning in
                                warningRow(warning)
                            }
                        }
                    }
                } header: {
                    warningsSectionHeader(
                        title: "Warnings",
                        totalCount: localWarnings.count,
                        upcomingCount: localUpcomingCount,
                        isExpanded: $showWarnings,
                        showWFOPicker: true
                    )
                }

                if !otherWarnings.isEmpty {
                    Section {
                        if showAllWarnings {
                            ForEach(otherWarnings) { warning in
                                warningRow(warning)
                            }
                        }
                    } header: {
                        warningsSectionHeader(
                            title: "All Warnings",
                            totalCount: otherWarnings.count,
                            upcomingCount: otherUpcomingCount,
                            isExpanded: $showAllWarnings,
                            showWFOPicker: false
                        )
                    }
                }
            } else {
                Section {
                    if showWarnings {
                        ForEach(allWarnings) { warning in
                            warningRow(warning)
                        }
                    }
                } header: {
                    warningsSectionHeader(
                        title: "Warnings",
                        totalCount: allWarnings.count,
                        upcomingCount: upcomingWarnings.count,
                        isExpanded: $showWarnings,
                        showWFOPicker: false
                    )
                }
            }
        }
    }

    private func warningsSectionHeader(
        title: String,
        totalCount: Int,
        upcomingCount: Int,
        isExpanded: Binding<Bool>,
        showWFOPicker: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.yellow)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .textCase(nil)
                    Text("(\(totalCount))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                    if upcomingCount > 0 {
                        Text("· \(upcomingCount) upcoming")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                    Spacer()
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showWFOPicker {
                Menu {
                    Button {
                        preferredWFO = ""
                    } label: {
                        if preferredWFO.isEmpty {
                            Label("Near Me" + (autoDetectedWFO.map { " (\($0))" } ?? ""), systemImage: "checkmark")
                        } else {
                            Text("Near Me" + (autoDetectedWFO.map { " (\($0))" } ?? ""))
                        }
                    }

                    Divider()

                    ForEach(availableWarningWFOs, id: \.self) { wfo in
                        Button {
                            preferredWFO = wfo
                        } label: {
                            if preferredWFO == wfo {
                                Label(wfoDisplayName(wfo), systemImage: "checkmark")
                            } else {
                                Text(wfoDisplayName(wfo))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.caption)
                        Text(wfoFilterLabel)
                            .font(.caption)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                }
            }
        }
    }

    private func warningRow(_ warning: MeshWXWarning) -> some View {
        Button {
            selectedWarningDetail = warning
        } label: {
            HStack {
                WarningRow(warning: warning)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Outlooks Section

    private var outlooksSection: some View {
        Section {
            ForEach(Array(appState.weatherCache.outlooks.keys).sorted(), id: \.self) { key in
                if let outlook = appState.weatherCache.outlooks[key] {
                    OutlookRow(outlook: outlook)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                appState.weatherCache.removeOutlook(key: key)
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            }
        } header: {
            HStack {
                Image(systemName: "calendar.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Text("Hazard Outlook (\(appState.weatherCache.outlooks.count))")
            }
        }
    }

    // MARK: - Storm Reports Section

    private var stormReportsSection: some View {
        Section {
            ForEach(Array(appState.weatherCache.stormReports.keys).sorted(), id: \.self) { key in
                if let reports = appState.weatherCache.stormReports[key] {
                    StormReportsRow(reports: reports)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                appState.weatherCache.removeStormReports(key: key)
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            }
        } header: {
            HStack {
                Image(systemName: "tornado")
                    .foregroundStyle(.red)
                let total = appState.weatherCache.stormReports.values.reduce(0) { $0 + $1.reports.count }
                Text("Storm Reports (\(total))")
            }
        }
    }

    // MARK: - Rain Observations Section

    private var rainObsSection: some View {
        Section {
            ForEach(Array(appState.weatherCache.rainObservations.keys).sorted(), id: \.self) { key in
                if let obs = appState.weatherCache.rainObservations[key] {
                    RainObsRow(obs: obs)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                appState.weatherCache.removeRainObservations(key: key)
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            }
        } header: {
            HStack {
                Image(systemName: "cloud.rain.fill")
                    .foregroundStyle(.cyan)
                let total = appState.weatherCache.rainObservations.values.reduce(0) { $0 + $1.cities.count }
                Text("Precipitation Reports (\(total) cities)")
            }
        }
    }

    // MARK: - Warnings Near Section

    private var warningsNearSection: some View {
        Section {
            ForEach(Array(appState.weatherCache.warningsNear.keys).sorted(), id: \.self) { key in
                if let near = appState.weatherCache.warningsNear[key] {
                    WarningsNearRow(warningsNear: near)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                appState.weatherCache.removeWarningsNear(key: key)
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            }
        } header: {
            HStack {
                Image(systemName: "location.circle.fill")
                    .foregroundStyle(.red)
                let total = appState.weatherCache.warningsNear.values.reduce(0) { $0 + $1.entries.count }
                Text("Warnings Near You (\(total))")
            }
        }
    }

    // MARK: - Nowcast Section

    private var nowcastsSection: some View {
        Section {
            if showNowcasts {
                ForEach(Array(appState.weatherCache.nowcasts.values).sorted(by: { $0.receivedAt > $1.receivedAt }), id: \.locationKey) { nowcast in
                    NowcastRow(nowcast: nowcast)
                }
            }
        } header: {
            Button {
                withAnimation { showNowcasts.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "clock.badge.exclamationmark.fill").font(.footnote).foregroundStyle(.orange)
                    Text("Short-Term Forecast").font(.subheadline.weight(.semibold)).textCase(nil)
                    Text("(\(appState.weatherCache.nowcasts.count))").font(.subheadline).foregroundStyle(.secondary).textCase(nil)
                    Spacer()
                    Image(systemName: showNowcasts ? "chevron.down" : "chevron.right").font(.footnote).foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Fire Weather Section

    private var fireWeatherSection: some View {
        Section {
            ForEach(Array(appState.weatherCache.fireWeathers.values).sorted(by: { $0.receivedAt > $1.receivedAt }), id: \.locationKey) { fw in
                FireWeatherRow(fireWeather: fw)
            }
        } header: {
            HStack {
                Image(systemName: "flame.fill").foregroundStyle(.orange)
                Text("Fire Weather")
            }
        }
    }

    // MARK: - Daily Climate Section

    private var dailyClimateSection: some View {
        Section {
            if let dc = appState.weatherCache.dailyClimate {
                DailyClimateRow(climate: dc)
            }
        } header: {
            HStack {
                Image(systemName: "thermometer.medium").foregroundStyle(.secondary)
                Text("Daily Climate")
            }
        }
    }

    // MARK: - Radar Section

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
            LabeledContent("Messages Received", value: "\(appState.weatherCache.messageLog.count)")

            NavigationLink {
                WeatherLogView()
            } label: {
                Label("Message Log", systemImage: "doc.text.magnifyingglass")
            }

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
        List {
            botSection
            Section {
                ContentUnavailableView {
                    Label("No Weather Data", systemImage: "cloud.slash")
                } description: {
                    Text("Data appears when a MeshWX bot is active on the mesh. Join a bot above, or search for a city to request a forecast.")
                } actions: {
                    Button("Request Update") { Task { await requestUpdate() } }
                        .buttonStyle(.bordered)
                }
                .listRowBackground(Color.clear)
            }
        }
    }

    // MARK: - Actions

    private func sendObservationRequest(icao: String?) async {
        guard let icao, !isSendingSearch else { return }
        isSendingSearch = true
        defer { isSendingSearch = false }
        searchError = nil

        let result = await appState.sendMetarRequest(icao: icao)
        switch result {
        case .sent:
            dismissSearch()
            scrollToICAO = icao
        case .botNotFound:
            searchError = "Weather bot not configured. Set the bot contact name in Tools → Weather Log."
        case .notConnected:
            searchError = "Not connected to a LoRa device."
        case .noDataChannel:
            searchError = "Weather channel not available. Check your device connection."
        case .noLocation, .rateLimited:
            searchError = "Could not send request. Try again in a moment."
        }
    }

    private func sendCityObservationRequest(pfmPoint: WXBundleLoader.PFMPoint, place: WXBundleLoader.Place) async {
        guard !isSendingSearch else { return }
        isSendingSearch = true
        defer { isSendingSearch = false }
        searchError = nil

        let result = await appState.sendObservationRequest(
            placeIndex: place.id,
            zoneCode: pfmPoint.zone.isEmpty ? nil : pfmPoint.zone
        )
        switch result {
        case .sent:
            dismissSearch()
            scrollToPlaceIndex = place.id
        case .botNotFound:
            searchError = "Weather bot not configured. Set the bot contact name in Tools → Weather Log."
        case .notConnected:
            searchError = "Not connected to a LoRa device."
        case .noDataChannel:
            searchError = "Weather channel not available. Check your device connection."
        case .noLocation, .rateLimited:
            searchError = "Could not send request. Try again in a moment."
        }
    }

    private func requestUpdate() async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }

        let result = await appState.sendWeatherRefreshRequest()
        switch result {
        case .sent:
            break
        case .rateLimited, .notConnected, .botNotFound:
            break
        case .noDataChannel:
            requestError = "Weather channel not available. Check your device connection."
        case .noLocation:
            requestError = "Location not available yet. Move to a region with GPS signal, or wait a moment and try again."
        }
    }

}

// MARK: - Pending Row

private struct PendingRow: View {
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.75)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Unavailable Row

private struct UnavailableRow: View {
    let label: String

    var body: some View {
        Label(label, systemImage: "slash.circle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }
}

// MARK: - Warning Row

private struct WarningRow: View {
    let warning: MeshWXWarning

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Side bar: greyed for upcoming to visually indicate "not yet active"
            RoundedRectangle(cornerRadius: 2)
                .fill(warning.isUpcoming ? Color.secondary.opacity(0.4) : warningColor)
                .frame(width: 4)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(warning.displayTitle)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(warning.isUpcoming ? .secondary : .primary)
                    Spacer()
                    expiryBadge
                }

                if let onset = warning.onsetDate, onset > Date() {
                    Text(onsetLabel(onset))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !warning.headline.isEmpty {
                    Text(warning.headline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
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

    private var expiryBadge: some View {
        // Upcoming: show time until onset
        if let onset = warning.onsetDate, onset > Date() {
            let interval = onset.timeIntervalSinceNow
            let text: String
            if interval < 3600 {
                text = "active in \(Int(interval / 60))m"
            } else {
                let hours = Int(interval / 3600)
                let mins  = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)
                text = mins > 0 ? "active in \(hours)h \(mins)m" : "active in \(hours)h"
            }
            return Text(text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }

        // Active: show time until expiry
        let remaining = warning.expiryDate.timeIntervalSinceNow
        let text: String
        let color: Color

        if remaining <= 0 {
            text = "expired"
            color = .secondary
        } else if remaining < 1800 {
            let mins = Int(remaining / 60)
            text = "exp in \(mins)m"
            color = .orange
        } else {
            let hours = Int(remaining / 3600)
            let mins = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
            text = mins > 0 ? "exp in \(hours)h \(mins)m" : "exp in \(hours)h"
            color = .secondary
        }

        return Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
    }

    private var warningColor: Color { warning.swiftUIColor }
}

// MARK: - Radar Mini Card (for pager)

private struct RadarMiniCard: View {
    @Environment(\.appState) private var appState
    let regionID: UInt8

    @State private var currentIndex: Int = 0
    @State private var isPlaying = true
    @State private var loopTask: Task<Void, Never>?

    private var frames: [MeshWXRadarFrame] {
        appState.weatherCache.radarFrames[regionID] ?? []
    }
    private var region: MeshWXRegion? { MeshWXRegion.all[regionID] }
    private var currentFrame: MeshWXRadarFrame? {
        guard !frames.isEmpty else { return nil }
        return frames[min(currentIndex, frames.count - 1)]
    }

    private var isHiRes: Bool {
        currentFrame.map { $0.gridSize >= 64 } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Live map with radar overlay — auto-looping preview
            ZStack(alignment: .topTrailing) {
                if let region {
                    RadarMapView(region: region, frame: currentFrame, isInteractive: false)
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                        .allowsHitTesting(false)
                }

                // Resolution badge + play/pause
                HStack(spacing: 6) {
                    // Hi-res / standard badge
                    Text(isHiRes ? "HD" : "SD")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(isHiRes ? .cyan : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())

                    // Play/pause toggle
                    if frames.count > 1 {
                        Button {
                            isPlaying.toggle()
                            if isPlaying {
                                startLoop()
                            } else {
                                loopTask?.cancel()
                            }
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.caption2)
                                .foregroundStyle(.primary)
                                .frame(width: 24, height: 24)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))

            // Footer bar
            HStack(spacing: 8) {
                Text(region?.name ?? "Region \(regionID)")
                    .font(.subheadline.weight(.semibold))
                Text("·")
                    .foregroundStyle(.tertiary)
                if frames.count > 1 {
                    HStack(spacing: 3) {
                        ForEach(0..<frames.count, id: \.self) { idx in
                            Circle()
                                .fill(idx == currentIndex ? Color.cyan : Color.secondary.opacity(0.3))
                                .frame(width: 4, height: 4)
                        }
                    }
                } else {
                    Text("1 frame")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Full Screen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground), in: UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20))
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .onAppear { if isPlaying { startLoop() } }
        .onDisappear { loopTask?.cancel() }
    }

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task {
            try? await Task.sleep(for: .seconds(1))
            while !Task.isCancelled {
                let count = frames.count
                guard count > 1 else {
                    // Wait for more frames to arrive
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                for idx in 0..<count {
                    guard !Task.isCancelled else { return }
                    currentIndex = idx
                    let delay: Duration = idx == count - 1 ? .milliseconds(1500) : .milliseconds(800)
                    try? await Task.sleep(for: delay)
                }
            }
        }
    }
}

// MARK: - Forecast Row

private struct ForecastRow: View {
    @Environment(\.appState) private var appState
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
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Issued \(forecast.issuedHoursAgo == 0 ? "< 1h ago" : "\(forecast.issuedHoursAgo)h ago")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(receivedAgoLabel(forecast.receivedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(forecast.periods.prefix(7).enumerated()), id: \.offset) { _, period in
                        ForecastPeriodCell(period: period, receivedAt: forecast.receivedAt, showF: appState.wxAviationUsesF)
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
    let showF: Bool

    private func displayTemp(_ f: Int) -> Int {
        showF ? f : Int(round(Double(f - 32) * 5.0 / 9.0))
    }

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

    private var conditionIconNames: [String] {
        var icons: [String] = []
        // Skip flag if the sky icon already represents the same condition
        if period.hasThunderstorm && period.skyCode != 10 { icons.append("bolt.fill") }
        if period.hasFrost                                { icons.append("snowflake") }
        if period.hasFog && period.skyCode != 5           { icons.append("cloud.fog.fill") }
        return icons
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(dayLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()

            Image(systemName: period.skySystemImage)
                .font(.title3)
                .foregroundStyle(period.skyColor)
                .frame(height: 22)

            // High / Low temperatures (respects global °F/°C toggle)
            if let high = period.highF, let low = period.lowF {
                VStack(spacing: 0) {
                    Text("\(displayTemp(high))°")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(displayTemp(low))°")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if let high = period.highF {
                Text("\(displayTemp(high))°")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            } else if let low = period.lowF {
                Text("\(displayTemp(low))°")
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
                        .font(.caption2)
                    Text("\(period.precipPct)%")
                        .font(.caption2)
                }
                .foregroundStyle(.cyan)
            } else {
                Color.clear.frame(height: 14)
            }

            if period.windDir != 8 && period.windSpeedMph > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "wind")
                        .font(.caption2)
                    Text("\(period.windSpeedMph)")
                        .font(.caption2.weight(.medium))
                    Text(period.windDirName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
            } else {
                Color.clear.frame(height: 13)
            }

        }
        .frame(minWidth: 60)
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Station Group Model

private struct StationGroup: Identifiable {
    let icao: String
    var id: String { icao }
    var obs: MeshWXObservation?
    var taf: MeshWXTAF?
    var linkedForecast: (key: String, forecast: MeshWXForecast)?
    var pendingObs: Bool
    var pendingTAF: Bool
    var pendingForecast: Bool
    var obsUnavailable: Bool
    var tafUnavailable: Bool
    var forecastUnavailable: Bool
    /// True if the local user explicitly requested any product for this station.
    var isRequested: Bool
}

// MARK: - Unified Weather Card Item

/// A single item in the card pager — either a station group or a city observation.
private enum WeatherCardItem: Identifiable {
    case station(StationGroup)
    case city(MeshWXObservation)

    var id: String {
        switch self {
        case .station(let g): return "s:\(g.icao)"
        case .city(let o): return "c:\(o.locationKey)"
        }
    }
}

// MARK: - Station Page Card (Apple Weather-inspired card for pager)

private struct StationPageCard: View {
    @Environment(\.appState) private var appState
    let group: StationGroup
    let isFavorite: Bool

    @AppStorage("wxFavoriteICAOs") private var favoriteICAOsRaw: String = ""

    private var favoriteICAOs: Set<String> {
        Set(favoriteICAOsRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }
    private func toggleFavorite() {
        var favs = favoriteICAOs
        if favs.contains(group.icao) { favs.remove(group.icao) } else { favs.insert(group.icao) }
        favoriteICAOsRaw = favs.sorted().joined(separator: ",")
    }

    private var showF: Bool { appState.wxAviationUsesF }

    private var stationName: String? {
        WXBundleLoader.allStations.first(where: { $0.id == group.icao })?.name
    }

    private var pfmIndex: Int? {
        guard let station = WXBundleLoader.allStations.first(where: { $0.id == group.icao }) else { return nil }
        return WXBundleLoader.nearestPFMPoint(
            to: CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)
        )?.id
    }

    private var hasAnyContent: Bool {
        group.obs != nil || group.taf != nil || group.linkedForecast != nil
        || group.pendingObs || group.pendingTAF || group.pendingForecast
        || group.obsUnavailable || group.tafUnavailable || group.forecastUnavailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // --- Card Header ---
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
                Text(group.icao)
                    .font(.title3.weight(.bold))
                if let name = stationName {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Menu {
                    stationContextMenu
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(.bottom, 10)

            if !hasAnyContent {
                HStack {
                    Spacer()
                    Menu {
                        stationContextMenu
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.largeTitle)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                            Text("Request Data")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .contentShape(Rectangle())
                    }
                    Spacer()
                }
            } else {
                // --- Current Conditions ---
                if group.pendingObs && group.obs == nil {
                    PendingRow(label: "Awaiting current conditions…")
                } else if group.obsUnavailable && group.obs == nil {
                    UnavailableRow(label: "No conditions available")
                }
                if let obs = group.obs {
                    ObservationRow(observation: obs, onRefresh: group.pendingObs ? nil : {
                        Task { _ = await appState.sendMetarRequest(icao: group.icao) }
                    }, showHeader: false)
                }

                // --- Forecast ---
                let hasForecastContent = group.linkedForecast != nil || group.pendingForecast || group.forecastUnavailable
                if (group.obs != nil || group.pendingObs || group.obsUnavailable) && hasForecastContent {
                    Divider().padding(.vertical, 8)
                }
                if group.pendingForecast && group.linkedForecast == nil {
                    PendingRow(label: "Awaiting forecast…")
                } else if group.forecastUnavailable && group.linkedForecast == nil {
                    UnavailableRow(label: "No forecast available")
                }
                if let (_, fc) = group.linkedForecast {
                    InlineForecastRow(forecast: fc, onRefresh: group.pendingForecast ? nil : {
                        if let pfmIdx = fc.pfmPointIndex {
                            Task { _ = await appState.sendWeatherDataRequest(pfmPointIndex: pfmIdx, originICAO: group.icao) }
                        }
                    })
                }

                // Prompt to request missing forecast
                if !hasForecastContent, let pfmIdx = pfmIndex {
                    Button {
                        Task { _ = await appState.sendWeatherDataRequest(pfmPointIndex: pfmIdx, originICAO: group.icao) }
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "sun.max.fill")
                                .font(.title2)
                                .foregroundStyle(.orange)
                            Text("Get Forecast")
                                .font(.subheadline.weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                // --- Aviation (TAF) ---
                let hasTAFContent = group.taf != nil || group.pendingTAF || group.tafUnavailable
                if hasTAFContent {
                    Divider().padding(.vertical, 8)
                    HStack(spacing: 4) {
                        Image(systemName: "airplane")
                            .font(.caption2)
                        Text("Aviation")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                }
                if group.pendingTAF && group.taf == nil {
                    PendingRow(label: "Awaiting TAF…")
                } else if group.tafUnavailable && group.taf == nil {
                    UnavailableRow(label: "No TAF available")
                }
                if let taf = group.taf {
                    TAFRow(taf: taf, onRefresh: group.pendingTAF ? nil : {
                        Task { _ = await appState.sendTAFRequest(icao: group.icao) }
                    })
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            GeometryReader { geo in
                Color.clear.preference(key: CardHeightKey.self, value: geo.size.height)
            }
        )
    }

    @ViewBuilder
    private var stationContextMenu: some View {
        let pfmIdx = pfmIndex
        let icao = group.icao
        let hasObs = group.obs != nil
        let hasForecast = group.linkedForecast != nil
        let hasTAF = group.taf != nil

        let isFav = favoriteICAOs.contains(group.icao)
        Button { toggleFavorite() } label: {
            Label(isFav ? "Remove from Favorites" : "Add to Favorites",
                  systemImage: isFav ? "star.slash" : "star")
        }

        Section("Request Data") {
            Button { Task { _ = await appState.sendMetarRequest(icao: icao) } }
                label: { Label(hasObs ? "Refresh Conditions" : "Current Conditions", systemImage: "thermometer.medium") }
                .disabled(group.pendingObs)
            Button { Task { _ = await appState.sendTAFRequest(icao: icao) } }
                label: { Label(hasTAF ? "Refresh TAF" : "TAF (Aviation)", systemImage: "airplane") }
                .disabled(group.pendingTAF)
            if let pfmIdx {
                Button { Task { _ = await appState.sendWeatherDataRequest(pfmPointIndex: pfmIdx, originICAO: icao) } }
                    label: { Label(hasForecast ? "Refresh Forecast" : "Forecast", systemImage: "sun.max.fill") }
                    .disabled(group.pendingForecast)
                Button { } label: { Label("Hazard Outlook", systemImage: "calendar.badge.exclamationmark") }
                    .disabled(true)
                Button { } label: { Label("Storm Reports", systemImage: "tornado") }
                    .disabled(true)
                Button { } label: { Label("Precipitation Reports", systemImage: "cloud.rain.fill") }
                    .disabled(true)
                Button { } label: { Label("Warnings Near Location", systemImage: "location.circle.fill") }
                    .disabled(true)
            }
        }

        if hasObs || hasForecast || hasTAF {
            Section("Delete") {
                if hasObs {
                    Button(role: .destructive) {
                        appState.weatherCache.removeObservation(key: group.obs!.locationKey)
                    } label: { Label("Delete Observations", systemImage: "trash") }
                }
                if hasForecast, let (fKey, _) = group.linkedForecast {
                    Button(role: .destructive) {
                        appState.weatherCache.removeForecast(key: fKey)
                    } label: { Label("Delete Forecast", systemImage: "trash") }
                }
                if hasTAF {
                    Button(role: .destructive) {
                        appState.weatherCache.removeTAF(icao: icao)
                    } label: { Label("Delete TAF", systemImage: "trash") }
                }
            }
        }
    }
}

// MARK: - Station Card (used in non-pager list rows like Your Requests)

private struct StationCard: View {
    @Environment(\.appState) private var appState
    let group: StationGroup
    var isFavorite: Bool = false

    @AppStorage("wxFavoriteICAOs") private var favoriteICAOsRaw: String = ""

    private var favoriteICAOs: Set<String> {
        Set(favoriteICAOsRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }
    private func toggleFavorite() {
        var favs = favoriteICAOs
        if favs.contains(group.icao) { favs.remove(group.icao) } else { favs.insert(group.icao) }
        favoriteICAOsRaw = favs.sorted().joined(separator: ",")
    }

    private var showF: Bool { appState.wxAviationUsesF }

    private var stationName: String? {
        WXBundleLoader.allStations.first(where: { $0.id == group.icao })?.name
    }

    private var pfmIndex: Int? {
        guard let station = WXBundleLoader.allStations.first(where: { $0.id == group.icao }) else { return nil }
        return WXBundleLoader.nearestPFMPoint(
            to: CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)
        )?.id
    }

    private var hasAnyContent: Bool {
        group.obs != nil || group.taf != nil || group.linkedForecast != nil
        || group.pendingObs || group.pendingTAF || group.pendingForecast
        || group.obsUnavailable || group.tafUnavailable || group.forecastUnavailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // --- Card Header (matches StationPageCard) ---
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
                Text(group.icao)
                    .font(.title3.weight(.bold))
                if let name = stationName {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Menu {
                    stationContextMenu
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(.bottom, 10)

            if !hasAnyContent {
                HStack {
                    Spacer()
                    Menu {
                        stationContextMenu
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.largeTitle)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                            Text("Request Data")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .contentShape(Rectangle())
                    }
                    Spacer()
                }
            } else {
                if group.pendingObs && group.obs == nil {
                    PendingRow(label: "Awaiting current conditions…")
                } else if group.obsUnavailable && group.obs == nil {
                    UnavailableRow(label: "No conditions available")
                }
                if let obs = group.obs {
                    ObservationRow(observation: obs, onRefresh: group.pendingObs ? nil : {
                        Task { _ = await appState.sendMetarRequest(icao: group.icao) }
                    }, showHeader: false)
                }

                let hasForecastContent = group.linkedForecast != nil || group.pendingForecast || group.forecastUnavailable
                if (group.obs != nil || group.pendingObs || group.obsUnavailable) && hasForecastContent {
                    Divider().padding(.vertical, 8)
                }
                if group.pendingForecast && group.linkedForecast == nil {
                    PendingRow(label: "Awaiting forecast…")
                } else if group.forecastUnavailable && group.linkedForecast == nil {
                    UnavailableRow(label: "No forecast available")
                }
                if let (_, fc) = group.linkedForecast {
                    InlineForecastRow(forecast: fc, onRefresh: group.pendingForecast ? nil : {
                        if let pfmIdx = fc.pfmPointIndex {
                            Task { _ = await appState.sendWeatherDataRequest(pfmPointIndex: pfmIdx, originICAO: group.icao) }
                        }
                    })
                }

                let hasTAFContent = group.taf != nil || group.pendingTAF || group.tafUnavailable
                if hasTAFContent {
                    Divider().padding(.vertical, 8)
                    HStack(spacing: 4) {
                        Image(systemName: "airplane")
                            .font(.caption2)
                        Text("Aviation")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                }
                if group.pendingTAF && group.taf == nil {
                    PendingRow(label: "Awaiting TAF…")
                } else if group.tafUnavailable && group.taf == nil {
                    UnavailableRow(label: "No TAF available")
                }
                if let taf = group.taf {
                    TAFRow(taf: taf, onRefresh: group.pendingTAF ? nil : {
                        Task { _ = await appState.sendTAFRequest(icao: group.icao) }
                    })
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var stationContextMenu: some View {
        let pfmIdx = pfmIndex
        let icao = group.icao
        let hasObs = group.obs != nil
        let hasForecast = group.linkedForecast != nil
        let hasTAF = group.taf != nil

        let isFavorite = favoriteICAOs.contains(group.icao)
        Button { toggleFavorite() } label: {
            Label(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                  systemImage: isFavorite ? "star.slash" : "star")
        }

        Section("Request Data") {
            Button { Task { _ = await appState.sendMetarRequest(icao: icao) } }
                label: { Label(hasObs ? "Refresh Conditions" : "Current Conditions", systemImage: "thermometer.medium") }
                .disabled(group.pendingObs)
            Button { Task { _ = await appState.sendTAFRequest(icao: icao) } }
                label: { Label(hasTAF ? "Refresh TAF" : "TAF (Aviation)", systemImage: "airplane") }
                .disabled(group.pendingTAF)
            if let pfmIdx {
                Button { Task { _ = await appState.sendWeatherDataRequest(pfmPointIndex: pfmIdx, originICAO: icao) } }
                    label: { Label(hasForecast ? "Refresh Forecast" : "Forecast", systemImage: "sun.max.fill") }
                    .disabled(group.pendingForecast)
                Button { } label: { Label("Hazard Outlook", systemImage: "calendar.badge.exclamationmark") }
                    .disabled(true)
                Button { } label: { Label("Storm Reports", systemImage: "tornado") }
                    .disabled(true)
                Button { } label: { Label("Precipitation Reports", systemImage: "cloud.rain.fill") }
                    .disabled(true)
                Button { } label: { Label("Warnings Near Location", systemImage: "location.circle.fill") }
                    .disabled(true)
            }
        }

        if hasObs || hasForecast || hasTAF {
            Section("Delete") {
                if hasObs {
                    Button(role: .destructive) {
                        appState.weatherCache.removeObservation(key: group.obs!.locationKey)
                    } label: { Label("Delete Observations", systemImage: "trash") }
                }
                if hasForecast, let (fKey, _) = group.linkedForecast {
                    Button(role: .destructive) {
                        appState.weatherCache.removeForecast(key: fKey)
                    } label: { Label("Delete Forecast", systemImage: "trash") }
                }
                if hasTAF {
                    Button(role: .destructive) {
                        appState.weatherCache.removeTAF(icao: icao)
                    } label: { Label("Delete TAF", systemImage: "trash") }
                }
            }
        }
    }
}

// MARK: - City Observation Card (for zone/PFM-point observations)

private struct CityObservationCard: View {
    @Environment(\.appState) private var appState
    @AppStorage("wxFavoritePlaces") private var favoritePlacesRaw: String = ""
    let observation: MeshWXObservation

    private var isFavorite: Bool {
        guard let idx = observation.placeIndex else { return false }
        return favoritePlacesRaw.split(separator: ",").contains(where: { Int($0) == idx })
    }

    private var cityName: String {
        observation.displayName
    }

    private var pfmIndex: Int? {
        // Direct PFM index from the observation
        if let idx = observation.pfmPointIndex { return idx }
        // For place observations, find the nearest PFM point by coordinates
        if let placeIdx = observation.placeIndex {
            let places = WXBundleLoader.allPlaces
            if placeIdx < places.count {
                let place = places[placeIdx]
                return WXBundleLoader.nearestPFMPointIndex(latitude: place.latitude, longitude: place.longitude)
            }
        }
        // For zone observations, find the matching PFM point
        if let code = observation.zoneCode {
            return WXBundleLoader.allPFMPoints.firstIndex(where: { $0.zone == code })
        }
        return nil
    }

    private var zoneLabel: String? {
        if let idx = pfmIndex {
            let points = WXBundleLoader.allPFMPoints
            if idx < points.count {
                let p = points[idx]
                if !p.zone.isEmpty { return "\(p.wfo) · \(p.zone)" }
            }
        }
        return observation.zoneCode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cityName)
                        .font(.title3.weight(.bold))
                    if let zone = zoneLabel {
                        Text(zone)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    contextMenu
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(.bottom, 10)

            ObservationRow(observation: observation, showHeader: false)

            // Inline forecast (if available or pending)
            if pendingForecast && linkedForecast == nil {
                PendingRow(label: "Awaiting forecast…")
            }
            if let fc = linkedForecast {
                Divider().padding(.vertical, 6)
                InlineForecastRow(forecast: fc, onRefresh: pendingForecast ? nil : {
                    if let placeIdx = observation.placeIndex {
                        Task { _ = await appState.sendForecastRequest(placeIndex: placeIdx) }
                    }
                })
            }

            // Prompt to request missing forecast
            if linkedForecast == nil && !pendingForecast, let placeIdx = observation.placeIndex {
                Button {
                    Task { _ = await appState.sendForecastRequest(placeIndex: placeIdx) }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "sun.max.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        Text("Get Forecast")
                            .font(.subheadline.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            GeometryReader { geo in
                Color.clear.preference(key: CardHeightKey.self, value: geo.size.height)
            }
        )
    }

    private var forecastKey: String? {
        if let idx = observation.placeIndex { return "place:\(idx)" }
        return nil
    }

    private var linkedForecast: MeshWXForecast? {
        guard let fKey = forecastKey else { return nil }
        return appState.weatherCache.forecasts[fKey]
    }

    private var pendingForecast: Bool {
        guard let fKey = forecastKey else { return false }
        return appState.weatherCache.isPending("forecast:\(fKey)")
    }

    @ViewBuilder
    private var contextMenu: some View {
        Section("Request Data") {
            Button {
                if let placeIdx = observation.placeIndex {
                    Task { _ = await appState.sendObservationRequest(placeIndex: placeIdx, zoneCode: zoneLabel) }
                }
            } label: {
                Label("Refresh Conditions", systemImage: "thermometer.medium")
            }
            .disabled(observation.placeIndex == nil)

            if let placeIdx = observation.placeIndex {
                Button {
                    Task { _ = await appState.sendForecastRequest(placeIndex: placeIdx) }
                } label: {
                    Label("Forecast", systemImage: "sun.max.fill")
                }
            }
        }

        if let placeIdx = observation.placeIndex {
            if isFavorite {
                Button {
                    var favs = Set(favoritePlacesRaw.split(separator: ",").compactMap { Int($0) })
                    favs.remove(placeIdx)
                    favoritePlacesRaw = favs.sorted().map(String.init).joined(separator: ",")
                } label: {
                    Label("Remove from Favorites", systemImage: "star.slash")
                }
            } else {
                Button {
                    var favs = Set(favoritePlacesRaw.split(separator: ",").compactMap { Int($0) })
                    favs.insert(placeIdx)
                    favoritePlacesRaw = favs.sorted().map(String.init).joined(separator: ",")
                } label: {
                    Label("Add to Favorites", systemImage: "star")
                }
            }
        }

        Section("Delete") {
            Button(role: .destructive) {
                appState.weatherCache.removeObservation(key: observation.locationKey)
                if let fKey = forecastKey {
                    appState.weatherCache.removeForecast(key: fKey)
                }
            } label: {
                Label("Delete Observation", systemImage: "trash")
            }
        }
    }
}

// MARK: - Inline Forecast Row (used inside station sections — no location name header)

private struct InlineForecastRow: View {
    @Environment(\.appState) private var appState
    let forecast: MeshWXForecast
    var onRefresh: (() -> Void)? = nil

    private var wfoLabel: String {
        guard let idx = forecast.pfmPointIndex else { return "" }
        let points = WXBundleLoader.allPFMPoints
        guard idx < points.count else { return "" }
        let p = points[idx]
        return "\(p.wfo) · \(p.zone)"
    }

    private var canRefresh: Bool {
        onRefresh != nil && Date().timeIntervalSince(forecast.receivedAt) > wxRefreshCooldown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !wfoLabel.isEmpty {
                    Text(wfoLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if canRefresh {
                    Button { onRefresh?() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text("Forecast · Issued \(forecast.issuedHoursAgo == 0 ? "< 1h ago" : "\(forecast.issuedHoursAgo)h ago")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(forecast.periods.prefix(7).enumerated()), id: \.offset) { _, period in
                        ForecastPeriodCell(period: period, receivedAt: forecast.receivedAt, showF: appState.wxAviationUsesF)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Weather Detail Cell (shared by ObservationRow and TAFRow)

private struct WeatherDetailCell: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Observation Row

private struct ObservationRow: View {
    @Environment(\.appState) private var appState
    let observation: MeshWXObservation
    var onRefresh: (() -> Void)? = nil
    var showHeader: Bool = true

    private var showF: Bool { appState.wxAviationUsesF }

    private var canRefresh: Bool {
        onRefresh != nil && Date().timeIntervalSince(observation.receivedAt) > wxRefreshCooldown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                if showHeader {
                    Text(observation.displayName)
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                if canRefresh {
                    Button { onRefresh?() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text(receivedAgoLabel(observation.receivedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Conditions + wind
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: observation.skySystemImage)
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(showF ? "\(observation.tempF)°F" : "\(observation.tempC)°C")
                        .font(.title2.weight(.bold))
                    if observation.feelsLikeDelta != 0 {
                        let fl = showF ? "\(observation.feelsLikeF)°F" : "\(observation.feelsLikeC)°C"
                        Text("Feels like \(fl)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(observation.skyName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Wind (knots — METAR standard)
                VStack(alignment: .trailing, spacing: 3) {
                    if observation.windSpeedKts == 0 && observation.windDir == 8 {
                        Label("Calm", systemImage: "wind")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "wind").font(.caption)
                            Text("\(observation.windSpeedKts) kts")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                        Text(observation.windDirName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if observation.hasGust {
                            Text("G \(observation.windGustKts) kts")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            // Detail grid — 2×2
            Grid(horizontalSpacing: 0, verticalSpacing: 8) {
                GridRow {
                    WeatherDetailCell(icon: "thermometer.snowflake",
                                      label: "Dewpoint",
                                      value: showF ? "\(observation.dewpointF)°F" : "\(observation.dewpointC)°C")
                    WeatherDetailCell(icon: "humidity.fill",
                                      label: "Humidity",
                                      value: "\(observation.relativeHumidityPct)%")
                }
                GridRow {
                    WeatherDetailCell(icon: "eye.fill",
                                      label: "Visibility",
                                      value: "\(observation.visibilityMi) mi")
                    WeatherDetailCell(icon: "gauge.with.needle",
                                      label: "Altimeter",
                                      value: String(format: "%.2f\"", observation.pressureInHg))
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Outlook Row

private struct OutlookRow: View {
    let outlook: MeshWXOutlook

    private func dayLabel(_ offset: UInt8) -> String {
        let cal = Calendar.current
        guard let date = cal.date(byAdding: .day, value: Int(offset) - 1, to: outlook.receivedAt) else {
            return "Day \(offset)"
        }
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        let fmt = DateFormatter(); fmt.dateFormat = "EEE"; return fmt.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Hazard Outlook")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Issued \(outlook.issuedLabel)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ForEach(outlook.days, id: \.dayOffset) { day in
                let activeHazards = day.hazards.filter { $0.riskLevel > 0 }
                if !activeHazards.isEmpty {
                    HStack(spacing: 8) {
                        Text(dayLabel(day.dayOffset))
                            .font(.caption.weight(.medium))
                            .frame(width: 52, alignment: .leading)
                        ForEach(activeHazards, id: \.hazardType) { hazard in
                            HStack(spacing: 3) {
                                Image(systemName: hazard.hazardSystemImage)
                                    .font(.caption2)
                                Text(hazard.riskName)
                                    .font(.caption2.weight(.medium))
                            }
                            .foregroundStyle(hazard.riskColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(hazard.riskColor.opacity(0.12), in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Storm Reports Row

private struct StormReportsRow: View {
    let reports: MeshWXStormReports

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Storm Reports")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(reports.reports.count) report\(reports.reports.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(reports.reports.prefix(6).enumerated()), id: \.offset) { _, report in
                HStack(spacing: 10) {
                    Image(systemName: report.eventSystemImage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(width: 18, alignment: .center)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(report.eventTypeName)
                                .font(.caption.weight(.medium))
                            if let mag = report.magnitudeLabel {
                                Text(mag)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        let place = WXBundleLoader.allPlaces.indices.contains(report.placeID)
                            ? WXBundleLoader.allPlaces[report.placeID].displayName
                            : "Location \(report.placeID)"
                        Text(place)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(report.timeLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if reports.reports.count > 6 {
                Text("+\(reports.reports.count - 6) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Rain Observations Row

private struct RainObsRow: View {
    let obs: MeshWXRainObservations

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(obs.cities.count) location\(obs.cities.count == 1 ? "" : "s") reporting precipitation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(receivedAgoLabel(obs.receivedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(obs.cities.prefix(12).enumerated()), id: \.offset) { _, city in
                        let places = WXBundleLoader.allPlaces
                        let cityName = city.placeID < places.count
                            ? places[city.placeID].name.capitalized
                            : nil
                        VStack(spacing: 2) {
                            Image(systemName: city.rainSystemImage)
                                .font(.caption)
                                .foregroundStyle(city.rainColor)
                            Text(city.rainTypeName)
                                .font(.caption2)
                                .foregroundStyle(city.rainColor)
                                .lineLimit(1)
                            if let name = cityName {
                                Text(name)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            Text("\(city.tempF)°")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 64)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - TAF Row

private struct TAFRow: View {
    @Environment(\.appState) private var appState
    let taf: MeshWXTAF
    var onRefresh: (() -> Void)? = nil

    private var canRefresh: Bool {
        onRefresh != nil && Date().timeIntervalSince(taf.receivedAt) > wxRefreshCooldown
    }

    private var flightCategoryColor: Color {
        switch taf.flightCategory {
        case "VFR":  return .green
        case "MVFR": return .blue
        case "IFR":  return .red
        case "LIFR": return .purple
        default:     return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Text(taf.icao)
                    .font(.subheadline.weight(.semibold).monospaced())
                Text("TAF")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.15), in: Capsule())
                Text(taf.flightCategory)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(flightCategoryColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(flightCategoryColor.opacity(0.15), in: Capsule())
                Spacer()
                if canRefresh {
                    Button { onRefresh?() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text(receivedAgoLabel(taf.receivedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Conditions + wind
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: taf.skySystemImage)
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(taf.skyName)
                        .font(.title3.weight(.semibold))
                    if !taf.weatherPhenomena.isEmpty {
                        Text(taf.weatherPhenomena.joined(separator: " "))
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text("Valid \(taf.validPeriodLabel)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // Wind (knots — aviation standard)
                VStack(alignment: .trailing, spacing: 3) {
                    if taf.windSpeedKts == 0 {
                        Label("Calm", systemImage: "wind")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "wind").font(.caption)
                            Text("\(taf.windSpeedKts) kts")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                        Text("\(taf.windDirName) (\(taf.windDirDegrees)°)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if taf.hasGust {
                            Text("G \(taf.windGustKt) kts")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            // Detail row — visibility + ceiling
            HStack(spacing: 0) {
                WeatherDetailCell(icon: "eye.fill",
                                  label: "Visibility",
                                  value: "\(taf.visibilitySM) SM")
                WeatherDetailCell(icon: "arrow.up.to.line",
                                  label: "Ceiling",
                                  value: taf.ceilingLabel)
                WeatherDetailCell(icon: "clock",
                                  label: "Issued",
                                  value: taf.issuedHoursAgo == 0 ? "Just now" : "\(taf.issuedHoursAgo)h ago")
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Warnings Near Row

private struct WarningsNearRow: View {
    let warningsNear: MeshWXWarningsNear

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(warningsNear.entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(entry.entryColor)
                        .frame(width: 4)
                        .padding(.vertical, 2)

                    Text(entry.displayTitle)
                        .font(.callout.weight(.medium))

                    Spacer()

                    let remaining = entry.expiryDate.timeIntervalSinceNow
                    if remaining > 0 {
                        let hrs = Int(remaining / 3600)
                        let mins = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
                        Text(hrs > 0 ? "\(hrs)h \(mins)m" : "\(mins)m")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(remaining < 1800 ? .orange : .secondary)
                    } else {
                        Text("Expired")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Radar Region Picker

/// Sheet listing all 10 MeshWX regions. Tap a row to request radar data for that region.
private struct RadarRegionPickerView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var requesting: UInt8? = nil
    @State private var sentRegions: Set<UInt8> = []
    @State private var error: String?

    private var sortedRegions: [MeshWXRegion] {
        MeshWXRegion.all.values.sorted { $0.id < $1.id }
    }

    var body: some View {
        NavigationStack {
            List(sortedRegions, id: \.id) { region in
                Button {
                    Task { await request(region) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(region.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            if let frames = appState.weatherCache.radarFrames[region.id], !frames.isEmpty {
                                Text("\(frames.count) frame\(frames.count == 1 ? "" : "s") cached · latest \(timestampLabel(frames.last?.timestamp))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("No data")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        if requesting == region.id {
                            ProgressView().scaleEffect(0.8)
                        } else if sentRegions.contains(region.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .disabled(requesting != nil || appState.connectionState != .ready)
            }
            .navigationTitle("Request Radar Region")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.red.opacity(0.85), in: Capsule())
                        .padding()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onTapGesture { self.error = nil }
                }
            }
            .animation(.default, value: error)
        }
    }

    private func request(_ region: MeshWXRegion) async {
        guard requesting == nil else { return }
        requesting = region.id
        defer { requesting = nil }

        let result = await appState.sendRadarRequest(regionID: region.id)
        switch result {
        case .sent:
            sentRegions.insert(region.id)
        case .notConnected:
            error = "Not connected to a LoRa device."
        case .noDataChannel:
            error = "Weather channel not available. Check your device connection."
        default:
            error = "Request failed. Try again."
        }
    }

    private func timestampLabel(_ unixMinutes: UInt32?) -> String {
        guard let unixMinutes else { return "—" }
        let date = Date(timeIntervalSince1970: Double(unixMinutes) * 60)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: date)
    }
}

// MARK: - Card Height Preference Key

/// Preference key that propagates the maximum card height up to the TabView container.
private struct CardHeightKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Helpers

/// Minimum age before a refresh button is shown for a received product.
/// Set to 0 so the button is always visible; the server enforces its own rate limit.
private let wxRefreshCooldown: TimeInterval = 0

/// Returns a human-readable "X min ago" / "Xh ago" label for a received-at date.
private func receivedAgoLabel(_ date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    if interval < 90    { return "just now" }
    if interval < 3600  { return "\(Int(interval / 60))m ago" }
    if interval < 86400 { return "\(Int(interval / 3600))h ago" }
    return "\(Int(interval / 86400))d ago"
}

// MARK: - Info Sheet

private struct WXInfoSheet: View {
    @Environment(\.appState) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let bound = Bindable(appState)
                    Picker("Request Mode", selection: bound.wxRequestMode) {
                        Text("Channel").tag(AppState.WXRequestMode.channel)
                        Text("Direct Message").tag(AppState.WXRequestMode.dm)
                    }
                    if appState.wxRequestMode == .channel {
                        LabeledContent("Command Channel") {
                            TextField("#channel-name", text: bound.wxCommandChannelName)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    Text("Bot Requests")
                } footer: {
                    switch appState.wxRequestMode {
                    case .channel:
                        Text("Requests are sent as channel messages — better over poor multi-hop links since no ACK is required. The bot must be listening on this channel.")
                    case .dm:
                        Text("Requests are sent as DMs to the bot's pubkey with retry and ACK tracking. The bot's contact name must be configured in Contacts.")
                    }
                }

                Section {
                    infoRow(icon: "satellite", title: "GOES Satellite Reception",
                            body: "The MeshWX bot uses a Software Defined Radio (SDR) to receive the GOES weather satellite signal directly. It decodes the broadcast as EMWIN (Emergency Managers Weather Information Network) files — the same data feed used by NWS offices — with no internet connection required anywhere in the chain.")
                    infoRow(icon: "wave.3.right.circle", title: "Satellite to Mesh to You",
                            body: "GOES continuously broadcasts NWS weather data to anyone with an SDR. The bot decodes it, formats it into compact binary messages, and rebroadcasts over LoRa. Your phone receives it passively on the mesh channel — completely off-grid.")
                } header: {
                    Label("No Internet Required", systemImage: "antenna.radiowaves.left.and.right")
                }

                Section {
                    infoRow(icon: "arrow.up.message", title: "Explicit Requests",
                            body: "Tapping a city or airport in the search results sends a single short DM to the bot. The bot responds once with the requested data. Nothing is requested automatically.")
                    infoRow(icon: "dot.radiowaves.left.and.right", title: "Broadcast Reception",
                            body: "The bot periodically broadcasts weather summaries on the channel for the regions it monitors. The app receives these passively — no transmission from your device is needed.")
                    infoRow(icon: "memorychip", title: "Local Caching",
                            body: "Once received, data is cached in memory for the session. Refreshing a product sends a new request; the app never polls the bot automatically.")
                    infoRow(icon: "clock.arrow.2.circlepath", title: "Refresh Cooldown",
                            body: "The bot enforces its own rate limit. Tapping Refresh on a product that was just received will be silently ignored by the bot, so no extra airtime is wasted.")
                } header: {
                    Label("Minimizing Airtime", systemImage: "waveform.path.ecg")
                }

                Section {
                    infoRow(icon: "thermometer.medium", title: "Observations (METAR)",
                            body: "Current conditions at an airport: temperature, dewpoint, wind, altimeter, clouds, visibility, and flight rules (VFR / MVFR / IFR / LIFR).")
                    infoRow(icon: "sun.max", title: "7-Day Forecast",
                            body: "NWS gridded forecast for the nearest forecast point: daily high/low, wind, precipitation chance, humidity, and a sky condition summary.")
                    infoRow(icon: "airplane", title: "TAF",
                            body: "Terminal Aerodrome Forecast — aviation weather valid for 24–30 hours at instrument-capable airports.")
                    infoRow(icon: "cloud.rain", title: "Radar",
                            body: "64×32 grid of radar intensity data for a regional NWS sector, showing current precipitation coverage.")
                    infoRow(icon: "exclamationmark.triangle", title: "Warnings & Reports",
                            body: "Active NWS warnings, nearby storm reports (tornado, hail, wind, flood), precipitation summaries, and hazard outlooks are all available on request via the context menu on any station card.")
                } header: {
                    Label("What You Can Receive", systemImage: "list.bullet.rectangle")
                }

                Section {
                    infoRow(icon: "magnifyingglass", title: "Finding a Location",
                            body: "Use the search bar to find a city or airport ICAO code. Tap a result to send a request to the bot. You must be connected to your radio and on the meshwx channel.")
                    infoRow(icon: "wrench.and.screwdriver", title: "Bot Setup",
                            body: "Channel mode sends requests on a shared mesh channel — no bot contact name needed. DM mode addresses requests directly to the bot; configure the request mode using the ⓘ button.")
                } header: {
                    Label("Getting Started", systemImage: "questionmark.circle")
                }

                Section {
                    infoRow(icon: "thermometer.medium", title: "Dew",
                            body: "Dewpoint — the temperature at which the air becomes saturated and condensation forms. Closer to air temp = higher humidity.")
                    infoRow(icon: "eye.fill", title: "Vis",
                            body: "Surface visibility in statute miles.")
                    infoRow(icon: "gauge.with.needle", title: "Pres",
                            body: "Altimeter setting in inches of mercury (inHg). Standard sea-level pressure is 29.92\".")
                    infoRow(icon: "humidity.fill", title: "RH",
                            body: "Relative Humidity — how saturated the air is as a percentage of its maximum moisture capacity at the current temperature.")
                    infoRow(icon: "wind", title: "kts",
                            body: "Wind speed in knots (nautical miles per hour). 1 knot ≈ 1.15 mph.")
                } header: {
                    Label("Observation Abbreviations", systemImage: "character.magnify")
                }

                Section {
                    infoRow(icon: "sun.max.fill", title: "Clear",
                            body: "Sky clear or mostly clear. Sun icon shown in yellow.")
                    infoRow(icon: "cloud.sun.fill", title: "Few / Partly Cloudy",
                            body: "Some clouds but still significant sunshine.")
                    infoRow(icon: "cloud.fill", title: "Mostly Cloudy / Overcast",
                            body: "Predominantly cloudy sky.")
                    infoRow(icon: "cloud.fog.fill", title: "Fog / Mist",
                            body: "Low visibility due to fog or mist.")
                    infoRow(icon: "cloud.rain.fill", title: "Rain / Drizzle",
                            body: "Precipitation as rain or light drizzle.")
                    infoRow(icon: "cloud.snow.fill", title: "Snow",
                            body: "Precipitation as snow or mixed wintry precipitation.")
                    infoRow(icon: "cloud.bolt.rain.fill", title: "Thunderstorm",
                            body: "Active or forecast thunderstorm activity.")
                } header: {
                    Label("Sky Condition Icons", systemImage: "cloud.sun.fill")
                }

                Section {
                    infoRow(icon: "star.fill", title: "Favorites",
                            body: "Stations you've starred. Always shown even without data — long press any card to request an update anytime.")
                    infoRow(icon: "arrow.up.message", title: "Your Requests",
                            body: "Non-favorite stations where you explicitly requested data this session via search or the context menu.")
                    infoRow(icon: "dot.radiowaves.left.and.right", title: "Broadcasts",
                            body: "Data received from the bot's scheduled broadcasts or in response to another mesh user's request. No action from you was needed.")
                    infoRow(icon: "exclamationmark.triangle.fill", title: "Active Warnings",
                            body: "NWS weather warnings pushed by the bot. Severity is shown by circle color: green = advisory, yellow = watch, orange = warning, red = extreme.")
                } header: {
                    Label("Section Guide", systemImage: "list.bullet.rectangle")
                }
            }
            .navigationTitle("How Weather Works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func infoRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - NowcastRow

private struct NowcastRow: View {
    let nowcast: MeshWXNowcast

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "clock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Next \(nowcast.validHours) hour\(nowcast.validHours == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                if !nowcast.urgencySystemImages.isEmpty {
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(nowcast.urgencySystemImages, id: \.self) { img in
                            Image(systemName: img)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            if !nowcast.text.isEmpty {
                Text(nowcast.leadText)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - FireWeatherRow

private struct FireWeatherRow: View {
    let fireWeather: MeshWXFireWeather

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Fire Weather", systemImage: "flame.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Text("\(fireWeather.issuedHoursAgo)h ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(fireWeather.periods.indices, id: \.self) { i in
                let period = fireWeather.periods[i]
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(periodLabel(period.periodID))
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(period.maxTempF)°F  RH ≥\(period.minRHPct)%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Label("\(period.transportWindDirName) \(period.transportWindMph) mph", systemImage: "wind")
                            .font(.caption)
                        Label("\(period.mixingHeightFt) ft", systemImage: "arrow.up.to.line")
                            .font(.caption)
                        Text(period.hainesLabel)
                            .font(.caption)
                            .foregroundStyle(period.hainesIndex >= 5 ? .red : (period.hainesIndex >= 4 ? .orange : .secondary))
                    }
                    if period.lightningRisk > 0 {
                        Label(period.lightningLabel, systemImage: "bolt.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func periodLabel(_ id: UInt8) -> String {
        switch id {
        case 0: return "Tonight"
        case 1: return "Today"
        default:
            let day = (id / 2) + (id % 2 == 0 ? 0 : 0)
            return id % 2 == 0 ? "Day \(id/2) Night" : "Day \((id+1)/2)"
        }
    }
}

// MARK: - DailyClimateRow

private struct DailyClimateRow: View {
    let climate: MeshWXDailyClimate
    @Environment(\.appState) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(climate.dayLabel, systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(climate.cities.count) station\(climate.cities.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(climate.cities.indices, id: \.self) { i in
                let city = climate.cities[i]
                Divider()
                HStack {
                    Text("Place \(city.placeID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let hi = city.maxTempF, let lo = city.minTempF {
                        let usF = appState.wxAviationUsesF
                        Text(usF ? "\(hi)°/\(lo)°F" : "\(fToC(hi))°/\(fToC(lo))°C")
                            .font(.caption.monospacedDigit())
                    }
                    if city.hasPrecip || city.hasSnow {
                        HStack(spacing: 4) {
                            if city.hasPrecip {
                                Label(city.precipLabel, systemImage: "cloud.rain")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }
                            if city.hasSnow {
                                Label(city.snowLabel, systemImage: "snowflake")
                                    .font(.caption)
                                    .foregroundStyle(.cyan)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func fToC(_ f: Int8) -> Int { (Int(f) - 32) * 5 / 9 }
}

// MARK: - Preview

#Preview {
    WeatherView()
        .environment(\.appState, AppState())
}
