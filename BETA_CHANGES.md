# Beta Changes — Build 13

## Shared Route Map

- **Inline route card** — When an incoming message contains route info (from "Reply with Route"), a tappable "Shared Route" card appears below the message bubble. The card shows a summary of the route — hop count, repeater hex IDs, and distance.

- **Shared route map** — Tap the card to open an interactive map plotting the shared route. Repeater hex IDs are resolved against your known contacts and discovered nodes to place pins on the map. Lines connect consecutive hops, with dashed orange lines for hops that couldn't be located. An info banner shows how many of the hops were located and the original distance text.

  **How to test:** Have someone send a message through multiple hops. Long-press the message, expand path details, and tap "Reply with Route". On the receiving end, verify the reply shows an inline "Shared Route" card below the bubble. Tap the card — the map should open showing pins for any repeaters that have GPS locations in your contacts or discovered nodes. If no hops resolve, an empty state message should appear. Verify that normal messages without "RX via" text do not show the card, and that outgoing messages never show it.

---

# Previous Builds

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

# Previous Builds

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
