Beta Changes -- v0.10.1 (Build 24)

Weather UI Redesign (HIG)

All weather product rows have been redesigned to follow Apple Human Interface Guidelines. Observations and TAF now use a large 40pt sky icon, bold temperature, semantic SwiftUI fonts (callout/caption2), and a 2×2 detail grid (dewpoint, humidity, visibility, altimeter). Warning and "Warnings Near" rows replace the dot indicator with a vertical color stripe (Apple Calendar style). Forecast period cells use caption2 throughout and are slightly wider. Precipitation report cards use caption2 with wider frames. Storm Reports adds a proper section header. A TipKit tooltip is now anchored directly to the station card via .popoverTip instead of the search bar.

Signal Bars Aggressive Recovery

The repeater TX signal bars service now retries faster when a repeater fails: first retry at 20 s, second at 45 s, third at 90 s (was a single 120 s interval). The service also reactively re-pings any .failed repeater when a packet is received from it (30 s cooldown), so recovery is triggered by live traffic instead of waiting for the timer.

---

v0.10.1 (Build 23)

Weather Sections & Navigation

The Weather tab now organizes station cards into three collapsible sections: Favorites (always populated, even without data), Your Requests (stations you explicitly requested), and Broadcasts (stations from bot auto-broadcasts). Section headers are full-row tap targets with a chevron indicator. After requesting a station, the view automatically scrolls to the new card and expands its section if collapsed.

Weather Icon Legend

A new "Observation Abbreviations" section in the Weather info sheet explains all abbreviations (Dew, Vis, Pres, RH, kts) and sky condition icons. A "Section Guide" explains Favorites, Requests, Broadcasts, and Warnings sections.

---

v0.10.1 (Build 22)

Weather Bot Reliability

DM requests now retry with flood-routing fallback if unacknowledged. Forecast, TAF, and METAR requests re-send once after 45 s with no response; if still no reply the pending state is cleared. A new toggle in Tools → Weather Log switches between DM mode (default, with retry/ACK) and Channel mode (plain message, better over poor links). The #wx-broadcast channel is auto-provisioned and muted on first connect. Bot name is auto-discovered from the first broadcast — no manual setup required. MSG_NOT_AVAILABLE (0x03) responses are decoded immediately, stopping spinners and showing an inline "unavailable" label. Fixed tapback messages being truncated mid-hash on long channel messages.

---

v0.10.1 (Build 21)

MeshWX Weather System

New Weather tab showing live NWS data over the mesh from a MeshWX bot. Supports the full MeshWX v3 binary protocol: Observations (METAR), 7-Day Forecasts, TAF, 64×32 Radar loops, Active Warnings, Storm Reports, Hazard Outlooks, Precipitation Reports, and Warnings Near Location. Search by city, state, or ICAO code to request data via DM. Broadcast forecasts are automatically linked to the nearest station by proximity. Station cards blend obs, forecast, and TAF into one unified row with a context menu. Favorites always appear at top. Per-product refresh buttons, global °F/°C toggle, swipe to clear.

---

Previous Builds

v0.10.1 (Build 21)

MeshWX Weather System

New Weather tab showing live NWS weather data received over the mesh from a MeshWX bot node. Supports the full MeshWX v3 binary protocol (COBS-encoded channel messages) across all message types:

- Observations (METAR) — current conditions at airport stations: temperature, dewpoint, wind speed/gust/direction, altimeter, cloud layers, visibility, present weather, and flight rules (VFR/MVFR/IFR/LIFR)
- 7-Day Forecasts — NWS gridded forecasts for ~1,900 US forecast points with high/low temps, wind, precipitation chance, humidity, and period icons
- TAF — Terminal Aerodrome Forecast for IFR-capable stations
- Radar — 64x32 grid radar intensity loops from NWS regional sectors, showing precipitation intensity with timestamped frames
- Active Warnings — NWS weather warnings with type, severity, and expiry time
- Storm Reports — Local storm reports by type (tornado, hail, wind, flood)
- Hazard Outlooks — Multi-day NWS hazard outlook text
- Precipitation Reports — Nearby recent rain/snow observation summaries with station names and rain type labels
- Warnings Near Location — Warnings within range of a forecast point

Search by city name, city + state ("Austin TX", "Austin, TX"), state abbreviation ("TX", "PR"), or ICAO airport code to request data from the bot via DM. Broadcast forecasts arriving on the weather channel without a prior request are automatically linked to the nearest observed station by geographic proximity, so forecast data folds into the correct station card instead of appearing in a separate section.

Station cards blend observations, forecast, and TAF for each airport into a single unified row with one context menu. Favorites can be starred and always appear at the top; non-favorite stations are sorted by most recently received data. A global degrees toggle (F/C) in the navigation bar applies across all temperature displays. Per-product refresh buttons let you re-request individual data types. Swipe a station card to clear all its data.

