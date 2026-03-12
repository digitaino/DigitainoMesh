# Beta Changes — Build 9

## Swipe to Reply & Haptic Improvements

- **Swipe right to reply** — In both channel and direct message conversations, swipe an incoming message to the right to quickly reply. A reply arrow appears as you swipe; release past the threshold to trigger the reply (pre-fills the input bar with a mention and quoted preview). Works the same as the existing Reply action in the long-press menu, just faster.

- **Improved long-press haptic** — The haptic feedback when you tap and hold a message to open the actions sheet now uses a heavier impact, closer to the old force touch feel.

  **How to test:** Open any channel or DM conversation with incoming messages. Swipe right on an incoming message — you should see a reply arrow icon appear on the left and feel a haptic tick when passing the threshold. Releasing should pre-fill the input bar with a reply. Also tap and hold any message to verify the stronger haptic feedback fires when the actions sheet opens.

## Message Draft Persistence

- **Drafts survive navigation** — If you start typing a message in a channel or DM and press the back button, the text you typed is preserved. When you return to that conversation, the draft is restored in the input bar. Each conversation has its own independent draft. Drafts are kept in memory for the current session (cleared on app restart).

  **How to test:** Open a channel or DM, type some text (don't send), press back. Navigate back to the same conversation — the text should still be in the input bar. Verify that different conversations keep separate drafts. Sending a message should clear the draft.

## Upstream Sync: PocketMesh → MeshCore One (MC1)

- **Merged upstream rename** — The upstream project has been renamed from PocketMesh to MeshCore One (MC1). All fork files have been moved and updated to match the new project structure. Import statements updated from `PocketMeshServices` to `MC1Services`.

- **File reorganization** — Views for route maps, traffic heatmap, and contact route maps moved from `PocketMesh/Views/` to `MC1/Views/` to align with the new upstream layout.

- **Build version sync** — Fixed a CFBundleVersion mismatch between the main app and the widget extension that was preventing the app from launching on device.

  **How to test:** Install the app on your device and verify it launches correctly. All existing features (route maps, traffic map, channel DM, mentions) should work as before. Check that the widget still appears in the widget gallery.

---

# Previous Builds

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
