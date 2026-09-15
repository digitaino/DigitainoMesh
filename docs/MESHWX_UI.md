# Weather tool UI — rework spec (v2)

Status: v2, 2026-09-14, after three adversarial reviews (first-time user and wording; severe
weather and data honesty; SwiftUI feasibility and state completeness). Replaces the first-cut
screen shipped in `5244d996`. §3 records every review finding that changed the design, and the
ones that were rejected, with the reason.

## 1. Why the first cut failed

Rafael opened it on his phone (iPhone 15 Pro Max, live WX-AUS on the air) and asked why there
was a long list of observations already, why he had to scroll to find anything, what the
CT NJ NY TX tab bar was, and where the stations and the warnings came from. The phone's own
state file (`devicectl` copy, 23:25) answers each one:

| What he saw | Cause in the data | Cause in the UI |
|---|---|---|
| A long list of observations | The bot broadcasts its whole coverage batch hourly: 14 central-Texas stations | Every station a four-line row, no primary reading, no ranking that meant anything |
| Scrolling for everything | — | Seven sections at one level: warnings, 14 stations, three forecasts × 7 rows, a product panel |
| CT NJ NY TX tabs | Someone else on the mesh asked for Central Park NY and San Juan forecasts; answers are broadcast, so the phone kept them | The text section took its office from the newest forecast held (New York, OKX) and offered OKX's states plus the stations' Texas |
| "Where do the stations come from?" | Observation messages, type 4 | Nothing on screen named the source, the area or the time |
| "What would the warnings be from?" | Warning and digest messages for the bot's coverage; the phone had **no digest yet** | "No active warnings" shown while the app did not know |

Further defects in the same data:

- **The live bot's forecasts are daily, not 12-hour periods.** All three held forecasts start
  at period 0 with seven entries, each carrying a high and a low (Austin Camp Mabry: 102/77,
  100/78, 98/75, 97/73, 98/74, 99/76, 96/81). Spec §7 describes alternating day/night periods,
  one temperature each. The first cut labelled them Today / Tonight / Tomorrow night and
  showed only the high: "Tonight High 100°".
- **Placing the phone outside coverage ranked nonsense as "now".** In the simulator (location
  in California) the nearest of the 14 stations was Llano, the westernmost.
- WX-AUS's advert carries no position (0,0).
- *(Corrected after review.)* The radio's channel table does carry `#meshwx`, at slot 31 of 32,
  beside the legacy `#meshwx-discover` and `#aus-meshwx-v4`. An earlier draft said it was
  missing; that came from a query whose output was cut off.

## 2. Principles

1. **One place drives the screen**: where you are, or a town you searched. Alerts, current
   conditions and the forecast all answer for it, and the screen says which place it is.
2. **Silence is not calm.** A green check means "no alerts received, and this phone would have
   received them" — never "safe". Every other case says what is not known and why.
3. **Every number names its source and its age**, measured on the bot's clock (`now`, `ts`,
   `issued`), never on when the phone happened to read it out of the radio's queue.
4. **An answer on the channel is everyone's.** Other people's answers are kept and labelled
   as theirs; this phone's own requests are said to be public before they are sent.
5. **Asking costs everyone airtime**: one deliberate tap, a button that says what it asks,
   progress where you can see it, nothing automatic, and no second request for anything the
   channel delivered in the last five minutes.
6. **Details one tap away, not one scroll away.** The main screen is a summary; alerts and
   current conditions are above the fold on a 6.1" iPhone; everything else drills in.

## 3. Review decisions

