import MC1Services
import MeshWX
import SwiftUI

/// The weather radio's own page (docs/MESHWX_UI.md §12), **pushed** from the radio row at the
/// foot of a place page: how asking works, what the radio says it covers, what this phone has
/// asked for, what the channel has carried, the radios themselves, and what is being kept.
///
/// It is pushed, not presented. It used to be the one row on a place page that opened a sheet
/// while every other row pushed, so the same list of rows had two navigation grammars and two
/// ways back (docs/MESHWX_UI.md §3.1 U-11).
///
/// One screen for the radio and the channel, in place of the About sheet. Nothing on it says who
/// asked for anything: an answer on `#meshwx` reaches every phone listening and carries no
/// requester, so the only requests that can be listed are this phone's own.
///
/// The radio picker is inline rows with checkmarks, not a menu: picking reshapes the screen behind.
struct WeatherRadioView: View {
  @Environment(\.appTheme) private var theme

  /// The page this page was opened from: the alert and station counts, the coverage verdict and
  /// the radio it is about are that place's.
  let screen: WeatherPageScreen

  private var model: WeatherToolModel { screen.model }

  @State private var isConfirmingClear = false
  /// The bot the confirmation names, fixed when it is presented: the source can change while the
  /// alert is up, and the clear must remove what the alert said it would.
  @State private var clearBotID: UInt16?
  @State private var clearsAfterAlert = false
  /// The town at the centre of the stated circle, looked up off the main actor.
  @State private var centreName: String?

