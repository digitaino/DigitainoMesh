import Foundation
import MC1Services
import MeshWX

/// Facts that depend only on the place, computed once per place value.
struct WeatherPlaceFacts: Sendable {
  var input: WeatherBuildRequest.PlaceInput
  /// The label for a location place.
  var label: String?
  var hasStateCode = false
  var stateCode: String?
  /// Looked up once the outlines were loaded.
  var hasCounty = false
  var county: WeatherAreaName?
  /// The place's forecast zone, from the same lookup: what a place outside the bot's area is
  /// asked about by name (docs/MESHWX_UI.md §11).
  var zoneUGC: String?
  /// The nearest bundled weather station within 80 km, looked up once per place.
  var hasNearbyStation = false
  var nearbyStation: WeatherNearbyStation?
}

/// What the model hands to a build: references to actors, plain values, and the caches from the
/// last build, so the whole build runs off the main actor and the 30-second rebuild is cheap.
struct WeatherBuildRequest: Sendable {
  enum PlaceInput: Sendable, Hashable {
    case none
    case searched(WeatherPlace)
    case location(WeatherLocationSample)
  }

  var weatherService: WeatherService?
  var contactService: ContactService?
  var dataStore: PersistenceStore?
  var radioID: UUID?
  var preferredBotID: UInt16?
  /// The page this build answers for, stamped into the snapshot and the context it produces
  /// (docs/MESHWX_UI.md §13). A build is asked for one page and belongs to that page for good:
  /// the pager can be swiped while it runs, and the result must not land under another name.
  var pageID: String
  var place: PlaceInput
  var isRadioConnected: Bool
  /// The weather transport's own link, when it has one: only the DEBUG bridge to a real bot
  /// does (`WeatherTransportLink`). It stands in for the radio and for the bot's advert.
  var transportLink: WeatherTransportLink?
  var isChannelSyncDone: Bool
  var firmwareSupportsWeather: Bool?
  var firmwareVersion: String
  var now: Date
  var calendar: Calendar

  // Caches: nil is "fetch".
  var contacts: [ContactDTO]?
  var channels: [ChannelDTO]?
  var offlineStates: [UInt16: WeatherBotState]?
  var placeFacts: WeatherPlaceFacts?
  var stationTowns: [UInt16: String]
}

/// One weather radio as the About sheet lists it.
struct WeatherBotRow: Sendable, Hashable, Identifiable {
  var botID: UInt16
  var bot: WeatherBot?
  var lastHeardAt: Date?
  /// Heard live, not drained from your radio's queue: what "heard" means on screen.
  var lastLiveHeardAt: Date?
  /// What the bot's last alert list said about its home Weather Service office; nil before one.
  var feed: MeshWXFeedHealth?

  var id: UInt16 { botID }
}

/// A county or zone by code and display name.
struct WeatherAreaName: Sendable, Hashable {
  var ugc: String
  var name: String
}

/// Facts the screen needs beyond the snapshot, computed in the same off-main pass because each
/// needs the tables, the geometry or the raw per-bot state.
struct WeatherScreenContext: Sendable {
  /// The page these facts were computed for. The same key the snapshot carries: the two are one
  /// build and are never read apart.
  var page = WeatherPageKey()
  var bots: [WeatherBot] = []
  var botRows: [WeatherBotRow] = []
  var channelSlot: UInt8?
  var session = WeatherSessionInfo()
  /// The place's state, for storm reports and rainfall ("TX").
  var placeStateCode: String?
  /// The office of the place's forecast point, for the forecast discussion ("EWX").
  var placeOffice: String?
  /// The county the place is in, once outlines have loaded.
  var placeCounty: WeatherAreaName?
  /// The forecast zone it is in ("TXZ192"): zones carry the watches and advisories a county
  /// request never finds (spec §8.2).
  var placeZoneUGC: String?
  /// The source bot's state: its missed-messages and missing-warnings requests are chosen from it
  /// alone (`WeatherAlertRequests`).
  var sourceState: WeatherBotState?
  /// Every bot's radar tiles in one list (spec revision 11, §7D). Not the source bot's alone: the
  /// lattice is shared, so a tile of this square from the radio next door is a picture of the same
  /// storm, and the radar screen's width control has to see all of them to say what is held for a
  /// width. The snapshot's own card is built from exactly this list.
  var radarTiles: [WeatherStoredRadarTile] = []
  /// A held warning is placed by areas whose outlines have not loaded.
  var needsGeometry = false
  var isGeometryLoaded = false
  /// The town named for the nearest station when none is in reach ("Temple").
  var nearestStationTown: String?
  /// The nearest bundled station to the place, which can be asked for by code (`>o <ICAO>`).
  /// What the page names, and what Update spends its readings packet on, whenever the reading
  /// held is no good for the place (`WeatherConditions`).
  var nearbyStation: WeatherNearbyStation?
  /// What the page leads with: a reading good enough to be the weather here, or the ask.
  var conditions: WeatherConditions = .noPlace
  /// The alert covering the place that the banner names, if any.
  var banner: WeatherWarningBanner?
  /// The radio row at the foot of the page, and whether it is orange.
  var radioRow = WeatherRadioRow()
  /// When NWS issued each held warning (spec §3, revision 5), where the wire carried it. Read
  /// from the stored copy rather than recomputed from the wire's expiry-relative field: a digest
  /// can extend a warning's expiry, and the instant it was issued never moves.
  var warningIssuedAt: [MeshWXWarningIdentity: Date] = [:]
  /// Where each held warning came from (spec §2.2, revision 7), read from the stored copy the way
  /// ``warningIssuedAt`` is: the wire carries it on the header, not in the warning, so an alert's
  /// detail can only get at it through the state it was stored in. Absent means the radio did not
  /// say, and the screen then says nothing.
  var warningSource: [MeshWXWarningIdentity: MeshWXDataSource] = [:]
}