| # | Finding | Decision |
|---|---|---|
| A1 | A green check could sit beside a tornado warning one county over | **Adopted.** Alerts near the place (≤ 50 km) are rows in the card with distance and direction; the green check appears only when nothing is active anywhere in the bot's area |
| A2 | Ask buttons stay live when the answer cannot arrive (old firmware, no channel) | **Adopted.** Buttons are replaced by the blocking reason |
| A3 | The coverage centroid names "Brushy Creek" and a Georgetown forecast | **Adopted.** No centroid place; with no location the card asks "Where do you want weather for?" |
| A4 | A searched town sticks and answers tomorrow's "anything dangerous?" | **Adopted.** Searched places last for the visit; the header offers "Back to my location" |
| A5, M7 | "updated 2 min ago" reads as "everything is current" | **Adopted.** "WX-AUS heard 2 min ago"; time words cut to *as of*, *issued*, *heard* |
| A6 | Unknown state jargon; the button does not help when the feed is stale | **Adopted.** Plain reasons, button only where it can help (§7.4) |
| A7, M5 | Button feedback vanishes or never appears | **Adopted.** Status keyed by request, persists until the next tap, names the time |
| A8 | Asking is public and nothing says so; New York looks like a bug | **Adopted.** Footer under ask buttons; "Asked for by others nearby" section, 24 h expiry |
| A9, B5c | Outside coverage "none nearby" reads as calm | **Adopted.** "WX-AUS doesn't report on Dallas, so alerts there are unknown" |
| A10, M13 | Three answers do not fit above the fold on a storm night | **Adopted.** Promise alerts + Now only; cap alert rows at 2 + "N more" (tornado warnings never fold) |
| A11 | Source of stations and warnings still not on screen | **Adopted.** Source lines on both cards and screens |
| A12 | Raw names ("Draughon-Miller Cntrl Tx Rgnl Arpt") | **Adopted.** Abbreviation expansion and suffix stripping |
| A13 | Seven verbs for one action | **Adopted.** Every radio request starts with "Ask" |
| A15 | METAR/TAF unreadable in "Reports" | **Adopted.** Moved into the station screen as "Pilot report (coded)" |
| B1 | Freshness by receipt time; clock skew ends warnings early | **Adopted** bot-clock ages. **Rejected** the clock-offset estimator for this cut: a covering alert that passed its expiry in the last 15 min stays as "Expired · no update received", which absorbs realistic skew without guessing an offset |
| B2 | Gap, missing identity or unfinished upgrade does not block the check | **Adopted** in the reducer (gap tracking, upgrade markers) and in §7.4 |
| B3 | A cached or older digest deletes newer warnings | **Adopted** in the reducer: a digest never removes or shortens a warning received after it was built (10 min margin); an older digest is ignored. **Rejected** exact-length decoding: the reference codec accepts trailing bytes; the slot filter (M3) is the protection instead |
| B4 | One bot's data drives the card | **Adopted.** Alerts are the union across bots, deduplicated by identity |
| B5 | "Coverage" invented; the check claims more than was tested | **Adopted**: station footprint from multi-station batches in the last 24 h; the check requires the place inside it. **Adopted in part**: office coverage is only claimed *against* ("may not carry alerts for Bell County") when the bot has shown the offices it carries |
| B6 | Point test without uncertainty; old fixes; saved place far away | **Adopted.** Uncertainty radius, "near" rows, last-known location never earns a check |
| B7 | The design invites a request storm | **Adopted**: overheard answers satisfy the five-minute rule; no retry once the bot has been heard. **Rejected** random send jitter: the cache already collapses a storm to the first answer, and jitter delays the one tap that matters. **Changed**: a bot not heard for 90 min gets a caption, not a block |
| M1 | Stale readings beat fresh ones; "59%" unlabelled | **Adopted** |
| M2, m1 | Forecast labels wrong after midnight; grouping hides storms | **Adopted.** Rows relative to now; merged flags; shape read from the data |
| M3 | Weather data accepted from any channel slot | **Adopted.** Only the slot holding the `#meshwx` secret |
| M4, M6 | Text shown under the wrong label; someone else's forecast settles yours | **Adopted.** Replies record the request that produced them; forecasts always asked by point index; "Home forecast" removed |
| M5 | Tornado warning folded behind shorter-lived warnings | **Adopted.** Fixed event priority (§7.2) |
| C-B1 | Pushing a screen detaches the model | **Adopted.** The model lives as long as the tool |
| C-B3 | Confirmation dialogs become popovers anchored to vanishing banners on iPad | **Adopted.** `.alert` only |
| C-M3 | Offline, every bot looks heard-only | **Adopted.** Bots read from the offline data store |
| C-M7 | ScrollView cards invisible on the default theme | **Changed.** The screen is an inset-grouped `List` whose sections read as cards; theming comes free |
| C-M8, M9 | Tables and geometry on the main actor; recomputation unspecified | **Adopted.** One snapshot built off the main actor on defined triggers |
| C-M11 | Value-based navigation links do not push in the compact stack | **Adopted.** Destination-closure links |
| — | Radio's configured position as a place source | **Rejected.** Often a home address or deliberately offset; an unlabelled hand-typed coordinate is exactly the false-calm path B6 describes |
| — | Tapping a station makes it primary | **Rejected.** Details only |
| — | Local notification for a new covering warning | **Out of scope** — product decision for Rafael (§14) |

