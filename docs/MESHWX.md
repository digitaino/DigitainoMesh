# MeshWX — the weather tool

Branch: `feature/meshwx` (off `personal`). Status: v5 protocol; first cut 2026-09-14, screen
reworked 2026-09-15 (docs/MESHWX_UI.md), then brought in line with the bot's spec revision 3 the
same day (docs/MESHWX_UI.md §3.1, R-1 to R-10). Revision 4's Coverage message (type 8) is decoded
and is now what the app reads a bot's area from, in place of the station guess (below). Revision
6's Request datagram (type 9) is how the app asks, in place of the DM (2026-09-17,
docs/MESHWX_UI.md §3.1.2 V-7; "Requests", below).

The Tools tab gains a **Weather** tool that listens to the MeshWX v5 weather bot
(`WX-<city>`, e.g. `WX-AUS`) on the `#meshwx` channel and shows what it hears:
active warnings on a map, current conditions for the nearby METAR stations, the
point forecast, and narrative text on request. The protocol is the owner's own
(`meshcore-weather`, kit cut 2026-09-15); this document records how the app maps
it onto the existing architecture and the decisions taken on 2026-09-14.

The reference codec came with the kit (`MeshWX_iOS_Kit_2026-09-15/`). The spec and the wire
vectors now live in the bot's repository (`docs/MeshWX_v5_Spec.md`, revision 3, and
`docs/meshwx_v5_vectors.json`): revision 2 corrected what the kit described, revision 3 fixed the
bot. The app vendors only what it needs, listed below.

## Decisions (Rafael, 2026-09-14)

| Question | Decision |
|---|---|
| Branch | `feature/meshwx` off `personal`, merged in when ready — same shape as packet-scope and signal-mapper. |
| Zone/county polygons (15 MB of GeoJSON) | **Bundled**, both files. Full area fills for every warning type; the centroid-pin fallback still exists for a code with no polygon (spec §9). |
| App requests to the bot (`>f 102` …) | Sent at the **session level**, never through `MessageService`. No chat rows and none of `MessageService`'s ACK bookkeeping (the weather service watches the radio's confirmation itself, below); the bot's DM thread stays the human `wx austin tx` surface. |
| Adding `#meshwx` to the radio | **Prompted.** The tool shows an "Add #meshwx to this radio?" card with a button; nothing is written until tapped. |

## Layers

```
MeshWX (SwiftPM target in MC1Services/)     codec + tables + geometry, Foundation only
   ▲
MC1Services/Services/Weather/               WeatherService actor: session ingest, state, requests
   ▲
MC1/Views/Tools/Weather/                    WeatherToolModel (@Observable, per tool visit) + the screens
```

### MeshWX target

Pure port of `reference/v5.py`. `MeshWXDecoder.decode(Data) -> MeshWXMessage`,
`MeshWXEncoder.*` (so the vectors round-trip and tests can fabricate traffic),
`MeshWXTables.shared` (offices / stations / states / events / places / points /
zones / counties / offices, loaded from `PreloadBundle/` — not `Resources/`: a
top-level directory of that name inside the SwiftPM resource bundle reads to
`codesign` as an old-style versioned bundle and fails the iOS build), `MeshWXGeometry` (polygon
rings by UGC code, lazy), and `MeshWXPresentation` (sky → SF Symbol, event → tint
and icon, staleness rules) so every rendering rule is unit-testable on macOS.

