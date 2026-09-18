import MC1Services
import MeshWX
import SwiftUI

/// The top of a place's page (docs/MESHWX_UI.md §8): the weather here, set the way a weather app
/// sets it — centred, on the canvas, not in a card.
///
///     MY LOCATION                         ← the first page only
///        86°
///     ☁︎ Cloudy
///     High 92° · Low 71°
///     Feels like 91° · Wind SSE 12 · Humidity 59%
///     Camp Mabry · 6 km · as of 8:24 PM ›  ← opens the station
///     Everything is current · WX-AUS 4:25 PM  ← what Update and the pull would ask for (§11.1)
///
/// A temperature here is a claim about the weather *here*, so it is only shown bare for a reading
/// good enough to make it (`WeatherConditions`). A fresh one from 25 to 40 km off is shown under
/// the station it came from, named above the number — "Nearest report: San Marcos, 26 km away" —
/// and the line at the foot then says only when (§3.1 U-2a). Otherwise the block is the sentence that says
/// what to do about it, set as the page's statement rather than as a footnote: the same sections
/// follow whatever the phone holds, which is how the shape can be learned (§3.2 Q3).
struct WeatherConditionsSection: View {
  @Environment(\.appTheme) private var theme
  @ScaledMetric(relativeTo: .largeTitle) private var temperatureSize: CGFloat = 80

  /// The page this block answers for: its snapshot, its place, and the bot it would ask.
  let screen: WeatherPageScreen
  let onOpenSettings: () -> Void
  let onUseMyLocation: () -> Void
  /// The status line is drawn here unless a banner above already says the one thing it would
  /// say (docs/MESHWX_UI.md §3.1 U-24).
  var showsStatus = true

  private var snapshot: WeatherScreenSnapshot { screen.snapshot }

  var body: some View {
    Section {
      VStack(spacing: 6) {
        // Only once the page has a place: the title then names the town, and the eyebrow says
        // which page this is. With no place yet the title already reads "My location".
        if screen.pageID == WeatherPage.myLocationID, snapshot.place != nil {
          eyebrow
        }
        block
        // The bot pushes warnings for its own area only, so outside it silence says nothing. One
        // quiet line, and never "no alerts for Dallas" — which the phone cannot know (§14).
        if isOutsideArea {
          Text(L10n.Weather.Weather.Place.outsideArea)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if showsStatus {
          status
        }
      }
      .frame(maxWidth: .infinity)
      .multilineTextAlignment(.center)
      .padding(.top, 2)
      .padding(.bottom, 6)
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
      .accessibilityElement(children: .contain)
      .accessibilityLabel(L10n.Weather.Weather.Now.summary)
    }
  }

  /// "MY LOCATION", with the arrow the dots use for the same page.
  private var eyebrow: some View {
    Label(L10n.Weather.Weather.Picker.yourLocation, systemImage: "location.fill")
      .font(.caption.weight(.semibold))
      .textCase(.uppercase)
      .foregroundStyle(.secondary)
      .padding(.bottom, 2)
  }

  private var isOutsideArea: Bool {
    guard let place = snapshot.place else { return false }
    return snapshot.coverage.verdict(for: place) == .outside
  }

  /// What a pull or Update would ask for; while a run is on the air, what it said; with nothing
  /// to ask, that everything is current and as of when (docs/MESHWX_UI.md §11.1).
  private var status: some View {
    Text(WeatherUpdateControl.caption(screen: screen, plan: screen.plan))
      .font(.footnote)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 6)
      // What Update would ask for, and what the last run did: the line the UI tests read
      // before and after a live request (docs/Testing.md).
      .accessibilityIdentifier("weather.page.caption")
  }

