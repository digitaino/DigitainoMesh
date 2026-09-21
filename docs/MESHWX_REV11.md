# MeshWX revision 11: radar, one design for the bot, the iOS app and the web client

Owner's ask, 20 September 2026: *can you take a look at what comes down over the GOES satellite
that we could use to provide some type of radar coverage on the app?* Then, on the findings:
*yes, write up revision 11 and build it, request-only to start.*

What the dish already receives: the EMWIN stream carries the Weather Service's radar mosaics as
GIFs, one national picture (`RADREFUS`) and fourteen regional ones, a new one of each every 15
minutes, about 60 KB apiece. The bot read none of them because it only opens `.TXT`. Radar was in
the v4 protocol and was removed on 14 September because it pulled a 4 MB composite off the
internet (about 11 GB a day). This source needs no internet at all.

This file fixes the wire and the names so three codebases can be changed at once. The bot's spec
(`meshwx/docs/MeshWX_v5_Spec.md`) becomes revision 11, section 7D; `protocol.json` becomes version
15; the screen decisions are folded into `docs/MESHWX_UI.md` (§3.1 rows U-41 onward, new §18) by
whoever implements them. The web client follows `meshwx/web/docs/PORTING.md`: the Swift names
below are the JS names. Revision 10's contract is `docs/MESHWX_REV10.md` and nothing in it moves.

## 1. Wire (spec revision 11)

