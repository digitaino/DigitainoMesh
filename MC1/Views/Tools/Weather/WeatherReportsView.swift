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

  @MainActor
  func description(model: WeatherToolModel) -> String {
    switch self {
    case .discussion:
      model.context.placeOffice.map { L10n.Weather.Weather.Reports.Discussion.description(WeatherReferenceNames.officeName($0)) }
        ?? L10n.Weather.Weather.Reports.Discussion.descriptionNoPlace
    case .outlook:
      L10n.Weather.Weather.Reports.Outlook.description(model.sourceName)
    case .stormReports:
      L10n.Weather.Weather.Reports.Storms.description
    case .rainfall:
      L10n.Weather.Weather.Reports.Rainfall.description
    case .spaceWeather:
      L10n.Weather.Weather.Reports.Space.description
    }
  }

  /// The request, with its argument from the place; nil when the place gives none.
  @MainActor
  func request(model: WeatherToolModel) -> WeatherRequest? {
    switch self {
    case .discussion: model.context.placeOffice.map { .forecastDiscussion(office: $0) }
    case .outlook: .hazardousOutlook
    case .stormReports: model.reportState.map { .stormReports(state: $0) }
    case .rainfall: model.reportState.map { .rainfall(state: $0) }
    case .spaceWeather: .spaceWeather
    }
  }
}

struct WeatherReportsView: View {
  @Environment(\.appTheme) private var theme

  let model: WeatherToolModel

  var body: some View {
    List {
      Section {
        Text(L10n.Weather.Weather.Reports.intro(WeatherFormatting.sentenceStart(model.sourceName)))
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .themedRowBackground(theme)

      Section {
        productLink(.discussion)
        productLink(.outlook)
      }
      .themedRowBackground(theme)

      Section {
        NavigationLink {
          WeatherStatePickerView(model: model)
        } label: {
          Text(L10n.Weather.Weather.Reports.stateRow(
            model.reportState.map(WeatherReferenceNames.stateName) ?? L10n.Weather.Weather.Reports.noState))
        }
        productLink(.stormReports)
        productLink(.rainfall)
      } header: {
        Text(L10n.Weather.Weather.Reports.byState)
      }
      .themedRowBackground(theme)

      Section {
        productLink(.spaceWeather)
      }
      .themedRowBackground(theme)
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
    .navigationTitle(L10n.Weather.Weather.Reports.title)
    .navigationBarTitleDisplayMode(.inline)
    .weatherPendingBar(model: model, requestsOnScreen: [])
  }

  private func productLink(_ product: WeatherReportProduct) -> some View {
    NavigationLink {
      WeatherReportProductView(model: model, product: product)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(product.title)
          .font(.headline)
        Text(product.description(model: model))
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
    }
  }
}

/// One product: the newest text this phone asked for, else the newest somebody else asked for.
struct WeatherReportProductView: View {
  @Environment(\.appTheme) private var theme

  let model: WeatherToolModel
  let product: WeatherReportProduct

  var body: some View {
    let texts = model.snapshot?.texts.filter { $0.assembly.subject == product.subject } ?? []
    let own = texts.first(where: \.isOwn)
    let overheard = own == nil ? texts.first : nil
    let request = product.request(model: model)

    List {
      Section {
        Text(product.description(model: model))
          .font(.subheadline)
          .foregroundStyle(.secondary)
        if let request {
          WeatherAskButton(
            model: model, title: L10n.Weather.Weather.Request.askLatest, request: request, showsFootnotes: true)
        } else {
          Text(L10n.Weather.Weather.Reports.needsPlace)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .themedRowBackground(theme)

      if let item = own ?? overheard {
        Section {
          Text(WeatherReportText.body(item.assembly))
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
        } header: {
          Text(header(item))
        } footer: {
          if !item.isOwn {
            Text(L10n.Weather.Weather.Reports.someoneElse)
          }
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
  }

  private func header(_ item: WeatherTextItem) -> String {
    let received = L10n.Weather.Weather.Reports.received(WeatherFormatting.clockTime(
      item.assembly.lastReceivedAt, now: model.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent))
    let subject: String? = switch item.assembly.request {
    case let .stormReports(state), let .rainfall(state): WeatherReferenceNames.stateName(state)
    case let .forecastDiscussion(office): WeatherReferenceNames.officeName(office)
    default: nil
    }
    guard let subject else { return received }
    return "\(subject) · \(received)"
  }
}

/// The state storm reports and rainfall ask for, for this visit.
struct WeatherStatePickerView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appTheme) private var theme

  let model: WeatherToolModel

  var body: some View {
    let states = WeatherReferenceNames.requestableStates(from: MeshWXTables.shared.states)
    List {
      Section {
        ForEach(states, id: \.self) { code in
          Button {
            model.reportStateOverride = code
            dismiss()
          } label: {
            HStack {
              Text(WeatherReferenceNames.stateName(code))
                .foregroundStyle(.primary)
              Spacer()
              if model.reportState == code {
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
  }
}
