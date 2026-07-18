# Survey v2 — System Design

Date: 2026-07-18 · Branch: `feature/survey-v2`
Companion: [ADVERSARIAL_REVIEW.md](ADVERSARIAL_REVIEW.md) (the "why" for every decision here).

## 1. Goals

1. **One spatial truth.** Finish the H3 migration end-to-end. The server's v2 pipeline,
   database, and web frontend are already H3 res-10; the iOS client joins them. The custom
   axial grid becomes legacy-read-only.
2. **Stop hammering the mesh.** Probe cadence is governed by a hard transmission budget
   (token bucket) plus speed-adaptive cell resolution — driving fast coarsens the sampling
   cell instead of multiplying transmissions.
3. **A real scaffold.** One shared Swift package (`SurveyKit`) owns grid math, wire DTOs,
   sampling policy, quality scale, and validation — compiled into both the iOS app and the
   Vapor server. No more copy-paste contracts.
4. **Max data per cell.** Directional per-repeater stats (heard-them AND heard-us), route
   and hop breakdowns, active/passive splits, probe success, and full time data (per-cell
   range, per-repeater first/last heard, per-day observation counts).
5. **Anonymous by default, authenticated app.** Uploads carry no PII and no stable client
   identifier unless the user opts into attribution. The app still authenticates to the API.
6. **HIG-conformant, unified UX.** One map stack, one palette, standard navigation,
   accessible controls.

## 2. Architecture overview

```
┌──────────────────────────── iOS app (MC1) ────────────────────────────┐
│  SignalSurveyView (SwiftUI, thin)                                     │
│  SignalSurveyViewModel (display state only)                           │
│          │ observes                                                   │
│  ┌───────▼─────────────  MC1Services  ─────────────────────────┐      │
│  │  SurveyEngine (actor) — sessions, RX intake, probe loop,    │      │
│  │  TX budget, dedup, batching, upload queue                   │      │
│  └───────┬─────────────────────────────────────────────────────┘      │
└──────────┼────────────────────────────────────────────────────────────┘
           │ imports                                    imports
   ┌───────▼───────────────── SurveyKit (SPM) ────────────────▼───────┐
   │  CH3 (vendored uber/h3 C library)                                │
   │  SurveyGrid   — typed H3: cell, parent, boundary, center         │
   │  SamplingPolicy — speed tiers, token bucket, probe decisions     │
   │  SurveyWire   — v2.2 DTOs (upload, cells, stats, receipts)       │
   │  SignalQuality — one 5-tier SNR scale + thresholds               │
   │  CellAggregator — points → per-cell stats (display = upload)     │
   └──────────────────────────────▲───────────────────────────────────┘
                                  │ imports (path dependency)
   ┌──────────────────────────────┴───────────────────────────────────┐
   │  pocketmesh-survey-server (Vapor) — /api/v2 ingest & serve,      │
   │  Postgres + PostGIS + h3-pg, MapLibre/deck.gl frontend           │
   └──────────────────────────────────────────────────────────────────┘
```

`SurveyKit` lives at the repo root beside `MeshCore` and `MC1Services`. The server gains a
local path dependency on it (Docker build context moves to the repo root with a
`.dockerignore` to keep the context small). The web frontend needs **no grid math at all**:
it already renders H3 indices directly via deck.gl's `H3HexagonLayer`.

## 3. Grid: H3 end-to-end

- **Vendored C library.** `SurveyKit/Sources/CH3/` vendors the official uber/h3 C sources
  (Apache-2.0, pinned release, no third-party Swift wrapper). Builds for iOS, macOS, and
  Linux. `SurveyGrid` is the only Swift API surface; nothing outside SurveyKit touches CH3.
- **Base recording resolution: H3 res 10** (~76 m edge, ~130 m across) — matches the
  server's v2 pipeline and is nearly identical in area to the old ~100 m axial cells.
- **Sampling tiers** (drive the probe cadence and live paint, not storage):

  | Tier | H3 res | ~across | Selected when (with hysteresis) |
  |------|--------|---------|--------------------------------|
  | fine | 10 | ~130 m | speed < 4.5 m/s (walking, jogging, slow cycle) |
  | medium | 9 | ~350 m | 4.5–14 m/s (cycling, city driving) |
  | coarse | 8 | ~920 m | > 14 m/s (highway) |

  Tier switches require the speed band to hold for 5 s and use ±10 % thresholds so noisy
  GPS speed doesn't flap the tier. Manual override (`Auto / Fine / Medium / Coarse`) is
  available but Auto is the default.
- **Recording vs sampling.** Every recorded packet is bucketed at the *finest* resolution
  its GPS accuracy supports (normally res 10) regardless of tier. The tier only decides
  *when a new probe is worth a transmission* and how the live map paints "surveyed" area
  while moving fast. Driving a highway paints res-8 cells live; the underlying res-10
  samples still upload, so data quality never degrades silently — coverage is just sparser.