Nothing already on the wire moves. One message type is added (11, which revision 2 reserved "for a
future structured product"), one request word, and one Not-available letter.

### 1.1 The tile

A radar answer is **one packet, always**: a square grid of cells over a fixed tile of the earth.

- `zoom` 0 to 3. A tile spans `2^(zoom+1)` degrees on each side: 2°, 4°, 8°, 16°.
- The grid is 32 × 32 cells, so a cell is `span / 32` degrees: 1/16° (about 7 km) at zoom 0,
  1/8°, 1/4°, 1/2°. When the 32 × 32 picture does not fit the packet the bot sends the same tile
  as 16 × 16 (**coarse**, flags bit 0), each coarse cell the highest of the four it replaces. A
  16 × 16 tile always fits.
- Tiles sit on a fixed lattice so that every phone can use a tile any phone asked for. The
  lattice step is half the span, `step = 2^zoom` degrees. For an asked coordinate the tile is the
  one whose **centre** is the nearest lattice point:
  `centreLat = floor(lat / step + 0.5) * step`, `south = centreLat - step`; the same for
  `centreLon` and `west`. The asked place is therefore never closer than a quarter of the span to
  any edge (55 km at zoom 0). `south` and `west` are whole degrees at every zoom.
- Row 0 is the **northern** row, column 0 the **western** column. Cell `(row, col)` covers
  latitude `south + span - (row + 1) * cell` to `south + span - row * cell` and longitude
  `west + col * cell` to `west + (col + 1) * cell`.
- A cell holds a level, 2 bits: 0 none, 1 light (20 dBZ and up), 2 moderate (35 and up), 3 heavy
  (50 and up). The thresholds are in `protocol.json` `v5.radar.levels_dbz`. A level is the
  strongest echo in the cell, so a small core is never averaged away.

### 1.2 Radar (type 11)

Flags nibble: bit 0 **coarse** (16 × 16), bit 1 **partial** (the four `bounds` bytes are present),
bits 2 and 3 the data source as everywhere (a picture off the dish is 1).

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 4 | 4 | `taken` | u32 LE, Unix minutes: the time printed on the radar picture. Not when it was received, not when it was sent |
| 8 | 1 | `south` | i8, the tile's southern edge, whole degrees |
| 9 | 2 | `west` | i16 LE, the tile's western edge, whole degrees (−180 to 179) |
| 11 | 1 | `shape` | bits 0-1 `zoom`; bits 2-7 `product`, the index of the mosaic this was cut from in `v5.radar.products` |
| 12 | 4 | `bounds` | **only when partial**: `row0`, `row1`, `col0`, `col1`, u8 each, inclusive, in this packet's own grid (0-31, or 0-15 when coarse). The radar picture covers those rows and columns; every cell outside them is **unknown** and is encoded as level 0 |
| 12 or 16 | ≤ 153 | `cells` | The quadtree below, most significant bit first, zero bits to the end of the last byte |

The quadtree. `node(size)`:
- `size == 1`: 2 bits, the level.
- otherwise 1 bit. `0`: the whole square is one level, 2 bits follow. `1`: four children follow
  in the order north-west, north-east, south-west, south-east, each `node(size / 2)`.

The root is `node(32)`, or `node(16)` when coarse. An all-dry tile is 3 bits, one byte. A decoder
rejects a packet whose bits run out before the tree is complete; bits left over after it (fewer
than 8, all zero) are padding.

Measured on the squall line of 20 September 2026, 23:38Z, whole packets: Dallas under the line
131 bytes (the `radar_tile` vector), Austin on its edge 76, a clear tile 13.

### 1.3 Requests

| Request | Answer |
|---|---|
| `>radar` | The zoom 0 tile around the bot's home point |
| `>radar 30.270,-97.740` | The zoom 0 tile for that coordinate (three decimals, the `>f` form) |
| `>radar 30.270,-97.740 z2` | The same at zoom 2. `z0` to `z3`; anything else after the place is part of the place |
| `>radar round rock tx`, `>radar 78701 z1` | A place or ZIP the bot resolves, as `>f` does |

Refusals are Not available with request letter **`x`**, not `r`: `r` is `>rain`, and a refusal has
to say which of the two it refuses. It is the one request whose letter is not its first letter.

| Reason | When |
|---|---|
| 0 | No picture: none newer than 60 minutes covers the tile, or the region is not calibrated (Guam), or the tile lies outside every picture |
| 1 | The place did not resolve, or the coordinate is not one |
| 2 | This bot has no radar source (no dish directory) |
| 4 | This tile, cut from this same picture, went out in the last 5 minutes |

Limits: the per-sender 5 s rule and the hourly 60-packet budget apply; an answer is one packet.
The 5-minute rule is keyed on `(south, west, zoom, taken)`, so a newer picture is never held
back by an older one. Never broadcast on a schedule.

People's text command: `radar`, `radar austin tx`. A DM in words: the picture's time, what is
over the place, and where the nearest and the nearest heavy precipitation are.

### 1.4 What the bot does with a GIF (for the record; none of it is on the wire)

- Source: `*-RAD*.GIF` in the dish's EMWIN directory, newest per product by the `_C_KWIN_` stamp.
- Frame: 24 px banner above, 22 px legend below; between them x is linear in longitude and y is
  linear in **Mercator** latitude. The corners of all 14 calibrated products are in
  `meshcore_weather/radar/products.json`, fitted from each picture's own state lines (mean error
  0.15 to 0.8 px). Guam would not fit and is left out.
- dBZ: the GIF palette changes per image, so the colour scale drawn on the picture itself is read
  each time (−30 dBZ at x = 36, 2.38 px per dBZ) and the 256 palette entries are classified once.
- Furniture: roads, borders and labels are in the same place in every picture, so a mask per
  product learned from three days of pictures removes them. Warning polygons are drawn in colours
  the scale also uses, but their strokes are edged in black: a black pixel outside the mask, grown
  3 px, is a polygon. Masked cells take their neighbours' level. A lone light cell is dropped.
- Time: the picture's own time is read off its corner by matching the ten digit shapes. When that
  fails the product's issue time is used, which runs 2 to 8 minutes late.
- A picture whose state lines are not where the mask says they are is refused: the frame changed.

## 2. Names (Swift; JS per PORTING.md)

### MeshWX target
- `MeshWXWire.radarCoarseBit = 0x01`, `.radarPartialBit = 0x02`, `.radarGrid = 32`,
  `.radarCoarseGrid = 16`, `.maxRadarZoom = 3`, `.radarRequestLetter: Character = "x"`.
