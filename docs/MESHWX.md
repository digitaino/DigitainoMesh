# MeshWX — the weather tool

Branch: `feature/meshwx` (off `personal`). Status: v5 protocol, first cut, 2026-09-14.

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
MC1/State/AppState+Weather.swift            WeatherModel (@Observable) mirroring the actor
MC1/Views/Tools/Weather/                    the tool
```

### MeshWX target

Pure port of `reference/v5.py`. `MeshWXDecoder.decode(Data) -> MeshWXMessage`,
`MeshWXEncoder.*` (so the vectors round-trip and tests can fabricate traffic),
`MeshWXTables.shared` (offices / stations / states / events / places / points /
zones / counties / offices, loaded from `Resources/`), `MeshWXGeometry` (polygon
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
late-drained message decode correctly).

Firmware gate: `DeviceDTO.supportsChannelDatagrams` (`firmwareVersion >= 11`,
MeshCore v1.15). Below it the radio silently drops `GRP_DATA`, so the tool says so
instead of showing an empty screen.

### State (`WeatherService`)

One `MeshWXBotState` per bot (`bot` = first two public-key bytes, LE), reduced by
`MeshWXStateReducer` — a pure function so every rule in spec §2.3, §3–§8 has a test:

- `(bot, seq)` dedupe; a gap in `seq` sets `needsDigest` (the cue for `>d`).
- Warnings keyed by `(event, office, etn)`; a message with a known identity
  replaces the stored one. Cancel removes. A digest removes every identity it does
  not list, and records the identities it lists that the app does not hold
  (`>w <identity>` is one tap away). Expiry is evaluated at read time from the
  phone's clock.
- Observations: latest batch wins, per station. Forecasts: keyed by `point`.
- Text: reassembled by `(bot, group)` in `idx` order; a group with a missing chunk
  renders with a "missing part" marker and may be re-requested once after 20 s.
- `feedHealth` from the last digest; "feed stale" above 60 (four hours).

State is persisted as JSON under Application Support (`MeshWX/state.json`), keyed
by bot, so the tool opens on the last-known picture with no radio. It is not
SwiftData: nothing joins it, and a schema migration for a cache is a cost with no
benefit.

### Requests

`MeshWXRequest` is the spec §8.2 grammar as an enum with `wireText` and the reply
it expects. The service enforces the etiquette (§13): one request per 5 s, an
identical request within 5 min is served from what was already received, 15 s
timeout then one retry, then "the bot may be out of range". Answers are matched to
pending requests by kind (and point / station / subject where the request names
one); a `NotAvailable` carries the request's first letter.

Requests are DMs to the bot's public key via `MessagingSessionOps.sendMessage`.
They do not touch `MessageService`, the chat store, or the ACK tracker (decision
above).

### Bots

A bot is any contact whose name starts with `WX-` (spec §12). The tool lists them
nearest-first using the contact's advertised position and remembers the choice
per phone (`AppStorageKey.weatherSelectedBot`). Two bots covering one place send
the same warning identity; state is per bot, so both are shown under their bot.

### Channel

`#meshwx` is a hashtag channel: secret = `SHA256("#meshwx")[0..<16]`, exactly what
`JoinHashtagChannelView` does. The tool checks the radio's channel list; when the
channel is missing it shows the prompt card and, on tap, writes it to the first
free slot above 0.

## Not in this cut

- Notifications for new warnings (the bot's own broadcast cadence is the cue; a
  local notification needs a product decision on severity thresholds).
- Radar. v5 has no radar product.
- Widgets / Live Activities.
- Bot text commands from inside the tool: the bot's chat thread already does this.