  @ViewBuilder
  private var block: some View {
    if let empty = WeatherEmptyPlace.make(screen: screen) {
      emptyBlock(empty)
    } else {
      switch screen.context.conditions {
      case let .reading(reading):
        readingBlock(reading, attributed: false)
      case let .nearby(reading, _):
        readingBlock(reading, attributed: true)
      case let .ask(icao, _):
        // With every request blocked the sentence does not offer a pull that cannot send
        // anything (docs/MESHWX_UI.md §3.1 U-6).
        statement(WeatherCopy.conditionsAsk(
          placeName: screen.placeName ?? "", source: screen.sourceName, icao: icao,
          block: snapshot.requestBlock))
      case .noneYet:
        statement(L10n.Weather.Weather.Now.empty(WeatherFormatting.sentenceStart(screen.sourceName)))
      case let .noStation(nearest):
        statement(WeatherCopy.noStationNearby(
          placeName: screen.placeName ?? "",
          nearestTown: screen.context.nearestStationTown
            ?? nearest.map { WeatherNames.stationName($0.station.name) } ?? "",
          kilometres: nearest?.distanceKilometres))
      case .noPlace:
        noPlaceBlock
      }
    }
  }

  /// What the page has to say in place of a temperature, set as its statement.
  private func statement(_ text: String) -> some View {
    Text(text)
      .font(.body)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 8)
  }

  private func sentence(_ text: String) -> some View {
    Text(text)
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: - A good reading

  /// - Parameter attributed: the reading is not the weather here, only the nearest report: the
  ///   station and its distance lead, above the number, so nobody reads 79° as the town's.
  private func readingBlock(_ reading: WeatherStationReading, attributed: Bool) -> some View {
    let observation = reading.stored.observation
    let calendar = Calendar.autoupdatingCurrent
    let symbol = MeshWXPresentation.observationSymbolName(
      for: observation.sky, isNight: WeatherFormatting.isNight(reading.stored.observedAt, calendar: calendar))

    return VStack(spacing: 4) {
      if attributed {
        Text(WeatherCopy.nearbyReadingLead(
          stationName: WeatherNames.stationName(reading.station.name),
          kilometres: reading.distanceKilometres))
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("weather.nearbyReading")
      }
      if let tempF = observation.tempF {
        Text(WeatherFormatting.temperature(fahrenheit: Int(tempF)))
          .font(.system(size: temperatureSize, weight: .thin))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.6)
      }
      HStack(spacing: 6) {
        // No cloud or weather group in the report: no icon rather than a made-up sky.
        if let symbol {
          Image(systemName: symbol)
            .symbolRenderingMode(.multicolor)
            .accessibilityHidden(true)
        }
        if let condition = WeatherFormatting.condition(observation.sky) {
          Text(condition)
        }
      }
      .font(.title3)
      if let highLow {
        Text(highLow)
          .font(.subheadline)
      }
      if let details = details(observation) {
        Text(details)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      sourceLine(reading, attributed: attributed)
    }
  }

  /// Today's high and low, from the forecast the page holds — the line a weather app puts under
  /// the condition. Nothing when there is no forecast yet.
  private var highLow: String? {
    guard case let .forecast(summary) = snapshot.forecast,
          let row = summary.rows.first(where: { $0.label == .today || $0.label == .tonight })
            ?? summary.rows.first
    else { return nil }
    var parts: [String] = []
    if let high = row.highF {
      parts.append(L10n.Weather.Weather.Forecast.high(WeatherFormatting.temperature(fahrenheit: Int(high))))
    }
    if let low = row.lowF {
      parts.append(L10n.Weather.Weather.Forecast.low(WeatherFormatting.temperature(fahrenheit: Int(low))))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func details(_ observation: MeshWXStationObservation) -> String? {
    var parts: [String] = []
    if observation.feelsDeltaF != 0, let feelsLike = observation.feelsLikeF {
      parts.append(L10n.Weather.Weather.Now.feelsLike(WeatherFormatting.temperature(fahrenheit: feelsLike)))
    }
    if let wind = WeatherFormatting.wind(MeshWXWindReading(observation: observation)) {
      parts.append(L10n.Weather.Weather.Now.wind(wind))
    }
    if let humidity = observation.humidityPercent {
      parts.append(L10n.Weather.Weather.Now.humidity(Int(humidity)))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// The one honesty line, and the way to the station behind it.
  /// With `attributed`, the station and distance already lead the block, so this says when only.
  private func sourceLine(_ reading: WeatherStationReading, attributed: Bool) -> some View {
    Button {
      // This page's, so the station screen measures and names its distance from this place.
      screen.model.stationToOpen = WeatherStationTarget(pageID: screen.pageID, index: reading.index)
    } label: {
      HStack(spacing: 3) {
        Text(WeatherCopy.conditionsSource(
          stationName: attributed ? nil : WeatherNames.stationName(reading.station.name),
          kilometres: attributed ? nil : reading.distanceKilometres,
          observedAt: reading.stored.observedAt,
          now: screen.now,
          calendar: .autoupdatingCurrent,
          locale: .autoupdatingCurrent))
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .accessibilityHidden(true)
      }
      .font(.footnote)
      .foregroundStyle(.secondary)
      .padding(.top, 2)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("weather.honestyLine")
  }

  // MARK: - Nothing held at all

  /// Everything the phone holds for this place is missing: the empty slot, one sentence about
  /// what is nearest, and one about what to do — or, when nothing can be asked at all, why not
  /// (docs/MESHWX_UI.md §3.1 U-13).
  @ViewBuilder
  private func emptyBlock(_ empty: WeatherEmptyPlace) -> some View {
    Text(WeatherCopy.emptyPlaceTitle(placeName: screen.placeName ?? ""))
      .font(.title3.weight(.semibold))
      .padding(.top, 8)
    if let nearest = WeatherCopy.emptyPlaceNearest(empty) {
      sentence(nearest)
    }
    // Nil while nothing can be asked at all: the page says why once, in the status line.
    if let action = WeatherCopy.emptyPlaceAction(
      empty, placeName: screen.placeName ?? "", source: screen.sourceName,
      block: snapshot.requestBlock) {
      sentence(action)
    }
  }

  // MARK: - No place

  /// The My location page before there is a place: what the phone is waiting for, and the one tap
  /// that may ask for permission (docs/MESHWX_UI.md §5). Nothing prompts on its own.
  @ViewBuilder
  private var noPlaceBlock: some View {
    switch screen.model.placeState {
    case .locating:
      HStack(spacing: 8) {
        ProgressView()
        Text(L10n.Weather.Weather.Header.locating)
      }
      .font(.body)
      .foregroundStyle(.secondary)
      .padding(.top, 8)
    case .denied:
      statement(L10n.Weather.Weather.Header.locationOff)
      Button(L10n.Weather.Weather.Header.settings, action: onOpenSettings)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .padding(.top, 4)
    case .needsPermission:
      // Places opens by itself on a first visit with no permission and no saved place (§5), so
      // this page is read *under* the sheet that is already saying "Choose a place in Places".
      // Printing the same instruction twice, once modally, is the app talking over itself
      // (docs/MESHWX_UI.md §3.1 U-19). The page offers the one thing the sheet does not: the tap
      // that asks for location.
      statement(L10n.Weather.Weather.Place.useMyLocationPrompt)
      Button(L10n.Weather.Weather.Place.useMyLocation, action: onUseMyLocation)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .padding(.top, 4)
    case .unavailable, .resolved:
      // Permission is settled and there is still no fix: no sheet is up, and the instruction is
      // the right thing to say.
      statement(L10n.Weather.Weather.Place.choosePrompt)
      Button(L10n.Weather.Weather.Place.useMyLocation, action: onUseMyLocation)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .padding(.top, 4)
    }
  }
}

/// The small-capitals label at the top of a card — "FORECAST", "WEATHER SERVICE TEXT REPORTS" —
/// with, at the right, the one time the card has to give (docs/MESHWX_UI.md §4).
///
/// Inside the card, the way Apple Weather labels its cards, rather than a section header over it:
/// the header the list draws is title-sized, and at that size the forecast's provenance ran to
/// three lines of grey floating between two cards. The label is a row of its own, so it is
/// tested and accessible as a header.
struct WeatherCardLabel: View {
  let title: String
  var systemImage: String?
  var trailing: String?
  var accessibilityLabel: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if let systemImage {
        Label(title, systemImage: systemImage)
      } else {
        Text(title)
      }
      Spacer(minLength: 8)
      if let trailing {
        Text(trailing)
          .multilineTextAlignment(.trailing)
      }
    }
    .font(.caption.weight(.semibold))
    .textCase(.uppercase)
    .foregroundStyle(.secondary)
    .listRowSeparator(.hidden)
    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 2, trailing: 16))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel ?? [title, trailing].compactMap { $0 }.joined(separator: ", "))
    .accessibilityAddTraits(.isHeader)
  }
}