Also fixed: METAR rebroadcasts no longer reset the received timestamp, so the age label correctly reflects when the data actually arrived rather than always showing "just now".

---

Previous Builds

v0.10.1 (Build 20)

Path Map Crash Fix

Fixed a crash when opening a shared route map or path map where no hops could be geo-located. The app would crash with "Range requires lowerBound <= upperBound" because the line overlay loop underflowed when the located points array was empty. Applied the same defensive fix to the heard repeats map.

---

Previous Builds

v0.10.1 (Build 19)

Human-Readable Reaction Wire Format

Reactions (tapbacks) are now sent as human-readable messages over the mesh instead of compact binary-style payloads. Channel reactions look like `👍 reacted to [SenderName]: "message snippet" (hash)` and DM reactions look like `👍 reacted to: "snippet" (hash)`. This makes reactions visible on non-iOS clients that display raw message text. Backwards compatible — the parser accepts both old and new formats.

Reaction Heard Repeats & Send Again

When you long-press a reaction badge to open the reaction details sheet, your own outgoing reactions now show how many times the reaction was repeated through the mesh (the same repeat count shown on regular messages). A "Send Again" button lets you re-broadcast a reaction that may not have reached enough repeaters. This works by linking each outgoing reaction to its carrier message in the database.

Simplified Survey UI

Removed the survey focus mode toggle and streamlined the signal survey toolbar. The survey view now always shows the full toolbar without a separate focused/unfocused state. Focus mode buttons (lock, chart, radar) have been removed in favor of the standard toolbar layout.

Repeater Benchmark Improvements

The benchmark tool now includes a repeater picker row component and improved comparison logic. Benchmark view and view model have been updated with additional signal analysis features.

Contacts View Cleanup

Contacts list views (compact, split, empty states, search empty) have been cleaned up with minor layout and consistency improvements.

---

Previous Builds

v0.10.1 (Build 18)

Deep Scan Gating

Discover requests are now gated behind Deep Scan mode. Regular active probing sends channel messages only, reducing RF overhead. When Deep Scan is enabled, full discover + trace probing resumes for comprehensive coverage analysis.

Mesh Gateway Scoring

Trace data is analyzed to identify the best gateway repeater per cell based on mesh connectivity. The cell detail card adapts its layout based on available data — single RX column without deep scan data, two-column RX/TX with a mesh gateway section when deep scan data is present.

Path Hash Size Quick-Picker

New picker in the repeater signal popover lets you switch between 1-byte, 2-byte, and 3-byte path hash modes without navigating to settings.

Client-Authority Route Sharing

When sharing a route from the iOS app, a `clientResolved` flag tells the server to trust the client's bidirectional anchor-aware repeater resolution. Previously the server would re-resolve hex IDs against the community database, often producing different (incorrect) matches, especially for ambiguous 1-byte prefixes.

Hop Distances on Shared Web Pages

Shared route and path web pages now display per-hop distances computed via Haversine formula. Distances are shown between consecutive located hops in the hop connector, with a total chain distance in the summary. Formatting is locale-aware (miles for en-US, km otherwise).

Collapsed Share Panel

Shared route/path web pages now start with the detail panel collapsed so the path lines are visible on the map. A one-line summary (hop count + total distance) is shown in the collapsed header. Tap to expand for full details.

Repeater Benchmark Tool

New tool in the Tools tab for benchmarking repeater signal quality with comparison and history views.

Ambiguous Repeater Selection Fix

User selections in the "Choose Repeater" disambiguation sheet now persist across view rebuilds and are correctly applied when sharing routes to the server. Previously, selections were stored in ephemeral SwiftUI state and lost when the sheet was reopened.

Resolver Staleness Bias

The repeater resolver now checks recency before anchor proximity. If one candidate hasn't been heard in 7+ days and another has, the active one wins regardless of geographic distance. This prevents stale repeaters from incorrectly matching hash prefixes.

Deleted Repeater Cleanup

Deleting a contact now also removes the corresponding DiscoveredNode entry from the database. Previously, deleted repeaters continued appearing in disambiguation because the DiscoveredNode table was not cleaned up.

Stale Node Filtering

Discovered nodes not heard in 7+ days are excluded from the disambiguation sheet, preventing offline or deleted repeaters from cluttering candidate lists.

Web Map: 7-Day Repeater Declutter

Repeater map pins and the "Repeaters" stat on the community web map now only show repeaters heard in the last 7 days, hiding stale/offline repeaters from the map.

Web Map: Prefix-Aware Repeater Filter

