# PocketMesh (Fork)

A personal fork of [PocketMesh](https://github.com/Avi0n/PocketMesh), an unofficial MeshCore client built for iOS in Swift.

> **Note:** This is an independent fork. For the official app, TestFlight beta, and releases, visit the [upstream repository](https://github.com/Avi0n/PocketMesh).

## Fork Additions

Features and fixes added in this fork on top of upstream:

- **Contact Route Map** — Visualize the aggregated route history for a specific contact on an interactive map, showing the current routing path through repeaters with traffic bubbles and endpoint pins
- **Message Route Map** — Visualize the geographic path a specific message took through mesh repeaters on an interactive map with hop-by-hop detail, SNR-based signal quality coloring on the last hop, and dashed orange lines for unlocated hops
- **Traffic Map** — Aggregate received RF packets over selectable time windows (1h, 24h, 7d, all time) and visualize mesh traffic patterns with sized/colored bubble annotations on repeaters and weighted route lines between hops
- **Historical GPS on Messages** — Messages store the phone's GPS coordinates at send/receive time so route maps show where the user actually was, not the phone's current location
- **Channel DM & Contact Card** — Long-press a channel message to direct-message the sender or tap their name to view their contact card, without leaving the channel
- **Mention Improvements** — Live-updating mention suggestion order based on most recent sender, keyboard auto-reset to letters after selecting a mention
- **BLE Reconnect Fix** — Fixed a race condition crash during BLE auto-reconnect when services were cleared concurrently

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