ZIP codes (spec §9, §11). `PreloadBundle/zips.json` is the bot's `client_data/zips.json` byte for
byte (1,082,771 bytes, 33,144 Census 2020 ZCTAs; `MeshWXZipTests` pins its SHA-256), so a ZIP
resolves the same texted to the bot as typed into the app. It is not read at launch:
`MeshWXTables.zip(_:)` reads it on the first query that is a ZIP, behind a `Mutex` as
`MeshWXGeometry` does. The rule is the bot's: 5 digits or ZIP+4 (`78701-1234`), the first five
looked up exactly, never by prefix; a ZIP not in the table (PO-box-only and some business ZIPs,
`20500`) is unknown. The label is the place's label, a space and the ZIP (`Hell's Kitchen, NY 10019`), by the rule
of the bot's spec §9.1 that the bot's replies and the app's town rows share (`MeshWXPlaceNames`,
which `WeatherNames` calls): Census suffixes such as `ZONA URBANA` and `COMUNIDAD` dropped,
initialisms such as `AFB` and `DC` in capitals, joining words (`of`, `the`, `de`, `del`) lower case
after the first word, and `'s`, `14th`, `McGuire`, `O'Fallon`, `ʻEwa`. State codes are not kept in
capitals in place names (La Grange, De Queen). A picked ZIP is a searched place at the ZIP's own point
(`WeatherPlace.zip`): forecast point, station and zone/county come from that coordinate like any
other place's. The header reads "Searched ZIP 78701". `MeshWXZipTests` hashes all 33,144 ZIP labels and
`WeatherZipPlaceTests` all 34,937 town labels against the bot's `geodata/names.py`.

Conformance: `MeshWXTests` decodes every vector in the bot's `meshwx_v5_vectors.json` (thirteen at
revision 5, including `forecast_seven_days`, `coverage_wx_aus` and the two carrying the new times,
`observations_three_stations_ages` and `severe_thunderstorm_warning_issued`) to its `decoded` JSON
and re-encodes to the same hex; the count is read from the file, not fixed. Revision 6's
`request_digest` — the one message the app *sends* — is tested beside them from the sixteen bytes
the spec prints, since the publisher's file does not carry it yet. That suite is the
tie-breaker when a screen looks wrong. `PreloadBundle/protocol.json` is the bot's own file too,
at `version` 10.

### Transport

Every v5 message is the `data` of a `GRP_DATA` packet (`ChannelDatagram`, response
`0x1B`) with `dataType == 0xFF10`. The session already parses these and emits
`.channelDataReceived`; `MessagePollingService` drains them from the firmware queue
but deliberately does nothing with them. `WeatherService` subscribes with the new
`EventFilter.anyChannelDatagram` and ignores every other `dataType`. The
subscription is opened before the polling service's initial drain so datagrams
queued while the phone was away are not lost (spec §5: the digest's `now` makes a
late-drained message decode correctly). Each datagram is stamped as backlog while
`MessagePollingService.isDrainingBacklog` is true (the connect-time drain and resync). Backlog
updates state like anything else but fills no five-minute answer slot and does not count as
hearing the bot.

Firmware gate: `DeviceDTO.supportsChannelDatagrams` (`firmwareVersion >= 11`,
MeshCore v1.15). Below it the radio silently drops `GRP_DATA`, so the tool says so
instead of showing an empty screen. The same gate decides whether a request can be *sent* as a
datagram (`CMD_SEND_CHANNEL_DATA`, 0x3E, added in the same firmware): the container hands it to
`SessionWeatherTransport`, which otherwise falls back to the DM ("Requests", below).

### State (`WeatherService`)

One `WeatherBotState` per bot (`bot` = first two public-key bytes, LE), reduced by
`WeatherStateReducer` — a pure function so every rule in spec §2.3, §3–§8 has a test:

- `(bot, seq)` dedupe over the last 16 accepted messages, by `seq` and a fingerprint of the
  content, so a new message that reuses a `seq` is not dropped as a copy. A `seq` 1–128 ahead
  is a gap past 1; up to 32 behind is out of order (the bot resends an unechoed packet 8–10 s
  later, behind newer ones); further behind, or the newest `seq` again with new content, is a
  restart — until revision 3 the bot's counter started at random — which starts a new stream,
  is applied normally and counts as a gap. A gap sets `needsDigest` (the cue for `>d`),
  cleared by a digest built more than 2 min after the gap was seen: the margin is the two
  clocks' disagreement only, since the bot keeps no answer cache.
- Warnings keyed by `(event, office, etn)`; a message with a known identity
  replaces the stored one. Cancel removes; a cancel flagged "upgraded" leaves a
  marker until an overlapping warning or a later digest arrives. Out of order, a warning is
  stored unless its identity is held or was cancelled in the last hour (`recentCancels`), and
  a cancel always applies (an ETN is never reissued). A digest removes
  identities it does not list, but never a warning received after the digest was
  built (2 min margin), nor, when it is full (25 entries, soonest expiry first), one expiring
  at or after its last entry; it only extends expiries of newer ones; an older digest is
  ignored, in order or not. Identities it lists that the app does not hold are recorded
  (`>w <identity>` is one tap away). Expiry is evaluated at read time, and the issue time, when
  the message carries one, is kept on `issuedAt` (Times, below); a replacement that carries none
  leaves it alone, since an identity's issuance never moves.
- `lastHeardAt` counts every message; `lastLiveHeardAt` excludes backlog and drives
  the no-retry rule and the "not heard" caption.
- Observations: newest wins, per station, by each station's own report time (Times, below);
  fields the report did not carry arrive as
  unknown (revision 3) and are not shown, sky 15 has no icon, visibility 0 reads "under 1 mi".
  Forecasts: keyed by `point`; whole days, entry `i` dated the issue date plus `first / 2 + i`.
- Text: reassembled by `(bot, group)` in `idx` order; a group with a missing chunk
  renders with a "missing part" marker and may be re-requested once after 20 s (the answer is
  rebuilt under a new group).
- Retention: every answer on the channel reaches every phone, so a phone that never asks for
  anything still accumulates other people's replies. Readings have always had an age and a
  ceiling — gone once neither in one of the bot's scheduled batches nor heard at all for 48 h,
  capped at 64 — and texts and forecasts now get the same (48 h, 24 each;
  `WeatherStateReducer.pruneTexts` / `pruneForecasts`). What a screen would still show survives
  both rules however old it is, and is bounded so it can never hold the cache open: the newest
  reply on each subject and the newest on each subject this phone asked for, and the newest
  forecast this phone asked for, which is the one the Forecast card is holding open.
- `feedHealth` from the last digest counts only the bot's home office (spec §5). Above 60
  (four hours) the office is quiet, which withholds "no alerts" but is not called a broken
  feed; 255, nothing ever received, is the only case that says alerts may not reach you.
- Coverage: the bot's own statement of its area (spec §7A), newest per bot with its receipt
  time. It carries no time of its own — it describes the bot, not an hour — so out of order it
  yields to the statement already held, and it never goes stale (Coverage, below).

State is persisted as JSON under Application Support (`MeshWX/state.json`), keyed
by bot, so the tool opens on the last-known picture with no radio. One shared
`FileWeatherStateStore` actor per file serves both the service and the tool's offline
path, and `modify` reads, changes and writes in one step, so an offline clear cannot race
a service that attaches meanwhile. The view model is
held by `WeatherModelStore` for one visit to the tool, so it survives pushes and the
compact/regular shell swap; it is not on `AppState`, and re-attaches on every services
change like the other tool models; the service keeps ingesting whether or not the
screen exists. It is not
SwiftData: nothing joins it, and a schema migration for a cache is a cost with no
benefit.

### Times (spec §3, §6.1, §10.5)

Two words carry the honesty of the whole tool, and neither is ever when the packet arrived:

- **as of** — a reading, from `ts − age`. A batch's `ts` is the *newest* report in it while the
  bot admits stations up to 120 minutes older, so "as of 8:24 PM" under every temperature was
  wrong about most of them. From revision 5 the flags nibble bit 0 says a block of
  `ceil(n / 2)` bytes follows the station records: one nibble per station, 10-minute steps, 0 to
  150 where **150 means "150 minutes or more"** (`MeshWXStationObservation.isAgeSaturated`).
  `MeshWXObservations.reportMinutes(for:)` resolves it, and the reducer stores *that* as
  `WeatherStoredObservation.timestampMinutes`, so `observedAt`, `isStale` and the newest-wins
  merge are per station with no screen doing anything: a station two hours behind its batch goes
  stale two hours before the batch does. The batch time itself stays on `lastBatchMinutes`, which
  is membership of a scheduled broadcast — the evidence the bot's area is read from — and never a
  reading's age. A batch from a bot that sends no ages leaves every station reading the batch
  `ts`, as before. The block costs the fourteenth station: a full batch with ages is 13 stations
  (159 bytes), which is why WX-AUS's Coverage now states a cap of 13.
- **issued** — a warning, from `expires − issued_before`, and a forecast, from `issued`. Flags
  nibble bit 1 on a warning says the last two bytes are a u16 of the minutes between the NWS
  product's own issuance and its expiry (65535 saturates: "at least that long ago"). It is the
  product's header time, kept across continuations, so an SVS update does not restamp a warning
  as newly issued, and a radio out of range for three hours still says *issued 1:29 PM*.
  `MeshWXWarning.issuedBeforeMinutes` keeps the wire value (so a re-encode is byte-identical and
  the saturation stays readable) and `issuedMinutes` resolves it; the reducer resolves it once on
  arrival into `WeatherStoredWarning.issuedAt`, because a digest may later extend the expiry the
  wire measured it against and the instant a warning was issued does not move with it.

Both are trailing blocks announced by a flag bit, after everything revision 4 reads, and the
decoder treats a length as a lower bound — so the old bytes and the new bytes both decode, and an
app that missed the flags would simply never learn the two times. Both fields are optional
everywhere they are stored: nil means "the bot did not say", which is not the same as zero.

### Coverage (spec §7A)

The bot states what it carries and the app takes its word, instead of guessing. Coverage (type 8,
broadcast every 3 h) carries the centre and radius of the bot's circle, the cap on one hourly
observation batch, the NWS offices it covers, and its zones as the same UGC runs a warning's area
list uses — 39 bytes for WX-AUS's real area. `MeshWXDecoder` reads it like any other type, the
reducer keeps the newest per bot in `WeatherBotState.coverage`, and it persists with the rest of
the state (a file written before the field decodes with it absent).

`WeatherCoverage` then answers "is this place in this bot's area?" as a verdict, not a boolean:

- **Inside** — the place is in the stated circle, or one of its UGCs is in a stated run, or the
  bot stated no area filter at all (`n` = 0 and `k` = 0: it carries everything its feed does). The
  place's UGCs come from the bundled `zones.geojson` / `counties.geojson`, widened by the place's
  own uncertainty, through the same lookup the alerts card uses.
- **Outside** — both lists whole, runs stated to test against, and none of the place's UGCs in
  them. For a bot that has stated nothing, the station footprint (§6 of docs/MESHWX_UI.md) still
  decides, exactly as before.
- **Unknown** — everything else: a list the bot had to cut, outlines still loading, a place in no
  bundled area, a bot that has neither stated nor reported. **A cut list means "not listed", never
  "not covered"** — the rule the message exists for, enforced here and not only in a comment.

Across bots one "inside" wins, any "unknown" withholds a denial, and "outside" needs every bot
with evidence to say so: one bot's outside never speaks for a place another carries.
`WeatherAlertStatus` reads outside as `outOfCoverage` (before anything else) and unknown as
`coverageUnknown` (below the statuses that ask for something), as §7.4 orders them.

`officeMayNotBeCovered` is produced again, on this evidence and nothing weaker: every bot
answering for the place must state its offices with the office-cut flag clear, and none of them
may list the office of the place's zone. docs/MESHWX_UI.md §3.1 I-B18 suspended that row until the
bot advertised its coverage — it now does, so the row is live again and §14 Q2 is answered. The
offices a bot has *shown* on active warnings remain no evidence: `WeatherAlertStatus.showsOffice`
stays as the rule for reading a warning's issuer, not for what a bot lacks.

The app also **asks** for it (`>cov`, spec §8.2), because waiting for the three-hourly broadcast
means up to three hours in which a freshly opened tool cannot tell "outside the area" from
"nothing said yet" — and withholds the check and the out-of-area requests for all of it. It is a
case in `WeatherRequest` with an answer slot of its own and a step in `WeatherUpdatePlan`, sent
last and only while the bot has been heard, has stated nothing, and has not been asked on this
visit. One packet: a statement describes the bot rather than an hour and never goes stale, so a
bot that has made one is never asked again, and one that did not answer is not asked on every tap
(docs/MESHWX_UI.md §11.1, §14 Q4).

### Requests

`WeatherRequest` is the spec §8.2 grammar as an enum with `wireText` and the reply
it expects. The service enforces the etiquette (§13): one request per 5 s, and
no second request for anything the channel delivered live in the last 5 min — airtime
etiquette only, since the bot rebuilds every answer. Slots
are filled on ingest, whoever asked, but only by a message the reducer applied and
that was not backlog; they carry the content's own time. `>w` is not served from a
slot while the bot still has a missing identity or an unfinished upgrade, and no alert request
is while a gap newer than the held answer is outstanding (or, once a list built now could
clear a gap the held list was built too soon to clear).

**The channel first** (spec §7B, revision 6; the owner's decision of 17 September,
docs/MESHWX_UI.md §3.1.2 V-7). A request goes out as a **Request datagram** — type 9, the
`MeshWXRequest` this module encodes — flooded on `#meshwx` under the same data type the
answers arrive with, not as a DM: a DM rides one stored route hop by hop and fails silently
once that route has gone stale, and the field record of 16 September lost seven of forty
requests that way to a bot which was on the air and answering everyone else. A flood needs no
route. `SessionWeatherTransport` finds the slot whose secret is `#meshwx` (cached once found),
takes the first six bytes of this radio's own public key as the sender, and floods the
datagram with `CMD_SEND_CHANNEL_DATA`; the header carries the bot asked and this phone's own
`seq` — a wrapping counter of the sender's, one per new request — and the body the request's
`ts` in Unix seconds. There
is **no acknowledgement** for a datagram — the answer on the channel is the acknowledgement —
so `botRadioReceived` is never set for one. Unanswered after **10 s**, the same bytes go out
once more (same `ts`, same `seq`, so the bot reads a copy of one request rather than a second
one), and never a third time: two sends, 20 s, then `.timedOut`.