The server-side repeater filter now uses bidirectional prefix matching. Filtering by "0C1377" (3-byte) matches cells with "0C" (1-byte) and vice versa, handling mixed hash-size modes correctly.

Web Map: Hex ID Stability

The server no longer upgrades shorter hex IDs to longer ones in the repeater database or cell references. When a shorter prefix already exists (e.g. "0C"), it is preserved. When a shorter prefix is uploaded and a longer one exists, the longer is downgraded to maintain compatibility with all existing cell references.

Server Fix

Fixed missing averageTxSNR parameter in SurveyController metrics query that was causing Docker build failures.

---

Previous Builds

v0.10.1 (Build 16)

Signal Bars Service

Live repeater signal monitoring with round-robin ping engine measuring RX quality, TX quality, and RTT across all reachable repeaters. Compact firmware-style popover shows all repeaters ranked by signal strength with RX/TX bars, RTT, and age. Best repeater indicator in toolbar. Dual RX/TX bars on survey floating pill.

iMessage-Style Swipe Timestamps

Swipe horizontally on chat messages to reveal per-message timestamps. Works across channels and DMs.

Two-Column RX/TX Cell Detail Card

Cell detail card shows RX and TX data in side-by-side columns with signal bars, quality label, average SNR, and direction-specific details (RSSI under RX, SNR range under each). Shared stats appear below the columns.

Streamlined Survey Completion

Single completion sheet with stats, coverage breakdown, repeater info, personal records, community map impact, and inline upload button.

Survey Completion Stats

Sessions persist completion stats (duration, packets, cell breakdown, repeaters). View saved stats from session list via the chart icon.

Personal Records

Trophy badges for personal bests: longest duration, most packets/cells/connected cells/unique repeaters.

Lifetime Stats Dashboard

Session list header shows lifetime totals across all sessions.

TX SNR Tracking

Survey points capture TX SNR from discover and trace responses. Included in exports and community uploads.

Survey Point Dedup Fix

Heard-repeat confirmations from different repeaters sharing the same packet hash are now recorded separately using a composite dedup key.

Improved Tap Targets

Touch targets across the cell detail card meet Apple's 44pt HIG minimum via contentShape modifiers.

Updated How It Works Guide

Rewritten with 10 sections covering probe settings, cell detail card, RX/TX signal columns, community map, sessions & history, and more.

Survey UX Improvements

Full-row tap targets for empty state actions. Custom back button returns to survey dashboard. Cached session counts for fast loading.

Contact Sync Crash Fix

Fixed EXC_BAD_ACCESS from concurrent SQLite writes during contact sync. Contacts now saved in a single batch transaction.

TipKit Prompt

Contextual prompt encouraging repeater location sharing.

Heard Repeats Share Fix

Fixed blank sheet when sharing heard repeats by using fullScreenCover instead of nested sheet.

---

Previous Builds

v0.10.1 (Build 15)

Path Map

New "Path Map" tool in the Tools tab. Enter hex IDs (comma or space-separated) to visualize the path through repeaters on an interactive map. Hex IDs are resolved against your local contacts and discovered nodes. Supports 2–6 character hex hashes and full 64-character public keys. Includes map controls for layers, label modes, and centering on the path.

Once the map is generated, tap "Share" to upload the path and create a shareable web link (e.g. mesh.digitaino.com/p/abc123). The web page shows the same hop-by-hop map with a collapsible details panel.

Chat Path Detection

Messages containing hex path chains (3+ hex tokens) are now automatically detected. An inline "Path Map" card appears below the message bubble — tap it to open the path on a map.

Web Path Creator

New public web page at mesh.digitaino.com/path for creating shareable path maps in a browser without the app. Enter hex IDs in the form, and the server resolves repeater locations from the community database and generates a short link. Rate-limited, no API key required.

Background Repeater Location Sharing

New opt-in feature that periodically shares your device's known repeater locations with the community server. When enabled, repeater GPS coordinates from your contacts and discovered nodes are uploaded to enrich the community map for everyone. Requires contributor verification via your device's cryptographic key. Uploads are throttled to a 15-minute minimum interval and only sent when repeater data changes. Includes a "Share Now" button for immediate manual uploads.

My Survey Routes

New view in Signal Survey showing your uploaded survey routes from the community server. Displays route status (Created, In Progress, Completed, Abandoned), waypoint progress, skipped waypoints, and origin (web or local).

Repeater Resolver Improvements

The repeater resolver now supports anchor-aware resolution for path visualization. When a previous or next hop location is known, the resolver prioritizes repeaters geographically close to that anchor point, significantly improving accuracy over recency-only matching. Also handles full 32-byte public key inputs by truncating to the matching prefix length.

Server-Side Path Resolution

