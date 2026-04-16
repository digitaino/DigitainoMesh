# MeshWX

**Mesh Weather Client** — receive live weather data over LoRa mesh networks using a [MeshCore](https://github.com/rme-mesh/meshcore) companion radio.

MeshWX connects to your radio via USB Serial or Bluetooth Low Energy, joins the mesh weather data channel, and displays a live dashboard with observations, forecasts, radar, warnings, and more.

## What You Need

- A **MeshCore companion radio** (any MeshCore-compatible LoRa device)
- A **MeshWX weather bot** broadcasting on your mesh network
- **Chrome or Edge** browser (for the web client — requires Web Serial or Web Bluetooth API)

## Quick Start

### Option 1: Download the Desktop App

Download pre-built binaries from the [Releases](https://github.com/digitaino/meshwx-client/releases) page:

| Platform | Download |
|----------|----------|
| macOS (Apple Silicon) | `MeshWX-1.0.0-arm64.dmg` |
| Windows (x64) | `MeshWX Setup 1.0.0.exe` (installer) or `MeshWX 1.0.0.exe` (portable) |
| Linux (x64) | `MeshWX-1.0.0.AppImage` or `meshwx_1.0.0_amd64.deb` |
| Linux (ARM64) | `MeshWX-1.0.0-arm64.AppImage` or `meshwx_1.0.0_arm64.deb` |

The macOS build is signed and notarized by Apple. On Linux, you may need to `chmod +x` the AppImage before running it.

### Option 2: Run the Web Client

Requires [Node.js](https://nodejs.org/) (no dependencies to install).

```bash
node serve.js
```

Open **http://localhost:8095** in Chrome or Edge, then click **USB Serial** or **Bluetooth** to connect your radio.

## How It Works

1. **Connect** — MeshWX pairs with your MeshCore companion radio over USB or BLE
2. **Discover** — It sends a ping on the `#meshwx-discover` channel to find weather bots. If the channel doesn't exist, it's auto-provisioned on a free slot
3. **Join** — When a bot responds with a beacon, you can join its data channel (e.g. `#aus-meshwx-v4`)
4. **Receive & Decode** — Weather messages arrive as compact binary packets (MeshWX Protocol v4) over LoRa and are decoded in real time. V4 frames support FEC (forward error correction) with XOR parity recovery for dropped quadrants
5. **Display** — Data is rendered in a tabbed dashboard with auto-updating cards. You can also search for locations and request specific data from the bot

## Weather Products

MeshWX decodes and displays the following products from NWS data broadcast over the mesh:

| Product | Description |
|---------|-------------|
| Observations (METAR) | Current conditions — temperature, wind, sky, pressure, visibility, feels-like |
| Forecasts (PFM) | Multi-period point forecasts with day/night breakdowns |
| TAF | Terminal aerodrome forecasts with flight category (VFR/IFR/LIFR/MVFR) |
| Warnings (VTEC) | Severe weather warnings, watches, and advisories with polygon or zone geometry |
| Radar | Regional radar imagery rendered as color-mapped grids on canvas and on a MapLibre map |
| QPF | Quantitative precipitation forecasts (same grid format as radar) |
| Fire Weather (FWF) | Fire weather forecasts — wind, humidity, temperature, Haines index, lightning risk |
| Nowcasts (NOW) | Short-term forecasts with urgency flags (thunder, flooding, winter, fire, wind) |
| Hazardous Weather Outlook | Multi-day hazard outlook with risk levels per hazard type |
| Storm Reports (LSR) | Local storm reports — tornado, hail, damaging wind, etc. with magnitude |
| Rain Observations (RTP) | Precipitation reports by city |
| Daily Climate | Daily high/low temperatures, precipitation, and snowfall by city |
| Warnings Near | Active warnings near a specific zone |

## Data Requests

When connected, you can search for a city, station, or ICAO code to request data directly from the weather bot. Available request types:

- **METAR** — current observations for a station
- **TAF** — terminal forecast for a station
- **Forecast** — multi-period point forecast
- **Outlook** — hazardous weather outlook
- **Storm Reports** — local storm reports near a location
- **Rain Observations** — precipitation data near a location

Requests are sent as `WXQ` + hex-encoded binary on the data channel.

## Project Structure

```
meshwx-web/
  index.html          # Single-page app
  serve.js            # Zero-dependency Node.js dev server
  package.json        # npm metadata
  css/portal.css      # Styles
  js/
    app.js            # Main app controller & UI
    decoder.js        # MeshWX binary protocol decoder (v4 + FEC)
    cobs.js           # COBS framing codec
    radar.js          # Radar image renderer (thumbnail + smooth)
  data/               # Station/location lookup tables (pfm_points, stations, zones, state_index)
  geo/                # GeoJSON for map layers (countries, states, cities)
  vendor/
    meshcore/         # MeshCore Companion JS library
    maplibre/         # MapLibre GL JS (map rendering)
  electron/           # Electron desktop app wrapper
    main.js           # Main process (BLE/Serial permissions)
    package.json      # Build config (electron-builder)
    entitlements.plist # macOS entitlements
```

## Building the Desktop App

To build the Electron app yourself:

```bash
cd electron
npm install
npm run build:mac      # macOS (.dmg, .zip)
npm run build:win      # Windows (.exe installer + portable)
npm run build:linux    # Linux (.AppImage, .deb)
```

Cross-platform builds from macOS work for Windows and Linux. Add `-- --x64` or `-- --arm64` to target a specific architecture.

## Protocol

MeshWX uses a compact binary protocol (v4) designed for LoRa's low bandwidth. Weather data from NWS is compressed into small packets, COBS-encoded, and broadcast over MeshCore mesh channels. V4 wraps inner message types in a frame header with FEC support — large messages (like 64x64 radar grids) are split into quadrants with an XOR parity unit, allowing recovery of one lost quadrant per group. The JavaScript decoder in `js/decoder.js` is a port of the Swift decoder used in the [DigitainoMesh](https://github.com/digitaino/DigitainoMesh) iOS app.

## Related

- **[meshwx](https://github.com/digitaino/meshwx)** — The weather bot server. Fetches NWS EMWIN data and broadcasts it over LoRa mesh networks.
- **[DigitainoMesh](https://github.com/digitaino/DigitainoMesh)** — iOS MeshCore client with built-in MeshWX weather decoding.

## License

MIT
