# DigitainoMesh (Fork)

A personal fork of [MeshCore One (MC1)](https://github.com/AviAn-Tech/MC1), an unofficial MeshCore client built for iOS in Swift. Previously known as PocketMesh.

> **Note:** This is an independent fork. For the official app, TestFlight beta, and releases, visit the [upstream repository](https://github.com/AviAn-Tech/MC1).

## Fork Additions

Features and fixes added in this fork on top of upstream:

- **Community Signal Map** — Crowd-sourced mesh coverage map at mesh.digitaino.com. Survey data from all contributors is aggregated into a hex-grid overlay with SNR-based color coding. Includes a web frontend built on Apple MapKit JS with auto-refreshing cells, repeater pins, signal quality bars, repeater filtering, and a stats panel. The iOS app shows a dedicated Community Map view and a toggleable hex overlay on the main map, both auto-refreshing every 15 seconds
- **Live Community Upload** — Per-packet real-time upload to the community map. When "Live Upload" is enabled in the survey setup sheet, each received packet's hex cell is immediately POSTed to the server as you survey. Data is anonymized — only hex grid cells (~100 m), signal stats, and repeater IDs are sent. No exact GPS, device identity, or message content is included
- **Idempotent Session Uploads** — Batch uploads include session UUIDs for server-side deduplication. Re-uploading the same sessions replaces previous data instead of accumulating duplicates. Live per-packet uploads are also tagged with the session ID so batch uploads cleanly replace them
- **Shareable Route Links** — When you "Reply with Route", the route data is uploaded to the server and a short URL is generated (e.g. `mesh.digitaino.com/r/abc123`). The link opens an interactive Apple MapKit JS web page showing the route plotted through repeaters with hop-by-hop annotations, a polyline connecting located hops, and a collapsible details panel
- **Shareable Repeater Map Links** — Repeater maps can be shared as web links showing all known repeaters with signal quality color coding, heard counts, SNR, and RSSI stats, with a collapsible bottom panel
- **Traffic Map** — Aggregate received RF packets over selectable time windows and visualize mesh traffic patterns with sized/colored bubble annotations on repeaters and weighted route lines between hops. Built on native MKMapView with proper annotation clustering, tappable callouts with packet count/SNR/last-seen, and a public key hex label on each pin. Time period filtering dynamically adapts its options based on data age. Includes an info guide button explaining pin colors, SNR thresholds, and filtering
- **Map Last Heard Filter** — Scrollable time filter bar on the main map lets you filter displayed nodes by when they were last heard (1 Hour, 12 Hours, 1 Day, 3 Days, 5 Days, All Time) to quickly distinguish active nodes from stale ones
- **Contact Route Map** — Visualize the aggregated route history for a specific contact on an interactive map, showing the current routing path through repeaters with traffic bubbles and endpoint pins
- **Message Route Map** — Visualize the geographic path a specific message took through mesh repeaters on an interactive map with hop-by-hop detail, SNR-based signal quality coloring on the last hop, and dashed orange lines for unlocated hops
- **Historical GPS on Messages** — Messages store the phone's GPS coordinates at send/receive time so route maps show where the user actually was, not the phone's current location
- **Channel DM & Contact Card** — Long-press a channel message to direct-message the sender or tap their name to view their contact card, without leaving the channel
- **Reply with Route** — Reply to a message with its route info (hop count, distance, and repeater hex IDs) from the expanded path details view
- **Shared Route Map** — When a message contains route info (from Reply with Route), an inline card appears below the bubble. Tap it to open an interactive map plotting the shared route through repeaters, reusing the same map renderer as message route maps
- **Path Map Generator** — Enter hex IDs manually (from message paths) to visualize repeater routes on an interactive map. Supports 2–6 character hex hashes and full 64-character public keys. Share the path as a web link (`mesh.digitaino.com/p/...`). Chat messages containing hex path chains are auto-detected with an inline card
- **Web Path Creator** — Public web page at `mesh.digitaino.com/path` for creating shareable path maps in a browser without the app. Server-side resolution fills in repeater locations from the community database
- **Background Repeater Location Sharing** — Opt-in periodic upload of your device's known repeater GPS coordinates to the community server. Enriches the community map for all users. Throttled to 15-minute intervals, only sent when data changes, requires contributor verification
- **Route Distance on Maps** — Message route maps and heard repeats maps display the total chain distance along the path, with a "≥" prefix when intermediate repeaters lack location data
- **Swipe to Reply** — Swipe right on an incoming message in channels or DMs to quickly reply, with haptic feedback and a visual reply indicator (UIKit-based gesture avoids scroll blocking)
- **Message Draft Persistence** — Unsent message text is preserved when navigating away from a conversation and restored when returning
- **Mention Improvements** — Live-updating mention suggestion order based on most recent sender, keyboard auto-reset to letters after selecting a mention
- **Signal Survey (Wardriving)** — Record mesh signal quality as you move, building a coverage heatmap. Start a GPS-tagged survey session that pairs every received packet with your location. Visualize data as individual points or an aggregated hex-grid heatmap with SNR-based color coding. Tap any hex cell to see signal stats in a native bottom sheet. Includes active trace probing with channel messages, discover requests, and flood traces (Deep Scan mode) with active/passive packet distinction and filtering, session management with rename/delete, batch upload with session picker, JSON export of anonymized grid data, screen-lock prevention during recording, a floating survey indicator visible from any tab, community map overlay with coverage/repeater/time filters, and a comprehensive "How It Works" guide explaining radio asymmetry, probe types, hop counts, and map legend
- **SNR Last-Hop Attribution** — Signal quality (SNR) is now correctly attributed only to the last hop in the packet path, preventing misleading signal data on intermediate repeaters and route segments
- **Public Key Hex on Nodes** — Each node row and traffic map pin shows the first bytes of the node's public key as a hex label for quick identification. Full public key is shown in detail sheets
- **Signal Bars Service** — Live repeater signal monitoring with round-robin ping engine measuring RX quality, TX quality, and RTT across all reachable repeaters. Compact firmware-style popover shows all repeaters ranked by signal strength. Best repeater indicator in toolbar. Dual RX/TX bars on survey floating pill
- **iMessage-Style Swipe Timestamps** — Swipe horizontally on chat messages to reveal per-message timestamps, matching iMessage behavior
- **Two-Column RX/TX Cell Detail** — Survey cell detail card shows RX and TX signal in side-by-side columns with bars, quality labels, average SNR, RSSI, and SNR ranges. Shared stats (Last Heard, Mesh Reach, Probe Success) appear below
- **Survey Completion Stats & Personal Records** — Survey sessions persist completion stats (duration, packet counts, cell breakdown, repeaters) when you stop recording. Stats can be viewed later from the session list. The completion sheet highlights personal bests with trophy badges for longest duration, most packets, most cells, most connected cells, and most unique repeaters. Lifetime stats dashboard in session list header
- **Streamlined Survey Completion** — Stopping a survey shows a single summary sheet with stats, coverage breakdown, personal records, and inline community upload button
- **TX SNR Tracking** — Survey points capture TX SNR from discover and trace responses for bidirectional signal analysis in exports and uploads
- **Batch Contact Sync** — Contacts are saved in a single batch transaction during initial sync, preventing concurrent SQLite write crashes on devices with many contacts
- **BLE Reconnect Fix** — Fixed a race condition crash during BLE auto-reconnect when services were cleared concurrently
- **Deep Scan Gating & Mesh Gateway Scoring** — Discover requests are gated behind Deep Scan mode to reduce RF overhead. Trace data identifies the best gateway repeater per cell with an adaptive cell detail card layout
- **Client-Authority Route Sharing** — Shared routes preserve the iOS client's bidirectional anchor-aware repeater resolution instead of the server re-resolving from the community database
- **Hop Distances on Shared Pages** — Shared route/path web pages display per-hop and total distances with locale-aware formatting (mi/km)
- **Repeater Benchmark** — New tool for benchmarking repeater signal quality with comparison and history views
- **Ambiguous Repeater Persistence** — User selections in the repeater disambiguation sheet persist across view rebuilds and are correctly applied when sharing routes
- **Web Map Declutter** — Repeater pins and stats on the community web map only show repeaters heard in the last 7 days. Prefix-aware repeater filtering handles mixed hash-size modes

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
