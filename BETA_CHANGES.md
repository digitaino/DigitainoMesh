# Beta Changes — v0.10.1 (Build 2)

## Signal Survey (Wardriving)

- **Coverage heatmap tool** — New tool under Tools > Signal Survey. Start a GPS-tagged survey session that pairs every received RF packet with your phone's location. As you move around, the app builds a live coverage map of your mesh network's signal quality.

- **Hex grid heatmap** — Received packets are aggregated into a hex grid overlay on the map. Each cell is color-coded by average SNR (green = excellent, red = poor). Tap any hex cell to see a detail card with signal quality, packet count, and which repeaters were heard in that cell. The heatmap is the default visualization; you can switch to a raw point cloud view if preferred.

- **Active trace probing** — Toggle active probing to automatically send flood traces on a smart schedule (triggered by cell-exit or a max timer). Probed repeaters appear in the cell detail card alongside passively heard packets. Filter the heatmap by All / Passive / Active to see probe-only vs. passive-only coverage. A manual probe button with heavy haptic feedback and a visual pulse animation lets you trigger a trace on demand.

- **Repeater annotations** — Resolved repeater contacts with GPS locations appear as cyan antenna pins on the survey map. Tap a repeater pin to see a detail sheet with name, public key, coordinates, and a "View Contact Card" button. When you select a repeater filter chip in the cell detail card, a dashed line is drawn from the cell center to the repeater's location on the map.

- **Session management** — Create, rename, and delete survey sessions. Switch between sessions to review past data. The active session resumes automatically when navigating back to the survey. A "Recording" indicator is visible from the Tools list. Screen lock is prevented during recording.

- **JSON export** — Export anonymized grid data as JSON for external analysis.

  **How to test:** Go to Tools > Signal Survey. Tap "Start Survey" and walk/drive around with your MeshCore device connected. Verify hex cells appear and update as packets arrive. Tap a cell to see the detail card — check signal bars, quality label, packet count, and repeater chips. Switch between All/Passive/Active filters and verify the cell colors and card stats update. Toggle active probing and verify traces are sent (the manual probe button should show an expanding orange ring). Tap a cyan repeater pin and verify the detail sheet shows correct info. Navigate away from the survey and come back — it should resume recording. Try renaming and deleting a session.

---

## Nodes List Improvements

- **Search by public key** — The search bar in the Nodes list now matches against public key hex prefixes. Type a hex string like "0C" or "D1A9" and nodes whose public key starts with that prefix appear at the top of results, followed by substring matches, then name-only matches.

- **Public key prefix display** — Each node row now shows the first 3 bytes of the node's public key in monospaced text below the name and distance (e.g. "0C 13 77"). This makes it easy to identify nodes by their key prefix at a glance.

- **Public key in map contact detail** — Tapping a node pin on the map and opening its detail card now shows the full public key in a selectable monospaced field.

  **How to test:** Open the Nodes tab and verify each row shows a 3-byte hex prefix below the name. Use the search bar — type a 2-character hex prefix and verify the matching node appears at the top. Open the map, tap a node pin, and verify the detail card shows the public key.

---

## Maps Modernization

- **SwiftUI Map migration** — All route maps have been modernized from UIKit MapKit wrappers to native SwiftUI Map views. This improves rendering consistency and simplifies the codebase.

- **DM path display fix** — Direct message route maps now correctly show the message path.

- **Contact route map fix** — The contact route map now correctly renders the aggregated route history.

---

## Upstream Merge & Unified Chat

- **Unified chat view** — DM and channel chat views have been merged into a single `ChatConversationView`, reducing code duplication and ensuring feature parity between DM and channel conversations.

- **Performance improvements** — SwiftData indexes added to Contact, Channel, and RemoteNodeSession models. Conversation reload tasks are debounced. Existence checks use `fetchCount` instead of full fetches.

- **Persistent message deduplication** — Replaced the in-memory dedup cache with persistent packet hash deduplication, preventing duplicate messages across app restarts.

- **Crash fix** — Handle transient ModelContainer creation failure during app launch with automatic retry.

---

# Previous Builds

## Build 13

### Shared Route Map

- **Inline route card** — When an incoming message contains route info (from "Reply with Route"), a tappable "Shared Route" card appears below the message bubble. The card shows a summary of the route — hop count, repeater hex IDs, and distance.

- **Shared route map** — Tap the card to open an interactive map plotting the shared route. Repeater hex IDs are resolved against your known contacts and discovered nodes to place pins on the map. Lines connect consecutive hops, with dashed orange lines for hops that couldn't be located. An info banner shows how many of the hops were located and the original distance text.

  **How to test:** Have someone send a message through multiple hops. Long-press the message, expand path details, and tap "Reply with Route". On the receiving end, verify the reply shows an inline "Shared Route" card below the bubble. Tap the card — the map should open showing pins for any repeaters that have GPS locations in your contacts or discovered nodes. If no hops resolve, an empty state message should appear. Verify that normal messages without "RX via" text do not show the card, and that outgoing messages never show it.

---

## Build 11

### Reply with Route

- **Reply with route info** — In the message long-press menu, expand the path details and tap the new "Reply with Route" button. This pre-fills the input bar with a quoted reply that includes the route summary — hop count, distance, and repeater hex IDs. Example: `Via 3 hops · 12.4 mi (A1,B2,C3)`.