## 4. Information architecture

```
Weather
├── Header: place (▾ picker) · source line (ⓘ About)
├── Status banner (only when blocking)
├── Alerts card ──────────── Alert detail (map, covers-line, areas, narrative)
│                            Alerts in WX-AUS's area (map + list)
├── Now card ─────────────── Stations (list; station detail with pilot report)
├── Forecast card
└── Reports row ──────────── Weather Service text reports → product screen
```

## 5. The place

`WeatherPlace` = kind (`current`, `lastKnown`, `searched`), coordinate, label, uncertainty
radius r (km).

- **Current location**: the phone fix. Resolved once per appearance, with up to 5 s
  "Locating…" if no fix yet; a late fix replaces the place only if the user has not picked
  one. r = max(accuracy, 0.5 km) + min(1 km per minute of age beyond 5 min, 25 km).
- **Last known**: a phone fix older than 60 min. Shown as "Last known location · 3 h ago";
  never earns a green check.
- **Searched**: a town from `places.json`, r = 5 km, labelled "For Round Rock, TX". Lasts
  until the tool is left; the header offers "Back to my location".
- **None** (location undetermined, denied, or never fixed): the header reads "Choose a place";
  the Alerts card still lists every alert in the bot's area without "here" claims; the Now and
  Forecast cards ask "Where do you want weather for?" with *Use my location* and *Search a town*.
  Denied shows "Location is off · Settings".

Label: nearest place of ≥ 1,000 people within 25 km, title-cased with its state; else the
nearest station's city; else "this location".

## 6. Coverage footprint

The stations the bot reported in multi-station batches received in the last 24 h (a batch of
one is somebody's single-station request and says nothing about coverage). A place is **in
coverage** when a footprint station is within 80 km. Out of coverage, every card says so
rather than answering from far away.

## 7. Alerts

### 7.1 Placement

Alerts are the union of all bots' held warnings, deduplicated by identity (freshest message
wins). Each is placed relative to the place:

| Placement | Rule |
|---|---|
| **here** | Its polygon contains the place or passes within r; or one of its areas (county or zone) contains the place or passes within r |
| **near** | Its outline is within 50 km; carries distance and compass direction |
| **checking** | It names areas and the outlines are still loading |
| **unplaced** | No polygon and no outline for any of its areas — never "not here" |
| **elsewhere** | Everything else in the bot's area |

Upgrade markers (spec §4 flag 2) are placed by the upgraded warning's geometry and shown as
"Upgraded — replacement not received". A *here* alert that expired less than 15 min ago stays
as "Expired 3 min ago · no update received".

### 7.2 Order

Tornado Warning, Extreme Wind Warning, Flash Flood Warning with catastrophic damage tag,
Severe Thunderstorm Warning with a tornado tag, Flash Flood Warning, Severe Thunderstorm
Warning, then other warnings, watches, advisories, statements; within a rank, soonest expiry.

### 7.3 Card

