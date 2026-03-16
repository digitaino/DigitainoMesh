# DigitainoMesh (Fork)

A personal fork of [MeshCore One (MC1)](https://github.com/AviAn-Tech/MC1), an unofficial MeshCore client built for iOS in Swift. Previously known as PocketMesh.

> **Note:** This is an independent fork. For the official app, TestFlight beta, and releases, visit the [upstream repository](https://github.com/AviAn-Tech/MC1).

## Fork Additions

Features and fixes added in this fork on top of upstream:

- **Community Signal Map** — Crowd-sourced mesh coverage map at mesh.digitaino.com. Survey data from all contributors is aggregated into a hex-grid overlay with SNR-based color coding. Includes a web frontend built on Apple MapKit JS with auto-refreshing cells, repeater pins, and a stats panel. The iOS app shows a dedicated Community Map view and a toggleable hex overlay on the main map, both auto-refreshing every 15 seconds
- **Live Community Upload** — Per-packet real-time upload to the community map. When "Live Upload" is enabled in the survey setup sheet, each received packet's hex cell is immediately POSTed to the server as you survey. Data is anonymized — only hex grid cells (~100 m), signal stats, and repeater IDs are sent. No exact GPS, device identity, or message content is included
- **Shareable Route Links** — When you "Reply with Route", the route data is uploaded to the server and a short URL is generated (e.g. `mesh.digitaino.com/r/abc123`). The link opens an interactive Apple MapKit JS web page showing the route plotted through repeaters with hop-by-hop annotations, a polyline connecting located hops, and a collapsible details panel
- **Shareable Repeater Map Links** — Repeater maps can be shared as web links showing all known repeaters with signal quality color coding, heard counts, SNR, and RSSI stats, with a collapsible bottom panel
- **Traffic Map** — Aggregate received RF packets over selectable time windows (1h, 24h, 7d, all time) and visualize mesh traffic patterns with sized/colored bubble annotations on repeaters and weighted route lines between hops. Built on native MKMapView with proper annotation clustering, tappable callouts with packet count/SNR/last-seen, and a public key hex label on each pin. Includes an info guide button explaining pin colors, SNR thresholds, and filtering
- **Contact Route Map** — Visualize the aggregated route history for a specific contact on an interactive map, showing the current routing path through repeaters with traffic bubbles and endpoint pins
- **Message Route Map** — Visualize the geographic path a specific message took through mesh repeaters on an interactive map with hop-by-hop detail, SNR-based signal quality coloring on the last hop, and dashed orange lines for unlocated hops
- **Historical GPS on Messages** — Messages store the phone's GPS coordinates at send/receive time so route maps show where the user actually was, not the phone's current location
- **Channel DM & Contact Card** — Long-press a channel message to direct-message the sender or tap their name to view their contact card, without leaving the channel
- **Reply with Route** — Reply to a message with its route info (hop count, distance, and repeater hex IDs) from the expanded path details view
- **Shared Route Map** — When a message contains route info (from Reply with Route), an inline card appears below the bubble. Tap it to open an interactive map plotting the shared route through repeaters, reusing the same map renderer as message route maps
- **Route Distance on Maps** — Message route maps and heard repeats maps display the total chain distance along the path, with a "≥" prefix when intermediate repeaters lack location data
- **Swipe to Reply** — Swipe right on an incoming message in channels or DMs to quickly reply, with haptic feedback and a visual reply indicator (UIKit-based gesture avoids scroll blocking)
- **Message Draft Persistence** — Unsent message text is preserved when navigating away from a conversation and restored when returning
- **Mention Improvements** — Live-updating mention suggestion order based on most recent sender, keyboard auto-reset to letters after selecting a mention
- **Signal Survey (Wardriving)** — Record mesh signal quality as you move, building a coverage heatmap. Start a GPS-tagged survey session that pairs every received packet with your location. Visualize data as individual points or an aggregated hex-grid heatmap with SNR-based color coding. Tap any hex cell to see signal stats in a native bottom sheet. Includes active trace probing (sends flood traces on a smart schedule triggered by cell-exit or a max timer), session management with rename/delete, JSON export of anonymized grid data, screen-lock prevention during recording, and a "Recording" indicator visible from the Tools list
- **SNR Last-Hop Attribution** — Signal quality (SNR) is now correctly attributed only to the last hop in the packet path, preventing misleading signal data on intermediate repeaters and route segments
- **Public Key Hex on Nodes** — Each node row and traffic map pin shows the first bytes of the node's public key as a hex label for quick identification. Full public key is shown in detail sheets
- **BLE Reconnect Fix** — Fixed a race condition crash during BLE auto-reconnect when services were cleared concurrently

## Requirements

- **iOS 18.0+**
- **Xcode 26.0+**
- **MeshCore-compatible hardware**

## Getting Started

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen).
2. Run `xcodegen generate`.
3. Open `MC1.xcodeproj`.

For more details, see the [Development Guide](docs/Development.md).

## License

MeshCore One — GNU General Public License v3.0
Swift MeshCore — MIT