- **Route distance in message details** — The "Hops" row in the expanded path details now shows the total route distance alongside the hop count (e.g. "Hops: 3 · 12.4 mi"). When intermediate repeaters lack location data, a "≥" prefix indicates the distance is a minimum estimate.

  **How to test:** Long-press an incoming message that was relayed through hops. Expand the path details section — verify the Hops row shows a distance. Tap "Reply with Route" and verify the input bar is pre-filled with a reply containing the route info. Send it and confirm the route info appears in the message. Test with both channel messages (should include @[name] mention) and DMs (no mention).

## Route Distance on Maps

- **Message route map distance** — The message route map now displays the total chain distance along the path at the top of the screen. Uses "≥" prefix only when intermediate repeaters in the route are missing location data.

- **Heard repeats map distance** — The heard repeats map shows the total path distance when viewing a single repeat.

  **How to test:** Open a message route map for a multi-hop message — verify the distance badge appears. If all repeaters have GPS, the distance should be exact (no ≥). If some intermediate repeaters lack location, it should show ≥. Check the heard repeats map similarly.

## Swipe to Reply Fix

- **Fixed scroll blocking** — The swipe-to-reply gesture has been rebuilt using UIKit's `UIPanGestureRecognizer` instead of SwiftUI's `DragGesture`. This fixes the issue where the swipe gesture would block normal vertical scrolling in conversations. Swiping right to reply and scrolling up/down now work independently without interfering with each other.

  **How to test:** Open a channel or DM with many messages. Scroll up and down — scrolling should be smooth with no hesitation or blocking. Then swipe right on an incoming message to trigger a reply — the gesture should still work as before with the arrow icon and haptic feedback. Verify that a diagonal swipe (mostly vertical) scrolls instead of triggering the reply.

---

## Build 9

### Swipe to Reply & Haptic Improvements

- **Swipe right to reply** — In both channel and direct message conversations, swipe an incoming message to the right to quickly reply. A reply arrow appears as you swipe; release past the threshold to trigger the reply (pre-fills the input bar with a mention and quoted preview). Works the same as the existing Reply action in the long-press menu, just faster.

- **Improved long-press haptic** — The haptic feedback when you tap and hold a message to open the actions sheet now uses a heavier impact, closer to the old force touch feel.

### Message Draft Persistence

- **Drafts survive navigation** — If you start typing a message in a channel or DM and press the back button, the text you typed is preserved. When you return to that conversation, the draft is restored in the input bar. Each conversation has its own independent draft. Drafts are kept in memory for the current session (cleared on app restart).

### Upstream Sync: PocketMesh → MeshCore One (MC1)

- **Merged upstream rename** — The upstream project has been renamed from PocketMesh to MeshCore One (MC1). All fork files have been moved and updated to match the new project structure. Import statements updated from `PocketMeshServices` to `MC1Services`.

- **File reorganization** — Views for route maps, traffic heatmap, and contact route maps moved from `PocketMesh/Views/` to `MC1/Views/` to align with the new upstream layout.

- **Build version sync** — Fixed a CFBundleVersion mismatch between the main app and the widget extension that was preventing the app from launching on device.

## Build 4

### Map Pin Overhaul

- **Native Apple Map Markers** — All route and trace path map pins have been replaced with Apple's native `MKMarkerAnnotationView` balloon markers, following Apple Human Interface Guidelines. This gives us automatic label collision avoidance, consistent visual language with Apple Maps, and cleaner rendering.

- **Hop Numbers Inside Markers** — On trace path maps, the hop number is now displayed inside the marker balloon glyph instead of a custom badge overlay. Repeaters in the path show a blue marker with the hop number; idle repeaters show a cyan marker with an antenna icon.

- **Endpoint Markers** — Sender and receiver endpoints on message route maps now use distinct colored balloons: teal with a person icon (sender) and blue with a phone icon (receiver).

- **Label Mode Toggle** — A new toolbar button cycles through three label modes on all route/trace maps:
  - **Hidden** — Labels off, tap a pin to see its callout
  - **Hex Short** — Shows the 2-byte public key prefix (e.g. "A1B2") for quick identification without cluttering the map
  - **Full Name** — Shows the repeater's display name with MapKit's adaptive collision avoidance

### Heard Repeats Map — Repeat Cycling

- **Individual Repeat Navigation** — The heard repeats map now has left/right chevron arrows in the summary banner. Tap them to cycle through each repeat individually, seeing only that repeat's path on the map. The default view shows all repeats aggregated. The cycle order is: All → Repeat 1 → Repeat 2 → ... → All.

- **Single Repeat Detail** — When viewing a single repeat, the banner shows "Repeat X of N", the SNR value, and hop count instead of the aggregate summary. Arrows are hidden when there's only one repeat.

  **How to test:** Open a sent message that has multiple heard repeats, then tap "Show on Map". You should see the aggregate view by default. Use the chevron arrows to cycle through — each individual repeat should show only its own path and pins. Verify the SNR and hop count match what the list view shows.

### GPS Location Accuracy

- **Non-blocking GPS** — Sending a message no longer waits for a GPS fix. The message is sent immediately with whatever cached location is available. A fresh GPS request is kicked off in the background, and the message's coordinates are silently patched once the fix arrives. This means route maps should always show your actual position at send/receive time, even if the phone's GPS was cold or stale.

  **How to test:** Send a message from a known location, then open the message route map. Verify the sender pin (teal) matches where you actually were, not some old cached position. Try sending right after opening the app (cold GPS) — the pin should still land correctly after a few seconds.

### Welcome Screen

- Added fork attribution and feedback links to the onboarding welcome screen
- TestFlight builds show a beta indicator