- `MeshWXMessageType.radar = 11`; `MeshWXMessage.radar(MeshWXRadar)`.
- `MeshWXRadar { takenMinutes: UInt32, south: Int8, west: Int16, zoom: UInt8, product: UInt8,
  isCoarse: Bool, bounds: MeshWXRadarBounds?, cells: [UInt8] }`, `cells` row-major, north row
  first, `size * size` of them, each 0 to 3. `size` is 16 when coarse, else 32.
  `MeshWXRadarBounds { row0, row1, col0, col1: UInt8 }`.
- `MeshWXRadarTile { south: Int, west: Int, zoom: Int }` (Hashable, Codable):
  `static func containing(latitude:longitude:zoom:) -> MeshWXRadarTile` (the lattice rule of 1.1),
  `spanDegrees`, `north`, `east`, `contains(latitude:longitude:)`,
  `cellBox(row:col:size:) -> (south, west, north, east)`, `cell(latitude:longitude:size:) ->
  (row, col)?`.
- `MeshWXRadarLevel: UInt8 { none, light, moderate, heavy }`.
- Decoder and encoder for type 11; the bot's new vectors (`radar_tile`, `radar_tile_coarse_partial`,
  `request_radar`, `not_available_radar`) join the fixtures. Decoded JSON keys: `taken_min`,
  `south`, `west`, `zoom`, `product`, `coarse`, `partial`, `bounds` (array of four or null),
  `size`, `rows` (array of `size` strings of the digits 0-3).

### Requests (`WeatherRequest`)
- `.radar(latitude: Double, longitude: Double, zoom: UInt8)`. Wire:
  `>radar 30.270,-97.740` at zoom 0, `>radar 30.270,-97.740 z2` otherwise. `requestLetter` is
  `x` for this case and the first letter for every other.
- `WeatherReplyKind.radar(tile: MeshWXRadarTile)`, the tile `containing` the asked coordinate. A
  Radar message for that tile from the bot asked settles the request whatever its `taken`.
  Another bot's Radar for the same tile settles it too (the picture is the same picture).

### State (`WeatherBotState`)
- `radarTiles: [WeatherStoredRadarTile]`, newest `taken` first.
  `WeatherStoredRadarTile { tile: MeshWXRadarTile, radar: MeshWXRadar, receivedAt: Date,
  source: MeshWXDataSource }`.
  Reducer rule on every Radar message: replace the stored entry for the same tile when the new
  `taken` is the same or newer (a coarse picture never replaces a fine one of the same `taken`);
  drop entries whose `taken` is more than 3 hours before **the newest `taken` this bot has sent**
  (a Radar packet carries no other bot clock, and a backlog tile is as old as its picture); keep
  at most 12, oldest `taken` dropped. Absent in an old state file means empty.

### Screen rules (`Services/Weather/Screen/`)
- `WeatherRadarPick.best(for coordinate:, tiles: [WeatherStoredRadarTile] (all bots), now:)` →
  `WeatherStoredRadarTile?`: among tiles that contain the coordinate (inside `bounds` when
  partial) and whose `taken` is at most 120 minutes old, the newest by `taken` rounded down to 15
  minutes, then the lowest zoom, then fine before coarse. `best(for:zoom:…)` is the same limited
  to one zoom.
- `WeatherRadarPick.held(_ tile:, tiles:, now:)`: the same for one exact tile, **without** the
  bounds filter. It is what the width control uses, and the only path on which "This picture does
  not reach Austin." can show.
- `WeatherRadarAge.make(takenMinutes:now:)` → `{ minutes: Int, isOld: Bool }`, old from 30
  minutes. Past 120 minutes a tile is not drawn at all.
- `WeatherRadarSummary.make(tile:coordinate:)` → `{ here: MeshWXRadarLevel?, nearest:
  Reach?, nearestHeavy: Reach? }` with `Reach { level, kilometres: Double, bearing:
  MeshWXCompass (8 points) }`. `here` is nil when the coordinate is outside `bounds`. `nearest` is
  the closest wet cell centre other than the place's own cell; `nearestHeavy` the closest level 3
  cell, omitted when it is the same cell as `nearest` or when `here` is heavy. Distances are great
  circle from the coordinate to the cell centre.
