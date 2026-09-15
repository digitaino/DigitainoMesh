import MC1Services
import MeshWX
import SwiftUI

/// A button that puts one request on the air, with the request's status in place
/// (docs/MESHWX_UI.md §11).
///
/// A blocking reason replaces the button. From the tap until the answer, the button is disabled
/// with a spinner, and every other button is disabled and says so. `showsFootnotes` marks the
/// first ask button on a screen: it carries the "everyone gets the answer" note and the quiet-bot
/// caption.
struct WeatherAskButton: View {
  let model: WeatherToolModel
  let title: String
  let request: WeatherRequest
  var showsFootnotes = false

  var body: some View {
    let status = model.status(for: request)
    let text = model.statusText(for: request)
    VStack(alignment: .leading, spacing: 4) {
      if case .blocked = status {
        Text(text ?? "")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else if isAskable(status), let reply = model.freshOwnedReply(for: request) {
        Text(text ?? WeatherCopy.ownedReply(
          source: model.botName(reply.botID), at: reply.assembly.lastReceivedAt, now: model.now,
          calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent))
        .font(.footnote)
        .foregroundStyle(.secondary)
      } else {
        Button {
          Task { await model.send(request) }
        } label: {
          HStack(spacing: 8) {
            if case .pending = status {
              ProgressView()
            }
            Text(title)
          }
        }
        .buttonStyle(.borderless)
        .disabled(isDisabled(status))
        .accessibilityValue(text ?? "")

        if let text {
          Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        if showsFootnotes {
          WeatherAskFootnotes(model: model)
        }
      }
    }
  }

  private func isAskable(_ status: WeatherRequestStatus) -> Bool {
    switch status {
    case .idle, .settled: true
    case .pending, .waitingForOther, .blocked: false
    }
  }

  private func isDisabled(_ status: WeatherRequestStatus) -> Bool {
    switch status {
    case .pending, .waitingForOther, .blocked: true
    case .idle, .settled: false
    }
  }
}

/// "Everyone listening on #meshwx gets the answer." and, for a quiet bot, that it may not answer.
struct WeatherAskFootnotes: View {
  let model: WeatherToolModel

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(L10n.Weather.Weather.Request.publicNote)
        .font(.caption)
        .foregroundStyle(.secondary)
      if let since = model.snapshot?.sourceQuietSince {
        Text(WeatherCopy.quietCaption(
          source: model.sourceName, since: since, now: model.now, calendar: .autoupdatingCurrent,
          locale: .autoupdatingCurrent))
        .font(.caption)
        .foregroundStyle(.orange)
      }
    }
  }
}

/// A request on the air whose button is not on this screen, in a bar that stays in view above
/// the bottom edge rather than a row that scrolls away.
struct WeatherPendingBar: View {
  let model: WeatherToolModel
  let requestsOnScreen: Set<WeatherRequest>

  var body: some View {
    if let request = model.activeRequest, !requestsOnScreen.contains(request),
       let text = model.statusText(for: request) {
      HStack(spacing: 10) {
        ProgressView()
        Text(text)
          .font(.subheadline)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .liquidGlass(in: .capsule)
      .padding(.horizontal, 16)
      .padding(.bottom, 8)
      .accessibilityElement(children: .combine)
    }
  }
}

extension View {
  func weatherPendingBar(model: WeatherToolModel, requestsOnScreen: Set<WeatherRequest>) -> some View {
    safeAreaInset(edge: .bottom) {
      WeatherPendingBar(model: model, requestsOnScreen: requestsOnScreen)
    }
  }
}

/// "Where do you want weather for?" with the two ways to answer it.
struct WeatherPlacePrompt: View {
  let onUseMyLocation: () -> Void
  let onSearch: () -> Void

  var body: some View {
    // Stacked, always: side by side the two labels do not fit a phone row, and every attempt to
    // choose a layout by measuring wrapped, truncated or collapsed one of them.
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.Weather.Weather.Place.prompt)
        .font(.headline)
      Button(action: onUseMyLocation) {
        Label(L10n.Weather.Weather.Place.useMyLocation, systemImage: "location")
      }
      .buttonStyle(.bordered)
      Button(action: onSearch) {
        Label(L10n.Weather.Weather.Place.searchTown, systemImage: "magnifyingglass")
      }
      .buttonStyle(.bordered)
    }
    .padding(.vertical, 4)
  }
}
