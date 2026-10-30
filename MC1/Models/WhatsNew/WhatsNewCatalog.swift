import Foundation

/// Per-release What's New notes, keyed by the `major.minor` they belong to. Add a
/// release as one `WhatsNewRelease` plus its `L10n` strings; it presents once on upgrade.
/// These are DigitainoMesh's notes: the fork's own changes first, then what the MeshCore One
/// release underneath brought that testers will notice.
enum WhatsNewCatalog {
  static let releases: [WhatsNewRelease] = [
    WhatsNewRelease(
      version: WhatsNewVersion(major: 1, minor: 6),
      items: [
        WhatsNewItem(
          symbol: "cloud.sun",
          title: L10n.WhatsNew.WhatsNew.WeatherBots.title,
          description: L10n.WhatsNew.WhatsNew.WeatherBots.description
        ),
        WhatsNewItem(
          symbol: "star",
          title: L10n.WhatsNew.WhatsNew.FavoritesEveryRadio.title,
          description: L10n.WhatsNew.WhatsNew.FavoritesEveryRadio.description
        ),
        WhatsNewItem(
          symbol: "pin",
          title: L10n.WhatsNew.WhatsNew.PinnedChats.title,
          description: L10n.WhatsNew.WhatsNew.PinnedChats.description
        ),
        WhatsNewItem(
          symbol: "envelope.badge",
          title: L10n.WhatsNew.WhatsNew.ReadAndUnread.title,
          description: L10n.WhatsNew.WhatsNew.ReadAndUnread.description
        ),
        WhatsNewItem(
          symbol: "slider.horizontal.3",
          title: L10n.WhatsNew.WhatsNew.AdvancedMapFilters.title,
          description: L10n.WhatsNew.WhatsNew.AdvancedMapFilters.description
        ),
        // Flipping the landscape glyph puts its home indicator on top, which is the tab bar.
        WhatsNewItem(
          symbol: "ipad.landscape",
          title: L10n.WhatsNew.WhatsNew.IPadTabBar.title,
          description: L10n.WhatsNew.WhatsNew.IPadTabBar.description,
          flipsSymbolVertically: true
        ),
        WhatsNewItem(
          symbol: "arrow.left.arrow.right",
          title: L10n.WhatsNew.WhatsNew.BluetoothAndWiFi.title,
          description: L10n.WhatsNew.WhatsNew.BluetoothAndWiFi.description
        )
      ],
      // Upstream's iPhone Duo item is left out (untested here), and so is its "More changes",
      // which points at a link this sheet replaces with the credit section.
      releaseNotesURL: URL(string: "https://github.com/Avi0n/MeshCoreOne/releases/tag/v1.6.0")!
    ),
    WhatsNewRelease(
      version: WhatsNewVersion(major: 1, minor: 5),
      items: [
        WhatsNewItem(
          symbol: "arrow.left.arrow.right.circle",
          title: L10n.WhatsNew.WhatsNew.RadioSwap.title,
          description: L10n.WhatsNew.WhatsNew.RadioSwap.description
        ),
        WhatsNewItem(
          symbol: "cloud.bolt.rain",
          title: L10n.WhatsNew.WhatsNew.RadarLoops.title,
          description: L10n.WhatsNew.WhatsNew.RadarLoops.description
        ),
        WhatsNewItem(
          symbol: "point.topleft.down.to.point.bottomright.curvepath",
          title: L10n.WhatsNew.WhatsNew.PathDetails.title,
          description: L10n.WhatsNew.WhatsNew.PathDetails.description
        ),
        WhatsNewItem(
          symbol: "face.smiling",
          title: L10n.WhatsNew.WhatsNew.Reactions.title,
          description: L10n.WhatsNew.WhatsNew.Reactions.description
        ),
        WhatsNewItem(
          symbol: "bolt",
          title: L10n.WhatsNew.WhatsNew.FasterChatLoading.title,
          description: L10n.WhatsNew.WhatsNew.FasterChatLoading.description
        )
      ],
      // Upstream's notes for the MeshCore One release this one is built on.
      releaseNotesURL: URL(string: "https://github.com/Avi0n/MeshCoreOne/releases/tag/v1.5.0")!
    )
  ]
}
