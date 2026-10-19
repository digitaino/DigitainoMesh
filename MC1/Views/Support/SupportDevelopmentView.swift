import SwiftUI

/// Settings › Support the Developer. DigitainoMesh is an unofficial fork of MeshCore One, so
/// support goes to Avi0n, never to the fork. Upstream's tip jar and theme store are gone: in
/// this app they sold under the fork's own product IDs, so any money would have reached the
/// fork's account rather than the person who wrote the app.
struct SupportDevelopmentView: View {
  @Environment(\.appTheme) private var theme

  var body: some View {
    List {
      Section {
        Text(L10n.Settings.Support.Fork.body)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .themedRowBackground(theme)

      Section {
        linkRow(L10n.Settings.Support.Fork.sponsor, systemImage: "heart", destination: ForkCredit.sponsorsURL)
        linkRow(
          L10n.Settings.Support.Fork.upstream,
          systemImage: "chevron.left.forwardslash.chevron.right",
          destination: ForkCredit.upstreamRepositoryURL
        )
      } footer: {
        Text(L10n.Settings.Support.Fork.footer)
      }
      .themedRowBackground(theme)
    }
    .themedCanvas(theme)
    .navigationTitle(L10n.Settings.Support.title)
    .navigationBarTitleDisplayMode(.inline)
  }

  private func linkRow(_ title: String, systemImage: String, destination: URL) -> some View {
    Link(destination: destination) {
      HStack {
        TintedLabel(title, systemImage: systemImage)
        Spacer()
        Image(systemName: "arrow.up.right")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .foregroundStyle(.primary)
  }
}

#Preview {
  NavigationStack {
    SupportDevelopmentView()
  }
}