- `WeatherRadarCard.make(place:tiles:now:)` → `.noCoordinate | .missing | .held(picture:
  WeatherRadarPicture)` with `WeatherRadarPicture { stored, age, summary, isWiderThanAsked: Bool
  (zoom > 0) }`. Also `WeatherRadarCard.width(_ zoom:, place:tiles:now:)` (one width of the radar
  screen, through `held`), `.ask(place:zoom:) -> WeatherRequest?`, `.tile(for:zoom:)`, `.pageZoom`
  (0). Radar is **not** in `WeatherUpdatePlan`: Update never spends a packet on it.
- `WeatherRadarRefusal(reason:)` → `.noPicture` (0), `.unknownPlace` (1), `.unsupported` (2),
  `.sentRecently` (4), `.other`.
- `WeatherRadarCells.rectangles(radar:)` → `[WeatherRadarRectangle]` (`level, south, west, north,
  east`), one rectangle
  per horizontal run of equal non-zero level in a row, so a map draws hundreds of shapes and not
  a thousand. Unknown cells (outside `bounds`) are returned separately as `unknownRectangles`.
- `WeatherTrafficSummary`: title `.radar`, detail `[.tile(south, west, zoom), .wetCells(n)]`.
  Request rows read "Radar picture" with the asked coordinate or place.
- Cached and heard: `WeatherCacheGroup.radarPictures`, `WeatherChannelSubject.radar(tile:)`.
- Decode errors `radarTreeTruncated`, `radarBoundsOutsideGrid`; encode errors
  `radarCellOutsideBounds`, `radarBoundsOutsideGrid`.

Settled while building, and binding on all three codebases:
- **Tile edges.** `contains` is half-open on the north and east (`south <= lat < north`,
  `west <= lon < east`); `cell` floors then clamps into the grid. The bot's `describe()` does the
  same. `containing` clamps a zoom outside 0 to 3; the encoder refuses one.
- **Eight-point bearings are rounded from the bearing itself**, `floor((deg + 22.5) / 45) % 8`,
  never by folding a sixteen-point sector, which shifts every sector by 11.25° and made the phone
  say NE where the bot's text reply said N.
- **Footnotes under a radar ask**: the standard "Everyone listening on #meshwx gets the answer."
  first, the radar note last.
- The Radar section shows even on a page too empty to show a forecast: a coordinate is all it
  needs.

## 3. Screens (both clients)

**Place page, new Radar section** after the forecast. Three states:
- *Nothing held*: "No radar picture yet." and the ask, "Ask WX-AUS for the radar picture", with
  the footnote "1 packet. Pictures are made about every 15 minutes."
- *Held*: a square map of the tile (not interactive on the page; the whole card opens the radar
  screen): the cells in three colours, the place's dot, state and county lines. Under it the
  summary in words and the time: "Picture from 6:38 PM · 12 min old". From 30 minutes the time
  line takes the caution tone and adds "Precipitation has moved since." The ask reads "Ask for a
  newer picture".
- *Place with no coordinate*: the section is absent.

The summary sentences: "Heavy precipitation at Austin." / "Moderate …" / "Light …"; "Dry at
Austin. Nearest precipitation 45 km northwest."; with a separate heavy core, "Heavy precipitation
80 km northwest."; "No precipitation on this picture."; outside the bounds, "This picture does
not reach Austin." Distances follow the device's units. Radar sees snow as well as rain, hence
"precipitation".

**Radar screen** (pushed from the card). An interactive map framed on the tile: cells under the
alert shapes this device holds (alerts drawn as outlines only here, so they do not hide the
cells), the place's dot, a three-swatch legend (Light, Moderate, Heavy), the time line and the
summary. A segmented control picks the width: Local, Regional, Wide (zoom 0, 1, 2; zoom 3 exists
on the wire and is not offered). Each width shows the tile held for it, or "Not asked for yet",
and has its own ask with the cost "1 packet". A coarse tile says so in one quiet line. Unknown cells of a partial tile are hatched or
greyed, never left looking dry, with the line "Part of this area is outside the radar picture."

