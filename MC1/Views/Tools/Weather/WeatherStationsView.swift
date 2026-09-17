import MC1Services
import MeshWX
import SwiftUI

/// The airport stations whose readings the phone holds (docs/MESHWX_UI.md §12): the station the
/// Now card is showing first, then nearest to the place, in two sections named for where the
/// reading came from.
struct WeatherStationsView: View {
  @Environment(\.appTheme) private var theme
  @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28

  /// The page this list was opened from: its order, its distances and the radio it names are
  /// that place's.
  let screen: WeatherPageScreen

  var body: some View {
    List {
      let snapshot = screen.snapshot
      // Where the reading came from, which is all this phone knows: the bot's scheduled report,
      // or a single-station answer broadcast on the channel. Who asked for that answer is never
      // recorded, so it is never claimed — the owner's own TJSJ and KNYC requests were filed
      // under other people's. The snapshot's order already leads with the Now card's station.
      let scheduled = snapshot.readings.filter(\.isInFootprint)
      let answers = snapshot.readings.filter { !$0.isInFootprint }

      Section {
        Text(L10n.Weather.Weather.Stations.intro(WeatherFormatting.sentenceStart(screen.sourceName)))
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .themedRowBackground(theme)

      if !scheduled.isEmpty {
        Section {
          WeatherCardLabel(title: L10n.Weather.Weather.Stations.scheduled, systemImage: "wind")
          ForEach(scheduled) { reading in
            row(reading)
          }
        }
        .themedRowBackground(theme)
      }
      if !answers.isEmpty {
        Section {
          WeatherCardLabel(title: L10n.Weather.Weather.Stations.answers, systemImage: "wind")
          ForEach(answers) { reading in
            row(reading)
          }
        }
        .themedRowBackground(theme)
      }
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
    .navigationTitle(L10n.Weather.Weather.Stations.title)
    .navigationBarTitleDisplayMode(.inline)
    .weatherPendingBar(model: screen.model, requestsOnScreen: [])
    .weatherToolChrome()
  }

  private func row(_ reading: WeatherStationReading) -> some View {
    let observation = reading.stored.observation
    let isNight = WeatherFormatting.isNight(reading.stored.observedAt, calendar: .autoupdatingCurrent)
    var meta: [String] = []
    if let kilometres = reading.distanceKilometres {
      meta.append(WeatherFormatting.distance(kilometres, direction: reading.direction))
    }
    meta.append(reading.isStale
      ? WeatherFormatting.age(reading.stored.observedAt, now: screen.now)
      : L10n.Weather.Weather.Stations.asOf(WeatherFormatting.clockTime(
        reading.stored.observedAt, now: screen.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)))
    // A reading that came from another radio says so: the intro names the one this page asks.
    if reading.botID != screen.snapshot.source?.botID {
      meta.append(L10n.Weather.Weather.Stations.fromBot(screen.model.botName(reading.botID)))
    }

    return NavigationLink {
      WeatherStationDetailView(screen: screen, index: reading.index)
    } label: {
      HStack(spacing: 12) {
        // An unknown sky keeps the column but shows nothing, rather than a made-up condition.
        let symbol = MeshWXPresentation.observationSymbolName(for: observation.sky, isNight: isNight)
        Image(systemName: symbol ?? "cloud")
          .symbolRenderingMode(.multicolor)
          .opacity(symbol == nil ? 0 : 1)
          .frame(width: iconWidth)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(WeatherNames.stationName(reading.station.name))
            .font(.headline)
          Text(meta.joined(separator: " · "))
            .font(.footnote)
            .foregroundStyle(reading.isStale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        Spacer(minLength: 8)
        if let tempF = observation.tempF {
          Text(WeatherFormatting.temperature(fahrenheit: Int(tempF)))
            .font(.title3)
            .monospacedDigit()
        }
      }
      .accessibilityElement(children: .combine)
    }
  }
}

/// One station's reading in full, why it is as old as it is, and its coded airport reports on
/// request (docs/MESHWX_UI.md §12).
///
/// Reached from the Now card's list and straight from a Places search by airport code, so it is
/// built from the station rather than from a reading: a station nothing has ever arrived for has
/// a screen too, with the one Update on it.
struct WeatherStationDetailView: View {
  @Environment(\.appTheme) private var theme

  /// The page this station was opened from: the distance and the "from Austin" line are from
  /// that place, whatever the pager has since been swiped to.
  let screen: WeatherPageScreen
  let index: UInt16

  private var model: WeatherToolModel { screen.model }

  private var station: MeshWXStation? { MeshWXTables.shared.station(at: index) }

  private var reading: WeatherStationReading? {
    screen.snapshot.readings.first { $0.index == index }
  }

  /// From the place to the station, whether or not a reading is held: the station's true
  /// distance, never a capped one.
  private var placement: (kilometres: Double, direction: MeshWXCompass)? {
    guard let station, let place = screen.place else { return nil }
    let coordinate = MeshWXCoordinate(latitude: station.lat, longitude: station.lon)
    return (
      MeshWXGeo.distanceKilometres(
        fromLat: place.coordinate.latitude, lon: place.coordinate.longitude,
        toLat: station.lat, lon: station.lon),
      WeatherFormatting.direction(from: place.coordinate, to: coordinate))
  }

  var body: some View {
    let plan = model.updatePlan(forStation: index, in: screen.snapshot)
    List {
      if let station {
        summary(station)
        Section {
          WeatherUpdateControl(screen: screen, plan: plan, showsCaption: true)
        }
        .themedRowBackground(theme)
        if let reading {
          values(reading)
        }
        airportReports(station)
      }
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
    .navigationTitle(station.map { WeatherNames.stationName($0.name) } ?? L10n.Weather.Weather.Stations.title)
    .navigationBarTitleDisplayMode(.inline)
    .weatherPendingBar(model: model, requestsOnScreen: requestsOnScreen(plan))
    .weatherToolChrome()
  }

  private func requestsOnScreen(_ plan: WeatherUpdatePlan) -> Set<WeatherRequest> {
    var requests = Set(plan.requests).union(screen.updateRequests)
    if let icao = station?.icao {
      requests.formUnion([.metar(station: icao), .taf(station: icao)])
    }
    return requests
  }

  private func summary(_ station: MeshWXStation) -> some View {
    Section {
      VStack(alignment: .leading, spacing: 4) {
        Text(WeatherNames.stationName(station.name))
          .font(.headline)
        Text("\(station.icao) · \(station.state)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        // How far it is **from the page this screen was opened on**, named — the one distance
        // line on the screen (docs/MESHWX_UI.md §3.1 U-8). The station's name is the headline
        // above and the distance was in the source line too, so the same two facts were printed
        // three times between them.
        if let placement, let placeName = screen.placeName {
          Text(L10n.Weather.Weather.Stations.fromPlace(
            WeatherFormatting.distance(placement.kilometres, direction: placement.direction), placeName))
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
        if let reading {
          // Which message this reading arrived in, which nothing else on the screen says.
          Text(WeatherCopy.stationReport(
            botName: model.botName(reading.botID),
            reportedAt: reading.stored.observedAt,
            now: screen.now,
            calendar: .autoupdatingCurrent,
            locale: .autoupdatingCurrent))
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
        if let reading {
          if reading.isStale {
            Text(WeatherFormatting.age(reading.stored.observedAt, now: screen.now))
              .font(.footnote)
              .foregroundStyle(.orange)
          }
          // Why it is as old as it is: the bot's hourly report does not carry this station, so
          // nothing refreshes it until somebody asks for it by name.
          if !reading.isInLatestBatch {
            Text(L10n.Weather.Weather.Station.notInBatch)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        } else {
          Text(L10n.Weather.Weather.Station.nothingHeld)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .combine)
    }
    .themedRowBackground(theme)
  }

  private func values(_ reading: WeatherStationReading) -> some View {
    let observation = reading.stored.observation
    return Section {
      if let tempF = observation.tempF {
        LabeledContent(L10n.Weather.Weather.Station.temperature, value: WeatherFormatting.temperature(fahrenheit: Int(tempF)))
      }
      if observation.feelsDeltaF != 0, let feelsLike = observation.feelsLikeF {
        LabeledContent(L10n.Weather.Weather.Station.feelsLike, value: WeatherFormatting.temperature(fahrenheit: feelsLike))
      }
      if let condition = WeatherFormatting.condition(observation.sky) {
        LabeledContent(L10n.Weather.Weather.Station.sky, value: condition)
      }
      if let wind = WeatherFormatting.wind(MeshWXWindReading(observation: observation)) {
        LabeledContent(L10n.Weather.Weather.Station.wind, value: wind)
      }
      if let humidity = observation.humidityPercent {
        LabeledContent(L10n.Weather.Weather.Station.humidity, value: L10n.Weather.Weather.Station.percent(Int(humidity)))
      }
      if let dewpointF = observation.dewpointF {
        LabeledContent(L10n.Weather.Weather.Station.dewPoint, value: WeatherFormatting.temperature(fahrenheit: Int(dewpointF)))
      }
      if let pressure = observation.pressureInHg {
        LabeledContent(
          L10n.Weather.Weather.Station.pressure,
          value: L10n.Weather.Weather.Station.inchesOfMercury(WeatherFormatting.pressure(inchesOfMercury: pressure)))
      }
      if let visibility = observation.visibilityMiles {
        LabeledContent(L10n.Weather.Weather.Station.visibility, value: WeatherFormatting.visibility(miles: visibility))
      }
    } footer: {
      // When the report was taken, on the bot's clock (§12). The list row carries it too.
      Text(L10n.Weather.Weather.Stations.asOf(WeatherFormatting.clockTime(
        reading.stored.observedAt, now: screen.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)))
    }
    .themedRowBackground(theme)
  }

  /// METAR and TAF come back as coded text and leave the reading untouched, so they keep their
  /// own buttons: they are not what Update plans for (§8, §11).
  private func airportReports(_ station: MeshWXStation) -> some View {
    let icao = station.icao
    // The Update control above already carries the reason nothing can be asked, so these two say
    // it no further: they stay as the disabled buttons they are (docs/MESHWX_UI.md §3.1 U-24).
    return Section {
      WeatherCardLabel(title: L10n.Weather.Weather.Station.airportReports)
      WeatherAskButton(
        screen: screen, title: L10n.Weather.Weather.Request.askMetar, request: .metar(station: icao),
        showsBlockReason: false)
      ownText(.metar(station: icao))
      WeatherAskButton(
        screen: screen, title: L10n.Weather.Weather.Request.askTaf, request: .taf(station: icao),
        showsBlockReason: false)
      ownText(.taf(station: icao))
    }
    .themedRowBackground(theme)
  }

  @ViewBuilder
  private func ownText(_ request: WeatherRequest) -> some View {
    if let item = screen.snapshot.texts.first(where: { $0.assembly.request == request }) {
      VStack(alignment: .leading, spacing: 4) {
        Text(WeatherReportText.body(item.assembly))
          .font(.system(.footnote, design: .monospaced))
          .textSelection(.enabled)
        Text(L10n.Weather.Weather.Reports.received(WeatherFormatting.clockTime(
          item.assembly.lastReceivedAt, now: screen.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)))
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }
}