When creating shared paths (from the app or the web form), the server auto-resolves missing repeater locations using the community repeater database. Uses cascading match logic: exact hex ID, then prefix matching (handles 2-char IDs matching 4-char stored IDs), then public key prefix matching.

Admin Dashboard

New tabs in the admin dashboard: Shared Links (view/delete shared routes, maps, and paths), Survey Routes (lifecycle status, notes, deletion), Plan Sessions (view/manage planning sessions). All tables have sortable column headers. Repeaters and cells can now be hidden from public maps with admin notes.

Bug Fixes

Fixed server-side repeater resolution excluding all repeaters because the hidden field is nullable — NULL != true evaluates to NULL in SQLite, so no repeaters were returned. Fixed admin dashboard linking path shares to /m/ instead of /p/. Fixed shared path web pages not auto-expanding the details panel. Added "No Located Hops" overlay on web path pages when no repeaters could be resolved. Corrected repeater timestamp semantics for lastHeard field. Full public key is now sent with repeater location uploads for better resolution.

---

Previous Builds

v0.10.1 (Build 14)

Plan Survey Route (Experimental)

New route planner in Signal Survey. Tap the route icon in the toolbar to define a survey area by drawing a polygon directly on the map, then generate a walking or driving route through all hex cells in that area. You can also use "Draw on Web" to draw the polygon on a larger screen -- it creates a 6-character pairing code and shareable link, and the polygon is sent back to your phone. Once generated, the route appears as an overlay with turn-by-turn guidance.

CLI Console from Repeater Settings

After logging in as admin on a repeater, a new "CLI" button in the settings view opens the CLI console pre-authenticated to that repeater. No need to re-login from the Tools tab -- the existing session is reused.

Bug Fixes

Improved error messages for "Draw on Web" session creation failures -- now shows actual HTTP status instead of a generic error code.

---

Previous Builds

v0.10.1 (Build 13)

Message Search

The search bar in the Chats list now searches message content across all conversations, not just conversation names. Results appear in a "Messages" section grouped by conversation with highlighted text snippets. Tap a result to jump directly to that message -- it flashes briefly so you can spot it. When a conversation has more than 3 matches, tap "X more" to expand all results inline.

Inside any conversation, pull down to reveal a search bar. A bottom toolbar shows "X of Y" with previous/next arrows to navigate between matches. The current match gets an accent-colored border on the bubble.

Both search modes use database-level queries (case and diacritic insensitive) so they stay fast even with thousands of messages.

Upstream Merge

Channel messages now appear instantly before server confirmation (optimistic sending). New toggle in chat settings for quoting the original message in replies. BLE stability fixes for session reconnect races, RX log pruning, and message auto-fetch coalescing.

Community Map Filters and Performance

The community overlay on both the survey map and standalone map now has a filter toolbar with coverage type (All/Active/Passive), repeater selection, and time range. Filters re-fetch from the server for accurate results. When filtering by a specific repeater, cell detail cards show that repeater's individual SNR/RSSI/packet count. Selecting a repeater filter draws dashed lines from each cell to the repeater's location with arrows for off-screen repeaters. Community hex cells now render via UIKit MKOverlayRenderer, handling 5000+ cells without lag. A "My Cell" button during active surveys zooms to your current cell.

Bug Fix

Fixed scrolling bug in repeater telemetry status history. Thanks ASTpoetry.

---

Previous Builds

v0.10.1 (Build 10)

## Web Share Identity

- **Sharer's name on web links** — Shared route and repeater map web pages now show your MeshCore contact name instead of "You" at the receiver position. When you share a route (`/r/...`) or repeater map (`/m/...`), your device name is included in the upload and displayed on the web page — both in the hop list and on the map marker. Older shares without a name gracefully fall back to "User".

- **Contact name pre-filled for surveys** — The "Include Contact Name" toggle in the survey setup sheet now defaults to on for new installs, so your MeshCore name is automatically associated with community map contributions. You can still toggle it off if you prefer anonymous uploads.

## Community Map Filters & Performance

- **Coverage, repeater, and time filters** — The community overlay on both the survey map and the standalone map now has a filter toolbar with coverage type (All/Active/Passive), repeater selection, and time range. Changing any filter re-fetches from the server so results are accurate, not just client-filtered.

- **Per-repeater signal metrics** — When filtering by a specific repeater, cell detail cards show that repeater's individual SNR/RSSI/packet count instead of the cell's aggregate stats. Active/passive counts are hidden when irrelevant to the selected coverage filter.

- **Cell-to-repeater polylines** — Selecting a repeater filter draws dashed lines from each cell to the repeater's location. Lines for off-screen repeaters extend to the map edge with an arrow indicator.

- **MKOverlayRenderer for community cells** — Community hex cells now render via UIKit `MKOverlayRenderer` instead of SwiftUI `MapPolygon` views, handling 5000+ cells without UI lag.

