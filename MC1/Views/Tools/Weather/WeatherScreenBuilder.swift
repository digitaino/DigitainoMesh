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
  /// The nearest bundled weather station within 80 km, looked up once per place.
  var hasNearbyStation = false
  var nearbyStation: WeatherNearbyStation?
}

/// A weather station near the place that the phone holds no reading from ("Luis Munoz Marin
/// International Airport, 11 km"): the one station worth asking for by its code.
struct WeatherNearbyStation: Sendable, Hashable {
  var icao: String
  var name: String
  var kilometres: Double
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
  var place: PlaceInput
  var isRadioConnected: Bool
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
  /// Minutes since the bot last heard from the Weather Service, from its last alert list.
  var feedMinutes: Int?
  var isFeedStale: Bool

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
  /// The source bot's state: its missed-messages and missing-warnings requests are chosen from it
  /// alone (`WeatherAlertRequests`).
  var sourceState: WeatherBotState?
  /// A held warning is placed by areas whose outlines have not loaded.
  var needsGeometry = false
  var isGeometryLoaded = false
  /// The town named for the nearest station when none is in reach ("Temple").
  var nearestStationTown: String?
  /// With no held reading in reach of the place: the nearest bundled station, which can be asked
  /// for (`>o <ICAO>`).
  var nearbyStation: WeatherNearbyStation?
}

struct WeatherBuildResult: Sendable {
  var snapshot: WeatherScreenSnapshot
  var context: WeatherScreenContext
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
    let bots = WeatherBot.bots(
      from: contacts,
      near: place.map { (latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) })
    let channelSlot = WeatherChannel.existingSlot(in: channels)

    let inputs = WeatherScreenSnapshot.Inputs(
      states: states,
      bots: bots,
      preferredBotID: request.preferredBotID,
      place: place,
      isRadioConnected: request.isRadioConnected,
      firmwareSupportsWeather: request.firmwareSupportsWeather,
      firmwareVersion: request.firmwareVersion,
      // Before the channel sync the table is empty: no claim that #meshwx is missing.
      hasWeatherChannel: channelSlot != nil || !request.isChannelSyncDone,
      session: session,
      now: now,
      calendar: request.calendar)
    let snapshot = WeatherScreenSnapshot.make(inputs, geometry: geometry, tables: tables)

    var context = WeatherScreenContext()
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
        feedMinutes: digest.map { MeshWXPresentation.feedHealthMinutes($0.digest.feedHealth) },
        isFeedStale: digest?.isFeedStale ?? false)
    }

    switch snapshot.forecast {
    case let .forecast(summary): context.placeOffice = summary.point.office
    case let .missing(point, _): context.placeOffice = point.office
    // Too far for its forecast, but offices cover wide areas: still the office to ask.
    case let .noPointNearby(nearest, _): context.placeOffice = nearest?.office
    case .noPlace: context.placeOffice = nil
    }
    if let place {
      if !facts.hasStateCode {
        facts.stateCode = stateCode(place: place, readings: snapshot.readings, tables: tables)
        facts.hasStateCode = true
      }
      if !facts.hasCounty, geometry.isLoaded {
        let county = geometry.areaCodes(containing: place.coordinate).first { $0.count == 6 && $0.dropFirst(2).first == "C" }
        if let county, let name = tables.county(county)?.name {
          facts.county = WeatherAreaName(ugc: county, name: L10n.Weather.Weather.Area.county(name))
        }
        facts.hasCounty = true
      }
      context.placeStateCode = facts.stateCode
      context.placeCounty = facts.county
    }

    context.sourceState = snapshot.source.flatMap { states[$0.botID] }

    if !geometry.isLoaded {
      context.needsGeometry = states.values.contains { state in
        state.warnings.values.contains { needsOutline($0.warning) }
          || state.pendingUpgrades.values.contains { needsOutline($0.warning) }
      }
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

    if case .noneNearby = snapshot.primaryStation, let place {
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

    return WeatherBuildResult(
      snapshot: snapshot, context: context, contacts: contacts, channels: channels,
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
    stationTown(station, tables: tables).map { WeatherNames.titleCased($0.name) }
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
       let state = WeatherFormatting.pointState(point.name) {
      return state
    }
    return readings.first?.station.state
  }

  static func needsOutline(_ warning: MeshWXWarning) -> Bool {
    (warning.polygon?.count ?? 0) < 3 && !(warning.areas ?? []).isEmpty
  }
}
