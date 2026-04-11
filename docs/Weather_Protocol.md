# MeshWX Protocol v0.1

**An open protocol for delivering weather data over MeshCore LoRa mesh networks.**

Any app or client that joins the well-known weather channel can consume this data. The reference server implementation is [meshcore-weather](https://github.com/pesqair/meshcore-weather). The reference iOS client is DigitainoMesh.

**Data source**: GOES East HRIT/EMWIN downlink via SDR (goestools/SatDump)

---

## Table of Contents

1. [Design Principles](#design-principles)
2. [Channel Architecture](#channel-architecture)
3. [Binary Message Types](#binary-message-types)
4. [Radar Grid (0x10)](#radar-grid-0x10)
5. [Warning Polygon (0x20)](#warning-polygon-0x20)
6. [Refresh Request (0x01)](#refresh-request-0x01)
7. [Reflectivity Quantization](#reflectivity-quantization)
8. [Region Definitions](#region-definitions)
9. [Server Behavior](#server-behavior)
10. [Client Behavior](#client-behavior)
11. [GIF-to-Reflectivity Pipeline](#gif-to-reflectivity-pipeline)
12. [Implementation Roadmap](#implementation-roadmap)
13. [Contributing](#contributing)

---

## Design Principles

1. **Channel-first delivery.** ALL weather data flows through a shared channel. Every listening client caches everything. One transmission serves all listeners. DMs are NEVER used for data delivery.

2. **Minimize airtime.** LoRa spectrum is shared and precious. The protocol is designed so that:
   - Scheduled broadcasts keep everyone current with zero per-user cost
   - When one user triggers a refresh, the fresh data goes on the channel — everyone benefits
   - A request that results in data that's already in the broadcast queue costs nothing extra
   - Clients should aggressively cache and only request refreshes when data is genuinely stale

3. **Open and client-agnostic.** The wire format is documented here. Any MeshCore-compatible app (iOS, Android, desktop, embedded) can join the channel, decode the binary messages, and render weather data however it wants. No app-specific handshake or registration required.

4. **Graceful degradation.** Clients without protocol support simply see binary messages on the channel as gibberish — harmless, easily muted. The existing text-based `wx` / `forecast` / `warn` commands continue to work unchanged for all users.

5. **Privacy-respecting.** User GPS coordinates are sent via DM (private). Weather data responses always go on the channel (public). No user location is ever broadcast.

---

## Channel Architecture

### Two Channels, One System

The meshcore-weather server operates on **two separate channels** that serve distinct purposes:

| Channel | Purpose | Content | Who listens |
|---------|---------|---------|-------------|
| **Text channel** (e.g., `#digitaino-wx-bot`) | Human-readable weather commands | Text messages (`wx Austin TX`, `forecast`, `warn`, `metar`, `more`, etc.) | All mesh users — works with any MeshCore client |
| **Data channel** (`#meshwx`) | Binary weather data delivery | `0x10` radar grids, `0x20` warning polygons, `0x01` refresh requests | MeshWX-aware clients only |

The text channel is the existing meshcore-weather interface — unchanged, fully backward-compatible. The data channel is new and carries only binary protocol traffic.

**Why separate channels:**
- Text users never see binary gibberish cluttering their chat
- Binary data broadcasts on its own cadence without competing with text conversations
- Either channel can operate independently — text-only deployments still work
- Clients can join one or both depending on their capabilities
- The data channel can be silently joined by apps — invisible to the user unless they want to see it

### The Data Channel (`#meshwx`)

- **Channel name**: `#meshwx` (or operator-configurable)
- **Channel secret**: Derived from the channel name (MeshCore standard)
- **Published**: The channel name is public knowledge — anyone can join
- **Content**: Binary-only. No text chat. Clients SHOULD NOT display these messages in any chat UI.

### The Text Channel (existing)

- **Channel name**: Operator-configured (e.g., `#digitaino-wx-bot`)
- **Content**: Human-readable weather queries and responses
- **Unchanged**: The existing meshcore-weather text interface works exactly as before
- **Interop**: Users without MeshWX-aware apps use this channel for all weather data

### Data Flow

```
                    ┌──────────────┐
                    │   WX SERVER  │
                    │              │
                    │  GOES East   │
                    │  SDR/EMWIN   │
                    └──┬───────┬───┘
                       │       │
          ─────────────┘       └──────────────
         │                                     │
         ▼                                     ▼
┌─────────────────────┐          ┌──────────────────────────┐
│  #digitaino-wx-bot  │          │       #meshwx            │
│  (text channel)     │          │    (data channel)        │
│                     │          │                          │
│  "wx Austin TX"     │          │  0x10 ████ radar grid    │
│  "Currently 72F..." │          │  0x20 ▲▲▲▲ warnings     │
│  "forecast Denver"  │          │  0x01 ← refresh req     │
│  "more"             │          │                          │
│                     │          │  ALL clients cache       │
│  Any MeshCore user  │          │  silently — no chat UI   │
└─────────────────────┘          └──────────────────────────┘

     Refresh trigger (private):
     ┌────────┐  DM: "@lat,lng refresh"  ┌──────────┐
     │ Client │ ──────────────────────▶  │  SERVER  │
     └────────┘                          └────┬─────┘
                                              │
                    responds on #meshwx       │
                    (everyone benefits)       ▼
                                    ┌──────────────────┐
                                    │  0x10 fresh data  │
                                    │  on #meshwx       │
                                    │  → all clients    │
                                    └──────────────────┘
```

### Why Channel-First

| Traditional (per-user DM) | MeshWX (channel broadcast) |
|---------------------------|---------------------------|
| 5 users request radar = 5 transmissions | 5 users hear 1 broadcast = 1 transmission |
| Each user's data is private and wasted | Each transmission benefits all listeners |
| More users = more airtime | More users = same airtime |
| Data dies with the conversation | Data is cached network-wide |

---

## Binary Message Types

All MeshWX messages are identified by their first byte (after COBS decoding — see below):

| Byte 0 | Type | Direction | Description |
|--------|------|-----------|-------------|
| `0x10` | Radar Grid | Server → Channel | 16x16 reflectivity grid, one frame |
| `0x20` | Warning Polygon | Server → Channel | Alert area with headline text |
| `0x01` | Refresh Request | Client → Channel | Request fresh data for a region |

Any message on `#meshwx` that does NOT start with a recognized type byte (after COBS decoding) is ignored by protocol-aware clients.

### COBS Encoding (Required)

**All binary messages MUST be COBS-encoded before being sent on the channel.** This is required because MeshCore firmware treats channel message payloads as C-strings, truncating at the first `0x00` byte. COBS (Consistent Overhead Byte Stuffing) eliminates all zero bytes from the encoded output.

**Why this matters:** The MeshWX wire format naturally contains `0x00` bytes — packed radar grid cells for clear weather (two 0-valued 4-bit cells = `0x00`), big-endian uint16 expiry fields with high byte zero (any expiry < 256 min), etc. Without COBS encoding, these messages are silently truncated by the firmware.

**Overhead:** COBS adds at most 1 byte per 254 input bytes. A 133-byte radar message encodes to at most ~134 bytes — well within the 136-byte LoRa frame limit.

**Encoding/Decoding:**

```python
# Python COBS encode (server side)
def cobs_encode(data: bytes) -> bytes:
    output = bytearray()
    block_start = len(output)
    output.append(0)  # placeholder for code byte
    run_length = 1
    for byte in data:
        if byte == 0x00:
            output[block_start] = run_length
            block_start = len(output)
            output.append(0)  # placeholder
            run_length = 1
        else:
            output.append(byte)
            run_length += 1
            if run_length == 0xFF:
                output[block_start] = run_length
                block_start = len(output)
                output.append(0)
                run_length = 1
    output[block_start] = run_length
    return bytes(output)

# Usage in broadcast:
raw_msg = pack_radar_message(grid, ...)
encoded_msg = cobs_encode(raw_msg)
await radio.send_channel(WX_CHANNEL, encoded_msg)
```

**Clients MUST attempt COBS decoding first**, then fall back to raw decoding for forward compatibility.

### Text Commands (Separate Channel)

The existing meshcore-weather text commands (`wx`, `forecast`, `warn`, `metar`, `taf`, etc.) continue to work on the text channel and via DM — completely unchanged. MeshWX binary data on `#meshwx` is a separate, additive data stream. It does not replace the text interface.

Users who only have basic MeshCore clients (no MeshWX support) use the text channel exclusively and are unaffected by the data channel's existence.

---

## Radar Grid (0x10)

A single radar frame covering one region. 133 bytes — fits in one 136-byte LoRa message.

### Wire Format

```
Offset  Size  Field
0       1     0x10 (message type)
1       1     region_id (high nibble) | frame_seq (low nibble)
                region_id: 0x0-0xF, identifies geographic region (see Region Definitions)
                frame_seq: sequence number for loop ordering (0 = oldest in a burst)
2       2     timestamp: minutes since midnight UTC, big-endian uint16
4       1     scale: km per grid cell, uint8
5       128   grid data: 16x16 cells, 4 bits each, packed row-major
                byte 5  = row0[col0] << 4 | row0[col1]
                byte 6  = row0[col2] << 4 | row0[col3]
                ...
                byte 132 = row15[col14] << 4 | row15[col15]
```

**Total: 133 bytes.**

Grid cells contain 4-bit reflectivity levels (see [Reflectivity Quantization](#reflectivity-quantization)).

### Geographic Positioning

Each `region_id` maps to a fixed, well-known bounding box (see [Region Definitions](#region-definitions)). Clients use the region bounding box to position the 16x16 grid on a map. No per-message coordinates are needed — the region ID is sufficient.

### Radar Loops

The server sends multiple frames for the same region in chronological order. Clients accumulate frames per region to build animated loops. The `frame_seq` field orders frames within a burst (0 = oldest). Clients SHOULD also accumulate frames across broadcast cycles to build longer loops over time.

---

## Warning Polygon (0x20)

A single active warning with polygon boundary and headline. Variable length, max 136 bytes.

### Wire Format

```
Offset  Size      Field
0       1         0x20 (message type)
1       1         warning_type (high nibble) | severity (low nibble)
2       2         expiry: minutes from now, big-endian uint16
4       1         vertex_count (N)
5       3         first vertex latitude: 24-bit signed, degrees * 10000 (~11m precision)
8       3         first vertex longitude: 24-bit signed, degrees * 10000 (~11m precision)
11      2*(N-1)   remaining vertices as signed delta pairs:
                    delta_lat: int8, units of 0.01 degrees (~1.1 km)
                    delta_lng: int8, units of 0.01 degrees (~0.9 km at mid-lat)
...     remainder headline text: UTF-8, fills to end of message
```

**Note on first vertex precision**: `degrees * 10000` (not `* 100000`) because 24-bit signed max is ±8,388,607 — US longitudes like -97.75° would overflow at `* 100000` (-9,775,000). At `* 10000`, the full range (-180° to +180°) fits comfortably (max value ±1,800,000) with ~11m precision, which is more than sufficient for NWS warning polygons.

### Warning Types

```
High nibble (type):            Low nibble (severity):
  0x1 = tornado                  0x1 = advisory
  0x2 = severe thunderstorm      0x2 = watch
  0x3 = flash flood               0x3 = warning
  0x4 = flood                     0x4 = emergency (PDS / tornado emergency)
  0x5 = winter storm
  0x6 = high wind
  0x7 = fire weather
  0x8 = marine
  0x9 = special weather statement
  0x0, 0xA-0xF = reserved
```

### Deduplication

Clients SHOULD deduplicate warnings by hashing (warning_type, severity, first_vertex_lat, first_vertex_lng, expiry). If a warning with the same hash is already cached and its expiry hasn't changed, ignore the duplicate.

### Size Budget

8-vertex tornado warning:
- Header + first vertex: 11 bytes
- 7 delta pairs: 14 bytes
- Polygon total: 25 bytes
- Remaining for headline: **111 bytes**
- Example: `"TORNADO WARNING til 345PM CDT - take shelter now"` (49 bytes)

---

## Refresh Request (0x01)

When a client determines its cached data for a region may be stale, it sends a refresh request **via DM to the server**. The server responds on the **data channel** so everyone benefits.

### Why DM for Requests, Channel for Responses

| | DM (request) | Channel (response) |
|-|--------------|---------------------|
| **Delivery** | ACK + retry — guaranteed to reach the server | Fire-and-forget — but all listeners hear it |
| **Cost** | 4 bytes, negligible | 133 bytes (radar) — expensive, so share it |
| **Privacy** | Only server sees which client asked | No user info in the response |

Channel messages have no delivery guarantee — no ACK, no retry. A refresh request that gets lost means the client is stuck waiting for data that never comes. DMs use MeshCore's built-in retry and acknowledgment, so a 4-byte request reliably reaches the server.

The response always goes on `#meshwx` — one broadcast serves all listeners regardless of who triggered it.

**Redundant requests are cheap and harmless.** If three clients DM a refresh for the same region within a few seconds, that's 12 bytes of DM traffic. The server rate-limits and only broadcasts once. When that fresh data appears on the channel, all three clients (and everyone else) update their cache and stop requesting.

### Wire Format

```
Offset  Size  Field
0       1     0x01 (message type)
1       1     region_id (high nibble) | request_type (low nibble)
                request_type: 0x1 = radar, 0x2 = warnings, 0x3 = both
2       2     client_newest: minutes since midnight UTC, big-endian uint16
                The timestamp of the NEWEST data the client has cached
                for this region. Set to 0x0000 if cache is empty.
```

**Total: 4 bytes.** Sent as a DM to the weather server's public key.

### Server Response

When the server receives a `0x01` refresh request via DM, it:

1. Compares `client_newest` against its own latest data timestamp for that region
2. **Server has newer data** → broadcasts fresh `0x10` and/or `0x20` messages on `#meshwx`
3. **Server has no newer data** → does nothing. **Silence means "you're already current."**

This prevents wasted airtime when the server hasn't received a new EMWIN product since the client's last update. Common scenarios where this saves airtime:
- EMWIN radar composite hasn't refreshed yet (satellite timing)
- Server just broadcast 5 minutes ago and nothing has changed
- Gap in the GOES downlink (dish issue, weather, maintenance)

### Client Interpretation of Silence

The client gets a DM ACK confirming the server received the request. If no new data appears on `#meshwx` within ~30 seconds after the ACK, the client SHOULD:
- Assume the server has nothing newer
- Continue displaying cached data
- Update the UI to show "Data current as of [cached timestamp]" rather than "Stale"
- Not retry immediately — wait at least 5 minutes before requesting the same region again

If the DM itself fails delivery (no ACK after retries), the client SHOULD show a "Server unreachable" status rather than "Stale data."

### Rate Limiting

The server SHOULD rate-limit refresh responses: at most one refresh per region per 5 minutes, regardless of how many clients ask. If a refresh was recently broadcast for a region, the server ignores subsequent requests for that region.

Clients SHOULD also self-rate-limit: track when they last sent a refresh request per region and don't re-request within 5 minutes.

### Privacy Note

Refresh requests are sent via DM — only the server sees them. The request contains a region ID, not the user's GPS coordinates. The server's response on the data channel contains only region-level data. No user location is ever exposed publicly.

### Location-Specific Text (DM Fallback)

For the traditional text weather commands (`wx Austin TX`, `forecast`, etc.), users continue to DM the bot directly. If a client wants to send GPS coordinates for automatic city resolution, it sends `@lat,lng wx` via DM. The text response comes back via DM. Binary weather data goes on the data channel.

---

## Reflectivity Quantization

4-bit values (0x0 - 0xE) map to dBZ ranges:

| Value | dBZ | Description | Suggested Color |
|-------|-----|-------------|-----------------|
| 0x0 | < 5 | No precipitation | transparent |
| 0x1 | 5 | Barely detectable | #00ECE0 (light cyan) |
| 0x2 | 10 | | #01A0F6 (blue) |
| 0x3 | 15 | | #0000F6 (dark blue) |
| 0x4 | 20 | Light rain | #00FF00 (green) |
| 0x5 | 25 | | #00C800 (mid green) |
| 0x6 | 30 | Moderate rain | #009000 (dark green) |
| 0x7 | 35 | | #FFFF00 (yellow) |
| 0x8 | 40 | Moderate-heavy | #E7C000 (gold) |
| 0x9 | 45 | | #FF9000 (orange) |
| 0xA | 50 | Heavy rain | #FF0000 (red) |
| 0xB | 55 | Hail possible | #D60000 (dark red) |
| 0xC | 60 | Hail likely | #C00000 (maroon) |
| 0xD | 65 | Severe | #FF00FF (magenta) |
| 0xE | 70+ | Extreme | #9955C9 (purple) |
| 0xF | — | Reserved | — |

Colors follow the standard NWS/NEXRAD reflectivity palette. Clients MAY use their own color scheme but SHOULD maintain the same perceptual intensity mapping (cool → warm → hot).

---

## Region Definitions

Each region has a fixed bounding box. Clients use these to position radar grids on a map. The server crops and downsamples EMWIN radar data to fit each region into a 16x16 grid.

| ID | Name | North | South | West | East | Scale (km/cell) |
|----|------|-------|-------|------|------|-----------------|
| 0x0 | Northeast | 48.0 | 37.0 | -82.0 | -67.0 | ~55 |
| 0x1 | Southeast | 37.0 | 24.0 | -92.0 | -75.0 | ~55 |
| 0x2 | Upper Midwest | 50.0 | 40.0 | -98.0 | -82.0 | ~55 |
| 0x3 | Southern | 37.0 | 25.0 | -105.0 | -88.0 | ~55 |
| 0x4 | Central | 44.0 | 34.0 | -105.0 | -90.0 | ~55 |
| 0x5 | Mountain | 49.0 | 31.0 | -117.0 | -102.0 | ~55 |
| 0x6 | Pacific | 49.0 | 32.0 | -125.0 | -114.0 | ~40 |
| 0x7 | Alaska | 72.0 | 51.0 | -180.0 | -130.0 | ~175 |
| 0x8 | Hawaii | 23.0 | 18.0 | -161.0 | -154.0 | ~28 |
| 0x9 | Puerto Rico | 19.5 | 17.0 | -68.0 | -65.0 | ~12 |
| 0xA-0xF | Reserved | — | — | — | — | — |

**Note**: These are approximate. Actual bounding boxes should be calibrated against the EMWIN radar composite GIF georeferencing. The scale values above assume the 16x16 grid covers the full bounding box width.

Servers and clients MUST agree on these bounding boxes. Changes require a protocol version bump.

---

## Server Behavior

### Broadcast Loop

The server runs a periodic broadcast cycle (configurable, default every 10 minutes):

```python
async def broadcast_loop():
    """Broadcast all weather data on #meshwx."""
    while True:
        await asyncio.sleep(BROADCAST_INTERVAL_SECONDS)  # default 600

        latest_gif = get_latest_radar_gif()
        if latest_gif is None:
            continue

        lut = get_or_build_palette_lut(latest_gif)
        timestamp = gif_timestamp_to_utc_minutes(latest_gif)

        # Broadcast radar for ALL regions that have data
        for region in ALL_REGIONS:
            grid = extract_radar_grid(
                latest_gif, lut,
                center_lat=region.center_lat,
                center_lng=region.center_lng,
                scale_km=region.scale_km
            )

            # Skip regions with no precipitation (all zeros) to save airtime
            if grid.max() == 0:
                continue

            msg = pack_radar_message(grid, region_id=region.id,
                                     frame_seq=0, timestamp=timestamp,
                                     scale_km=region.scale_km)
            await radio.send_channel(WX_CHANNEL, msg)

        # Broadcast all active warnings
        for w in get_all_active_warnings():
            msg = pack_warning_message(
                warning_type=w.type_code,
                severity=w.severity_code,
                expiry_minutes=w.minutes_until_expiry(),
                vertices=w.polygon_vertices,
                headline=w.headline
            )
            await radio.send_channel(WX_CHANNEL, msg)
```

**Airtime optimization**: Skip regions with no precipitation (all-zero grids). If it's a clear day across the southeast, don't broadcast 133 bytes of zeros for region 0x1. This alone can cut broadcast volume dramatically on fair-weather days.

### Refresh Handler

```python
# Timestamp of last refresh broadcast per region
last_refresh = {}

async def handle_channel_message(sender, data, channel):
    if channel != DATA_CHANNEL:
        return
    if len(data) < 4 or data[0] != 0x01:
        return

    region_id = (data[1] >> 4) & 0x0F
    request_type = data[1] & 0x0F
    client_newest = struct.unpack('>H', data[2:4])[0]  # minutes since midnight UTC

    # Rate limit: at most one refresh per region per 5 minutes
    now = time.time()
    if region_id in last_refresh and (now - last_refresh[region_id]) < 300:
        return

    region = REGIONS[region_id]
    latest_gif = get_latest_radar_gif()
    server_timestamp = gif_timestamp_to_utc_minutes(latest_gif)

    # Key check: does the server actually have newer data?
    # If client already has our latest, stay silent — save airtime
    if client_newest >= server_timestamp and client_newest != 0:
        return

    last_refresh[region_id] = now
    lut = get_or_build_palette_lut(latest_gif)

    if request_type in (0x1, 0x3):  # radar requested
        grid = extract_radar_grid(latest_gif, lut,
                                   region.center_lat, region.center_lng,
                                   region.scale_km)
        msg = pack_radar_message(grid, region_id=region.id,
                                 frame_seq=0, timestamp=server_timestamp,
                                 scale_km=region.scale_km)
        await radio.send_channel(DATA_CHANNEL, msg)

    if request_type in (0x2, 0x3):  # warnings requested
        for w in get_warnings_in_region(region):
            msg = pack_warning_message(
                warning_type=w.type_code, severity=w.severity_code,
                expiry_minutes=w.minutes_until_expiry(),
                vertices=w.polygon_vertices, headline=w.headline
            )
            await radio.send_channel(DATA_CHANNEL, msg)
```

### Two-Channel Server Setup

The server joins both channels simultaneously:

```python
# Server startup
TEXT_CHANNEL = "#digitaino-wx-bot"   # existing text command channel
DATA_CHANNEL = "#meshwx"             # binary data channel (MeshWX protocol)

await radio.join_channel(TEXT_CHANNEL)
await radio.join_channel(DATA_CHANNEL)
```

- **Text channel**: Handles all human-readable commands (`wx`, `forecast`, `warn`, `metar`, `taf`, `more`, `help`, etc.) — existing behavior, unchanged.
- **Data channel**: Broadcasts binary weather data (`0x10`, `0x20`) and listens for refresh requests (`0x01`).
- **DMs**: Handle `@lat,lng` prefixed commands from MeshWX-aware clients. Text response goes back via DM. Binary data goes on the data channel.

### Location-Aware DM Commands

When a DM arrives with `@lat,lng` prefix:

```python
async def handle_dm(sender_pubkey, message_text):
    lat, lng = parse_gps_prefix(message_text)
    if lat is not None:
        text_command = strip_gps_prefix(message_text)
        cache_user_location(sender_pubkey, lat, lng)
    else:
        text_command = message_text
        lat, lng = get_cached_location(sender_pubkey)

    # Text response via DM (existing behavior)
    response = process_command(text_command, sender_pubkey)
    await send_dm(sender_pubkey, response)

    # If GPS-capable client sent wx/radar/warn, trigger a data channel broadcast
    # for their region (benefits everyone listening on #meshwx)
    if lat is not None and text_command.strip().lower() in ('wx', 'radar', 'warn'):
        region = region_for_location(lat, lng)
        await trigger_refresh_for_region(region.id, request_type=0x3)
```

The key insight: **a DM request triggers a broadcast on the data channel**. The user gets their text response privately via DM. The binary weather data goes on `#meshwx` so every MeshWX-aware client benefits. The user's GPS stays private — only the region ID appears on the data channel.

---

## Client Behavior

### Joining the Channels

MeshWX-aware clients join **both** channels:

- **`#meshwx`** (data channel) — joined silently in the background. Never shown as a chat conversation. All binary weather data is ingested and cached here.
- **Text channel** (e.g., `#digitaino-wx-bot`) — optionally joined if the user wants to interact with the bot via text commands. Shown as a normal chat conversation.

Minimal clients that only want passive weather data need only join `#meshwx`. Full-featured clients join both.

### Message Handling

```
for each message received on #meshwx:
    byte0 = message.data[0]

    if byte0 == 0x10:
        decode radar grid
        store in cache keyed by (region_id, timestamp)
        do NOT display in chat UI

    else if byte0 == 0x20:
        decode warning polygon
        store in cache keyed by (type, severity, first_vertex, expiry)
        deduplicate against existing warnings
        do NOT display in chat UI

    else:
        ignore (or display as text if desired)
```

### Displaying Weather Data

When the user opens a weather view:

1. Check cache for data relevant to the user's current location
2. Find which region(s) overlap the user's coordinates
3. Display cached radar grids as map overlays, cached warnings as polygons
4. If newest cached data for user's region is **stale** (> 15 min old):
   - Send a `0x01` refresh request on `#meshwx` for that region
   - Show cached data with a "stale" indicator while waiting
   - When fresh data arrives on the channel, update the display
5. If cache has data and it's fresh → display immediately, zero airtime cost

### Radar Rendering

- Decode the 16x16 grid
- Look up the region bounding box by `region_id`
- Create a bitmap image: map each 4-bit value to its RGBA color (see quantization table)
- Render as a map overlay positioned at the region bounding box
- Apply bilinear interpolation for smooth appearance (the phone smooths 16x16 into a clean overlay)
- For loops: cycle through cached frames for the same region on a 0.5s timer

### Warning Rendering

- Decode polygon vertices (absolute first vertex + deltas)
- Render as map polygon overlays, color-coded by type and severity
- Solid fill + border for warnings; dashed border for watches
- Tap a polygon → show detail sheet with headline, expiry countdown
- Optionally: "Get Full Text" button sends a `warn` DM to the bot for paginated text

### Optional Notifications

Clients MAY show an optional badge or indicator when new weather data arrives on the channel. This should be user-configurable (settings toggle). Useful for tinkerers who want to see the data stream flowing. Default: off (silent caching).

### Data Cache Structure

```
Weather Cache
├── radar/
│   └── [region_id]/
│       └── frames[]              (ring buffer, keep last ~12 per region)
│           ├── timestamp
│           ├── grid (16x16 uint4)
│           └── scale_km
├── warnings[]                    (list, auto-pruned by expiry)
│   ├── type, severity
│   ├── expiry (absolute time)
│   ├── polygon vertices
│   ├── headline
│   └── dedup_hash
└── meta/
    └── last_refresh_request      (per region, to avoid spamming)
```

---

## GIF-to-Reflectivity Pipeline

GOES HRIT/EMWIN does not carry binary NEXRAD data. It carries pre-rendered radar composite GIF/PNG images. These GIF files use indexed color palettes where each palette index maps to a known dBZ range. The server extracts reflectivity values by reverse-mapping the palette.

### Pipeline Steps

1. **Intercept EMWIN radar composite GIF** from goestools output directory
2. **Read the GIF's embedded palette** — GIF files are palette-indexed (up to 256 colors)
3. **Build palette index → dBZ lookup table** by matching each palette color to the nearest known NEXRAD reflectivity color
4. **Geolocate** — CONUS radar mosaic bounds are approximately 21N-50N, 130W-60W (verify against actual GIF dimensions)
5. **Crop** to region bounding box using lat/lng → pixel conversion
6. **Downsample** to 16x16 using **NEAREST-NEIGHBOR** interpolation (critical: bilinear would blend palette indices which is meaningless)
7. **Quantize** each pixel's dBZ value to 4-bit level
8. **Pack** into wire format (two cells per byte, row-major)

### Python Reference Implementation

```python
from PIL import Image
import numpy as np
import struct

# CONUS radar mosaic approximate georeferencing
# VERIFY against actual EMWIN GIF dimensions
IMAGE_BOUNDS = {
    'lat_north': 50.0,  'lat_south': 21.0,
    'lon_west': -130.0, 'lon_east': -60.0,
}

# Standard NEXRAD reflectivity color table
# Map (R, G, B) -> dBZ value
# MUST be calibrated against actual EMWIN GIF palette
NEXRAD_COLORS_DBZ = {
    (0, 0, 0): None,        (0, 236, 236): 5,
    (1, 160, 246): 10,      (0, 0, 246): 15,
    (0, 255, 0): 20,        (0, 200, 0): 25,
    (0, 144, 0): 30,        (255, 255, 0): 35,
    (231, 192, 0): 40,      (255, 144, 0): 45,
    (255, 0, 0): 50,        (214, 0, 0): 55,
    (192, 0, 0): 60,        (255, 0, 255): 65,
    (153, 85, 201): 70,     (255, 255, 255): 75,
}


def build_palette_lut(gif_path):
    """Build a palette index -> dBZ lookup table from a GIF file."""
    img = Image.open(gif_path)
    palette = img.getpalette()
    if palette is None:
        raise ValueError("GIF has no palette")
    lut = {}
    for idx in range(256):
        r, g, b = palette[idx*3], palette[idx*3+1], palette[idx*3+2]
        lut[idx] = _nearest_dbz((r, g, b))
    return lut


def _nearest_dbz(rgb):
    """Find the nearest known NEXRAD color and return its dBZ value."""
    best_dist = float('inf')
    best_dbz = None
    for known_rgb, dbz in NEXRAD_COLORS_DBZ.items():
        dist = sum((a - b) ** 2 for a, b in zip(rgb, known_rgb))
        if dist < best_dist:
            best_dist = dist
            best_dbz = dbz
    return best_dbz


def latlon_to_pixel(lat, lng, img_width, img_height):
    b = IMAGE_BOUNDS
    x = int((lng - b['lon_west']) / (b['lon_east'] - b['lon_west']) * img_width)
    y = int((b['lat_north'] - lat) / (b['lat_north'] - b['lat_south']) * img_height)
    return max(0, min(x, img_width-1)), max(0, min(y, img_height-1))


def extract_radar_grid(gif_path, lut, center_lat, center_lng,
                       scale_km=12, grid_size=16):
    img = Image.open(gif_path)
    w, h = img.size
    cx, cy = latlon_to_pixel(center_lat, center_lng, w, h)

    total_km = scale_km * grid_size
    deg_radius = total_km / 111.0 / 2.0
    b = IMAGE_BOUNDS
    px_radius_x = int(deg_radius / (b['lon_east'] - b['lon_west']) * w)
    px_radius_y = int(deg_radius / (b['lat_north'] - b['lat_south']) * h)

    left = max(0, cx - px_radius_x)
    top = max(0, cy - px_radius_y)
    right = min(w, cx + px_radius_x)
    bottom = min(h, cy + px_radius_y)
    cropped = img.crop((left, top, right, bottom))

    # NEAREST preserves palette indices — do NOT use bilinear
    small = cropped.resize((grid_size, grid_size), Image.NEAREST)
    pixels = np.array(small)

    grid = np.zeros((grid_size, grid_size), dtype=np.uint8)
    for y in range(grid_size):
        for x in range(grid_size):
            dbz = lut.get(int(pixels[y, x]))
            if dbz is None or dbz < 5:
                grid[y, x] = 0
            else:
                grid[y, x] = min(14, max(1, dbz // 5))
    return grid


def pack_radar_message(grid, region_id, frame_seq, timestamp, scale_km):
    msg = bytearray()
    msg.append(0x10)
    msg.append((region_id & 0x0F) << 4 | (frame_seq & 0x0F))
    msg.extend(struct.pack('>H', timestamp & 0xFFFF))
    msg.append(scale_km & 0xFF)
    for row in range(16):
        for col in range(0, 16, 2):
            high = grid[row, col] & 0x0F
            low = grid[row, col + 1] & 0x0F
            msg.append((high << 4) | low)
    return bytes(msg)


def pack_warning_message(warning_type, severity, expiry_minutes,
                         vertices, headline):
    msg = bytearray()
    msg.append(0x20)
    msg.append((warning_type & 0x0F) << 4 | (severity & 0x0F))
    msg.extend(struct.pack('>H', min(expiry_minutes, 0xFFFF)))
    msg.append(len(vertices) & 0xFF)
    lat0, lng0 = vertices[0]
    msg.extend(int(lat0 * 10000).to_bytes(3, 'big', signed=True))
    msg.extend(int(lng0 * 10000).to_bytes(3, 'big', signed=True))
    for lat, lng in vertices[1:]:
        dlat = max(-128, min(127, int((lat - lat0) / 0.01)))
        dlng = max(-128, min(127, int((lng - lng0) / 0.01)))
        msg.extend(struct.pack('bb', dlat, dlng))
    remaining = 136 - len(msg)
    if remaining > 0:
        msg.extend(headline.encode('utf-8')[:remaining])
    return bytes(msg)


def parse_warning_latlon(text):
    """Parse LAT...LON line from NWS warning product."""
    import re
    match = re.search(r'LAT\.\.\.LON\s+([\d\s]+)', text)
    if not match:
        return []
    numbers = list(map(int, match.group(1).split()))
    vertices = []
    for i in range(0, len(numbers) - 1, 2):
        vertices.append((numbers[i] / 100.0, -numbers[i+1] / 100.0))
    return vertices
```

### Calibration

The color table above is approximate. Implementers **must** calibrate by:

1. Opening an actual EMWIN radar GIF received from goestools
2. Printing the embedded palette (`img.getpalette()`)
3. Comparing palette entries against known dBZ values
4. Adjusting `NEXRAD_COLORS_DBZ` to match

The IEM documents their composites use pixel values that "increase monotonically from -30 dBZ to 75 dBZ every 5 dBZ." If EMWIN GIFs follow this convention, the palette index itself directly encodes dBZ — check this first.

### GIF Georeferencing

CONUS radar mosaic bounds (verify against actual files):

```
Width:  ~6000 px    North: 50.0 N    West:  130.0 W
Height: ~2600 px    South: 21.0 N    East:   60.0 W
```

Verify by checking a known city's pixel location against the image.

---

## Implementation Roadmap

### Phase 1: Channel Broadcast (Server)

- Implement broadcast loop on `#meshwx`
- GIF palette → dBZ pipeline for all regions
- Skip empty regions (no precip) to save airtime
- Broadcast active warnings
- **Test**: Clients on the channel receive and can hex-dump radar grids

### Phase 2: Client Cache + Rendering (iOS / Android / etc.)

- Auto-join `#meshwx`
- Detect and decode binary messages
- Cache radar grids and warnings by region
- Render radar as MapKit overlay (iOS) or equivalent
- Render warnings as styled polygons
- **Test**: Open weather view, see radar overlay without any user action

### Phase 3: Refresh Requests

- Client sends `0x01` when cached data is stale
- Server responds on channel (rate-limited)
- **Test**: After 20 min of no broadcasts, opening weather view triggers refresh, all clients update

### Phase 4: Location-Aware Text via DM

- Parse `@lat,lng` prefix in DM handler
- Resolve to nearest city/zone for text responses
- DM request triggers channel broadcast for that region
- **Test**: DM `@32.87,-97.32 wx` → get text DM back + see region 0x3 radar on channel

### Phase 5: Polish

- Radar loop animation
- Warning tap-to-detail flow
- Optional data arrival badge (user-configurable)
- Data freshness indicators
- Airtime usage dashboard (for operators)

---

## Contributing

This is an open protocol. Contributions welcome:

- **Client implementations**: Build a MeshWX client for your platform
- **Region definitions**: Propose region bounding boxes for non-US coverage
- **New message types**: Propose new binary types (satellite imagery, forecasts, etc.) — reserve type bytes via PR
- **Server implementations**: Alternative data sources beyond EMWIN (NOAA API fallback, international weather services)

Reserved message type bytes for future use:

| Byte | Reserved For |
|------|-------------|
| 0x01 | Refresh Request (defined above) |
| 0x10 | Radar Grid (defined above) |
| 0x20 | Warning Polygon (defined above) |
| 0x30 | Satellite IR Grid (future) |
| 0x40 | Text Forecast Chunk (future) |
| 0x50 | Surface Observations (future) |
| 0xF0 | Protocol Negotiation / Version (future) |
