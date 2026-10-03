# MeshWX revision 13: radar loops and detail, one design for the bot, the iOS app and the web client

Owner's ask, 3 October 2026: *I would like to improve the radar system in a way that the user can
request older radar images and the client presents them in a loop. Also I was thinking we should
be able to zoom in further into a specific area and be able to request a more detailed picture of
an area.* Then, on the findings: one hour at 15-minute steps; the loop on its own button; the
detail level, with Local sent instead where there is no regional picture; picked by zooming the
map and asking for detail at a spot.

What was measured before deciding (38 Southern Plains pictures in the radar-audit corpus, 18-21
September 2026):

- The regional pictures have pixels about 1/37° across (2.6 km east-west, 3 km north-south at
  Austin). A Local cell (1/16°) already holds 2.3 × 2.3 of them. A 1° tile of 32 × 32 cells is
  1.2 pixels a cell: about twice the detail of Local, and the most the picture has. A 0.5° tile
  would draw each pixel as four cells and show nothing new, so there is one detail level, not two.
- The national picture is 11 km a pixel and Alaska's 9 km: coarser than Local already. Neither
  can make a detail tile.
- A 1° tile with precipitation on it: median 54 bytes, worst 100, never coarse. Local on the same
  pictures: median 31, worst 114.
- Sending a frame as its difference from the one before saved nothing (an XOR tree of two
  frames 30 minutes apart was the same size or larger), and a lost difference would break every
  frame after it. Every frame stands alone.

This file fixes the wire and the names so three codebases can be changed at once. The bot's spec
(`meshwx/docs/MeshWX_v5_Spec.md`) becomes revision 13: section 7D gains 7D.4 (older pictures) and
a new section 7E (Radar detail, type 12); `protocol.json` becomes version 17. The screen decisions
are folded into `docs/MESHWX_UI.md` (§18) by whoever implements them. The web client follows
`meshwx/web/docs/PORTING.md`: the Swift names below are the JS names. Revision 11's contract is
`docs/MESHWX_REV11.md`; everything in it stands unless a line below changes it.

## 1. Wire (spec revision 13)

One message type is added (12, Radar detail) and the `>radar` request gains two words. Nothing
already on the wire moves, and an app before revision 13 loses nothing: it ignores type 12 like
any unknown type, and it already ignores a Radar tile older than the one it holds.

### 1.1 Older pictures (no new message)

An older frame is an ordinary Radar (type 11) or Radar detail (type 12) packet. Its `taken` says
which picture it is. The request:

| Request | Answer |
|---|---|
| `>radar 30.270,-97.740 loop` | The pictures of the last hour for the zoom 0 tile, oldest first, one packet each |
| `>radar 30.270,-97.740 z1 loop` | The same for the zoom 1 tile; any zoom, the detail level included |
| `>radar 30.270,-97.740 z-1 loop 2353 2338` | The same for the detail tile, leaving out the pictures taken at 23:53 and 23:38 UTC, which the app already holds |

Grammar, in the order the bot reads it from the end: an optional `loop` token, which is `loop`
followed by zero to five `HHMM` groups to the end of the line, each four digits, the UTC hour and
minute of a picture's `taken`; then the optional zoom token (`z0` to `z3`, or `z-1`); then the
place. `loop` followed by anything that is not four digits is part of the place: `>radar loop tx`
is Loop, Texas.

A request is at most 40 bytes (section 7B), and that limit stays. The app lists its held pictures
**newest first, as many as fit**: `>radar 30.270,-97.740 loop` is 26 bytes, so two always fit,
which covers the usual case of a phone holding the newest picture and asking for the rest. A
held picture left off the list is sent again, which costs a packet and breaks nothing. Minutes
alone would not do: at 15-minute steps the newest picture and the one an hour before it end in
the same two digits.

What the bot sends:

1. The tile and the product exactly as for a single picture (revision 11; 1.2 below for the
   detail level), from the newest picture of that product no more than 60 minutes old. No such
   picture: Not available `x` reason 0, as today.
