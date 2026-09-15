import CoreLocation
import MC1Services
import MeshWX
import SwiftUI

/// The Weather tool: what the MeshWX bot on `#meshwx` has said, and the few things the user can
/// ask it (docs/MESHWX.md, spec §10).
///
/// The screen works with no radio at all. Everything the bot ever sent is on disk per bot, so a
/// phone out of Bluetooth range still shows the last picture — which is the point of a weather
/// tool on a mesh. A radio is needed only to *ask*, and every request button says so by being
/// disabled rather than by failing when tapped.
struct WeatherToolView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme

  @State private var model = WeatherToolModel()
  @State private var isShowingPlaceSearch = false
  @State private var isConfirmingClear = false

  var body: some View {
    content
      .navigationTitle(L10n.Weather.Weather.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { toolbarContent }
      .sheet(isPresented: $isShowingPlaceSearch) {
        WeatherPlaceSearchView(model: model, origin: appState.bestAvailableLocation?.coordinate)
      }
      .confirmationDialog(
        L10n.Weather.Weather.Menu.clearConfirm(model.selectedBotName),
        isPresented: $isConfirmingClear,
        titleVisibility: .visible
      ) {
        Button(L10n.Weather.Weather.Menu.clearAction, role: .destructive) {
          Task { await model.clearSelectedBotState() }
        }
        Button(L10n.Weather.Weather.Common.cancel, role: .cancel) {}
      }
      .task(id: appState.servicesVersion) {
        await model.attach(
          services: appState.services,
          device: appState.connectedDevice,
          location: appState.bestAvailableLocation?.coordinate
        )
      }
      .onChange(of: appState.contactsVersion) {
        Task { await model.refreshBots() }
      }
      .onDisappear {
        model.detach()
      }
  }

  // MARK: - Content

  /// A radio that has never delivered anything has nothing to show but the reason, so the
  /// list is replaced rather than headed by an empty state.
  @ViewBuilder
  private var content: some View {
    if model.radioStatus == .disconnected, model.states.isEmpty {
      ContentUnavailableView {
        Label(
          L10n.Weather.Weather.Status.Disconnected.title,
          systemImage: "antenna.radiowaves.left.and.right.slash"
        )
      } description: {
        Text(L10n.Weather.Weather.Status.Disconnected.description)
      }
    } else {
      list
    }
  }

  private var list: some View {
    List {
      statusSection
      requestStatusSection
      botSection
      WeatherWarningsSection(model: model)
      WeatherObservationsSection(model: model)
      WeatherForecastSection(
        model: model,
        userLocation: appState.bestAvailableLocation?.coordinate,
        onFindPlace: { isShowingPlaceSearch = true }
      )
      WeatherTextSection(model: model)
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
  }

  // MARK: - Status

  @ViewBuilder
  private var statusSection: some View {
    switch model.radioStatus {
    case let .firmwareTooOld(version):
      Section {
        firmwareCard(version: version)
      }
      .themedRowBackground(theme)

    case let .channelMissing(canAdd):
      Section {
        if !canAdd {
          Label(L10n.Weather.Weather.Status.channelFull, systemImage: "exclamationmark.triangle")
        } else if model.isChannelPromptDismissed {
          channelMissingRow
        } else {
          channelPromptCard
        }
      }
      .themedRowBackground(theme)

    case .disconnected:
      Section {
        Label(
          L10n.Weather.Weather.Status.Disconnected.banner,
          systemImage: "antenna.radiowaves.left.and.right.slash"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
      .themedRowBackground(theme)

    case .ready:
      EmptyView()
    }
  }

  private func firmwareCard(version: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(L10n.Weather.Weather.Status.FirmwareTooOld.title, systemImage: "exclamationmark.triangle")
        .font(.headline)
      Text(L10n.Weather.Weather.Status.FirmwareTooOld.body(version))
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  /// The prompt the owner asked for: `#meshwx` is never written to a radio without a tap
  /// (docs/MESHWX.md).
  private var channelPromptCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(L10n.Weather.Weather.Status.ChannelPrompt.title)
        .font(.headline)
      Text(L10n.Weather.Weather.Status.ChannelPrompt.body)
        .font(.footnote)
        .foregroundStyle(.secondary)
      if let channelError = model.channelError {
        Text(channelError)
          .font(.footnote)
          .foregroundStyle(.red)
      }
      HStack(spacing: 12) {
        Button(L10n.Weather.Weather.Status.ChannelPrompt.add) {
          Task { await model.addChannel() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isAddingChannel)

        Button(L10n.Weather.Weather.Status.ChannelPrompt.notNow) {
          model.dismissChannelPrompt()
        }
        .buttonStyle(.bordered)
        .disabled(model.isAddingChannel)

        if model.isAddingChannel {
          ProgressView()
        }
      }
    }
  }

  /// Declining hides the card, not the channel: the tool is inert without `#meshwx`, so the
  /// way back has to stay one tap away.
  private var channelMissingRow: some View {
    HStack {
      Text(L10n.Weather.Weather.Status.ChannelMissing.row)
        .font(.subheadline)
      Spacer(minLength: 12)
      if model.isAddingChannel {
        ProgressView()
      } else {
        Button(L10n.Weather.Weather.Status.ChannelMissing.add) {
          Task { await model.addChannel() }
        }
        .buttonStyle(.borderless)
      }
    }
  }

  // MARK: - Request status (spec §13)

  @ViewBuilder
  private var requestStatusSection: some View {
    if hasRequestStatus {
      Section {
        requestStatusLine
      }
      .themedRowBackground(theme)
      .task(id: model.lastOutcome?.request.id) {
        // The outcome banner is a receipt, not a state: it says its piece and goes, so a
        // "no answer" from five minutes ago is not still on screen at the next glance.
        guard model.lastOutcome != nil else { return }
        try? await Task.sleep(for: .seconds(8))
        guard !Task.isCancelled else { return }
        model.clearLastOutcome()
      }
    }
  }

  private var hasRequestStatus: Bool {
    if model.hasPendingRequest || model.requestFailure != nil { return true }
    guard let outcome = model.lastOutcome else { return false }
    return text(for: outcome.outcome) != nil
  }

  @ViewBuilder
  private var requestStatusLine: some View {
    if let pending = model.pendingRequests.first {
      HStack(spacing: 10) {
        ProgressView()
        Text(waitingText(for: pending))
          .font(.subheadline)
      }
      .accessibilityElement(children: .combine)
    } else if let failure = model.requestFailure {
      Label(text(for: failure), systemImage: "exclamationmark.circle")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    } else if let outcome = model.lastOutcome, let text = text(for: outcome.outcome) {
      Label(text, systemImage: "info.circle")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  private func waitingText(for pending: WeatherPendingRequest) -> String {
    let waiting = L10n.Weather.Weather.Request.waiting(model.selectedBotName)
    guard pending.attempt > 0 else { return waiting }
    return "\(waiting) \(L10n.Weather.Weather.Request.secondTry)"
  }

  private func text(for failure: WeatherToolModel.RequestFailure) -> String {
    switch failure {
    case let .rateLimited(seconds): L10n.Weather.Weather.Request.rateLimited(seconds)
    case let .transport(message): message
    case .noBot: L10n.Weather.Weather.Request.noBot
    }
  }

  /// An answered request says nothing: the data that arrived is the message.
  private func text(for outcome: WeatherRequestOutcome) -> String? {
    switch outcome {
    case .answered: nil
    case .servedFromCache: L10n.Weather.Weather.Request.cached
    case let .notAvailable(reason): WeatherFormatting.notAvailableText(reason)
    case .timedOut: L10n.Weather.Weather.Request.timedOut(model.selectedBotName)
    case let .failed(message): message
    }
  }

  // MARK: - Bot

  @ViewBuilder
  private var botSection: some View {
    Section(L10n.Weather.Weather.Bot.section) {
      if model.selectedBotID == nil {
        VStack(alignment: .leading, spacing: 6) {
          Text(L10n.Weather.Weather.Bot.NoBots.title)
            .font(.headline)
          Text(L10n.Weather.Weather.Bot.NoBots.description)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      } else {
        botHeader
        if model.selectedBot == nil {
          Label(L10n.Weather.Weather.Bot.heardOnlyNote, systemImage: "questionmark.circle")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if model.isFeedStale {
          Text(L10n.Weather.Weather.Bot.feedStaleDetail)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
    .themedRowBackground(theme)
  }

  private var botHeader: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(model.selectedBotName)
          .font(.headline)
        if model.isFeedStale {
          WeatherBadge(text: L10n.Weather.Weather.Bot.feedStale, tint: .orange)
        }
      }
      if let subtitle = botSubtitle {
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Text(lastHeardText)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  /// City and how far away it is — the two facts that decide whether this bot's coverage is
  /// the user's weather.
  private var botSubtitle: String? {
    guard let bot = model.selectedBot else { return nil }
    guard let location = appState.bestAvailableLocation,
          let metres = bot.distance(
            fromLatitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
          )
    else { return bot.city }
    return L10n.Weather.Weather.Bot.cityDistance(bot.city, WeatherFormatting.distance(metres: metres))
  }

  private var lastHeardText: String {
    guard let lastHeardAt = model.lastHeardAt else { return L10n.Weather.Weather.Bot.neverHeard }
    return L10n.Weather.Weather.Bot.lastHeard(lastHeardAt.formatted(.relative(presentation: .named)))
  }

  // MARK: - Toolbar

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      HStack(spacing: 16) {
        if model.selectedBotID != nil {
          botMenu
        }
        overflowMenu
      }
    }
  }

  private var botMenu: some View {
    Menu {
      ForEach(model.bots) { bot in
        Button {
          model.select(bot: bot)
        } label: {
          botMenuLabel(title: bot.name, isSelected: model.selectedBotID == bot.botID)
        }
      }
      ForEach(model.heardOnlyBotIDs, id: \.self) { botID in
        Button {
          model.select(botID: botID)
        } label: {
          botMenuLabel(
            title: L10n.Weather.Weather.Bot.heardOnly(WeatherToolModel.hexID(botID)),
            isSelected: model.selectedBotID == botID
          )
        }
      }
    } label: {
      Label(L10n.Weather.Weather.Bot.picker, systemImage: "antenna.radiowaves.left.and.right")
    }
    .accessibilityLabel(L10n.Weather.Weather.Bot.picker)
    .accessibilityValue(model.selectedBotName)
  }

  @ViewBuilder
  private func botMenuLabel(title: String, isSelected: Bool) -> some View {
    if isSelected {
      Label(title, systemImage: "checkmark")
    } else {
      Text(title)
    }
  }

  private var overflowMenu: some View {
    Menu {
      Button(role: .destructive) {
        isConfirmingClear = true
      } label: {
        Label(L10n.Weather.Weather.Menu.clearData, systemImage: "trash")
      }
      .disabled(model.botState == nil)
    } label: {
      Label(L10n.Weather.Weather.Menu.more, systemImage: "ellipsis.circle")
    }
    .accessibilityLabel(L10n.Weather.Weather.Menu.more)
  }
}

// MARK: - Shared pieces

/// A small capsule for "stale" and "feed stale": one look for every "this number is older than
/// it should be" on the screen.
struct WeatherBadge: View {
  let text: String
  let tint: Color

  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(tint.opacity(0.18), in: .capsule)
      .foregroundStyle(tint)
  }
}

/// A button that puts one request on the air.
///
/// Disabled whenever the tool cannot send — no ready radio, no bot with a key, or a request
/// already in flight — because spec §13 allows one request at a time, on a user action.
struct WeatherRequestButton: View {
  let title: String
  var systemImage: String?
  let model: WeatherToolModel
  let request: WeatherRequest
  var isEnabled = true

  private var isDisabled: Bool {
    !isEnabled || !model.canSendRequests || model.hasPendingRequest
  }

  var body: some View {
    Button {
      Task { await model.send(request) }
    } label: {
      if let systemImage {
        Label(title, systemImage: systemImage)
      } else {
        Text(title)
      }
    }
    .buttonStyle(.borderless)
    // A list row's Label keeps its tinted icon when the button is disabled, so a row of
    // icon buttons read as live while the text-only ones beside them greyed out. One look
    // for "cannot send now", whatever the label carries.
    .foregroundStyle(isDisabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
    .disabled(isDisabled)
  }
}

#Preview {
  NavigationStack {
    WeatherToolView()
  }
  .environment(\.appState, AppState())
}