**Refusals**, in the ask's own status line: reason 0 "WX-AUS has no recent radar picture for this
area."; reason 2 "WX-AUS does not receive radar pictures."; reason 4 "WX-AUS sent this picture a
few minutes ago and has nothing newer yet."; reason 1 as the forecast's.

**Cached screen**: a "Radar pictures" group, one row per stored tile (width, centre, time).
**Channel traffic**: "Radar picture · Local · 214 cells with precipitation".

Colours: light green, moderate amber, heavy red, fills at about 55% with no outline, the same
three in both clients and in both themes. They are not the alert tints and are never used for an
alert.

The width control reads **Local**, **Regional**, **Wide** (zoom 0, 1, 2), not kilometres: a tile
is two degrees, which is 222 km tall everywhere and a different width at every latitude.

### 3.1 Strings

New keys in `Weather.strings` for all 11 locales (the web converts them with
`tools/strings-to-json.mjs`). No em dashes, no exclamation marks, matter-of-fact wording. The
English is fixed here so both clients say the same thing; `%@` is the bot's name unless noted.
Ages ("12 min old"), packet costs ("1 packet"), distances and compass points reuse the keys and
formatters the tool already has; do not add second copies of those.

| Key | English |
|---|---|
| `weather.radar.title` | Radar |
| `weather.radar.empty` | No radar picture yet. |
| `weather.radar.ask` | Ask %@ for the radar picture |
| `weather.radar.askNewer` | Ask for a newer picture |
| `weather.radar.ask.footnote` | Pictures are made about every 15 minutes. |
| `weather.radar.time` | Picture from %@ (the clock time) |
| `weather.radar.moved` | Precipitation has moved since. |
| `weather.radar.here.light` | Light precipitation at %@. (the place) |
| `weather.radar.here.moderate` | Moderate precipitation at %@. |
| `weather.radar.here.heavy` | Heavy precipitation at %@. |
| `weather.radar.here.dry` | Dry at %@. |
| `weather.radar.here.outside` | This picture does not reach %@. |
| `weather.radar.nearest` | Nearest precipitation %1$@ %2$@. (distance, compass point) |
| `weather.radar.nearestHeavy` | Heavy precipitation %1$@ %2$@. |
| `weather.radar.none` | No precipitation on this picture. |
| `weather.radar.level.light` | Light |
| `weather.radar.level.moderate` | Moderate |
| `weather.radar.level.heavy` | Heavy |
| `weather.radar.width.local` | Local |
| `weather.radar.width.regional` | Regional |
| `weather.radar.width.wide` | Wide |
| `weather.radar.notAsked` | Not asked for yet. |
| `weather.radar.partial` | Part of this area is outside the radar picture. |
| `weather.radar.coarse` | A busy picture, sent at half detail to fit one packet. |
| `weather.radar.refused.noPicture` | %@ has no recent radar picture for this area. |
| `weather.radar.refused.unsupported` | %@ does not receive radar pictures. |
| `weather.radar.refused.recent` | %@ sent this picture a few minutes ago and has nothing newer yet. |
| `weather.radar.cached.title` | Radar pictures |
| `weather.radar.request.title` | Radar picture |
| `weather.radar.traffic.cells` | %d cells with precipitation |

| `weather.radar.width` | Width (accessibility label of the width control) |
| `weather.radar.mosaic` | Cut from the %@ mosaic. (the product's name) |
| `weather.radar.traffic.cellsOne` | 1 cell with precipitation |

The last three were added while building. `weather.radar.traffic.cells` takes `%lld` in the iOS
table, like every other count there. Compass points are the existing abbreviations ("45 km NW").

## 4. What is deliberately not in revision 11

- No scheduled radar broadcast (owner: request-only to start).
- No multi-packet radar, so no `>part` for it. One packet or a coarser packet.
- No animation and no history: one picture per tile.
- Storm motion from the warnings' `TIME...MOT...LOC` line: wanted, separate, next.
- Guam, until its frame is calibrated. GOES infrared as a fallback where there is no radar.