- **"My Cell" button** — During an active survey, a "My Cell" button in the stats bar zooms to your current cell and selects it. Camera zoom now correctly drives the UIKit MKMapView.

## Server & Performance

- **Server-side filtering** — `/api/v1/cells` now supports `coverage`, `maxAge`, and `repeater` query params, reducing payload size. Spatial index on lat/lon for faster bounding-box queries.

- **Gzip compression** — Server responses are gzip-compressed (~80% reduction). Cache-Control headers added per route type.

- **Raw SQL for cell queries** — Cell fetching uses raw SQL with GROUP_CONCAT for repeater data, replacing N+1 Fluent eager loads.

## Upstream Merge

- **Optimistic sending** — Channel messages appear instantly in the chat before server confirmation.
- **Reply with quote** — New toggle in chat settings for quoting the original message in replies.
- **BLE stability** — Fixes for session reconnect races, RX log pruning, and message auto-fetch coalescing.

---

# v0.10.1 (Build 9)

## Signal Survey Enhancements

- **Time filters on community map** — Both the iOS community map overlay and the standalone Community Map view now have time filters (1 Hour, 12 Hours, 1 Day, 3 Days, 5 Days, All Time) to show only recent survey data. Matches the time filter already available on the web frontend.

- **Community map is now an overlay** — The "Community Map" menu item has been replaced with a toggle that shows/hides community survey data directly on the main survey map, instead of opening a separate full-screen view. Filters for coverage type, repeater, and time are shown in a filter bar when the overlay is active.

- **Survey indicator moved to top-right** — The floating survey status indicator (visible when navigating away from the survey) now appears at the top-right of the screen instead of the bottom-right, avoiding overlap with the tab bar and chat input.

- **Session deselect clears map** — Tapping the X button on a selected session now clears the map entirely instead of loading all sessions. Use the "All Sessions" menu item to explicitly load all session data.

- **Clear Map option** — New "Clear Map" button in the toolbar menu and an X button on the "all sessions" view to quickly clear all survey data from the map without selecting a specific session.

- **Probe count persists on navigate away** — Probe data (`probesSentPerCell`) is now saved to the database when you navigate away from the survey, so returning via the floating indicator correctly restores the probe count instead of resetting to zero.

- **Resume flow no longer flashes empty state** — When tapping the floating indicator to return to an active survey, a "Resuming survey…" spinner is shown instead of briefly flashing the empty "Start Survey" screen.

- **Crash fix for force unwrap** — Fixed two force-unwrap crashes: one when navigating away while community data was loading (`communityUploadService!`), and one in grid bucket lookup (`gridBuckets[hex]!`). Community refresh is now cancelled on disappear.

- **Updated How It Works guide** — The "How It Works" info sheet has been rewritten with sections on radio asymmetry, passive vs. active surveys, hop count interpretation, map legend (including dead zones as gray dashed cells), community map overlay usage, and updated tips for Deep Scan mode, driving mode, and live upload.

---

# Previous Builds

## Build 8 (v0.10.1)

## Shared Repeater Maps — Full Web Experience

- **Repeat-by-repeat navigation on web** — Shared repeater map pages (`mesh.digitaino.com/m/...`) now have left/right navigation arrows matching the iOS "Repeat Coverage" screen. Cycle through individual repeats to see each path's hop chain, SNR, and route lines on the map. The "All" view shows aggregated repeaters with overall hop numbers.

- **Path lines on web maps** — Shared repeater maps now draw dashed outbound lines between hops and solid SNR-colored last-hop lines matching the iOS map rendering. Hop numbers are shown on pins and in the panel list.

- **"You" marker on web maps** — Both shared route and repeater map pages show your approximate location as a "You (approx.)" marker when location was included in the share, with connecting lines to the first/last hops.

- **Community signal overlay on web shares** — Both shared route and repeater map pages now have a toggleable community signal cell overlay (📶 button), showing crowd-sourced coverage data alongside your shared data.

- **Standalone share messages** — Shared repeater maps now compose a standalone message like "📡 4 repeats via 0C, C0, 80, 78" with the URL, instead of replying to yourself.

## Location Privacy for Sharing

- **Location picker for route sharing** — Route sharing now prompts you with an interactive location picker (same as repeater map sharing) where you can adjust your shared position within a 500m circle of your true location, or toggle location off entirely.

- **Simplified location options** — The location picker now offers two clear choices: include an approximate location (snapped to ~500m) or omit location entirely.

## Per-Repeater Signal Metrics

- **Per-repeater SNR/RSSI in cell detail** — When filtering the community map by a specific repeater, the cell detail popup now shows that repeater's individual signal metrics (SNR, RSSI, packet count) instead of the cell's aggregate. This lets you compare signal quality between repeaters in the same cell.

