import SwiftUI

/// The "What's New" sheet. Non-safety chrome, so glass on the footer buttons is
/// allowed; Continue, Support Avi0n, and swipe-to-dismiss share one dismiss path that
/// persists the baseline. Below the items, the credit: this app is a fork of Avi0n's
/// MeshCore One, and support goes to Avi0n's GitHub Sponsors (``ForkCredit``).
struct WhatsNewSheet: View {
  let release: WhatsNewRelease

  @Environment(\.openURL) private var openURL
  @Environment(\.dismiss) private var dismiss

  fileprivate enum Metrics {
    static let titleTopPadding: CGFloat = 32
    static let rowSpacing: CGFloat = 28
    static let titleToRowsSpacing: CGFloat = 36
    static let symbolColumnWidth: CGFloat = 44
    static let symbolToTextSpacing: CGFloat = 16
    static let titleToBodySpacing: CGFloat = 4
    static let buttonSpacing: CGFloat = 12
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Metrics.titleToRowsSpacing) {
        Text(L10n.WhatsNew.WhatsNew.title)
          .font(.largeTitle.bold())
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity, alignment: .center)
          .accessibilityHeading(.h1)
          .padding(.top, Metrics.titleTopPadding)

        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
          ForEach(release.items) { item in
            WhatsNewRow(item: item)
          }
        }

        credit
      }
      .padding()
    }
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: Metrics.buttonSpacing) {
        Button {
          supportMeTapped()
        } label: {
          Label {
            Text(L10n.WhatsNew.WhatsNew.supportButton)
          } icon: {
            Image(systemName: "heart")
              .foregroundStyle(.red)
          }
          .font(.headline)
          .frame(maxWidth: .infinity)
          .padding()
        }
        .liquidGlassSecondaryButtonStyle()

        Button {
          dismiss()
        } label: {
          Text(L10n.WhatsNew.WhatsNew.continueButton)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
        }
        .liquidGlassProminentButtonStyle()
      }
      .padding()
    }
    .presentationDragIndicator(.hidden)
  }

  private var credit: some View {
    VStack(alignment: .leading, spacing: Metrics.titleToBodySpacing) {
      Text(L10n.WhatsNew.WhatsNew.Credit.title)
        .font(.headline)
      Text(L10n.WhatsNew.WhatsNew.Credit.body)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Link(L10n.WhatsNew.WhatsNew.Credit.upstreamNotes, destination: release.releaseNotesURL)
        .font(.subheadline)
        .padding(.top, Metrics.titleToBodySpacing)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func supportMeTapped() {
    openURL(ForkCredit.sponsorsURL)
    dismiss()
  }
}

/// A decorative SF Symbol plus the feature's title and description; VoiceOver reads
/// the pair as one element.
private struct WhatsNewRow: View {
  let item: WhatsNewItem

  var body: some View {
    HStack(alignment: .top, spacing: WhatsNewSheet.Metrics.symbolToTextSpacing) {
      Image(systemName: item.symbol)
        .font(.title)
        .foregroundStyle(.tint)
        .scaleEffect(y: item.flipsSymbolVertically ? -1 : 1)
        .frame(width: WhatsNewSheet.Metrics.symbolColumnWidth)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: WhatsNewSheet.Metrics.titleToBodySpacing) {
        Text(item.title)
          .font(.headline)
        Text(item.description)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}

#Preview {
  if let release = WhatsNewCatalog.releases.first {
    Color.clear.sheet(isPresented: .constant(true)) {
      WhatsNewSheet(release: release)
    }
    .environment(\.appState, AppState())
  }
}
