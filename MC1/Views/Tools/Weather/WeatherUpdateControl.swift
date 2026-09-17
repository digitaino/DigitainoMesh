import MC1Services
import MeshWX
import SwiftUI

/// The Update button (docs/MESHWX_UI.md §11).
///
/// It is in the toolbar on a place screen and above the readings on a station screen, in the same
/// position whatever the screen holds. It plans the minimal request set from what the phone is
/// actually missing, says so before it sends anything, and sends the steps five seconds apart.
/// Pulling the list down runs the same plan (`WeatherToolModel.refresh`), which is why the caption
/// is a static: the pull has no button to hang it under and shows it at the top of the page.
struct WeatherUpdateControl: View {
  /// The page this Update is for. Everything it says and everything it sends is that page's:
  /// the toolbar's button belongs to the page the pager is on, and until that page has a build
  /// there is nothing to send and the button is disabled.
  let screen: WeatherPageScreen?
  let plan: WeatherUpdatePlan
  /// A station screen shows the caption under the button; a place screen shows it at the top of
  /// the list, where the pull reveals it.
  var showsCaption = false

  /// Nothing can be asked at all: the reason replaces the button (§3 A2), and it is said **once**.
  private var block: WeatherRequestBlock? { screen?.snapshot.requestBlock }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // The blocking reason and the caption used to be two views that printed the same sentence,
      // so every station screen said "Connect your radio to ask WX-AUS" twice, one line apart
      // (docs/MESHWX_UI.md §3.1 U-5). `caption` already returns the reason when there is one, so
      // the reason is the caption and there is only ever one of it.
      if showsCaption, block == nil {
        button
          .buttonStyle(.bordered)
      } else if !showsCaption {
        button
      }
      if showsCaption {
        Text(Self.caption(screen: screen, plan: plan))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityHidden(block == nil)
          .accessibilityIdentifier("weather.update.caption")
        if let screen, block == nil {
          WeatherAskFootnotes(screen: screen)
        }
      }
    }
    .padding(.vertical, showsCaption ? 2 : 0)
  }

  private var isUpdating: Bool { screen?.isUpdating ?? false }

  private var button: some View {
    Button {
      guard let screen else { return }
      screen.model.update(plan, pageID: screen.pageID)
    } label: {
      if showsCaption {
        HStack(spacing: 8) {
          if isUpdating { ProgressView() }
          Text(L10n.Weather.Weather.Update.button)
        }
      } else {
        // In the bottom toolbar the button is the word, not a glyph: Update spends airtime on
        // purpose, and a bare ↻ is the reflex tap every other app trains. The system sizes a bar
        // button's target itself (docs/MESHWX_UI.md §3.1 U-21).
        HStack(spacing: 6) {
          if isUpdating {
            ProgressView()
              .controlSize(.small)
          }
          Text(L10n.Weather.Weather.Update.button)
        }
      }
    }
    .disabled(plan.isEmpty || isUpdating || block != nil)
    .accessibilityLabel(L10n.Weather.Weather.Update.button)
    .accessibilityValue(Self.caption(screen: screen, plan: plan))
    .accessibilityIdentifier("weather.update.button")
  }

  /// What a tap or a pull will ask for; while a run is on the air, or just back, what it said;
  /// and, when nothing can be asked at all, the reason. A page still being built says nothing:
  /// there is no plan for it yet, and naming the last page's would be the bug this is here to
  /// prevent.
  static func caption(screen: WeatherPageScreen?, plan: WeatherUpdatePlan) -> String {
    guard let screen else { return "" }
    if let block = screen.snapshot.requestBlock {
      return WeatherCopy.requestBlocked(block, source: screen.sourceName)
    }
    if let status = screen.updateStatusText { return status }
    if !plan.isEmpty { return WeatherCopy.updateAsks(plan, source: screen.sourceName) }
    // Held back by the five-minute rule is not the same as current, and never claims to be.
    if !plan.justReceived.isEmpty { return WeatherCopy.updateJustReceived(source: screen.sourceName) }
    return WeatherCopy.everythingCurrent(
      source: screen.sourceName, asOf: plan.currentAsOf, now: screen.now,
      calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
  }
}
