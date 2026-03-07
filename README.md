# PocketMesh (Fork)

A personal fork of [PocketMesh](https://github.com/Avi0n/PocketMesh), an unofficial MeshCore client built for iOS in Swift.

> **Note:** This is an independent fork. For the official app, TestFlight beta, and releases, visit the [upstream repository](https://github.com/Avi0n/PocketMesh).

## Fork Additions

Features added in this fork on top of upstream:

- **Message Route Map** — Visualize the geographic path a specific message took through mesh repeaters on an interactive map with hop-by-hop detail
- **Traffic Map** — Aggregate received RF packets over selectable time windows (1h, 24h, 7d, all time) and visualize mesh traffic patterns with sized/colored bubble annotations on repeaters and weighted route lines between hops

## Features

### Messaging
- Direct messages with delivery status and flood retry
- Channels (public, private, and hashtag)
- Room Server connections with guest/participant modes
- Heard repeats tracking

### Contacts
- Auto-discovery on the mesh
- QR code sharing
- Favorites

### Map
- See contact positions

### Network Tools
- **Trace Path** — Route through specific repeaters with option to save paths
- **Line of Sight** — Terrain analysis with Fresnel zone and RF parameters
- **Message Route Map** — Geographic visualization of a message's path through repeaters *(fork)*
- **Traffic Map** — Mesh traffic heatmap with repeater bubbles and route lines *(fork)*
- **RX Log** — Live packet capture

### Remote Node Management
- Repeater status (battery, uptime, neighbors, telemetry)
- Admin authentication

### Companion Device
- Bluetooth pairing
- Radio presets and manual tuning (frequency, TX power, spreading factor, bandwidth)
- Battery monitoring with OCV curves

### General
- Offline mesh networking (no internet required)
- Push notifications with quick reply

### Future Features
- Import/Export config and/or data

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