- **Per-repeater data in uploads** — Survey uploads now include per-repeater weighted-average SNR/RSSI/packet counts (format v1.2), enabling finer-grained analysis on the server.

## Repeater Resolver Improvements

- **Recency-first resolver** — With 1-byte path hashes (256 values), collisions are common. The resolver now prioritizes recently-heard repeaters over geographically closer ones, fixing cases where a months-old stale contact would incorrectly match a hash.

- **Multi-byte hash support** — Hex ID consolidation now keeps the longest form (e.g. "8850" instead of "88") for better repeater specificity as multi-byte path hashes roll out.

## Community Web Map

- **Viewport-scoped repeater filter** — The repeater filter dropdown on the web community map now only lists repeaters whose physical locations are within the current map viewport. Zooming in narrows the list; zooming out expands it.

- **SSE real-time updates** — The web community map now receives push updates via server-sent events when new survey data is uploaded, instead of polling every 15 seconds. Cell updates are diff-based, preserving your selected cell popup across refreshes.

## Server Security & Operations

- **API key rotation** — Server now reads the API key from environment variables instead of hardcode. Supports dual-key acceptance (`SURVEY_API_KEY` + `SURVEY_API_KEY_OLD`) for zero-downtime key rotation.

- **Rate limiting** — Per-IP rate limiting added: 60 requests/minute for public endpoints, 10/minute for write endpoints (uploads, share creation).

- **Access logging** — Apache Combined Log Format access and error logging for all requests.

- **XSS protection** — HTML escaping and script-tag sanitization on shared route/map pages.

- **Database backups** — New deploy script automatically backs up the SQLite database before every rebuild, keeping the 10 most recent backups.

- **iOS API key in xcconfig** — API key moved from hardcoded Swift string to a gitignored `Secrets.xcconfig` file, read at runtime via Info.plist.

## Bug Fixes

- **Mesh Reach redesign** — Now shows max hop depth (1=direct, 2=one relay, etc.) instead of raw trace packet count.

- **Active filter fix** — Active probing filter now only counts `.control` packets (bidirectional discover responses) instead of including one-way `.trace` floods.

- **Follow-cell camera offset** — When tracking your location during a survey, the map center shifts slightly north so the current cell appears above the detail card instead of being hidden behind it.

---

## Build 7 (v0.10.1)

## Share Heard Repeaters

- **Share repeater map from messages** — On sent channel messages with heard repeats, a new "Share" button uploads the aggregated repeater data to the server and generates a shareable web link (e.g. `mesh.digitaino.com/m/abc123`). The web page shows all heard repeaters on an interactive map with signal quality color coding, heard counts, SNR/RSSI stats, and a collapsible detail panel.

## Route Distance Fix

- **Correct route distance calculation** — Fixed a bug where shared route distances were significantly underestimated (e.g. 1.4 mi instead of ~4 mi). The issue was caused by 1-byte hop hashes falsely matching non-repeater contacts whose public key prefix collided, producing wrong or missing locations. Hop resolution now prioritizes repeater-typed contacts before falling back to discovered nodes and then all contacts.

- **Direct distance computation for shared routes** — Route sharing now computes distance directly from resolved hop coordinates instead of parsing it from the route info string, ensuring the web link always shows the correct distance.

## Active vs Passive Survey Probing

- **Active/passive packet distinction** — Survey data now tracks whether each packet was collected during active probing (bidirectional confirmation via trace/control packets) or passively (RX only). The cell detail card shows separate active and passive packet counts.

- **Active/Passive filter on community map** — Both the iOS Community Map and the web frontend at mesh.digitaino.com have Active/Passive/All filter buttons. Filter the coverage map to see only actively probed cells, passively heard cells, or both.

- **Faster active probing** — The probe scheduler now triggers more frequently on cell-exit events, improving coverage density during wardriving.

- **Session close button** — Active survey sessions now have a close button in the toolbar for quick access.

---

## Signal Quality Bars & Repeater Filtering

- **Signal quality bars in cell detail** — Both the iOS community map and the web frontend cell popups now show a 5-segment visual signal quality bar (like cellular bars) color-coded by SNR quality level. Makes it easy to gauge signal strength at a glance.

- **Repeater filter** — Filter the community map by specific repeater. A dropdown menu lets you select a repeater (shown by name when known, hex ID otherwise) and see only cells where that repeater was heard. Available on both the iOS community map and the web frontend.

- **Selected cell highlight** — On the web frontend, clicking a cell now highlights it with a white border on the map so you can see which cell's popup you're viewing.

---

## Batch Upload & Session Deduplication

