# DigitainoMesh

**DigitainoMesh is an unofficial fork of [MeshCore One](https://github.com/Avi0n/MeshCoreOne) (formerly PocketMesh) by [Avi0n](https://github.com/Avi0n).**
Fork repository: <https://github.com/digitaino/DigitainoMesh>

It is not affiliated with or endorsed by the upstream project. The app is Avi0n's work; this fork only adds a few experiments on top, and is shared through TestFlight with a small group. It is not sold and takes no money.

**If you find it useful, please support Avi0n: <https://github.com/sponsors/Avi0n>.** The app itself is on the App Store as [MeshCore One](https://apps.apple.com/app/meshcore-one/id6757419477).

Everything in the upstream README below applies here too. The fork adds branding, its own bundle identity, and the features listed next.

## Fork status

This branch (`v2`) is a rebuild on top of upstream v1.3.0. The fork's own features are being **re-ported incrementally** onto upstream's current architecture rather than carried over wholesale:

- Signal bars (per-repeater link quality)
- Adaptive TX power
- Traffic heatmap
- Repeater benchmark and repeater watch
- Wio L1 Pro notification sync
- Message search
- Reactions
- Chat gestures

Signal Survey, weather, and route sharing from the previous fork line are **dropped for now** and will be reconsidered as separate, redesigned features. See [BETA_CHANGES.md](BETA_CHANGES.md) for the running beta log.

## Beta and feedback

Fork builds are distributed through TestFlight. Send feedback through TestFlight directly, or email <mesh@digitaino.com>. Please report problems with this fork here, not to the upstream project: the fork's bugs are not Avi0n's to field.

---

# MeshCore One (MC1)

A MeshCore client built for Apple devices in Swift.   
Disclaimer: Decisions are made by a human, but almost all code is created with AI.

Download from the App Store or sideload using unsigned IPA files under [Releases](https://github.com/Avi0n/MeshCoreOne/releases).

<a href="https://apps.apple.com/app/meshcore-one/id6757419477">
  <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" height="50">
</a>

## Features

### Messaging
- Direct messages with delivery status and flood retry
- Channels (public, private, and hashtag)
- Room Server connections with guest/participant modes
- Heard repeats tracking
- Message reactions (emoji)
- View Path Hops (list and map)
- Link previews and inline images
- Coordinate map previews
- @Mentions
- Per-conversation notification levels
- Hashtag channel deep links
- Blocking (contacts and channel sender names)

### Contacts
- Auto-discovery on the mesh
- QR code and advert sharing
- Favorites
- Zero-hop ping
- Telemetry fetch
- Edit Out Path

### Map
- Contact positions
- Map layers (standard, satellite, topography)
- Offline download

### Network Tools
- **Trace Path** - Route through specific repeaters with option to save paths
- **Line of Sight** - Terrain analysis with Fresnel zone and RF parameters
- **RX Log** - Live packet capture
- **Noise Floor Monitor** - Live dBm chart with signal quality stats
- **CLI Terminal** - Remote command-line access to repeaters and rooms

### Remote Node Management
- Node status (telemetry such as battery and uptime. Neighbors for repeaters)
- Remote repeater/room configuration (radio, behavior, identity, reboot)
- Telemetry history charts
- Admin and guest authentication for repeaters/rooms

### Companion Device
- Bluetooth and WiFi pairing
- Radio presets and manual tuning (frequency, TX power, spreading factor, bandwidth)
- Battery monitoring with OCV curves
- Repeat mode

### General
- Live Activity
- Themes
- Offline mesh networking (no internet required)
- Push notifications with quick reply
- Location sharing controls
- Config import/export
- App data backup/restore


## Requirements

-   **iOS/iPadOS 18.0+, or Apple Silicon Mac**
-   **Xcode 26.0+**
-   **MeshCore-compatible hardware**

## Getting Started

1.  Install [XcodeGen](https://github.com/yonaskolb/XcodeGen).
2.  Run `make generate` (creates a gitignored `dev.yml` — set your Apple team ID there for local signing).
3.  Open `MC1.xcodeproj`.

For more details, see the [Development Guide](docs/Development.md).

  
## License

MeshCore One - GNU General Public License v3.0   
Swift MeshCore - MIT
