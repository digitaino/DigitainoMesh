# MeshWX revision 13: radar loops, one design for the bot, the iOS app and the web client

Owner's ask, 3 October 2026: *I would like to improve the radar system in a way that the user can
request older radar images and the client presents them in a loop. Also I was thinking we should
be able to zoom in further into a specific area and be able to request a more detailed picture of
an area.* Then, on the findings: one hour at 15-minute steps; the loop on its own button; the
detail level, with Local sent instead where there is no regional picture; picked by zooming the
map and asking for detail at a spot.

**Amended the same day, before any release.** After trying both on the phone: *the loop worked
but im not sure I like the detail implementation. let's get rid of that.* The detail level (a
one-degree tile as message type 12, the Detail width, tap-to-pick) was removed from the bot and
both clients. Type 12 is free again. What follows is revision 13 as it stands: loops only. The
measurements about detail are kept below for whoever looks at it again.

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
(`meshwx/docs/MeshWX_v5_Spec.md`) becomes revision 13: section 7D gains 7D.4 (older pictures);
`protocol.json` becomes version 17. The screen decisions
are folded into `docs/MESHWX_UI.md` (§18) by whoever implements them. The web client follows
`meshwx/web/docs/PORTING.md`: the Swift names below are the JS names. Revision 11's contract is
`docs/MESHWX_REV11.md`; everything in it stands unless a line below changes it.

## 1. Wire (spec revision 13)

No message type is added; the `>radar` request gains one word. Nothing already on the wire
moves, and an app before revision 13 loses nothing: it already ignores a Radar tile older than the
one it holds.

### 1.1 Older pictures (no new message)

An older frame is an ordinary Radar (type 11) packet. Its `taken` says which picture it is. The
request:

| Request | Answer |
|---|---|
| `>radar 30.270,-97.740 loop` | The pictures of the last hour for the zoom 0 tile, oldest first, one packet each |
| `>radar 30.270,-97.740 z1 loop` | The same for the zoom 1 tile; any zoom 0 to 3 |
| `>radar 30.270,-97.740 z1 loop 2353 2338` | The same, leaving out the pictures taken at 23:53 and 23:38 UTC, which the app already holds |

Grammar, in the order the bot reads it from the end: an optional `loop` token, which is `loop`
followed by zero to five `HHMM` groups to the end of the line, each four digits, the UTC hour and
minute of a picture's `taken`; then the optional zoom token (`z0` to `z3`); then the place. `loop` followed by anything that is not four digits is part of the place: `>radar loop tx`
is Loop, Texas.

A request is at most 40 bytes (section 7B), and that limit stays. The app lists its held pictures
**newest first, as many as fit**: `>radar 30.270,-97.740 loop` is 26 bytes, so two always fit,
which covers the usual case of a phone holding the newest picture and asking for the rest. A
held picture left off the list is sent again, which costs a packet and breaks nothing. Minutes
alone would not do: at 15-minute steps the newest picture and the one an hour before it end in
the same two digits.

What the bot sends:

1. The tile and the product exactly as for a single picture (revision 11), from the newest
   picture of that product no more than 60 minutes old. No such
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

### 1.2 Requests

| Request | Answer |
|---|---|
| `>radar <place> [z<n>] loop [HHMM …]` | 1.1 |

Refusal reasons for `x` are unchanged.

Never broadcast on a schedule (owner, revision 11). The `radar` text command is unchanged.

### 1.3 `protocol.json` version 17

`v5.radar` gains:

```json
"loop": { "request_token": "loop", "window_minutes": 60, "max_frames": 5,
          "min_spacing_minutes": 10, "held_max": 5, "held_format": "HHMM UTC" }
```

One new vector: `request_radar_loop` (`>radar 30.270,-97.740 loop 2353 2338`).

## 2. Names (Swift; JS per PORTING.md)

### MeshWX target
- `MeshWXWire.radarLoopMaxFrames = 5`, `.radarLoopWindowMinutes = 60`,
  `.radarLoopMinSpacingMinutes = 10`, `.radarLoopHeldMax = 5`.
- `MeshWXRadarTile` edges stay `Double` where the detail build made them so: a state saved by that
  build on the owner's phone may hold zoom −1 tiles with half-degree edges, and it must still load.
  Such tiles are dropped when the state is read (and by retention), and `containing` clamps to
  zoom 0…3.