Requests are flooded, so this phone now *hears* other people's. A type-9 datagram is
recognised and dropped before the reducer: it is not from a bot, it is not an answer, and its
`seq` is the sender's, not a bot's — counting one would invent a bot, break gap detection, and
claim the bot had been heard.

**The DM is the fallback.** When the radio cannot send a datagram at all — firmware older than
v1.15.0 (`DeviceDTO.supportsChannelDatagrams`, the same gate the screen reads as
`firmwareSupportsWeather`), no slot carrying `#meshwx`, or no public key of its own yet — the
transport throws `WeatherTransportError.channelRequestsUnavailable` and the service sends the
§8.2 DM instead, silently, with the whole ladder below unchanged. A timeout (15 s)
resends: attempt 1 along the same route into silence — or, for a request the bot's radio
confirmed but nobody answered, along the route again, since the bot answers a copy from its cache
for one packet — and then, for a request still unconfirmed after its on-route sends (or one the
bot was *heard* past without confirming: the route is the suspect, not the range), the route is
forgotten (`resetPath`) and attempt 2 goes out **by flood**, once, the chat rule of D5. Three sends,
45 s — the same reasoning the datagram now applies from the first send, arrived at from the same
field log. A confirmed request is never flooded. A request keeps one
timestamp for its life: every resend carries the first send's timestamp and text under the next
attempt number, so the bot's radio sees one message sent again and the bot (the same text from one
sender within 2 min is one request) one request. Each send's
expected ACK code is kept; the session's ACK push for either marks the request received by the
bot's radio. A timeout of a confirmed request reads "received, but no answer reached this
phone"; an unconfirmed one keeps "may be out of range or busy". Answers are matched to pending requests by kind and what they name: `>w <identity>` by
identity, `>w <area>` by the warning's own area list (no digest follows either), bare `>o` by
any batch from the bot asked, `>f <point>` by that point, or from the bot asked a nearby point
within 80 km or `0xFFFF`; a text
reply settles and is owned only when its words match the request's argument
(`WeatherTextMatch`, docs/MESHWX_UI.md §12); `>cov` is settled by a statement from the bot asked
and by nothing else, since a statement describes whichever bot sent it, and it fills its slot with
no content time because the message carries none. A `NotAvailable` carries the request's
first letter. Silence has three causes the app cannot tell apart: range, the bot's
per-sender limit, and its hourly packet budget (spec §8.2, §8.3).