/// One page's build: the snapshot and the facts that came with it, which are only ever read
/// together and only ever for that page (docs/MESHWX_UI.md §13).
struct WeatherPageBuild: Sendable {
  var snapshot: WeatherScreenSnapshot
  var context: WeatherScreenContext

  var pageID: String { snapshot.page.pageID }
}

struct WeatherBuildResult: Sendable {
  var page: WeatherPageBuild
  var contacts: [ContactDTO]
  var channels: [ChannelDTO]
  var offlineStates: [UInt16: WeatherBotState]?
  var placeFacts: WeatherPlaceFacts
  var stationTowns: [UInt16: String]
}

enum WeatherScreenBuilder {
  static let labelReachKilometres = 25.0

  static func build(_ request: WeatherBuildRequest) async -> WeatherBuildResult {
    let tables = MeshWXTables.shared
    let geometry = MeshWXGeometry.shared
    let now = request.now

    var states: [UInt16: WeatherBotState] = [:]
    var session = WeatherSessionInfo()
    var offlineStates: [UInt16: WeatherBotState]?
    if let service = request.weatherService {
      states = await service.allStates()
      session = await service.sessionInfo()
    } else if let cached = request.offlineStates {
      states = cached
      offlineStates = cached
    } else {
      states = (try? await FileWeatherStateStore.default().load()) ?? [:]
      offlineStates = states
    }

    var contacts = request.contacts ?? []
    var channels = request.channels ?? []
    if let radioID = request.radioID {
      if request.contacts == nil {
        if let contactService = request.contactService {
          contacts = (try? await contactService.getContacts(radioID: radioID)) ?? []
        } else if let store = request.dataStore {
          contacts = (try? await store.fetchContacts(radioID: radioID)) ?? []
        }
      }
      if request.channels == nil, let store = request.dataStore {
        channels = (try? await store.fetchChannels(radioID: radioID)) ?? []
      }
    }

    var facts = request.placeFacts.flatMap { $0.input == request.place ? $0 : nil }
      ?? WeatherPlaceFacts(input: request.place)
    let place = resolvePlace(request.place, facts: &facts, states: states, tables: tables, now: now)
    var bots = WeatherBot.bots(
      from: contacts,
      near: place.map { (latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) })
    // The bridge's own bot, listed as announced beside the advertised ones so the About sheet
    // and every "from" line name it. DEBUG only: nothing but `RemoteBotWeatherTransport`
    // reports a link. The snapshot makes the same addition, so either path is complete.
    if let link = request.transportLink { bots = link.announcing(bots) }
    let channelSlot = WeatherChannel.existingSlot(in: channels)

    let inputs = WeatherScreenSnapshot.Inputs(
      states: states,
      bots: bots,
      preferredBotID: request.preferredBotID,
      place: place,
      pageID: request.pageID,
      isRadioConnected: request.isRadioConnected,
      transportLink: request.transportLink,
      firmwareSupportsWeather: request.firmwareSupportsWeather,
      firmwareVersion: request.firmwareVersion,
      // Before the channel sync the table is empty: no claim that #meshwx is missing.
      hasWeatherChannel: channelSlot != nil || !request.isChannelSyncDone,
      session: session,
      now: now,
      calendar: request.calendar)
    let snapshot = WeatherScreenSnapshot.make(inputs, geometry: geometry, tables: tables)

    var context = WeatherScreenContext()
    context.page = snapshot.page
    context.bots = bots
    context.channelSlot = channelSlot
    context.session = session
    context.isGeometryLoaded = geometry.isLoaded
    context.botRows = snapshot.knownBotIDs.map { botID in
      let digest = states[botID]?.digest
      return WeatherBotRow(
        botID: botID,
        bot: bots.first { $0.botID == botID },
        lastHeardAt: states[botID]?.lastHeardAt,
        lastLiveHeardAt: states[botID]?.lastLiveHeardAt,
        feed: digest?.feed)
    }

    switch snapshot.forecast {
    // Revision 10: a card can hold a forecast the bot chose the point for, and an empty card can
    // have no bundled point in reach. Either way there is no office to read off a point that is
    // not there, and the office falls back to the place's own lookup below.
    case let .forecast(summary): context.placeOffice = summary.point?.office
    case let .missing(point, _): context.placeOffice = point?.office
    case .noPlace: context.placeOffice = nil
    }
    if let place {
      if !facts.hasStateCode {
        facts.stateCode = stateCode(place: place, readings: snapshot.readings, tables: tables)
        facts.hasStateCode = true
      }
      if !facts.hasCounty, geometry.isLoaded {
        let codes = geometry.areaCodes(containing: place.coordinate)
        let county = codes.first { $0.count == 6 && $0.dropFirst(2).first == "C" }
        if let county, let name = tables.county(county)?.name {
          facts.county = WeatherAreaName(ugc: county, name: L10n.Weather.Weather.Area.county(name))
        }
        facts.zoneUGC = Self.placeZone(from: codes, stateCode: facts.stateCode, county: county)
        facts.hasCounty = true
      }
      context.placeStateCode = facts.stateCode
      context.placeCounty = facts.county
      context.placeZoneUGC = facts.zoneUGC
    }

    context.sourceState = snapshot.source.flatMap { states[$0.botID] }
    context.radarTiles = WeatherRadarCard.tiles(in: states)

    if !geometry.isLoaded {
      context.needsGeometry = Self.needsGeometry(hasPlace: place != nil, states: states)
    }
    var stationTowns = request.stationTowns
    if case let .noneNearby(nearest) = snapshot.primaryStation {
      if let cached = stationTowns[nearest.index] {
        context.nearestStationTown = cached
      } else {
        let town = town(for: nearest.station, tables: tables)
        stationTowns[nearest.index] = town
        context.nearestStationTown = town
      }
    }

    // The nearest bundled station is wanted for every place now, not only for one with nothing in
    // reach: a reading from further than `goodReadingKilometres` is not the weather here either,
    // and the page names the station the next packet would go to. Looked up once per place.
    if let place {
      if !facts.hasNearbyStation {
        facts.nearbyStation = tables.nearestStation(
          toLat: place.coordinate.latitude, lon: place.coordinate.longitude,
          within: WeatherPrimaryStation.maxDistanceKilometres
        ).map { station in
          WeatherNearbyStation(
            icao: station.icao,
            name: WeatherNames.stationName(station.name),
            kilometres: MeshWXGeo.distanceKilometres(
              fromLat: place.coordinate.latitude, lon: place.coordinate.longitude,
              toLat: station.lat, lon: station.lon))
        }
        facts.hasNearbyStation = true
      }
      context.nearbyStation = facts.nearbyStation
    }

    // The issue time of every warning any bot holds, newest copy wins: an alert's detail says
    // "issued 1:29 PM" rather than when this phone happened to hear it (spec §3, revision 5).
    for state in states.values {
      for stored in state.warnings.values {
        // Whichever bot stated a source wins; one that stated none never clears it (spec §2.2,
        // revision 7), the same way an issue time is only ever filled in, never erased.
        if stored.source != .unstated { context.warningSource[stored.identity] = stored.source }
        guard let issuedAt = stored.issuedAt else { continue }
        context.warningIssuedAt[stored.identity] = issuedAt
      }
      for pending in state.pendingUpgrades.values {
        guard let issuedAt = pending.warning.issuedMinutes.map(Date.init(unixMinutes:)) else { continue }
        context.warningIssuedAt[pending.warning.identity] = issuedAt
      }
    }

    context.conditions = WeatherConditions.make(
      primary: snapshot.primaryStation, nearbyStation: context.nearbyStation)
    context.banner = WeatherWarningBanner.make(snapshot.alerts)
    context.radioRow = WeatherRadioRow.make(
      source: snapshot.source, state: context.sourceState, now: now)

    return WeatherBuildResult(
      page: WeatherPageBuild(snapshot: snapshot, context: context),
      contacts: contacts, channels: channels,
      offlineStates: offlineStates, placeFacts: facts, stationTowns: stationTowns)
  }