- **Legacy compatibility.** `SurveyGrid` also hosts the legacy axial math (moved from
  `MC1/Utilities/HexGrid.swift`) as `LegacyAxialGrid`, used only to render/export old
  local sessions and to keep the v1 upload path alive during transition.

## 4. Mesh TX policy (SamplingPolicy)

All transmit decisions flow through one pure, unit-tested type. No other code may call the
radio for survey purposes.

- **Token bucket (the hard cap).** Capacity 6 tokens, refill 1 token / 10 s (≤ 6 radio
  transmissions per minute sustained, small bursts allowed). Costs: discover = 1,
  trace = 1, channel flood = 2. The bucket is shared by automatic *and* manual probes;
  manual probes may dip the bucket into a small reserve so the button still works, but can
  never exceed it. When the bucket is empty, probes are *skipped, not queued* — the next
  novel cell triggers the next attempt.
- **Novelty gating.** An automatic probe fires only when entering a tier-cell with no
  sample this session. Re-entering a sampled cell does not probe (the passive RX path still
  records anything heard for free).
- **Cadence bounds.** Min 8 s between automatic probe cycles regardless of novelty;
  keepalive probe at 60 s stationary-max only if the current cell has zero samples.
- **Flood quota.** ≤ 1 channel flood per tier-cell per session, and floods also pay the
  2-token cost. Discover+trace remain the default probe; floods only fire where two-way
  confirmation is missing.
- **Worked example (the reported bug).** Driving 110 km/h on the highway: old system =
  discover+trace every ~3.3 s plus floods every 8 s ⇒ ~45 TX/min. New system: coarse tier
  (res 8) crossings every ~26 s, bucket caps at 6 TX/min, novelty suppresses re-crossings
  ⇒ **≤ 4–6 TX/min worst case, ~2–3 typical**, with graceful degradation to zero in
  already-surveyed areas.

## 5. Wire protocol v2.2 (SurveyWire)

Additive evolution of the server's existing `UploadV2DTOs` (`version: "2.2"`); the server
keeps accepting 2.0/2.1.

**Per-cell (existing, now fully populated):** `h3`, SNR stats incl. `tx_avg`, `rssi_avg`,
`packet_count`, `active/passive_packet_count`, `probes_sent`, `route_breakdown`,
`time_range` (earliest/latest — now always sent), per-repeater observations.

**Per-cell (new in 2.2):**
- `daily_counts: {"2026-07-18": 42, …}` — observation counts per UTC day, powering
  accurate time filtering and freshness decay on the map.
- `hop_histogram: {"0": 12, "1": 30, "2": 5}` — mesh depth distribution.

**Per-repeater observation (new in 2.2):** `first_heard` joins `last_heard`; the
directional split `rx_packet_count` (we heard them) / `tx_packet_count` (they heard us —
confirmed by discover/trace responses) is required rather than optional.

**Privacy model (new in 2.2):**
- `contributor` becomes **optional**. Default upload is anonymous: no contributor ID, no
  display name, no session UUIDs.
- New top-level `receipt_b64`: 32 random bytes generated per batch, stored only on the
  uploading device. `DELETE /api/v2/uploads/:receipt` removes that batch's contributions
  exactly (same audit-row subtraction as contributor deletion). Re-uploading a session =
  delete old receipt + fresh upload; the client tracks session→receipt locally.
- Server stops persisting `client_ip` on `uploads` (rate limiting stays in-memory only).
- Verified attribution (Ed25519 profile, display name) remains available as an explicit
  opt-in and works exactly as today.
- Time data is retained at full fidelity by explicit product decision: coverage
  measurements need dates. The residual risk (a surveyed trail is inherently a movement
  trace of *someone*) is mitigated by anonymity of identity, deferred upload by default
  (batch at session end; live streaming is opt-in), and the existing deletion paths.

**App authentication:** goal is "only the PocketMesh app can post," not "identify the
client." v2.2 requests carry `X-Client-Sig: HMAC-SHA256(timestamp ‖ body, embedded key)`
plus `X-Client-Ts` (±5 min replay window). Constant-time verification server-side; the
static `X-API-Key` continues to work for older clients until sunset. An embedded key is
extractable by a determined attacker — accepted; defense in depth is validation + rate
limits + receipts-based cleanup + (future, documented) App Attest.

## 6. Client: SurveyEngine

New `public actor SurveyEngine` in MC1Services replaces the TX/upload halves of the view
model and absorbs `SurveyService`'s RX intake:

- **Explicit state machine:** `idle → starting → active(paused:) → stopping → idle`, with
  a single `SurveyEngineState` published via `AsyncStream` snapshots to the UI.
- **RX intake** (from RxLogService, discover/trace events): synchronous dedup
  check-and-reserve *before* any suspension point (fixes the reentrancy race B1), then
  GPS-stamp, res-10 bucket, persist, incrementally update the in-memory `CellStore`.
- **Probe loop** ticks on location updates (not a timer), asks `SamplingPolicy` for a
  `ProbeDecision`, executes via the protocol services, attributes responses back to the
  cell that requested them.