2. Older pictures **of the same product only**, walking back from that one: each picture whose
   `taken` is at least 10 minutes before the last one picked, back to 60 minutes before the
   newest, at most **5** in all, the newest included. The pictures come every 15 minutes, so a
   full hour is 5. A missing picture is a gap, never filled from another product: a loop that
   jumps between the regional and the national picture changes detail under the viewer's eye.
3. Leaves out every picture whose `taken` (as UTC `HHMM`) is in the request, and every frame whose
   `(south, west, zoom, taken)` went on the air in the last 5 minutes (everyone listening already
   has it).
4. Sends the rest **oldest first**, one packet each, under the ordinary rules: each packet counts
   against the hourly budget and the frames are spaced like every other send.
5. Nothing left to send: Not available `x` reason 4 when something was left out under rule 3,
   reason 0 when there was nothing older to find either.

An app holding the whole hour plays it without asking. An app that heard another phone's loop
holds those frames and lists them.

### 1.2 Radar detail (type 12)

One tile one degree on a side, the same 32 × 32 grid, so a cell is 1/32° (3.5 km north to south).

- The lattice step is **0.5°**. For an asked coordinate the tile is the one whose centre is the
  nearest lattice point, by the rule of revision 11 with `step = 0.5`:
  `centreLat = floor(lat / 0.5 + 0.5) * 0.5`, `south = centreLat - 0.5`; the same for the
  longitude. The asked spot is never closer than 0.25° (28 km) to an edge.
- In the data model this is **zoom −1**: span `2^(zoom+1)` = 1°, step `2^zoom` = 0.5°. Every rule
  of revision 11 that takes a zoom takes −1 the same way. Edges are half degrees.
- Cut only from a picture with **at least 30 pixels per degree**: the twelve calibrated regional
  pictures from the lower 48, Hawaii and Puerto Rico. Not the national picture (9.8) and not
  Alaska (12).
- **No such picture no more than 60 minutes old holds the tile: the bot answers with Local
  instead**, the zoom 0 tile (type 11) for the same coordinate, under all of Local's own rules
  (the 5-minute rule included, so the fallback can itself be reason 4). The same for a loop.

Flags nibble as type 11: bit 0 **coarse**, bit 1 **partial**, bits 2 and 3 the data source.

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 4 | 4 | `taken` | u32 LE, Unix minutes, the time printed on the picture (as type 11) |
| 8 | 2 | `south` | i16 LE, the tile's southern edge in **quarter degrees** (30.0° is 120, 30.5° is 122) |
| 10 | 2 | `west` | i16 LE, the tile's western edge in quarter degrees, −720 to 719 |
| 12 | 1 | `shape` | bits 0-1 `depth`, 0: a 1° tile. Other values are reserved and a decoder rejects them. Bits 2-7 `product`, as type 11 |
| 13 | 4 | `bounds` | **only when partial**, as type 11 |
| 13 or 17 | 1 to 144 | `cells` | the quadtree of revision 11, unchanged |

