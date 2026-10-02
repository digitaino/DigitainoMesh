import MC1Services
import MeshWX
import SwiftUI

/// The one request a pushed screen spends airtime on, asked from the bottom bar
/// (docs/MESHWX_UI.md §3.1 U-51).
///
/// Every screen of the tool now asks from the same place. The place pages had Update at the
/// bottom right since §3.1.2 V-2, but every screen pushed from them put its Ask at the foot of
/// its own list: the radar's under the legend, the alert map's under every part, kind and swatch,
/// the alerts list's under every alert. The answer lands at the **top** of those screens, so a
/// tap meant a scroll down and a scroll back up to see what it did — the owner's words, 1 October.
/// The bar is free on every pushed screen (`weatherToolChrome()` hides the app's tab bar), so the
/// Ask sits where Update does, and what it is doing is said beside the answer, not the button.
struct WeatherBarAsk: Equatable {
  var title: String
  var request: WeatherRequest
}

/// Whether the row a screen's answer lands in is on screen. Written by the row itself
/// (`weatherAskResult()`), read by the bar to decide whether to offer the way back up.
@MainActor
@Observable
final class WeatherAskAnchor {
  /// The `id` the answer's row carries, so the capsule can scroll to it.
  static let rowID = "weather.ask.result"

  /// Unknown counts as visible: the capsule is for an answer the reader cannot see, and a row
  /// that has never reported is one the list has not scrolled anywhere yet.
  var isResultVisible = true
}

extension EnvironmentValues {
  @Entry var weatherAskAnchor: WeatherAskAnchor?
}

extension View {
  /// The screen's Ask in the bottom bar, and the capsule that says what it did when its answer
  /// is scrolled out of view. Apply to the screen's `List`, inside `weatherToolChrome()`.
  func weatherAskBar(screen: WeatherPageScreen, ask: WeatherBarAsk?) -> some View {
    modifier(WeatherAskBarModifier(screen: screen, ask: ask))
  }

  /// Marks the row the screen's answer lands in: the capsule's **Show** scrolls here.
  func weatherAskResult() -> some View {
    modifier(WeatherAskResultModifier())
  }
}

private struct WeatherAskResultModifier: ViewModifier {
  @Environment(\.weatherAskAnchor) private var anchor

  func body(content: Content) -> some View {
    content
      .id(WeatherAskAnchor.rowID)
      .onScrollVisibilityChange(threshold: 0.25) { isVisible in
        anchor?.isResultVisible = isVisible
      }
  }
}

private struct WeatherAskBarModifier: ViewModifier {
  let screen: WeatherPageScreen
  let ask: WeatherBarAsk?

  @State private var anchor = WeatherAskAnchor()
  /// The request this screen sent and is still telling the reader about: set on the tap,
  /// cleared once its outcome has been seen or has sat in the capsule long enough to be read.
  @State private var told: WeatherRequest?
  /// When the outcome arrived, so the capsule can step down a few seconds later.
  @State private var settledAt: Date?

  private var model: WeatherToolModel { screen.model }

  func body(content: Content) -> some View {
    ScrollViewReader { proxy in
      content
        .environment(\.weatherAskAnchor, anchor)
        // An overlay, not an inset: a map at the top of the screen must not resize under a
        // capsule that comes and goes (docs/MESHWX_UI.md §3.1 U-33).
        .overlay(alignment: .bottom) {
          if let told, !anchor.isResultVisible {
            capsule(told, proxy: proxy)
              .transition(.move(edge: .bottom).combined(with: .opacity))
          }
        }
        .animation(.default, value: told)
        .animation(.default, value: anchor.isResultVisible)
        .modifier(WeatherAskBarToolbar(screen: screen, ask: ask, onAsk: send))
        .onChange(of: phase) { _, phase in
          guard told != nil else { return }
          switch phase {
          case .settled:
            settledAt = Date()
          case .pending:
            settledAt = nil
          case .other:
            // Another screen's request, or the status aged out: nothing left to say here.
            told = nil
            settledAt = nil
          }
        }
        // Seen it: the answer's row came into view after the outcome arrived.
        .onChange(of: anchor.isResultVisible) { _, isVisible in
          if isVisible, settledAt != nil {
            told = nil
            settledAt = nil
          }
        }
        .task(id: settledAt) {
          guard settledAt != nil else { return }
          try? await Task.sleep(for: .seconds(8))
          guard !Task.isCancelled else { return }
          told = nil
          settledAt = nil
        }
    }
  }

  /// What the capsule follows: on the air, back, or nothing to do with this screen's ask.
  private enum Phase: Equatable { case pending, settled, other }