  /// The order the page reads in (docs/MESHWX_UI.md §3.1 U-16): what this radio is and what it
  /// covers, what you have asked it, what it is reporting, what the channel has carried, and last
  /// the radios themselves and the way to throw it all away.
  ///
  /// "Heard on #meshwx" is **not** a section of its own any more. The page said the same thing
  /// three times over — "Heard on #meshwx", "19 weather stations", "Cached from the channel (29)"
  /// — because what was heard and what is cached are one pile counted twice. It is now the
  /// newest-first view inside Cached.
  var body: some View {
    List {
      howItWorksSection
      coverageSection
      requestsSection
      stationsSection
      alertsSection
      notificationsSection
      cacheSection
      channelSection
      radiosSection

      Section {
        Button(L10n.Weather.Weather.About.clear, role: .destructive) {
          clearBotID = screen.snapshot.source?.botID
          isConfirmingClear = clearBotID != nil
        }
        .disabled(screen.snapshot.source == nil)
      } footer: {
        Text(L10n.Weather.Weather.About.clearFooter(screen.sourceName))
      }
      .themedRowBackground(theme)
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
    .navigationTitle(WeatherFormatting.sentenceStart(screen.sourceName))
    .navigationBarTitleDisplayMode(.inline)
    .weatherToolChrome()
    .task(id: centreKey) {
      guard let centre = statement?.coverage.centre else { return }
      // Thirty-five thousand place names: never on the main actor.
      centreName = await Task.detached(priority: .userInitiated) {
        WeatherNames.placeLabel(near: centre, tables: .shared)
      }.value
    }
    .alert(L10n.Weather.Weather.About.Alert.title(clearName), isPresented: $isConfirmingClear) {
      Button(L10n.Weather.Weather.About.Alert.clear, role: .destructive) {
        clearsAfterAlert = true
      }
      Button(L10n.Weather.Weather.Common.cancel, role: .cancel) {}
    } message: {
      Text(L10n.Weather.Weather.About.Alert.message(clearName))
    }
    .onChange(of: isConfirmingClear) { _, isShowing in
      guard !isShowing else { return }
      let botID = clearBotID
      clearBotID = nil
      guard clearsAfterAlert, let botID else { return }
      clearsAfterAlert = false
      Task { await model.clearReceivedWeather(botID: botID) }
    }
  }

  private var clearName: String {
    clearBotID.map(model.botName) ?? screen.sourceName
  }

  private func time(_ date: Date) -> String {
    WeatherFormatting.clockTime(date, now: screen.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
  }

  // MARK: - How it works

  /// Four lines: where the request goes, where the answer goes, who keeps it, and what it costs.
  private var howItWorksSection: some View {
    Section {
      WeatherCardLabel(title: L10n.Weather.Weather.About.howItWorks, systemImage: "questionmark.circle")
      VStack(alignment: .leading, spacing: 8) {
        Text(L10n.Weather.Weather.About.line1)
        Text(L10n.Weather.Weather.About.line2)
        Text(L10n.Weather.Weather.About.line3)
        Text(L10n.Weather.Weather.About.line4)
      }
      .font(.subheadline)
      .padding(.vertical, 4)
      .accessibilityElement(children: .combine)
    }
    .themedRowBackground(theme)
  }

  // MARK: - What the radio carries

  /// Every alert in the radio's area, with its map and its status line. It is here rather than on
  /// a place page because it is about what the radio is relaying, not about the weather where you
  /// are: a page answers for one place, and one alert covering that place is a banner there (§7).
  @ViewBuilder
  private var alertsSection: some View {
    Section {
      NavigationLink {
        WeatherAlertsListView(screen: screen)
      } label: {
        LabeledContent {
          Text(String(screen.snapshot.alerts.count))
        } label: {
          Label(L10n.Weather.Weather.AlertsList.title(screen.sourceName), systemImage: "exclamationmark.triangle")
        }
      }
      .accessibilityIdentifier("weather.radio.alerts")
    }
    .themedRowBackground(theme)
  }

  /// The stations the radio reports, nearest the place on screen first, each with its age.
  @ViewBuilder
  private var stationsSection: some View {
    if !screen.snapshot.readings.isEmpty {
      let readings = screen.snapshot.readings
      Section {
        NavigationLink {
          WeatherStationsView(screen: screen)
        } label: {
          Label {
            Text(WeatherCopy.stationLink(
              inArea: readings.filter(\.isInFootprint).count, total: readings.count,
              source: screen.sourceName))
          } icon: {
            Image(systemName: "thermometer.medium")
          }
        }
        .accessibilityIdentifier("weather.radio.stations")
      }
      .themedRowBackground(theme)
    }
  }

  // MARK: - Alert notifications

  /// The way in to what this phone will tell you about without the tool open
  /// (docs/MESHWX_UI.md §16). It is on this page because everything about it depends on this
  /// radio being connected and in range.
  private var notificationsSection: some View {
    Section {
      NavigationLink {
        WeatherAlertNotificationsView(model: model)
      } label: {
        LabeledContent {
          Text(model.isWatchingAnything
            ? L10n.Weather.Weather.Notifications.watchingCount(
              model.watchedPlaces.count + (model.isMyLocationWatched ? 1 : 0))
            : L10n.Weather.Weather.Notifications.watchingNone)
        } label: {
          Label(L10n.Weather.Weather.Notifications.title, systemImage: "bell")
        }
      }
      .accessibilityIdentifier("weather.radio.notifications")
    }
    .themedRowBackground(theme)
  }

  // MARK: - What it covers

  /// The source bot's own statement of its area (spec §7A), and nothing weaker: the stations it
  /// happens to report this hour describe the weather, not the coverage (§3.1 I-B18).
  private var statement: WeatherCoverage.Stated? {
    guard let botID = screen.snapshot.source?.botID else { return nil }
    return screen.snapshot.coverage.stated[botID]
  }

  private var centreKey: String? {
    statement?.coverage.centre.map { "\($0.latitude),\($0.longitude)" }
  }

  @ViewBuilder
  private var coverageSection: some View {
    Section {
      WeatherCardLabel(title: L10n.Weather.Weather.Covers.header, systemImage: "map")
      if let coverage = statement?.coverage {
        if coverage.hasNoAreaFilter {
          // `n` = 0 and `k` = 0 with neither list cut: no filter at all, which is an answer.
          LabeledContent(L10n.Weather.Weather.Covers.area) {
            Text(L10n.Weather.Weather.Covers.everywhere)
          }
        } else {
          if let circle {
            LabeledContent(L10n.Weather.Weather.Covers.area) { Text(circle) }
          }
          if let zones {
            LabeledContent(L10n.Weather.Weather.Covers.zones) { Text(zones) }
          }
          if let offices {
            LabeledContent(L10n.Weather.Weather.Covers.offices) { Text(offices) }
          }
        }
        if coverage.stationCap > 0 {
          LabeledContent(L10n.Weather.Weather.Covers.stations) {
            Text(L10n.Weather.Weather.Covers.stationCap(Int(coverage.stationCap)))
          }
        }
      } else {
        // Not "it covers nothing": the bot has said nothing, and until it does the app cannot
        // tell a place outside its area from one it has not been told about (§6).
        Text(L10n.Weather.Weather.Covers.none(WeatherFormatting.sentenceStart(screen.sourceName)))
          .font(.subheadline)
        WeatherAskButton(
          screen: screen, title: L10n.Weather.Weather.Request.askCoverage, request: .coverage, showsFootnotes: true)
      }
    } footer: {
      // The statement carries no time of its own, so receipt is the only age there is.
      if let statement {
        Text(L10n.Weather.Weather.Covers.stated(screen.sourceName, time(statement.receivedAt)))
      } else {
        Text(L10n.Weather.Weather.Covers.noneFooter)
      }
    }
    .themedRowBackground(theme)
  }

  /// "Within 120 km of Austin, TX", or of the degrees the bot sent when no town is near enough
  /// to name the centre.
  private var circle: String? {
    guard let coverage = statement?.coverage, let centre = coverage.centre, coverage.radiusKilometres > 0 else {
      return nil
    }
    let place = centreName ?? Self.coordinates(centre)
    return L10n.Weather.Weather.Covers.circle(
      WeatherFormatting.kilometres(Double(coverage.radiusKilometres)), place)
  }

  static func coordinates(_ centre: MeshWXCoordinate) -> String {
    let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(3))
    return "\(centre.latitude.formatted(style)), \(centre.longitude.formatted(style))"
  }

  /// How many zones the statement lists. A list the bot had to cut says "and more it didn't
  /// list", never that the rest are uncovered (spec §7A).
  private var zones: String? {
    guard let coverage = statement?.coverage, !coverage.areas.isEmpty else { return nil }
    let count = coverage.areas.reduce(0) { $0 + Int($1.run) }
    let text = count == 1
      ? L10n.Weather.Weather.Covers.zoneCountOne
      : L10n.Weather.Weather.Covers.zoneCount(count)
    return coverage.areasCut ? L10n.Weather.Weather.Covers.andMore(text) : text
  }

  private var offices: String? {
    guard let coverage = statement?.coverage, !coverage.officeIndices.isEmpty else { return nil }
    let names = coverage.officeIndices
      .compactMap { MeshWXTables.shared.officeCode($0) }
      .map(WeatherReferenceNames.officeName)
    guard !names.isEmpty else { return nil }
    let text = names.joined(separator: ", ")
    return coverage.officesCut ? L10n.Weather.Weather.Covers.andMore(text) : text
  }

  // MARK: - Your requests

  /// What this phone asked for, newest first, and how each one ended. The only requests anyone
  /// can name: the answers were broadcast, and they carry no requester.
  ///
  /// **Three rows and a way in** (docs/MESHWX_UI.md §3.1 U-39). The owner, 20 September: *Your
  /// requests is way too long of a list.* Forty rows of a ledger sat in the middle of a page
  /// whose other nine sections are one row each, so everything under it was below the fold. The
  /// log is untouched — what was wrong was the page.
  private var requestsSection: some View {
    let split = model.requestLogSplit
    return Section {
      WeatherCardLabel(title: L10n.Weather.Weather.Requests.newest, systemImage: "paperplane")
      if split.newest.isEmpty {
        Text(L10n.Weather.Weather.Requests.none)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
        ForEach(split.newest) { entry in
          requestRow(entry)
        }
        if split.total > split.newest.count {
          NavigationLink {
            WeatherRequestsListView(screen: screen)
          } label: {
            Text(L10n.Weather.Weather.Requests.all(split.total))
          }
          .accessibilityIdentifier("weather.radio.allRequests")
        }
      }
    } footer: {
      Text(L10n.Weather.Weather.Requests.footer)
    }
    .themedRowBackground(theme)
  }

  @ViewBuilder
  private func requestRow(_ entry: WeatherRequestLogEntry) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(WeatherCopy.requestName(entry.request))
      Text("\(time(entry.sentAt)) · \(WeatherCopy.requestOutcome(entry.outcome))")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: - Radios

  private var radiosSection: some View {
    Section {
      WeatherCardLabel(
        title: L10n.Weather.Weather.About.radios, systemImage: "antenna.radiowaves.left.and.right")
      // With one radio there is nothing to choose.
      if screen.context.botRows.count >= 2 {
        Button {
          model.selectBot(nil)
        } label: {
          checkRow(
            title: L10n.Weather.Weather.About.automatic,
            detail: screen.snapshot.source.map { L10n.Weather.Weather.About.automaticDetail(model.botName($0.botID)) },
            isSelected: model.preferredBotID == nil)
        }
        .buttonStyle(.plain)
      }
      ForEach(screen.context.botRows) { row in
        Button {
          model.selectBot(row.botID)
        } label: {
          checkRow(
            title: model.botName(row.botID), detail: detail(row),
            isSelected: screen.context.botRows.count >= 2 && model.preferredBotID == row.botID)
        }
        .buttonStyle(.plain)
        .disabled(screen.context.botRows.count < 2)
      }
    } footer: {
      Text(L10n.Weather.Weather.About.radiosFooter)
    }
    .themedRowBackground(theme)
  }

  private func detail(_ row: WeatherBotRow) -> String {
    var parts: [String] = []
    // "heard" only for live traffic; a radio known only from a drained backlog says nothing.
    if let heard = row.lastLiveHeardAt {
      parts.append(L10n.Weather.Weather.About.heard(WeatherFormatting.ago(heard, now: screen.now)))
    } else if row.lastHeardAt == nil {
      parts.append(L10n.Weather.Weather.About.notHeard)
    }
    switch row.feed {
    case .recent: parts.append(L10n.Weather.Weather.About.feedOK)
    case let .quiet(minutes):
      parts.append(L10n.Weather.Weather.About.feedQuiet(WeatherFormatting.quietDuration(minutes: minutes)))
    case .neverReceived: parts.append(L10n.Weather.Weather.About.feedNone)
    case nil: break
    }
    if row.bot == nil {
      parts.append(L10n.Weather.Weather.About.noAdvert)
    }
    if screen.snapshot.source?.botID == row.botID {
      parts.append(L10n.Weather.Weather.About.inUse)
    }
    return parts.joined(separator: " · ")
  }

  private func checkRow(title: String, detail: String?, isSelected: Bool) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .foregroundStyle(.primary)
        if let detail {
          Text(detail)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 8)
      if isSelected {
        Image(systemName: "checkmark")
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
      }
    }
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  // MARK: - Channel

