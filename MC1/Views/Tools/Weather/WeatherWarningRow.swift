import MC1Services
import MeshWX
import SwiftUI

/// Everything active in the selected bot's coverage, plus the two ways the app recovers from
/// packets it missed (spec §5): the digest, and the identities the digest lists that never
/// arrived as warnings.
struct WeatherWarningsSection: View {
  @Environment(\.appTheme) private var theme

  let model: WeatherToolModel

  var body: some View {
    Section(L10n.Weather.Weather.Warnings.section) {
      if model.activeWarnings.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text(L10n.Weather.Weather.Warnings.none)
          Text(lastDigestText)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      } else {
        ForEach(model.activeWarnings, id: \.identity) { stored in
          NavigationLink {
            WeatherWarningDetailView(model: model, identity: stored.identity)
          } label: {
            WeatherWarningRow(stored: stored, tables: model.tables, now: model.now)
          }
        }
      }

      if model.needsDigest {
        recoveryRow(
          text: L10n.Weather.Weather.Warnings.needsDigest,
          buttonTitle: L10n.Weather.Weather.Warnings.getDigest,
          request: .digest
        )
      }

      ForEach(model.missingFromDigest, id: \.self) { identity in
        if let identityString = model.identityString(identity) {
          recoveryRow(
            text: L10n.Weather.Weather.Warnings.missing,
            buttonTitle: L10n.Weather.Weather.Warnings.fetch,
            request: .warning(identity: identityString)
          )
        } else {
          // No bundle row for the event or office: the identity cannot be spelled the way
          // the bot parses it, so the list says what is missing and offers nothing false.
          Text(L10n.Weather.Weather.Warnings.missing)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
    }
    .themedRowBackground(theme)
  }

  private func recoveryRow(text: String, buttonTitle: String, request: WeatherRequest) -> some View {
    HStack {
      Text(text)
        .font(.subheadline)
      Spacer(minLength: 12)
      WeatherRequestButton(title: buttonTitle, model: model, request: request)
    }
  }

  private var lastDigestText: String {
    guard let receivedAt = model.botState?.digest?.receivedAt else {
      return L10n.Weather.Weather.Warnings.noDigestYet
    }
    return L10n.Weather.Weather.Warnings.lastDigest(receivedAt.formatted(.relative(presentation: .named)))
  }
}

/// One watch, warning or advisory, in the three lines spec §10.2 asks for: what and when, the
/// storm tags, and the ground it covers.
struct WeatherWarningRow: View {
  let stored: WeatherStoredWarning
  let tables: MeshWXTables
  let now: Date

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: MeshWXPresentation.symbolName(forVTEC: vtec))
        .font(.title3)
        .foregroundStyle(tint)
        .frame(width: 28)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(eventName)
          .font(.headline)
        Text(headline)
          .font(.footnote)
          .foregroundStyle(.secondary)
        if !tagText.isEmpty {
          Text(tagText)
            .font(.footnote)
        }
        if !areaText.isEmpty {
          Text(areaText)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var vtec: String {
    tables.vtec(for: stored.warning.event) ?? ""
  }

  private var tint: Color {
    WeatherFormatting.color(for: MeshWXPresentation.tint(forVTEC: vtec))
  }

  private var eventName: String {
    tables.eventName(for: stored.warning.event)?.long ?? tables.eventLabel(for: stored.warning.event)
  }

  private var headline: String {
    let office = tables.officeLabel(stored.warning.office)
    let expiry = WeatherFormatting.expiry(expiresMinutes: stored.warning.expiresMinutes, now: now)
    return "\(office) · \(expiry)"
  }

  private var tagText: String {
    WeatherFormatting.tagTexts(for: stored.warning).joined(separator: " · ")
  }

  /// Three names and a count. A winter storm covering twenty zones is a paragraph otherwise,
  /// and the full list is one tap away in the detail.
  private var areaText: String {
    let areas = tables.namedAreas(for: stored.warning)
    guard !areas.isEmpty else { return "" }
    let shown = areas.prefix(3).map(WeatherFormatting.areaName)
    guard areas.count > shown.count else { return shown.joined(separator: ", ") }
    let more = L10n.Weather.Weather.Warnings.andMore(areas.count - shown.count)
    return shown.joined(separator: ", ") + ", " + more
  }
}