  private var phase: Phase {
    guard let told else { return .other }
    switch model.status(for: told) {
    case .pending: return .pending
    case .settled: return .settled
    case .idle, .blocked, .waitingForOther: return .other
    }
  }

  private func send() {
    guard let ask else { return }
    told = ask.request
    settledAt = nil
    Task { await model.send(ask.request) }
  }

  private func capsule(_ request: WeatherRequest, proxy: ScrollViewProxy) -> some View {
    let status = model.status(for: request)
    let isPending: Bool = if case .pending = status { true } else { false }
    return HStack(spacing: 10) {
      if isPending {
        ProgressView()
      }
      Text(model.statusText(for: request, source: screen.sourceName) ?? "")
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 4)
      Button {
        withAnimation {
          proxy.scrollTo(WeatherAskAnchor.rowID, anchor: .top)
        }
      } label: {
        Label(L10n.Weather.Weather.AskBar.show, systemImage: "arrow.up")
          .font(.subheadline.weight(.semibold))
      }
      .buttonStyle(.borderless)
      .accessibilityHint(L10n.Weather.Weather.AskBar.showHint)
      .accessibilityIdentifier("weather.ask.show")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .liquidGlass(in: .capsule)
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.updatesFrequently)
  }
}

/// The Ask itself, in the system's bottom bar at the trailing edge — Update's position on a place
/// page (`WeatherBottomToolbar`). The branch is on the OS, fixed for the life of the process.
private struct WeatherAskBarToolbar: ViewModifier {
  let screen: WeatherPageScreen
  let ask: WeatherBarAsk?
  let onAsk: () -> Void

  func body(content: Content) -> some View {
    if let ask {
      if #available(iOS 26, *) {
        content.toolbar {
          ToolbarSpacer(.flexible, placement: .bottomBar)
          ToolbarItem(placement: .bottomBar) {
            WeatherAskBarButton(screen: screen, ask: ask, onAsk: onAsk)
          }
        }
      } else {
        content.toolbar {
          ToolbarItemGroup(placement: .bottomBar) {
            Spacer()
            WeatherAskBarButton(screen: screen, ask: ask, onAsk: onAsk)
          }
        }
      }
    } else {
      content
    }
  }
}

private struct WeatherAskBarButton: View {
  let screen: WeatherPageScreen
  let ask: WeatherBarAsk
  let onAsk: () -> Void

  var body: some View {
    let model = screen.model
    let status = model.status(for: ask.request)
    let isPending: Bool = if case .pending = status { true } else { false }
    Button(action: onAsk) {
      HStack(spacing: 6) {
        if isPending {
          ProgressView()
            .controlSize(.small)
        }
        Text(ask.title)
          .lineLimit(1)
      }
    }
    // A complete reply this phone owns, under five minutes old, stands in for the button (§11.2):
    // the status row beside the answer says so.
    .disabled(!status.isAskable || model.freshOwnedReply(for: ask.request) != nil)
    .accessibilityValue(model.statusText(for: ask.request, source: screen.sourceName) ?? "")
    .accessibilityIdentifier("weather.ask.bar")
  }
}

/// What a bar Ask is doing, said beside the answer it is for (§11.2): the blocking reason, the
/// status while it is on the air and for five minutes after, and before a tap what it costs and
/// that everyone gets the answer. The shape every inline Ask had, without the button.
struct WeatherAskStatusRow: View {
  let screen: WeatherPageScreen
  let request: WeatherRequest
  /// "1 packet", said before the tap and never after it.
  var cost: String?
  /// One more quiet line before the tap: the radar's "Pictures are made about every 15 minutes."
  var note: String?
  /// False when the screen already says why nothing can be asked (§3.1 U-24).
  var showsBlockReason = true

  var body: some View {
    let model = screen.model
    let status = model.status(for: request)
    let text = model.statusText(for: request, source: screen.sourceName)
    VStack(alignment: .leading, spacing: 4) {
      switch status {
      case .blocked:
        if showsBlockReason, let text {
          Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      case .pending:
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(text ?? "")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
      case .waitingForOther:
        Text(text ?? "")
          .font(.footnote)
          .foregroundStyle(.secondary)
      case .idle, .settled:
        if let reply = model.freshOwnedReply(for: request) {
          Text(text ?? WeatherCopy.ownedReply(
            source: model.botName(reply.botID), at: reply.assembly.lastReceivedAt, now: model.now,
            calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent))
          .font(.footnote)
          .foregroundStyle(.secondary)
        } else {
          if let text {
            Text(text)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          if let cost {
            Text(cost)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          if let note {
            Text(note)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          WeatherAskFootnotes(screen: screen)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("weather.ask.status")
  }
}