  private var channelSection: some View {
    Section {
      WeatherCardLabel(title: WeatherChannel.name, systemImage: "antenna.radiowaves.left.and.right")
      LabeledContent(L10n.Weather.Weather.About.channelSlot) {
        // Without a radio, or before its channel sync, the table can be empty: that is not
        // "not on your radio".
        Text(screen.context.channelSlot.map { L10n.Weather.Weather.About.slot(Int($0)) }
          ?? (model.isRadioConnected && model.isChannelSyncDone
            ? L10n.Weather.Weather.About.noSlot
            : L10n.Weather.Weather.About.radioOffline))
      }
      LabeledContent(L10n.Weather.Weather.About.lastMessage) {
        Text(lastMessage)
      }
      // The owner's sixth ask, 20 September: *a way to see all the GRP_DATA traffic on a channel
      // like we do a chat.* It belongs here, under the channel it is about, and nowhere else on
      // the page: everything else on this screen is the weather, and this is the wire.
      NavigationLink {
        WeatherTrafficView(screen: screen)
      } label: {
        Label(L10n.Weather.Weather.Traffic.title, systemImage: "dot.radiowaves.up.forward")
      }
      .accessibilityIdentifier("weather.radio.traffic")
    }
    .themedRowBackground(theme)
  }

  /// This session's last datagram; without one, the last time any weather radio was heard live.
  private var lastMessage: String {
    let last = screen.context.session.lastChannelDatagramAt
      ?? model.liveHeardAt
    guard let last else { return L10n.Weather.Weather.About.noMessage }
    return time(last)
  }

