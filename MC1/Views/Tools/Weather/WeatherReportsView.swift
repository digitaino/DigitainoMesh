import MC1Services
import MeshWX
import SwiftUI

/// A text reply's body with a marker wherever a part never arrived.
enum WeatherReportText {
  static func body(_ assembly: WeatherTextAssembly) -> String {
    assembly.orderedChunks
      .map { $0 ?? L10n.Weather.Weather.Reports.missingPart }
      .joined()
  }
}

/// The Weather Service products a bot sends on request (docs/MESHWX_UI.md §12).
enum WeatherReportProduct: Hashable, CaseIterable {
  case discussion
  case outlook
  case stormReports
  case rainfall
  case spaceWeather

  var subject: MeshWXTextSubject {
    switch self {
    case .discussion: .forecastDiscussion
    case .outlook: .hazardousOutlook
    case .stormReports: .stormReports
    case .rainfall: .rainfall
    case .spaceWeather: .spaceWeather
    }
  }

  var title: String {
    switch self {
    case .discussion: L10n.Weather.Weather.Reports.Discussion.title
    case .outlook: L10n.Weather.Weather.Reports.Outlook.title
    case .stormReports: L10n.Weather.Weather.Reports.Storms.title
    case .rainfall: L10n.Weather.Weather.Reports.Rainfall.title
    case .spaceWeather: L10n.Weather.Weather.Reports.Space.title
    }
  }

  /// **What the product is, and nothing about where this copy came from**
  /// (docs/MESHWX_UI.md §3.1 U-15).
  ///
  /// One rule for all five. The blurbs used to attribute in two different currencies on adjacent
  /// rows — the discussion named a Weather Service office ("NWS San Juan"), the outlook named the
  /// radio ("for Weather radio 041D's area") — and the discussion's office was **the page's**, so
  /// a Fort Worth discussion overheard on an Austin page sat under "NWS Austin/San Antonio".
  ///
  /// Attribution belongs to the label directly above the text, where it is read off the reply
  /// that is actually on screen: the area when the request names one, the radio that sent it, and
  /// when it arrived. A blurb describes the product; it cannot describe a text it has not seen.
  var description: String {
    switch self {
    case .discussion: L10n.Weather.Weather.Reports.Discussion.description
    case .outlook: L10n.Weather.Weather.Reports.Outlook.description
    case .stormReports: L10n.Weather.Weather.Reports.Storms.description
    case .rainfall: L10n.Weather.Weather.Reports.Rainfall.description
    case .spaceWeather: L10n.Weather.Weather.Reports.Space.description
    }
  }

  /// The row's stable name for the UI tests, which cannot read `title` out of a localized
  /// string table (docs/Testing.md).
  var accessibilityIdentifier: String {
    switch self {
    case .discussion: "weather.report.discussion"
    case .outlook: "weather.report.outlook"
    case .stormReports: "weather.report.stormReports"
    case .rainfall: "weather.report.rainfall"
    case .spaceWeather: "weather.report.spaceWeather"
    }
  }

  /// The request, with its argument from **this page's** place; nil when the place gives none.
  @MainActor
  func request(screen: WeatherPageScreen) -> WeatherRequest? {
    switch self {
    case .discussion: screen.context.placeOffice.map { .forecastDiscussion(office: $0) }
    case .outlook: .hazardousOutlook
    case .stormReports: screen.reportState.map { .stormReports(state: $0) }
    case .rainfall: screen.reportState.map { .rainfall(state: $0) }
    case .spaceWeather: .spaceWeather
    }
  }
}

/// Whether a product is asked for by state, and so carries the state row on its own screen.
extension WeatherReportProduct {
  var isByState: Bool {
    switch self {
    case .stormReports, .rainfall: true
    case .discussion, .outlook, .spaceWeather: false
    }
  }

  /// Whether the product's argument names an *area* — an office or a state. A reply to one of
  /// these that this phone did not ask for could be about anywhere, because a chunk carries only
  /// its subject (§14 Q5). `>hwo` and `>space` take no place at all: they are the bot's products,
  /// and one of them is about the sun.
  var isByArea: Bool {
    switch self {
    case .discussion, .stormReports, .rainfall: true
    case .outlook, .spaceWeather: false
    }
  }
}

/// One product: the newest reply to **this page's** request for it, else the newest one somebody
/// else asked for, said to be somebody else's.
///
/// Reached straight from a row on the place page (docs/MESHWX_UI.md §8): the index screen that
/// used to sit between them was a card that opened a page of cards. It is handed the page it was
/// opened from, so the office in the blurb, the request the button sends and the text on screen
/// are all about one place (§13).
struct WeatherReportProductView: View {
  @Environment(\.appTheme) private var theme