Only the bot named answers, either way (spec §12): every bot on the channel decrypts a Request
datagram and only the one its `bot` field names replies, and only the addressed bot can decrypt
a DM at all. (The bot also takes `>` as plain `#meshwx` text, which *every* bot would answer;
the app never sends that.) Neither path touches `MessageService`, the chat store, or its ACK
tracker (decision above): the datagram goes out through
`MessagingSessionOps.sendChannelData`, the DM through `sendMessage`, and `WeatherService`
subscribes to the session's ACK pushes itself.

### Alert notifications

`WeatherAlertNotifier` is a second actor in the container, beside `WeatherService`
(docs/MESHWX_UI.md §16). Warnings are broadcast on `#meshwx` as they happen, so it asks the radio
for nothing: it subscribes to the service's events, and for every warning stored or ended it
places the warning against the places the user has put a bell on (`WeatherSavedPlace.isWatched`,
plus My location against `WeatherLastPosition`) with the same `WeatherAlertPlacement` and
`WeatherAlertPriority` the card uses. Storm warnings covering a watched place notify with sound;
rank 6 is a silent opt-in toggle; watches and advisories never notify. What it has posted is
remembered (`WeatherAlertPost`) so a repeat replaces the notification silently and only a real
escalation sounds again, a cancel removes it, and a warning drained from the radio's queue says
it arrived late. It is not on the tool's model: that lives for one visit, and the point is a
notification with the tool closed.

### Bots

A bot is any contact whose name starts with `WX-` (spec §12). Its advert carries no position
(0,0), so the tool uses the bot whose station footprint covers the place, else the one heard
most recently, and remembers a choice
per phone by wire id (`WeatherPreferenceStore`, key `weather.selectedBotID`) — by
id, not by public key, because a bot is heard on the channel long before its
advert is collected; such a heard-only bot is shown read-only, with requests
disabled until the radio has its key. Two bots covering one place send
the same warning identity; state is per bot, and the screen shows their union,
deduplicated by identity (docs/MESHWX_UI.md §7.1).

### Channel

`#meshwx` is a hashtag channel: secret = `SHA256("#meshwx")[0..<16]`, exactly what
`JoinHashtagChannelView` does. The tool checks the radio's channel list only once the
connect-time channel sync has finished (`AppState.canRunSettingsStartupReads`); when the
channel is missing it shows the prompt card and, on tap, reads the first free slot above
0 back from the radio and writes `#meshwx` there only if it is still empty.

## Not in this cut

- Radar. v5 has no radar product.
- Widgets / Live Activities.
- Bot text commands from inside the tool: the bot's chat thread already does this.
