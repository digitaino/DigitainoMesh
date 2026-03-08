# PocketMesh (Fork)

A personal fork of [PocketMesh](https://github.com/Avi0n/PocketMesh), an unofficial MeshCore client built for iOS in Swift.

> **Note:** This is an independent fork. For the official app, TestFlight beta, and releases, visit the [upstream repository](https://github.com/Avi0n/PocketMesh).

## Fork Additions

Features added in this fork on top of upstream:

- **Message Route Map** — Visualize the geographic path a specific message took through mesh repeaters on an interactive map with hop-by-hop detail
- **Traffic Map** — Aggregate received RF packets over selectable time windows (1h, 24h, 7d, all time) and visualize mesh traffic patterns with sized/colored bubble annotations on repeaters and weighted route lines between hops
- **Channel DM & Contact Card** — Long-press a channel message to direct-message the sender or tap their name to view their contact card, without leaving the channel
- **BLE Reconnect Fix** — Fixed a race condition crash during BLE auto-reconnect when services were cleared concurrently

## Features

### Messaging
- Direct messages with delivery status and flood retry
- Channels (public, private, and hashtag)
- Room Server connections with guest/participant modes
- Heard repeats tracking
- Message reactions (emoji)
- Quoted replies
- Link previews and inline images
- @Mentions
- Per-conversation notification levels
- Hashtag channel deep links
- Blocking (contacts and channel senders)

### Contacts
- Auto-discovery on the mesh
- QR code and advert sharing
- Favorites
- Ping repeater (latency and SNR)

### Map
- Contact positions
- Map layers (standard, satellite, hybrid)

### Network Tools
- **Trace Path** — Route through specific repeaters with option to save paths
- **Line of Sight** — Terrain analysis with Fresnel zone and RF parameters
- **Message Route Map** — Geographic visualization of a message's path through repeaters *(fork)*
- **Traffic Map** — Mesh traffic heatmap with repeater bubbles and route lines *(fork)*
- **RX Log** — Live packet capture
- **Noise Floor Monitor** — Live dBm chart with signal quality stats
- **CLI Terminal** — Remote command-line access to repeaters

### Remote Node Management
- Repeater status (battery, uptime, neighbors, telemetry)
- Remote repeater configuration (radio, behavior, identity, reboot)
- Telemetry history charts
- Admin authentication

### Companion Device
- Bluetooth and WiFi pairing
- Radio presets and manual tuning (frequency, TX power, spreading factor, bandwidth)
- Battery monitoring with OCV curves

### General
- Offline mesh networking (no internet required)
- Push notifications with quick reply
- Location sharing controls
- Config import/export

## Requirements

- **iOS 18.0+**
- **Xcode 26.0+**
- **MeshCore-compatible hardware**

## Getting Started

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen).
2. Run `xcodegen generate`.
3. Open `PocketMesh.xcodeproj`.

For more details, see the [Development Guide](docs/Development.md).

## License

PocketMesh — GNU General Public License v3.0
Swift MeshCore — MIT