### Requests (`WeatherRequest`)
- `.radar(latitude:longitude:zoom:)` as revision 11 (zoom 0 to 3).
- `.radarLoop(latitude:longitude:zoom:held: [UInt32])`, `held` the `taken` minutes of the frames
  the app holds for that tile (`WeatherRadarLoop.held`), written as UTC `HHMM` after `loop`,
  newest first, as many as keep the request within 40 bytes (1.1). `requestLetter` `x`. Request
  rows read "Radar, last hour".
- `WeatherReplyKind.radar(tile:)` settles both, as revision 11 says.

### State (`WeatherBotState`)
- `radarTiles` holds **frames**: one entry per `(tile, taken)`. The same `taken` arriving again
  follows revision 11 (a coarse picture never replaces a fine one of the same `taken`); a
  different `taken` is another frame, older or newer. Retention as revision 11 (3 hours before the
  newest `taken` this bot has sent); the limit is **40**, oldest `taken` dropped.

### Screen rules (`Services/Weather/Screen/`)
- `WeatherRadarPick` chooses the newest `taken` among frames.
- `WeatherRadarLoop.make(tile:tiles:now:)` → `WeatherRadarLoop { frames: [WeatherStoredRadarTile]
  (oldest first), hasGap: Bool, held: [UInt32] }`: the frames of that exact tile whose `taken` is
  within 60 minutes before the newest held for it and at most 120 minutes old (the "not drawn"
  rule of revision 11), at most 5, the newest kept when there are more. `hasGap` when two
  consecutive frames are more than 20 minutes apart. `held` is their `taken` minutes.
  `canPlay` when there are at least 2 frames.

## 3. Screens (both clients)

**Place page**: unchanged.

**Radar screen.** Local, Regional and Wide as revision 11. Under the map, for the width on screen:

- **Play / Pause**, when the loop has at least two frames. Each frame shows for 0.8 s and the
  newest for 2 s, repeating until paused. Nothing plays by itself; leaving the screen or changing
  width stops it. Each frame's drawing is made once, not on every step.
- While playing or paused on an older frame, the time line shows that frame's own time and place
  in the loop: "6:08 PM · 2 of 5", in the caution tone like any old picture. The summary sentences
  always describe the newest picture.
- **Ask for the last hour**, when the loop has fewer than 5 frames. Cost "Up to 5 packets",
  footnote "Pictures this device already has are not sent again." It sends `.radarLoop` with the
  frames held.
- "Some pictures from this hour are missing." when `hasGap`.

**Cached screen**: one row per tile, its newest time, and "5 pictures" when it holds more than
one. **Channel traffic**: older frames read like any radar picture, with their own time.

### 3.1 Strings

New keys in `Weather.strings` for all 11 locales (the web converts them with
`tools/strings-to-json.mjs`). No em dashes, no exclamation marks, matter-of-fact wording.

| Key | English |
|---|---|
| `weather.radar.loop.play` | Play |
| `weather.radar.loop.pause` | Pause |
| `weather.radar.loop.ask` | Ask for the last hour |
| `weather.radar.loop.cost` | Up to %lld packets |
| `weather.radar.loop.footnote` | Pictures this device already has are not sent again. |
| `weather.radar.loop.frame` | %1$@ · %2$lld of %3$lld (a clock time, the frame, the frames) |
| `weather.radar.loop.missing` | Some pictures from this hour are missing. |
| `weather.radar.loop.request.title` | Radar, last hour |
| `weather.radar.cached.frames` | %lld pictures |

The five detail keys of the first build (`weather.radar.width.detail`, `weather.radar.detail.hint`,
`.ask`, `.footnote`, `.fallback`) are removed.

## 4. What is deliberately not in revision 13

- No scheduled radar, loop or detail broadcast (owner: request-only).
- No difference frames: every frame is a whole tile (measured above).
- No detail level (built, tried and removed, above). If it comes back: one level only, a 1° tile
  of 32 × 32 cells, cut only from pictures of at least 30 pixels a degree; it needs its own message
  type because its edges are half degrees.
- No loop longer than an hour or more than 5 frames.
- The `radar` text command does not change.
- Storm motion from the warnings' `TIME...MOT...LOC` line: still wanted, still separate.
