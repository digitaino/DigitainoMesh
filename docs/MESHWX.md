# MeshWX — the weather tool

Branch: `feature/meshwx` (off `personal`). Status: v5 protocol; first cut 2026-09-14, screen
reworked 2026-09-15 (docs/MESHWX_UI.md).

The Tools tab gains a **Weather** tool that listens to the MeshWX v5 weather bot
(`WX-<city>`, e.g. `WX-AUS`) on the `#meshwx` channel and shows what it hears:
active warnings on a map, current conditions for the nearby METAR stations, the
point forecast, and narrative text on request. The protocol is the owner's own
(`meshcore-weather`, kit cut 2026-09-15); this document records how the app maps
it onto the existing architecture and the decisions taken on 2026-09-14.

Spec, reference codec and wire vectors live in the kit
(`MeshWX_iOS_Kit_2026-09-15/`); the app vendors only what it needs, listed below.

## Decisions (Rafael, 2026-09-14)

| Question | Decision |
|---|---|
| Branch | `feature/meshwx` off `personal`, merged in when ready — same shape as packet-scope and signal-mapper. |
| Zone/county polygons (15 MB of GeoJSON) | **Bundled**, both files. Full area fills for every warning type; the centroid-pin fallback still exists for a code with no polygon (spec §9). |
| App requests to the bot (`>f 102` …) | Sent at the **session level**, never through `MessageService`. No chat rows, no ACK bookkeeping; the bot's DM thread stays the human `wx austin tx` surface. |
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

Conformance: `MeshWXTests` decodes all nine kit vectors to their `decoded` JSON and
re-encodes to the same hex. That suite is the tie-breaker when a screen looks wrong.

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
instead of showing an empty screen.

### State (`WeatherService`)

One `WeatherBotState` per bot (`bot` = first two public-key bytes, LE), reduced by
`WeatherStateReducer` — a pure function so every rule in spec §2.3, §3–§8 has a test:

- `(bot, seq)` dedupe over the last 16 sequence numbers; a gap in `seq` sets
  `needsDigest` (the cue for `>d`), cleared only by a digest built more than 10 min
  after the gap was seen, because the bot's five-minute answer cache can re-send a
  list built before it.
- Warnings keyed by `(event, office, etn)`; a message with a known identity
  replaces the stored one. Cancel removes; a cancel flagged "upgraded" leaves a
  marker until an overlapping warning or a later digest arrives. A digest removes
  identities it does not list, but never a warning received after the digest was
  built (10 min margin), and only extends expiries of newer ones; an older digest is
  ignored. Identities it lists that the app does not hold are recorded
  (`>w <identity>` is one tap away). Expiry is evaluated at read time.
- `lastHeardAt` counts every message; `lastLiveHeardAt` excludes backlog and drives
  the no-retry rule and the "not heard" caption.
- Observations: latest batch wins, per station. Forecasts: keyed by `point`.
- Text: reassembled by `(bot, group)` in `idx` order; a group with a missing chunk
  renders with a "missing part" marker and may be re-requested once after 20 s.
- `feedHealth` from the last digest; "feed stale" above 60 (four hours).

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

### Requests

`WeatherRequest` is the spec §8.2 grammar as an enum with `wireText` and the reply
it expects. The service enforces the etiquette (§13): one request per 5 s, and
no second request for anything the channel delivered live in the last 5 min. Slots
are filled on ingest, whoever asked, but only by a message the reducer applied and
that was not backlog; they carry the content's own time. `>w` is not served from a
slot while the bot still has a missing identity or an unfinished upgrade. A timeout
retries once, only into silence (never once the bot has been heard live since the
send). Answers are matched to pending requests by kind, point and station; a text
reply settles and is owned only when its words match the request's argument
(`WeatherTextMatch`, docs/MESHWX_UI.md §12). A `NotAvailable` carries the request's
first letter.

Requests are DMs to the bot's public key via `MessagingSessionOps.sendMessage`.
They do not touch `MessageService`, the chat store, or the ACK tracker (decision
above).

### Bots

A bot is any contact whose name starts with `WX-` (spec §12). The tool lists them
nearest-first using the contact's advertised position and remembers the choice
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

- Notifications for new warnings (the bot's own broadcast cadence is the cue; a
  local notification needs a product decision on severity thresholds).
- Radar. v5 has no radar product.
- Widgets / Live Activities.
- Bot text commands from inside the tool: the bot's chat thread already does this.