- **Upload Sessions picker** — The "Upload All Sessions" button has been renamed to "Upload Sessions..." and opens a multi-select picker where you can choose which sessions to upload, not just all of them.

- **Idempotent uploads** — Each upload now includes session UUIDs. The server tracks which sessions have been uploaded and automatically replaces previous data for those sessions instead of accumulating duplicates. Re-uploading the same session is safe and produces the same result.

- **Live upload dedup** — Live per-packet uploads are tagged with the active session ID. When you later do a batch upload of the same session, the server removes the live-uploaded data and replaces it with the consolidated batch, preventing double-counting.

- **Delete My Server Data** — New option in the Upload Sessions toolbar menu lets you delete all your contributed data from the community map server. Useful for starting fresh.

---

## Hex ID Normalization

- **Consistent repeater hex IDs** — Repeater hex IDs are now normalized across sessions and upload paths. Different-length hashes for the same repeater (e.g. "0C" vs "0C13") are consolidated to the shortest unique prefix, ensuring consistent cell-to-repeater associations in the community map.

---

## Build 4 (v0.10.1)

### Community Signal Map

- **Live upload to community map** — New "Live Upload" toggle in the survey setup sheet. When enabled, each received packet's hex cell is immediately uploaded to mesh.digitaino.com as you survey, so the community coverage map updates in real time. Data is anonymized — only hex grid cells (~100m), signal stats, and repeater IDs are sent. No exact GPS, device identity, or message content is included. When disabled, you can still export and upload a full session manually from the toolbar menu after the survey.