A decoder rejects a tile whose `south` or `west` is not on the half-degree lattice (an odd number
of quarter degrees). A tile with nothing on it is 14 bytes. Quarter degrees, and a `depth` field
that is always 0, cost nothing today and leave room for a finer tile from a finer picture
(Puerto Rico's is 140 pixels a degree) without another type.

### 1.3 Requests

| Request | Answer |
|---|---|
| `>radar 30.270,-97.740 z-1` | The detail tile for that coordinate, or the Local tile (1.2) |
| `>radar <place> [z<n>] loop [HHMM …]` | 1.1 |

Refusal reasons for `x` are unchanged. Reason 1 now also covers a zoom other than −1 to 3.

Never broadcast on a schedule (owner, revision 11). The `radar` text command is unchanged.

### 1.4 `protocol.json` version 17

`v5.radar` gains:

```json
"detail": { "type": 12, "zoom": -1, "span_degrees": 1, "step_degrees": 0.5,
            "coord_unit_degrees": 0.25, "depth_mask": 3, "cells_bytes": 144,
            "min_px_per_degree": 30, "request_token": "z-1" },
"loop":   { "request_token": "loop", "window_minutes": 60, "max_frames": 5,
            "min_spacing_minutes": 10, "held_max": 5, "held_format": "HHMM UTC" }
```

`min_zoom` −1 joins `max_zoom` 3. New vectors: `radar_detail_tile` (real: the 1° tile at Dallas
cut from the Southern Plains picture of 20 September 2026, 23:38Z), `radar_detail_coarse_partial`,
`request_radar_detail` (`>radar 32.780,-96.800 z-1`), `request_radar_loop`
(`>radar 30.270,-97.740 loop 2353 2338`). Decoded JSON keys for type 12 are those of type 11 with
`south` and `west` as decimal degrees (32.5) and `zoom` −1.

## 2. Names (Swift; JS per PORTING.md)

### MeshWX target
- `MeshWXMessageType.radarDetail = 12`. It decodes into the **same** `MeshWXMessage.radar(MeshWXRadar)`
  with `zoom == -1`; the encoder writes type 12 for zoom −1 and type 11 otherwise.
- `MeshWXRadar.south` and `.west` become `Double` (degrees), `.zoom` becomes `Int`. A stored state
  written before revision 13 has whole numbers there and decodes unchanged.
- `MeshWXRadarTile { south: Double, west: Double, zoom: Int }`: `containing(latitude:longitude:zoom:)`
  clamps to −1…3; `spanDegrees: Double`; `north`, `east` `Double`; everything else as revision 11.
- `MeshWXWire.radarDetailZoom = -1`, `.minRadarZoom = -1`, `.radarDetailMinPixelsPerDegree = 30`
  (bot only, kept for the record), `.radarLoopMaxFrames = 5`, `.radarLoopWindowMinutes = 60`,
  `.radarLoopMinSpacingMinutes = 10`.
- Decode error `radarDetailDepthReserved(depth:)`, `radarDetailOffLattice(south:west:)`.

### Requests (`WeatherRequest`)
- `.radar(latitude:longitude:zoom:)`: `zoom` becomes `Int`. Wire `z-1` for the detail level.
- New `.radarLoop(latitude:longitude:zoom:held: [UInt32])`, `held` the `taken` minutes of the frames
  the app holds for that tile (`WeatherRadarLoop.held`), written as UTC `HHMM` after `loop`,
  newest first, as many as keep the request within 40 bytes (1.1). `requestLetter` `x`. Request
  rows read "Radar, last hour".
- `WeatherReplyKind.radar(tile:)` settles both, as revision 11 says, with one addition: a request
  at zoom −1 is also settled by the zoom 0 tile `containing` the same coordinate, which is the
  bot's fallback.

### State (`WeatherBotState`)
- `radarTiles` now holds **frames**: one entry per `(tile, taken)`, no longer one per tile. The
  same `taken` arriving again follows revision 11 (a coarse picture never replaces a fine one of
  the same `taken`); a different `taken` is another frame, older or newer. Retention as revision
  11 (3 hours before the newest `taken` this bot has sent); the limit rises from 12 to **40**,
  oldest `taken` dropped.

### Screen rules (`Services/Weather/Screen/`)
- `WeatherRadarPick.best(for:tiles:now:)` considers **zoom 0 to 3 only**: the place page never
  shows a detail tile. `held` and `best(for:zoom:)` take −1 like any zoom. Both already choose the
  newest `taken`, which now has to be chosen among frames.
- `WeatherRadarLoop.make(tile:tiles:now:)` → `WeatherRadarLoop { frames: [WeatherStoredRadarTile]
  (oldest first), hasGap: Bool, held: [UInt32] }`: the frames of that exact tile whose `taken` is
  within 60 minutes before the newest held for it and at most 120 minutes old (the "not drawn"
  rule of revision 11), at most 5, the newest kept when there are more. `hasGap` when two
  consecutive frames are more than 20 minutes apart. `held` is their `taken` minutes.
  `canPlay` when there are at least 2 frames.
- `WeatherRadarDetail.tile(for spot:)` = `containing(spot, zoom: -1)`.
  `WeatherRadarDetail.card(spot:tiles:now:)` → `.held(picture)` when a detail tile for the spot is
  held (at most 120 minutes old), else `.local(picture)` when the zoom 0 tile containing the spot
  is, else `.missing`. `.local` is the fallback and says so on screen.
- Copy: width name `Detail` for zoom −1 wherever a width is named (traffic rows, cached rows).

## 3. Screens (both clients)

**Place page**: unchanged. The card shows Local, Regional or Wide, never a detail tile.

**Radar screen.**

- **Picking a spot.** A tap on the map picks a spot (zoom the map in first to aim). The width
  control gains a fourth segment, **Detail**, which appears once a spot is picked and is then
  selected; the camera frames the 1° square, which is outlined. Another tap moves the spot. Local,
  Regional and Wide work as before; the Detail segment stays for the spot until the screen
  closes. Before any spot is picked, a quiet line under the control: "Tap the map for a detailed
  picture of that spot."
- **Detail segment.** Draws the held detail picture, with its own time line and summary for the
  place when the place is inside it. With no detail picture but a Local one for the spot, draws
  Local with the line "No detailed picture of this spot. Showing Local." The bar's ask reads "Ask
  for detail here" (nothing held) or "Ask for a newer picture"; cost "1 packet", footnote "Twice
  the detail of Local, over a quarter of the area."
- **Loop**, under the map, for whatever width is on screen, Detail included:
  - **Play / Pause**, when the loop has at least two frames. Each frame shows for 0.8 s and the
    newest for 2 s, repeating until paused. Nothing plays by itself; leaving the screen or
    changing width stops it. Each frame's drawing is made once, not on every step.
  - While playing or paused on an older frame, the time line shows that frame's own time and
    place in the loop: "6:08 PM · 2 of 5", in the caution tone like any old picture. The summary
    sentences always describe the newest picture.
  - **Ask for the last hour**, when the loop has fewer than 5 frames. Cost "Up to 5 packets",
    footnote "Pictures this device already has are not sent again." It sends `.radarLoop` with
    the frames held.
  - "Some pictures from this hour are missing." when `hasGap`.

**Cached screen**: one row per tile as before, its newest time, and "5 pictures" when it holds
more than one. **Channel traffic**: a detail tile reads "Radar picture · Detail · 214 cells with
precipitation"; older frames read like any radar picture, with their own time.

### 3.1 Strings

New keys in `Weather.strings` for all 11 locales (the web converts them with
`tools/strings-to-json.mjs`). No em dashes, no exclamation marks, matter-of-fact wording. Times,
ages, counts and packet costs reuse the formatters the tool already has.

| Key | English |
|---|---|
| `weather.radar.width.detail` | Detail |
| `weather.radar.detail.hint` | Tap the map for a detailed picture of that spot. |
| `weather.radar.detail.ask` | Ask for detail here |
| `weather.radar.detail.footnote` | Twice the detail of Local, over a quarter of the area. |
| `weather.radar.detail.fallback` | No detailed picture of this spot. Showing Local. |
| `weather.radar.loop.play` | Play |
| `weather.radar.loop.pause` | Pause |
| `weather.radar.loop.ask` | Ask for the last hour |
| `weather.radar.loop.cost` | Up to %lld packets |
| `weather.radar.loop.footnote` | Pictures this device already has are not sent again. |
| `weather.radar.loop.frame` | %1$@ · %2$lld of %3$lld (a clock time, the frame, the frames) |
| `weather.radar.loop.missing` | Some pictures from this hour are missing. |
| `weather.radar.loop.request.title` | Radar, last hour |
| `weather.radar.cached.frames` | %lld pictures |

## 4. What is deliberately not in revision 13

- No scheduled radar, loop or detail broadcast (owner: request-only).
- No difference frames: every frame is a whole tile (measured above).
- No level finer than 1°, and no detail from the national picture or Alaska's: they have no
  more to show.
- No loop longer than an hour or more than 5 frames.
- The `radar` text command does not change.
- Storm motion from the warnings' `TIME...MOT...LOC` line: still wanted, still separate.
