# Beta Changes — Build 4

## Map Pin Overhaul

- **Native Apple Map Markers** — All route and trace path map pins have been replaced with Apple's native `MKMarkerAnnotationView` balloon markers, following Apple Human Interface Guidelines. This gives us automatic label collision avoidance, consistent visual language with Apple Maps, and cleaner rendering.

- **Hop Numbers Inside Markers** — On trace path maps, the hop number is now displayed inside the marker balloon glyph instead of a custom badge overlay. Repeaters in the path show a blue marker with the hop number; idle repeaters show a cyan marker with an antenna icon.

- **Endpoint Markers** — Sender and receiver endpoints on message route maps now use distinct colored balloons: teal with a person icon (sender) and blue with a phone icon (receiver).

- **Label Mode Toggle** — A new toolbar button cycles through three label modes on all route/trace maps:
  - **Hidden** — Labels off, tap a pin to see its callout
  - **Hex Short** — Shows the 2-byte public key prefix (e.g. "A1B2") for quick identification without cluttering the map
  - **Full Name** — Shows the repeater's display name with MapKit's adaptive collision avoidance

## Welcome Screen

- Added fork attribution and feedback links to the onboarding welcome screen
- TestFlight builds show a beta indicator
