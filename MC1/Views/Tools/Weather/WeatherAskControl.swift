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
  /// The page this button is on, so the bot it names and the reason it is blocked are that
  /// page's and not the pager's last build (docs/MESHWX_UI.md §13).
  let screen: WeatherPageScreen
  let title: String
  let request: WeatherRequest
  var showsFootnotes = false
  /// This button is the screen's own voice for why nothing can be asked. False on a screen that
  /// already says it once — the station screen's Update control carries it above these buttons,
  /// and METAR and TAF printed the same sentence twice more under it (docs/MESHWX_UI.md §3.1
  /// U-24). The button then stays, disabled, which is the same fact without the third telling.
  var showsBlockReason = true

  private var model: WeatherToolModel { screen.model }

  var body: some View {
    let status = model.status(for: request)
    let text = model.statusText(for: request, source: screen.sourceName)
    let saysBlock = isBlocked(status) && showsBlockReason
    VStack(alignment: .leading, spacing: 4) {
      if saysBlock {
        Text(text ?? "")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else if isAskable(status), let reply = model.freshOwnedReply(for: request) {
        // Named from the reply's own bot: the answer on screen came from whoever sent it.
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

        // The blocked text is the screen's, not this row's, whenever the screen says it itself:
        // the button's accessibility value still carries it, so VoiceOver is not left guessing
        // why the button is disabled.
        if let text, !isBlocked(status) {
          Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        if showsFootnotes {
          WeatherAskFootnotes(screen: screen)
        }
      }
    }
  }

  private func isBlocked(_ status: WeatherRequestStatus) -> Bool {
    if case .blocked = status { return true }
    return false
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
  let screen: WeatherPageScreen

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(L10n.Weather.Weather.Request.publicNote)
        .font(.caption)
        .foregroundStyle(.secondary)
      if let since = screen.snapshot.sourceQuietSince {
        Text(WeatherCopy.quietCaption(
          source: screen.sourceName, since: since, now: screen.now, calendar: .autoupdatingCurrent,
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

  /// Every screen of the tool — the pager and everything pushed over it — takes the app's tab bar
  /// off the screen while it is up (docs/MESHWX_UI.md §4).
  ///
  /// The tool owns the bottom edge. The place pages put Places, the page dots and Update there
  /// in a bottom toolbar of the system's own, the way Apple Weather and Photos do, and a pushed
  /// screen simply ends at the home indicator. The tool's own glass capsule floating over the
  /// app's glass tab bar was two bars stacked at the foot of every page — the "disjointed" the
  /// owner named on 16 September — and the 49 pt inset every pushed screen carried to stay clear
  /// of the tab bar goes with it. Chats does the same inside a conversation, and the mapper
  /// during a ride.
  func weatherToolChrome() -> some View {
    toolbar(.hidden, for: .tabBar)
  }
}