- **Upload queue:** cells dirty-marked in `CellStore` are flushed as one batched v2.2
  payload at session end (default) or every 45 s / 20 cells in live mode, with
  exponential backoff and offline persistence (fixes B6).
- **One aggregation path:** display, export, and upload all read `CellAggregator` output
  from the same `CellStore` (fixes B3/B4).
- `SurveyService` remains as the thin RX classifier feeding the engine; the 2,551-line
  view model shrinks to display state + user intents.

Persistence: `SignalSurveyPoint` keeps raw GPS + adds stored `h3` (res 10, backfilled
lazily for old points); `SurveySession` gains `tierBreakdown` and receipt bookkeeping;
`probesSentData`/`completionStatsData` blobs migrate to typed tables when touched.

## 7. Server changes

1. **Adopt SurveyKit** (path dep) for DTOs, quality thresholds, validation — deleting the
   server-local copies (fixes E1's root cause, E9).
2. **Correctness:** roll back aggregates on v2 batch re-upload (E4); make v2 cell upserts
   not collide with the v1 unique constraint (E5); wrap v1 read-modify-write in
   transactions (E6).
3. **Multi-resolution reads:** `GET /api/v2/cells?bbox&res=8..10`. One `GROUP BY
   h3_cell_to_parent(h3_index, :res)` rollup (finer rows aggregate up; coarser rows pass
   through) so country-level viewports return hundreds of cells, not tens of thousands
   (fixes C3 server-side). deck.gl and the iOS overlay both render mixed-res results.
4. **Time data:** store `daily_counts` into a `cell_observation_days` table
   (cell_id, day, packet_count) and `first_heard` on `cell_repeaters`; native
   `TIMESTAMPTZ` columns for new fields (E8's string-timestamp debt stops growing).
5. **Receipts:** `upload_receipts` table (receipt-hash → contribution rows);
   `DELETE /api/v2/uploads/:receipt`; drop `client_ip` persistence.
6. **Admin auth:** dedicated `ADMIN_API_KEY` (constant-time compare) required by the whole
   admin group in-app; Cloudflare Access stays as the outer wall (E3, E12). `admin.html`
   prompts once and stores the key locally.
7. **HMAC middleware** for v2.2 (§5), constant-time everywhere.
8. **Tests:** ingest (2.0/2.1/2.2), re-upload rollback, receipt deletion, multi-res
   rollup, HMAC/admin auth — the endpoints finally get coverage (E11).

v1 stays mounted for old clients but is legacy-frozen; its SQLite-only read SQL gets the
minimal `STRING_AGG`/boolean fix (E2) so it doesn't 500 on production Postgres.

## 8. UX / HIG

- **One map stack.** `SurveyMapRepresentable` becomes the single survey/community host;
  shared `HexMapCore` helpers (palette, polygon hit-testing, overlay diffing) are consumed
  by the Map tab too. Dead `CommunityMapView` is deleted (its nested enum/helper move to
  real homes). (D1)
- **One palette.** `SignalQuality` in SurveyKit defines the 5-tier scale and thresholds;
  both overlays, the legend, the web map, and the server labels agree. Legend shown
  in-context on the survey map. (D2, E9)
- **Standard navigation.** No hidden back button; map sub-states become real navigation
  destinations. Map controls anchor bottom-right like every other map screen; the
  `.padding(.top, 240)` hack dies. (D3)
- **Controls:** all targets ≥ 44 pt; every sheet gets a Done affordance (RepeaterDetailSheet
  included); `sensoryFeedback` on start/stop/pause/upload; one success/error idiom. (D4, D7)
- **Setup split.** Starting a survey asks one question (passive / active+auto tier);
  identity, channel, upload prefs, and attribution live in a separate persistent
  settings screen. Five upload paths collapse to two: automatic session upload +
  Settings-managed batch/manage screen. (D8, D9)
- **Live status** pill shows the active tier ("Auto · Coarse — highway") and the TX budget
  state, making the mesh-protection behavior visible instead of magical.
- **Accessibility & localization:** labels on every control, the hex map exposes a
  summarized accessibility element, all new strings through L10n. (D5, D6)

## 9. Migration & compatibility

- Server data: existing v1 rows already carry backfilled `h3_index`; multi-res reads serve
  old and new data uniformly. No destructive schema change; v2.2 additions are additive.
- Old iOS clients: keep uploading v1 → still ingested; v1 reads fixed for Postgres.
- Local sessions recorded under the axial grid re-bucket to H3 lazily via stored raw GPS.
- Rollout: SurveyKit + engine land behind the existing UI first (same features, new
  plumbing), then the UI restructure, then server v2.2 deploy, then the client flips
  uploads to v2.2.

## 10. Verification

- SurveyKit: unit tests for grid round-trips (H3 index ↔ boundary ↔ parent), policy
  simulations (highway drive produces ≤ 6 TX/min; walking unaffected), DTO golden files.
- Server: `swift test` suite per §7.8 against SQLite where possible, plus a compose-based
  Postgres smoke script.
- App: `xcodegen && xcodebuild build` + existing MC1Tests; manual drive-sim via the debug
  overlay's location spoofing.