  // MARK: - Cache

  /// One disclosed row, at the foot of the page and nowhere else: what is being held, and how
  /// much of it is somebody else's question.
  @ViewBuilder
  private var cacheSection: some View {
    let cache = screen.snapshot.cache
    if cache.total > 0 {
      Section {
        NavigationLink {
          WeatherCachedView(screen: screen)
        } label: {
          Text(L10n.Weather.Weather.Cache.row(cache.total))
        }
        .accessibilityIdentifier("weather.radio.cached")
      }
      .themedRowBackground(theme)
    }
  }
}

// MARK: - Every request this phone has sent (§3.1 U-39)

/// The whole request log, from the radio page's "All requests (27)" row.
///
/// The same rows the page's first three are, and nothing more: the log is capped at forty and a
/// week by `WeatherRequestLog`, so this screen is the log, not a history of one. Pushed and handed
/// the page it was opened from, like every other drill-in in this tool (docs/MESHWX_UI.md §13).
struct WeatherRequestsListView: View {
  @Environment(\.appTheme) private var theme

  let screen: WeatherPageScreen

  private var model: WeatherToolModel { screen.model }

  var body: some View {
    List {
      Section {
        ForEach(model.requestLog) { entry in
          VStack(alignment: .leading, spacing: 2) {
            Text(WeatherCopy.requestName(entry.request))
            Text("\(WeatherFormatting.clockTime(entry.sentAt, now: screen.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)) · \(WeatherCopy.requestOutcome(entry.outcome))")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
        }
      } footer: {
        Text(L10n.Weather.Weather.Requests.footer)
      }
      .themedRowBackground(theme)
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
    .navigationTitle(L10n.Weather.Weather.Requests.allTitle)
    .navigationBarTitleDisplayMode(.inline)
    .weatherPendingBar(model: model, requestsOnScreen: [])
    .weatherToolChrome()
  }
}