  // MARK: - Place

  /// A searched place as it is; a phone fix labelled by the nearest town of 1,000 people within
  /// 25 km, else the town of the nearest station within 25 km, else "this location". The label is
  /// found once per fix; the kind and radius follow the clock on every build.
  static func resolvePlace(
    _ input: WeatherBuildRequest.PlaceInput,
    facts: inout WeatherPlaceFacts,
    states: [UInt16: WeatherBotState],
    tables: MeshWXTables,
    now: Date
  ) -> WeatherPlace? {
    switch input {
    case .none:
      return nil
    case let .searched(place):
      return place
    case let .location(sample):
      let label = facts.label
        ?? WeatherNames.placeLabel(near: sample.coordinate, tables: tables)
        ?? nearestStationLabel(to: sample.coordinate, states: states, tables: tables)
        ?? L10n.Weather.Weather.Place.thisLocation
      facts.label = label
      return WeatherPlace.location(sample, label: label, now: now)
    }
  }

  static func nearestStationLabel(
    to coordinate: MeshWXCoordinate,
    states: [UInt16: WeatherBotState],
    tables: MeshWXTables
  ) -> String? {
    let indexes = Set(states.values.flatMap(\.observations.keys))
    let nearest = indexes
      .compactMap(tables.station(at:))
      .map { station in
        (station, MeshWXGeo.distanceKilometres(
          fromLat: coordinate.latitude, lon: coordinate.longitude, toLat: station.lat, lon: station.lon))
      }
      .filter { $0.1 <= labelReachKilometres }
      .min { $0.1 < $1.1 }
    guard let station = nearest?.0 else { return nil }
    if let town = stationTown(station, tables: tables) {
      return WeatherNames.placeLabel(name: town.name, state: town.state)
    }
    return "\(WeatherNames.stationName(station.name)), \(station.state)"
  }

