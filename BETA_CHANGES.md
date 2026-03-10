# Beta Changes — Build 4

## Map Pin Overhaul

- **Native Apple Map Markers** — All route and trace path map pins have been replaced with Apple's native `MKMarkerAnnotationView` balloon markers, following Apple Human Interface Guidelines. This gives us automatic label collision avoidance, consistent visual language with Apple Maps, and cleaner rendering.

- **Hop Numbers Inside Markers** — On trace path maps, the hop number is now displayed inside the marker balloon glyph instead of a custom badge overlay. Repeaters in the path show a blue marker with the hop number; idle repeaters show a cyan marker with an antenna icon.

- **Endpoint Markers** — Sender and receiver endpoints on message route maps now use distinct colored balloons: teal with a person icon (sender) and blue with a phone icon (receiver).

- **Label Mode Toggle** — A new toolbar button cycles through three label modes on all route/trace maps:
  - **Hidden** — Labels off, tap a pin to see its callout
  - **Hex Short** — Shows the 2-byte public key prefix (e.g. "A1B2") for quick identification without cluttering the map
  - **Full Name** — Shows the repeater's display name with MapKit's adaptive collision avoidance

## GPS Location Accuracy

- **Non-blocking GPS** — Sending a message no longer waits for a GPS fix. The message is sent immediately with whatever cached location is available. A fresh GPS request is kicked off in the background, and the message's coordinates are silently patched once the fix arrives. This means route maps should always show your actual position at send/receive time, even if the phone's GPS was cold or stale.

  **How to test:** Send a message from a known location, then open the message route map. Verify the sender pin (teal) matches where you actually were, not some old cached position. Try sending right after opening the app (cold GPS) — the pin should still land correctly after a few seconds.

## Welcome Screen

- Added fork attribution and feedback links to the onboarding welcome screen
- TestFlight builds show a beta indicator
