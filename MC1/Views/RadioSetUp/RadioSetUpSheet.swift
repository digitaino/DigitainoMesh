import MC1Services
import SwiftUI

/// Asked of a blank radio once it has synced: set it up as one of the user's saved nodes, or
/// keep it as the new node it is (docs/RADIO_SWAP.md, flow B). Setting it up writes only the
/// key here; the radio then reconnects as that node and the usual "Copy to This Radio" screen
/// follows, listing everything else that will be written.
struct RadioSetUpSheet: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme

  let setUp: PendingRadioSetUp

  @State private var confirming: SavedIdentity?

  private var prompt: RadioSetUpPromptState {
    appState.radioSetUpPrompt
  }

  var body: some View {
    NavigationStack {
      List {
        switch prompt.phase {
        case .asking:
          askingContent
        case let .settingUp(nodeName):
          Section {
            HStack(spacing: 12) {
              ProgressView()
              Text(L10n.Settings.RadioSetUp.settingUp(nodeName))
            }
          } footer: {
            Text(L10n.Settings.RadioSetUp.settingUpFooter)
          }
          .themedRowBackground(theme)
        case let .failed(message):
          Section {
            Label(message, systemImage: "exclamationmark.triangle")
          } footer: {
            Text(L10n.Settings.RadioSetUp.failedFooter)
          }
          .themedRowBackground(theme)
        }
      }
      .themedCanvas(theme)
      .navigationTitle(L10n.Settings.RadioSetUp.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if case .failed = prompt.phase {
          ToolbarItem(placement: .confirmationAction) {
            Button(L10n.Localizable.Common.done) { prompt.close() }
          }
        }
      }
      .alert(
        L10n.Settings.RadioSetUp.Confirm.title(confirming?.nodeName ?? ""),
        isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
        presenting: confirming
      ) { identity in
        Button(L10n.Localizable.Common.cancel, role: .cancel) {}
        Button(L10n.Settings.RadioSetUp.Confirm.button) {
          Task { await appState.setUpConnectedRadio(as: identity) }
        }
      } message: { identity in
        Text(L10n.Settings.RadioSetUp.Confirm.message(setUp.radioName, identity.nodeName))
      }
    }
    .interactiveDismissDisabled(isSettingUp)
  }

  @ViewBuilder
  private var askingContent: some View {
    Section {
      Text(L10n.Settings.RadioSetUp.body(setUp.radioName))
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .themedRowBackground(theme)

    Section {
      ForEach(setUp.candidates) { identity in
        Button {
          confirming = identity
        } label: {
          Label(L10n.Settings.RadioSetUp.setUpAs(identity.nodeName), systemImage: "arrow.left.arrow.right.circle")
        }
      }
    } footer: {
      Text(L10n.Settings.RadioSetUp.setUpFooter)
    }
    .themedRowBackground(theme)

    Section {
      Button(L10n.Settings.RadioSetUp.useAsNewNode) {
        prompt.decline()
      }
    } footer: {
      Text(L10n.Settings.RadioSetUp.useAsNewNodeFooter)
    }
    .themedRowBackground(theme)
  }

  private var isSettingUp: Bool {
    if case .settingUp = prompt.phase { return true }
    return false
  }
}