  let screen: WeatherPageScreen
  let product: WeatherReportProduct

  private var model: WeatherToolModel { screen.model }

  var body: some View {
    let request = product.request(screen: screen)
    let choice = WeatherReportSelection.choose(
      texts: screen.snapshot.texts, subject: product.subject, request: request,
      isByArea: product.isByArea)

    List {
      Section {
        Text(product.description)
          .font(.subheadline)
          .foregroundStyle(.secondary)
        // Storm reports and rainfall are asked for by state, so the state is chosen here rather
        // than on a screen above this one — and it is this page's state, not the pager's.
        if product.isByState {
          NavigationLink {
            WeatherStatePickerView(screen: screen)
          } label: {
            Text(L10n.Weather.Weather.Reports.stateRow(
              screen.reportState.map(WeatherReferenceNames.stateName) ?? L10n.Weather.Weather.Reports.noState))
          }
        }
        if let request {
          WeatherAskButton(
            screen: screen, title: L10n.Weather.Weather.Request.askLatest, request: request, showsFootnotes: true)
        } else {
          Text(L10n.Weather.Weather.Reports.needsPlace)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .themedRowBackground(theme)

      if let choice {
        Section {
          // The label says it was heard on the channel; a footer saying "Somebody else on the
          // mesh asked for this" underneath was the same fact a second time, in a second voice
          // that also claimed to know somebody asked (§3.1 U-15).
          WeatherCardLabel(title: header(choice), trailing: received(choice))
          Text(WeatherReportText.body(choice.item.assembly))
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
        }
        .themedRowBackground(theme)
      } else {
        Section {
          Text(L10n.Weather.Weather.Reports.nothingYet)
            .foregroundStyle(.secondary)
        }
        .themedRowBackground(theme)
      }
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
    .navigationTitle(product.title)
    .navigationBarTitleDisplayMode(.inline)
    .weatherPendingBar(model: model, requestsOnScreen: Set([request].compactMap { $0 }))
    .weatherToolChrome()
  }

  /// What the text on screen is: the area it answers for when that is known, and the radio it
  /// came from. An overheard reply names no area — it has none the phone can read — and says so
  /// rather than borrowing the page's. When it arrived is the label's trailing time, ``received``.
  private func header(_ choice: WeatherReportSelection.Choice) -> String {
    let item = choice.item
    var parts: [String] = []
    switch item.assembly.request {
    case let .stormReports(state), let .rainfall(state): parts.append(WeatherReferenceNames.stateName(state))
    case let .forecastDiscussion(office): parts.append(WeatherReferenceNames.officeName(office))
    default: break
    }
    // Nobody here asked for it: it came off the channel, and for a product asked for by area
    // there is nothing in the chunk that says which area (docs/MESHWX_UI.md §3.1 U-15).
    if !choice.isOwn {
      parts.append(L10n.Weather.Weather.Reports.overheard)
      if choice.isUnknownArea { parts.append(L10n.Weather.Weather.Reports.unknownArea) }
    }
    parts.append(model.botName(item.botID))
    return parts.joined(separator: " · ")
  }

  /// When this phone received the text on screen — the one time the card has, at the right of its
  /// label the way the forecast's issue time is (docs/MESHWX_UI.md §4).
  private func received(_ choice: WeatherReportSelection.Choice) -> String {
    L10n.Weather.Weather.Reports.received(WeatherFormatting.clockTime(
      choice.item.assembly.lastReceivedAt, now: screen.now, calendar: .autoupdatingCurrent,
      locale: .autoupdatingCurrent))
  }
}

/// The state storm reports and rainfall ask for on one page, for this visit.
struct WeatherStatePickerView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appTheme) private var theme

  let screen: WeatherPageScreen

  var body: some View {
    let states = WeatherReferenceNames.requestableStates(from: MeshWXTables.shared.states)
    List {
      Section {
        ForEach(states, id: \.self) { code in
          Button {
            screen.model.setReportState(code, forPageID: screen.pageID)
            dismiss()
          } label: {
            HStack {
              Text(WeatherReferenceNames.stateName(code))
                .foregroundStyle(.primary)
              Spacer()
              if screen.reportState == code {
                Image(systemName: "checkmark")
                  .foregroundStyle(.tint)
                  .accessibilityLabel(L10n.Weather.Weather.Common.selected)
              }
            }
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
        }
      }
      .themedRowBackground(theme)
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
    .navigationTitle(L10n.Weather.Weather.Reports.stateTitle)
    .navigationBarTitleDisplayMode(.inline)
    .weatherToolChrome()
  }
}