- **Community map auto-refresh** — The community signal map overlay (both the dedicated Community Map view and the main map's hex overlay) now auto-refreshes every 15 seconds, so cells uploaded by you or other users appear live without needing to pan or zoom. The web frontend at mesh.digitaino.com also auto-refreshes.

- **Community overlay on main map** — Toggle the hex overlay from the main map to see crowd-sourced signal quality from all contributors, not just your own surveys. Cells are color-coded by SNR quality and scale opacity by contribution count.

- **Repeater names and locations in uploads** — Community uploads now include resolved repeater names and GPS locations (from your known contacts), so the community map can show named repeater pins, not just hex IDs.

### Shareable Route & Repeater Maps

- **Shareable route links** — When you "Reply with Route", the route data is uploaded to the server and a short URL is generated (e.g. `mesh.digitaino.com/r/abc123`). The link opens a web page with an interactive Apple MapKit JS map showing the route plotted through repeaters with hop-by-hop annotations, a polyline connecting located hops, and a collapsible details panel with hop count, distance, and a list of each hop.

- **Shareable repeater map links** — Similarly, repeater maps can be shared as web links showing all your known repeaters with signal quality color coding, heard counts, SNR, and RSSI stats.

- **Collapsible share panels** — The web pages for shared routes and repeater maps have a collapsible bottom panel that you can tap to expand/collapse, keeping the map unobstructed.

### Traffic Map Overhaul

- **MKMapView with clustering** — The traffic map has been rebuilt from SwiftUI Map with Annotation views to a native MKMapView (UIViewRepresentable) with proper annotation clustering, native callouts, and correct hit testing. Overlapping repeater bubbles are now tappable even when dense.

- **Public key hex on pins** — Repeater pins now show the first byte of the node's public key as a hex label (e.g. "A3") instead of a generic antenna icon. This makes it easy to identify individual repeaters at a glance. The full public key is shown in the detail sheet.

- **Tappable callouts** — Tapping a repeater pin shows a native MKAnnotation callout with packet count, SNR, last-seen time, and a 3-byte key prefix. A "Details" button opens the full detail sheet with signal stats and the complete public key.

- **Info guide button** — New info button in the traffic map toolbar opens a guide sheet explaining pin colors, SNR thresholds, route lines, callouts, and time period filtering.

- **SNR last-hop-only fix** — Signal quality (SNR) is now correctly attributed only to the last hop in the packet path. Previously, the same SNR was misleadingly applied to all hops and route segments. Route lines now use uniform cyan with opacity scaling by traffic volume instead of SNR-based coloring.

- **Time period filtering** — The traffic map's time period menu dynamically adapts its options based on how old the data is (e.g. Last 15m/30m/All for recent data; Last 1d/3d/7d/All for older data). The selected period filters which packets are shown on the map.

- **Location button fix** — The location button in the traffic map toolbar now correctly centers the map on the user's location, even after manually panning.

### Map — Last Heard Filter

- **Time filter bar on main map** — A scrollable filter bar at the top of the main map lets you filter displayed nodes by when they were last heard: 1 Hour, 12 Hours, 1 Day, 3 Days, 5 Days, or All Time. This makes it easy to see which repeaters and nodes are currently active versus stale.

### Branding

- **PocketMesh → DigitainoMesh** — Updated user-facing references from "PocketMesh" to "DigitainoMesh" in the survey export filename, setup sheet text, and code documentation. Internal identifiers and upstream attribution remain unchanged.

## Build 3 (v0.10.1)

### Signal Survey (Wardriving)

- **Coverage heatmap tool** — New tool under Tools > Signal Survey. Start a GPS-tagged survey session that pairs every received RF packet with your phone's location. As you move around, the app builds a live coverage map of your mesh network's signal quality.

- **Hex grid heatmap** — Received packets are aggregated into a hex grid overlay on the map. Each cell is color-coded by average SNR (green = excellent, red = poor). Tap any hex cell to see a detail card with signal quality, packet count, and which repeaters were heard in that cell. The heatmap is the default visualization; you can switch to a raw point cloud view if preferred.

- **Active trace probing** — Toggle active probing to automatically send flood traces on a smart schedule (triggered by cell-exit or a max timer). Probed repeaters appear in the cell detail card alongside passively heard packets. Filter the heatmap by All / Passive / Active to see probe-only vs. passive-only coverage. A manual probe button with heavy haptic feedback and a visual pulse animation lets you trigger a trace on demand.

- **Repeater annotations** — Resolved repeater contacts with GPS locations appear as cyan antenna pins on the survey map. Tap a repeater pin to see a detail sheet with name, public key, coordinates, and a "View Contact Card" button. When you select a repeater filter chip in the cell detail card, a dashed line is drawn from the cell center to the repeater's location on the map.

- **Session management** — Create, rename, and delete survey sessions. Switch between sessions to review past data. The active session resumes automatically when navigating back to the survey. A "Recording" indicator is visible from the Tools list. Screen lock is prevented during recording.

- **JSON export** — Export anonymized grid data as JSON for external analysis.

  **How to test:** Go to Tools > Signal Survey. Tap "Start Survey" and walk/drive around with your MeshCore device connected. Verify hex cells appear and update as packets arrive. Tap a cell to see the detail card — check signal bars, quality label, packet count, and repeater chips. Switch between All/Passive/Active filters and verify the cell colors and card stats update. Toggle active probing and verify traces are sent (the manual probe button should show an expanding orange ring). Tap a cyan repeater pin and verify the detail sheet shows correct info. Navigate away from the survey and come back — it should resume recording. Try renaming and deleting a session.

---

### Nodes List Improvements

- **Search by public key** — The search bar in the Nodes list now matches against public key hex prefixes. Type a hex string like "0C" or "D1A9" and nodes whose public key starts with that prefix appear at the top of results, followed by substring matches, then name-only matches.

- **Public key prefix display** — Each node row now shows the first 3 bytes of the node's public key in monospaced text below the name and distance (e.g. "0C 13 77"). This makes it easy to identify nodes by their key prefix at a glance.

- **Public key in map contact detail** — Tapping a node pin on the map and opening its detail card now shows the full public key in a selectable monospaced field.

  **How to test:** Open the Nodes tab and verify each row shows a 3-byte hex prefix below the name. Use the search bar — type a 2-character hex prefix and verify the matching node appears at the top. Open the map, tap a node pin, and verify the detail card shows the public key.

---

### Maps Modernization

- **SwiftUI Map migration** — All route maps have been modernized from UIKit MapKit wrappers to native SwiftUI Map views. This improves rendering consistency and simplifies the codebase.

- **DM path display fix** — Direct message route maps now correctly show the message path.

- **Contact route map fix** — The contact route map now correctly renders the aggregated route history.

---

### Upstream Merge & Unified Chat

- **Unified chat view** — DM and channel chat views have been merged into a single `ChatConversationView`, reducing code duplication and ensuring feature parity between DM and channel conversations.

- **Performance improvements** — SwiftData indexes added to Contact, Channel, and RemoteNodeSession models. Conversation reload tasks are debounced. Existence checks use `fetchCount` instead of full fetches.

- **Persistent message deduplication** — Replaced the in-memory dedup cache with persistent packet hash deduplication, preventing duplicate messages across app restarts.

- **Crash fix** — Handle transient ModelContainer creation failure during app launch with automatic retry.

---

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

### Route Distance on Maps

- **Message route map distance** — The message route map now displays the total chain distance along the path at the top of the screen. Uses "≥" prefix only when intermediate repeaters in the route are missing location data.

- **Heard repeats map distance** — The heard repeats map shows the total path distance when viewing a single repeat.

  **How to test:** Open a message route map for a multi-hop message — verify the distance badge appears. If all repeaters have GPS, the distance should be exact (no ≥). If some intermediate repeaters lack location, it should show ≥. Check the heard repeats map similarly.

### Swipe to Reply Fix

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