  /// "Temple" for KTPL: the town an airport is known by, or the station's own name.
  static func town(for station: MeshWXStation, tables: MeshWXTables) -> String {
    stationTown(station, tables: tables).map { WeatherNames.placeName($0.name) }
      ?? WeatherNames.stationName(station.name)
  }

  /// A regional airport sits outside the town it serves, often closer to a village's census
  /// centre: KTPL is nearer Morgans Point Resort than Temple. A sizeable town within 15 km wins.
  static func stationTown(_ station: MeshWXStation, tables: MeshWXTables) -> MeshWXPlace? {
    tables.nearestPlace(toLat: station.lat, lon: station.lon, within: 15, minimumPopulation: 20_000)
      ?? tables.nearestPlace(toLat: station.lat, lon: station.lon, within: 15)
  }

  static func stateCode(
    place: WeatherPlace,
    readings: [WeatherStationReading],
    tables: MeshWXTables
  ) -> String? {
    let coordinate = place.coordinate
    if let town = tables.nearestPlace(toLat: coordinate.latitude, lon: coordinate.longitude, within: 40) {
      return town.state
    }
    if let point = tables.nearestPoint(toLat: coordinate.latitude, lon: coordinate.longitude),
       let state = WeatherNames.pointState(point.name) {
      return state
    }
    return readings.first?.station.state
  }

  /// The place's own forecast zone: the land zone of its own state, not the water beside it.
  ///
  /// A coastal place lies in a marine zone as well as its land one — San Juan is in PRZ001 and
  /// PRZ016 and in Atlantic zone AMZ712 — and the outlines answer in no particular order, so
  /// taking the first zone found could ask a radio for warnings on the sea while the heat advisory
  /// sat on the land zone. The place's state decides; its county names that state when nothing
  /// else does (docs/MESHWX_UI.md §3.1 U-27).
  static func placeZone(from codes: [String], stateCode: String?, county: String?) -> String? {
    let zones = codes.filter { $0.count == 6 && $0.dropFirst(2).first == "Z" }.sorted()
    let state = stateCode ?? county.map { String($0.prefix(2)) }
    guard let state else { return zones.first }
    return zones.first { $0.hasPrefix(state.uppercased()) } ?? zones.first
  }

  /// Whether the outlines are worth loading for this page.
  ///
  /// **A place needs them as much as a warning does.** They used to load only for a held warning
  /// with no polygon of its own, which left a place outside the radio's area unable to ask for its
  /// alerts at all: the page learns it is outside, and learns the zone and county to ask by, from
  /// the outlines — so with none loaded it never asked, and never received the warning that would
  /// have loaded them. San Juan sat under "no alerts" while the same radio answered `warn pr` with
  /// a heat advisory (docs/MESHWX_UI.md §3.1 U-27). The load is off the main actor and both files
  /// together take about half a second.
  static func needsGeometry(hasPlace: Bool, states: [UInt16: WeatherBotState]) -> Bool {
    if hasPlace { return true }
    return states.values.contains { state in
      state.warnings.values.contains { needsOutline($0.warning) }
        || state.pendingUpgrades.values.contains { needsOutline($0.warning) }
    }
  }

  static func needsOutline(_ warning: MeshWXWarning) -> Bool {
    (warning.polygon?.count ?? 0) < 3 && !(warning.areas ?? []).isEmpty
  }
}