- Rows: *here* (and upgrade/expired rows placed here) first, then *checking*/*unplaced*, then
  *near*. At most 2 rows plus "N more"; Tornado Warnings here are never folded.
- A row: severity colour bar, icon, event name, "until 11:41 PM · in 40 min", one truncating
  line of tags, and for *near* "25 km N".
- Footer: "N elsewhere in WX-AUS's area ›" when any, then the status line (§7.4), then
  "National Weather Service alerts, relayed by WX-AUS".

### 7.4 Status line

Evaluated in this order; the first that applies wins.

| Condition | Line | Action |
|---|---|---|
| No place | "Choose a place to see which alerts cover it" | — |
| Place out of coverage | "WX-AUS doesn't report on Dallas, so alerts there are unknown." | — |
| No digest from any covering bot | "Alerts not checked yet. WX-AUS sends its alert list every 3 hours; none has arrived." | Ask for alerts |
| Feed stale | "WX-AUS hasn't heard from the Weather Service for 5 h. New alerts may not reach you." | — |
| Radio offline | "Radio offline. Last alert list as of 11:02 PM." | Connect caption |
| Gap, missing identity or upgrade marker | "This phone missed messages from WX-AUS. Some alerts may be missing." | Ask for alerts |
| Digest built more than 3 h 15 min ago, or before this radio session started | "Last alert list as of 8:02 PM." | Ask for alerts |
| Last-known location | "Your location is 3 h old." | Update location |
| Bot shows offices, place's office not among them | "WX-AUS may not carry alerts for Bell County (NWS Fort Worth)." | — |
| Alerts here/near/checking/unplaced | (rows speak; no status line) | — |
| Alerts only elsewhere | "None for your location · as of 11:02 PM" (no check) | — |
| Nothing anywhere | ✓ "No alerts received · as of 11:02 PM" | — |

## 8. Now card

- Primary station: the nearest **non-stale** station to the place within 80 km; beyond 25 km
  the source line reads "Nearest report · 40 km NW".
- Large temperature (scaled), sky icon (night variant after sunset hours), condition word
  (none for "other"), "Feels like 91°" when different, "Wind SSE 12", "Humidity 59%". All
  fields from one station.
- Source line: "Austin–Camp Mabry · 3 km · in WX-AUS's 11:18 PM report".
- Stale (no fresh station within 80 km): the nearest reading in small type with "3 h old".
- None within 80 km: "No weather station near Dallas. Nearest: Temple, 190 km."
- Footer: "14 weather stations ›".
- Empty: "No current conditions yet. WX-AUS broadcasts them every hour." + Ask.

## 9. Forecast card

- Point: the nearest bundled forecast point to the place. A held forecast for a different
  point within 10 km of the place is used instead, and says so ("from Austin Camp Mabry, 4 km").
- Shape from the data (`MeshWXForecastLayout`): **days** → one row per day with high/low;
  **periods** → day and night paired into one row, flags merged (thunder, wintry, windy, fog
  from either half), the higher rain chance with its half ("70% tonight"); **mixed** → one row
  per entry, labelled by its period id, every temperature shown.
- Rows are labelled against *now* (Today, Tonight, Tomorrow, weekday); rows that have ended
  are dropped.
- Title "Forecast for Austin"; subtitle "issued 7:52 PM"; stale (> 12 h) "issued 14 h ago" in
  orange + Ask.
- Nothing held for the place's point: "No forecast for Austin yet." + Ask for forecast.

## 10. Header and banners

```
Austin ▾
Your location · WX-AUS heard 2 min ago   ⓘ
```

Banners, at most one, above the cards:

| Condition | Banner |
|---|---|
| Firmware below v1.15 | "This radio has firmware 1.14. Weather needs MeshCore 1.15 or newer." |
| No slot holds the `#meshwx` secret and no weather datagram this session | "#meshwx isn't set up on this radio." + Add channel (`.alert` confirmation, write after dismissal) |
| No weather bot known and nothing heard | "No weather radio heard yet. They appear as nodes named like WX-AUS." |

Radio offline is part of the header's second line ("· radio offline"), not a banner. A bot
heard on the channel without an advert is named "Weather radio 041D" and its ask buttons say
"Can't ask until it announces itself".

## 11. Requests

- Labels: "Ask for alerts", "Ask for current conditions", "Ask for forecast", "Ask for latest".
- Under the first ask button on each screen: "Everyone listening on #meshwx gets the answer."
- Status is keyed by the request, so any button for it shows it, and a screen-level line shows
  it when the sender is not on screen:
  - pending: "Asking WX-AUS… (up to 30 s)"; retry: "Asking again…"
  - answered, content changed: nothing (the card updates); unchanged: "Up to date · issued 7:52 PM"
  - served from what the channel delivered: "WX-AUS sent this 40 s ago"
  - timed out, bot silent: "No answer at 11:26 PM. WX-AUS may be out of range."
  - timed out, bot heard: "WX-AUS was heard but didn't answer at 11:26 PM."
  - not available: "WX-AUS has no data for that yet" / "…didn't recognise that place" /
    "…can't do that" / "…had an error" / "…is busy, try again in a few minutes"
  - rate limited: "Wait a few seconds between requests"
  - Outcomes persist until the next tap on that button or 5 minutes.
- Other buttons while a request is pending: disabled, "Waiting for another answer…".
- Offline: "Connect your radio to ask WX-AUS" in place of buttons.
- Bot not heard for 90 min: caption "WX-AUS not heard since 8:02 PM — it may not answer".

## 12. Secondary screens

- **Alerts in WX-AUS's area**: a non-interactive map header (all polygons and area fills, the
  place) that opens the full map on tap; sections Here, Near, Elsewhere; the status line;
  "Listed, not received · Ask" rows (one request `>w <place county>` when several are missing).
- **Alert detail**: map (location layer only when authorized), "Covers Austin" / "Doesn't cover
  Austin (25 km N)" / "Can't tell whether this covers Austin", times, office, tags, areas,
  "Ask for full text"; the narrative shows only when it answered this phone's request for this
  identity.
- **Stations**: "Airport weather stations. WX-AUS broadcasts their readings every hour." List
  sorted by distance from the place: footprint stations, then "Answers to other people's
  requests". Station detail: all readings, age, and "Pilot report (coded)" with Ask for METAR
  and Ask for TAF.
- **Weather Service text reports**: Forecast discussion ("Forecaster's notes, technical —
  NWS Austin/San Antonio"), Hazardous weather outlook ("for WX-AUS's area"), Storm reports and
  Rainfall totals ("Texas · Change"), Space weather. Each product screen shows the latest
  text that answered this phone's request, or labels one somebody else asked for; missing-part
  markers; Ask for latest.
- **Place picker** (sheet, `.searchable` on its own list): Current location (with its state),
  search results with state and distance, "Asked for by others nearby" (forecast points held
  that this phone did not request, received in the last 24 h, excluding 0xFFFF) with the footer
  "When anyone asks WX-AUS, the answer goes to everyone listening. Who asked isn't shared."
- **About weather on the mesh** (sheet): how it works in four lines; weather radios as inline
  rows with checkmarks (no menu) — heard time, feed health in words; `#meshwx` slot and last
  datagram; "Clear received weather" (`.alert`).

## 13. Engineering

- **Lifetime**: the model is owned by the tool root and is not detached on `onDisappear`;
  `attach` is idempotent under `.task(id: servicesVersion)`; its tasks live in a holder that
  cancels them on deinit.
- **Snapshot**: views read one `WeatherScreenSnapshot`, rebuilt off the main actor on a service
  event, place change, bot change, location sample change, geometry load, or scene activation.
  A 30 s tick refreshes only times.
- **Tables and geometry**: warmed off the main actor; GeoJSON loaded only when an area-based
  alert is held, once, shared.
- **Location**: a value struct projected from `LocationService`; `onChange` on it, never on a
  `CLLocation`; the map's location layer gated on authorization; no automatic permission prompt.
- **Presentation**: `.alert` for confirmations; sheets for picker and About; destination-closure
  navigation links; no menus that tear down their host.
- **Accessibility**: sections `.contain` with a summary element; request status in
  `accessibilityValue` plus an announcement when it settles; scaled temperature; tags as one
  truncating `Text`.
- **Pure types** (MC1Services, `Services/Weather/Screen/`, macOS-testable): `WeatherPlace`,
  `WeatherLocationSample`, `WeatherCoverage`, `WeatherAlertPlacement`, `WeatherAlertStatus`,
  `WeatherAlertPriority`, `WeatherPrimaryStation`, `WeatherForecastRows`, `WeatherNames`,
  `WeatherRequestStatus`, `WeatherScreenSnapshot` + builder. Tested against the phone's real
  state and the kit vectors.

## 14. Questions for Rafael

1. **Forecast shape**: WX-AUS sends seven daily entries with both temperatures and
   `first_period` 0. Is that the intended v5 shape (then spec §7 needs updating, and what does
   `first_period` mean for days), or a bot bug?
2. **Alert coverage**: what decides which alerts WX-AUS relays — its NWS offices, a radius, a
   county list? The app currently infers coverage from the stations it reports. Advertising the
   offices in the protocol would let the app say "No alerts" with confidence.
3. **Cached digests**: spec §8.2's five-minute answer cache can re-send an alert list that a
   newer warning has already overtaken. The app now protects itself; should the bot also drop
   its cached `>d` answer whenever its warnings change?
4. **Notifications**: should a new warning covering your location notify you when the screen is
   closed (opt-in)? It needs a severity threshold decision.

## 15. Not in this cut

Local notifications; a stations map; request jitter; a phone-to-bot clock-offset estimator;
forecast points' own time zones (day labels use the phone's); widgets.
