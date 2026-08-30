# Active Survey / Ride Mode — M3.5 design (post-review)

Drafted and adversarially reviewed 2026-08-29 (three independent reviews: privacy,
code-vs-design correctness, field practicality). This is the **revised** design; §6
records what the reviews changed and why, so the reasoning survives. Extends
docs/SIGNAL_MAPPER_V2.md; everything here is local — no upload, no wire DTOs, no server.

## 0. Requirements (Rafael, 2026-08-29)

1. Active survey mode: non-flood probes to nearby repeaters recording the signal at
   which **they** received **us** (uplink), alongside the passive RX picture.
2. Two maps: passive (RX — what we hear) and active (uplink — what hears us).
3. Maximal local raw capture — every probe/packet kept with full detail for later
   filtering/parsing.
4. Ride-ready: e-bike speed, radio on helmet over BLE, glanceable, screen awake,
   zero-touch once rolling.
5. Lock-on: pick specific repeaters, see their live two-leg data and range while
   everything else logs in the background.
6. Local-first; must not compromise the M2 opt-in anonymous upload design.

## 1. Verified ground truth (explorer reports, 2026-08-29)

- Trace replies carry per-hop uplink SNR (`TraceInfo.path[i].snr` = what hop *i*
  measured receiving our packet; the hash-less final node = our own downlink reading
  of the reply). `DiscoverResponse.snrIn` is uplink; `.snr`/`.rssi` are downlink.
  ACKs carry no radio measurement. `.traceData` alone is sufficient for both legs;
  `.rxLogData` adds RSSI + packet metadata and is the *fragile* leg (RX-log push).
- `txSnrSum/txSnrCount` (cell) and `MapperRepeaterStats.txSnr*` (per repeater)
  already persist; the coverage builder discards them. `probesSent` persists but is
  never incremented. `activePacketCount`/`passivePacketCount` persist, discarded.
- The probe engine subscribes to `.rxLogData` + `.discoverResponse` only, probes one
  (freshest) target per cycle, and its `pathNodes.last` uplink read is only correct
  at `pathHashMode == 0`.
- Location is one-shot everywhere; `idleTimerDisabled` unused; sessions are
  in-memory and die on BLE rewire (`wireSignalMapper` kills them); the HUD poll loop
  exits permanently when the engine nils.
- `SignalBarsEngine` probes independently (best repeater every ~11 s while moving)
  and is the app's dominant self-generated airtime during a ride.
- Device model: `frequency`, `bandwidth`, `spreadingFactor`, `codingRate`, `txPower`.
- 11 `.lproj` directories (en + 10 translations).

## 2. Architecture (revised)

### 2.1 Location — live stream, one router

- `LocationService` gains session-scoped continuous updates:
  `startContinuousUpdates()` / `stopContinuousUpdates()`;
  `kCLLocationAccuracyBest`, `distanceFilter = kCLDistanceFilterNone` (a stopped
  rider must keep receiving fixes or the age gate starves — no cache fallback
  complexity). `desiredAccuracy` is saved/restored. While live, one-shot
  `requestCurrentLocation()` is served from the stream, never re-issued.
- `MapperFixRouter` (actor, **AppState-lifetime**, constructed once): conforms to
  `MapperFixProviding`; serves the live stream while a run is active, else delegates
  to `MapperFixCache`. Injected at **both** engine construction sites (ambient
  `wireSignalMapper` *and* session-scoped `startSignalMapperSurvey` — the
  capture-off path is the default). Live fixes: `movedSinceCapture false`, real
  speed + `courseDegrees` (new additive `MapperFix` field).
- Continuous location and the idle timer key off the **run**, not the BLE
  connection or any view (§2.6, §2.8).
- Precise Location pre-flight: at ride start, check `accuracyAuthorization`; if
  `.reducedAccuracy`, show a blocking banner and offer
  `requestTemporaryFullAccuracyAuthorization` (new
  `NSLocationTemporaryUsageDescriptionDictionary` purpose key `RideSurvey` in
  project.yml). Without precise fixes the 50 m accuracy gate rejects everything —
  the most likely silent-total-failure mode.

### 2.2 Probe engine (`SignalMapperProbeEngine`)

1. **Trace staging inside the tracker.** Subscribe to `.traceData` (tag-correlated,
   `RepeaterBenchmarkEngine` precedent). Probe lifecycle:
   `outstanding → partial → resolved | lost`, settled in exactly one place;
   staging deadline strictly shorter than the probe deadline; flush runs before the
   expiry sweep; `stopSession` settles partials. `.traceData` alone folds a result
   (txSnr = target hop, rxSnr = final hop, rssi nil); `.rxLogData` enriches with
   RSSI. The `pathNodes.last` fallback is used only at `pathHashMode == 0`
   (multi-byte-mode fixture added *first* to demonstrate the bug). Discover-tag
   `probeCells` entries get TTL cleanup.
2. **Focus scheduling — separate budget, zero policy contamination.** Focus traces
   run from their **own `TokenBucket`** (capacity `maxFocus × cost × 2`, refill
   `maxFocus × cost / focusProbeIntervalSeconds`, cost = 1: a lone trace is half
   the discover+trace pair `probeCost` describes). They never call into
   `SamplingPolicy` — no shared bucket, no `lastProbeAt`/`lastProbeTierCell`
   writes (a focus probe that touched policy state would reset the novelty
   cadence forever and kill the map fill; review C1). `spotCheck` alone spends the
   novelty bucket's manual reserve. Adaptive ladder per target keyed on
   `lossStreak`: base 20 s → **8 s** while streak 1–4 (57 m resolution exactly at
   the coverage edge) → 60 s heartbeat at streak ≥ 5 (link gone; stop burning
   airtime) → reset on any reply. Cap 3 targets (= 3 forced replies/min/repeater
   at base — inside the app's own signal-bars discipline).
3. **Round-robin novelty target.** Stalest-first over non-focus targets via a
   `lastProbeAt` side dictionary (never stored on `MapperProbeTarget`, which
   discover responses replace wholesale).
4. **Send-time placement.** At transmission the engine asks the sink to place the
   attempt (`ingestProbeAttempt(...) async -> MapperProbePlacement?` — cell + fix
   snapshot, having passed the full aggregate gate); the placement is stored per
   tag and the reply/loss folds against **it**, never against the fix current at
   reply time (at 7 m/s a reply lands ~2 boundary-straddling seconds downrange;
   review M4). Cell `probesSent` counts *transmissions* (traces and discovers);
   session counters keep cycles and per-kind tallies.
5. **RTT.** Client-measured trace RTT → **new** cell columns
   `probeRttMsSum`/`probeRttSampleCount` (the existing `rttMs*` pair means
   end-to-end DM ACKs; mixing them would average incomparable quantities).
6. **Focus state + stream.** `setFocusTargets([NodeHexID])` (≤3);
   `FocusTargetState`: id, name?, publicKey?, lastRxSnr/lastTxSnr/lastRssi/
   lastRttMs, lastHeardAt, lastProbeAt, probesSent, repliesHeard, lossStreak,
   maxReplyDistanceMeters. Passive sightings update it via
   `SignalBarsObservation.passiveSighting(from:)` (last path hop at hash width —
   `senderPubkeyPrefix` is DM-only and wrong for this). `snapshots()`
   AsyncStream yields on the 2 s loop tick (budget/tier are time-varying) and on
   fold events; the engine finishes the stream on stop.
7. **Airtime honesty.** A ride session pauses `SignalBarsEngine`'s active probing
   loops for its duration (the passive table keeps ingesting; targets keep
   flowing) — the mapper must not stack its traces on top of an independent
   11 s prober and call its own bucket a budget. Combined TX/min shows in the HUD.

### 2.3 SurveyKit

- `SamplingPolicy`: novelty becomes per-cell **counts** (`samplesPerCell` config,
  default 1 → existing tests unchanged); new saturating `markCovered(_:)` sets a
  cell to fully-sampled at every tier resolution — used by the warm pass, which
  under counts would otherwise mark 1-of-N and re-probe covered ground.
  `stationaryRetryInterval` becomes reachable config (`policyConfig` sets 15 s —
  at 34 s/cell ride dwell, 60 s made N>1 unreachable). Cross-tier count
  propagation (5 fine samples exhaust the medium parent) is the intended
  semantics and gets a pinning test.
- Reach-layer dead predicate lives on the coverage cell
  (`probesSent > 0 && txSnrCount == 0`), NOT by redefining
  `AggregatedCell.isDeadZone` (whose `packetCount` includes passive RX and would
  be false everywhere).
- Ride sessions pin `tierOverride = .fine` (engine passthrough): at 15–30 km/h
  auto-tier flaps across the 4.5/3.6 m/s hysteresis and sampling density becomes
  a function of traffic lights, not the mesh.

### 2.4 Raw log — own module, own store, own container

**Structure (the load-bearing part).** New SPM target **`MapperRawLog`** in the
MC1Services package, depending **on** MC1Services. MC1Services can never import it
(cycle), so no upload service in MC1Services can ever reference a raw row — the
guard is a dependency edge, not a convention. Engines emit through a
`MapperRawSampleRecording` protocol *defined in MC1Services*; the recorder
implementation lives in MapperRawLog; the app wires them.

**Storage.** Own `ModelContainer` at `Application Support/MapperRawLog/`,
`isExcludedFromBackup = true` on the directory (OfflineMapService precedent),
`FileProtectionType.complete` where SwiftData permits. Separate `@ModelActor`
store — zero contention with the chat store, and no cross-table JOIN surface.
Entities registered in **its own** schema only (never `PersistenceStore.schema`).
No version-number claims — the main store has no `VersionedSchema` mechanism;
the only main-store change is two additive `probeRtt*` columns (lightweight-safe).

**Entities.**
- `MapperSurveyRun`: id UUID, startedAt, endedAt?, radioID?, radio-config
  snapshot (`frequency`, `bandwidth`, `spreadingFactor`, `codingRate`,
  `txPower`), cumulative counters, focusTargetHexIDs JSON, sampleCount.
- `MapperRawSample` (`#Index` on runID+timestamp): runID, **seq** (run-local
  monotonic — the correlation key; there is deliberately **no `packetHash`**
  column, see §6/F1), timestamp, kindRaw
  (`probeAttempt | probeTraceReply | probeDiscoverResponse | probeLost |
  probeAbandoned | passiveRx | txHeard | ackResolved | breadcrumb |
  radioLinkDown | radioLinkUp`), rxSnr?, txSnr?, rssi?, hopCount?, rttMs?,
  routeTypeRaw?, payloadTypeRaw?, perHopSnrsData?, repeaterHexID?,
  repeaterPublicKey? (full key when known), wasFocused, latitude?, longitude?,
  horizontalAccuracyMeters?, speedMetersPerSecond?, courseDegrees?,
  fixAgeSeconds?, cellRaw?, gateOutcomeRaw
  (`accepted | noFix | staleFix | inaccurateFix | movedSinceCapture` — **no
  anchor case exists in the enum**, see §3).
  No `repeaterName` column (names resolve at export; they're personal data on
  every row otherwise).
- `breadcrumb` rows every 2 s from the live fix, independent of radio traffic —
  a BLE gap must be distinguishable from a dead zone, and they draw the ride
  polyline. `probeAbandoned` marks BLE-teardown write-offs so they can never
  masquerade as real losses (`probeLost` = genuine timeout, carries the target).
- Recorder batches ~100 rows / 5 s; cap `rawSampleCapPerSession` 50 000;
  retention `rawRetentionDays` default **30** (in `tuningKeys` so
  `resetToDefaults()` restores the safe value), purge at launch; launch
  reconciliation stamps `endedAt` on orphaned runs from their last sample.

**Gate split (correctness + privacy in one move).** The capture engine feeds the
recorder *before* anchor policy runs: raw rows carry only data-quality outcomes,
aggregate folding applies anchor discs afterward, unchanged. This is required
anyway — the stated use case starts at the user's front door, inside the disc.

### 2.5 Two map layers

- Builder stops discarding: `activePacketCount`, `passivePacketCount`,
  `probesSent`, `averageTxSnr`, `bestTxSnr/worstTxSnr`, `averageProbeRttMs`, and
  per-repeater `averageTxSnr` + rx/tx split reach `SignalMapperCoverageCell` /
  `SignalMapperCoverageRepeater`.
- Layer choice `heard | reach` via a `Picker` inside the map-controls `Menu`
  (44×44 column idiom; a segmented control in chrome fits neither the column
  nor the iOS 26 rules). **Overlay ids stay identical across layers** — only
  `features`/`paint` change, so `MC1MapView`'s diff takes the in-place path
  instead of destroying every `MLNShapeSource` per toggle (review M13).
  - *Heard*: today's rendering (quality = `SignalQuality(avgSnr)`).
  - *Reach*: quality = `SignalQuality(avgTxSnr)` where `txSnrCount > 0`; cells
    `probesSent > 0 && txSnrCount == 0` render as a distinct "no reach" fill;
    others absent.
- Selection re-resolves against the active layer's cell list; detail sheet gains
  an Uplink section (probes sent, active packets, avg/best uplink SNR, probe
  RTT, per-repeater uplink averages). Legend becomes layer-aware.

### 2.6 Run lifecycle — AppState-owned, engine instances are cattle

New `@MainActor @Observable` session object on AppState holding runID, focus
set, cumulative counters, engine generation, and the HUD-facing state. Engines
come and go with BLE rewires; the run persists:

- `startSignalMapperSurvey()` splits: `promptAndStartSurvey()` (user-initiated;
  the only place permission requests live) vs `resumeSurveyAfterRewire()`
  (silent; chained on `signalMapperStartTask` like the ambient path, so a
  restart can't race a stopping engine; reads `pathHashMode` after the device
  row settles). `wireSignalMapper`/`tearDownSignalMapper` accumulate counters
  onto the run row and trigger resume instead of silently killing the session.
- HUD subscribes per engine generation and shows "radio disconnected" (with
  `radioLinkDown/Up` raw markers) rather than vanishing; the poll loop never
  exits on nil engine.
- **Auto-end** (a forgotten stop must not become an ambient home log):
  cumulative background > 10 min, or no accepted movement > 15 min, or hard cap
  6 h → stamp `endedAt`. A persistent recording indicator lives outside the
  coverage view while a run is open.
- Screen awake: AppState-owned `idleTimerDisabled`, predicate
  *run active ∧ scenePhase == .active* (`.inactive` keeps it on; view
  visibility is deliberately not a term — the session outlives the view).

### 2.7 Ride HUD + lock-on

- Bottom-aligned opaque HUD (glanceable in sun; glass is decorative at 25 km/h):
  per focus target one **large 4-state block** — green (replied ≤1 interval,
  both legs) / amber (downlink only: heard passively, no reply) / cyan (uplink
  only: txHeard echo seen, no reply — the helmet-radio asymmetry made visible) /
  red (lossStreak ≥ 3) — with name, ▲txSnr ▼rxSnr, age, distance
  (contact-advertised position vs live fix), max-range-achieved. Tap expands
  session detail (probes/replies/lost, cells, raw rows, buckets, drop counters —
  `droppedInaccurateFix` visible so a Precise-Location failure is loud). Big
  spot-check button. Driven by the snapshots stream; the coverage reload drops
  to 60 s during a ride and overlays memoize on snapshot identity (thermal).
- Audio + haptics: a second `RepeaterWatchTonePlayer` instance (helmet-earbud
  spec already written for it), edge-triggered only — tock on target lost, note
  on regained, `.sensoryFeedback` mirror. `RepeaterWatchView` untouched.
- Follow-me camera while run active and centered (1 Hz `cameraBounds` bump);
  breadcrumb polyline via the existing `lines:` parameter; map-tap cell
  selection disabled and Delete-all hidden while a run is active.
- Lock-on picker sheet (repeater contacts + probe-target table, ≤3) opened from
  the options menu strictly via the `.task(id:)` 600 ms settle-delay pattern;
  the toolbar item is always present with content varying by value (iOS 26
  zoom-morph rules).
- HUD-only mode (map hidden, dark layout) as a toggle — halves the wattage and
  doubles legibility; stretch goal tonight.

### 2.8 Export — two tiers, encoder in the app target

- Encoder lives in the **app target** (MC1Services holds no code that can
  serialize a raw row; MapperRawLog exposes paginated reads).
- **Share sheet default = scrubbed**: coordinates rounded to 3 decimals,
  start/end trim (drop everything within 500 m of first/last fix — the two
  endpoints are the front door), repeater keys truncated to hash width, no
  names, minute-precision timestamps, no radio config, no gate outcomes.
- **Full raw** export only from the debug panel, confirmation enumerating the
  contents, filename `ride-…-RAW-PRIVATE.json`. Both write to a
  backup-excluded temp dir, deleted after the share sheet closes. Reads are
  paginated (`fetchLimit`/`fetchOffset`) streaming to the file — a 50 k-row
  fetch must not block an actor for seconds.

### 2.9 Tuning (defaults revised by review; each = six edits + debug row)

| Key | Old | New | Why |
|---|---|---|---|
| `probeIntervalSeconds` | 10 | 4 | novelty refill 0.2→0.5 tok/s; ride demand fits with headroom |
| `probeBurst` | 3 | 4 | absorb edge bursts |
| `communityFreshnessDays` | 7 | 0 | warm pass blanks the near field (one res-9 row marks 920 m/2.4 km parents sampled) |
| `fixMaxAgeSeconds` | 120 | 30 | live fixes are ~1 s old; 120 only masks a stalled stream |
| `fixMaxAccuracyMeters` | 100 | 50 | with Precise Location verified |
| `fixMaxDisplacementMeters` | 150 | 60 | ⅓ of a res-9 cell at speed |
| `samplesPerCellPerSession` | 5 (dead) | 3 (live) | implemented via policy counts |
| `focusProbeIntervalSeconds` | — | 20 | 3/min/repeater at base; ladder handles the edge |
| `rawSampleCapPerSession` | — | 50 000 | ~3–8 k rows/hr real |
| `rawRetentionDays` | — | 30 | keep-forever is an explicit user choice, not a default |

## 3. Privacy stance (revised — each divergence decided separately)

Aggregate pipeline: **unchanged in every respect** (discs, gate, hash-width IDs,
non-Codable DTOs, M2 reads only this store).

The raw log's divergences, each with its own defence:
1. **Raw GPS persisted** — deliberate session-scoped recording of the user's own
   ride; value *is* the precision. Defence: own backup-excluded container (a
   movement diary must not ride iCloud Backup), auto-ending runs, 30-day default
   retention, per-run + delete-all, scrubbed-by-default export.
2. **No anchor discs on raw rows** — the ride starts inside the disc and the
   question is "how far from home". Defence: the recorder is fed *before* disc
   policy and its outcome enum **cannot express** disc membership (a labelled
   in/out bit per visited cell is a solvable 3-parameter oracle for the disc
   geometry, which must never be recoverable); aggregates keep purging.
3. **Full repeater pubkeys on raw rows** — hash-width IDs would collide half the
   analysis away. Defence: module dependency edge (nothing in MC1Services can
   read them), scrubbed export truncates to hash width.
4. **No packetHash, ever** — SHA-256(payload) is identical on every node that
   heard the packet: a cross-mesh join key that would let any exported ride be
   de-anonymized against third-party RX logs (and locally joins to
   `RxLogEntry`). Run-local `seq` replaces it.
5. **Logs**: no coordinate, key, or name reaches `PersistentLogger`/OSLog from
   any new path (V2 §3 rule 3).

Tests that must exist (written with the feature, not deferred to M2):
source-reference allow-list (any new MC1Services file mentioning
`MapperRawSample` outside the named emitters fails), coordinate-column
assertions in both directions (raw sample *has* them, cell observation still
does not), export key-set freeze for the scrubbed tier, no-anchor-case-in-enum.

## 4. Testing bar

Engine: staging both arrival orders + traceData-only fold + flush-before-sweep +
partial settle on stop; focus bucket isolation (novelty cadence untouched by
focus probes — the C1 regression test); ladder transitions; round-robin;
send-time placement (attempt and reply same cell across a boundary straddle);
multi-hash-mode txSnr fixture; probeAbandoned vs probeLost. Policy: counts,
markCovered saturation, cross-tier pinning. Recorder/store: batching, cap,
retention purge, orphan reconciliation, run accumulation across rewires.
Builder: new fields, reach classification. Privacy: the four tests in §3.
Existing 149 mapper/SurveyKit tests stay green.

## 5. Out of scope

Background/locked-screen capture; any upload; multi-hop probe paths; session
history browsing UI (runs persist; export covers analysis); per-repeater
dead-zone map rendering (raw log answers it; map follow-up); the
`recordSample` ancestor-amplification bug beyond `markCovered` (follow-up);
signal-bars/mapper unified duty-cycle budget (paused during rides for now).

## 6. Adversarial review log (2026-08-29) — what changed and why

Three reviews (privacy / correctness / field practicality). Full reports in the
session; findings that reshaped the design:

| # | Finding | Consequence |
|---|---|---|
| F1 | `packetHash` = global cross-mesh join key | column removed; run-local seq |
| F4 | `anchorExcluded` labels = exact disc-geometry oracle; also dropped near-home probes (the use case) | gate split; no anchor case in raw enum |
| F3 | raw log would land in iCloud Backup beside chat store | own container, backup-excluded; retention 30 d |
| F2 | "private encoder" voided non-Codable guard | MapperRawLog module (dependency edge); encoder in app target |
| F5 | share sheet would publish home + keys + names | scrubbed default with start/end trim; raw behind debug |
| F6 | run "ends only at explicit stop" = ambient home log after one forgotten tap | auto-end triple + recording indicator |
| C1 | focus probes through `SamplingPolicy` reset `lastProbeAt` → novelty dead **regardless of budget** | focus never touches policy state |
| C2 | budget: 3×15 s×cost 2 = 200 % of refill; reserve drained; spotCheck dead | separate focus bucket, cost 1, interval 20 s, floor kept for spotCheck |
| C3 | SignalBars probes every 11 s concurrently — unbudgeted airtime, likely ETSI breach | pause signal-bars active loops during rides |
| C4 | auto-restart unreachable (teardown order), re-prompts permissions at speed, HUD stream dies with engine | AppState-owned run; prompt/resume split; generation re-subscribe |
| M1/M2 | router "wired once" was false (two construction sites; capture-off is default); distanceFilter 5 starves at rest | AppState-lifetime router at both sites; `kCLDistanceFilterNone` |
| M3 | per-cell counts break warm pass (1-of-N ≠ covered) | `markCovered` saturating API |
| M4 | attempt/reply placed 2 s apart straddle cells → false dead zones + orphan replies | send-time placement carried through the tracker |
| M5 | `isDeadZone` uses `packetCount` (incl. passive) → false everywhere | reach predicate on coverage cell; SurveyKit API untouched |
| M6 | trace RTT folded into ACK RTT column | separate `probeRtt*` columns |
| M7 | `senderPubkeyPrefix` is DM-only | `passiveSighting` last-hop matching |
| M9/M10 | staging premise (rxLog "only source of our SNR") false; sweep/flush double-count | traceData-sufficient folds; single settle path |
| M11 | "schema v11" mechanism doesn't exist | registration + additive columns, no version claims |
| M12 | shared-actor export stall; no orphan-run closing | own store actor; paginated export; launch reconciliation |
| M13 | layer-namespaced overlay ids destroy every MLNShapeSource per toggle | stable ids, vary features/paint |
| M16 | `.inactive` + view-visibility idle-timer predicate darkens mid-ride | AppState-owned, run ∧ scenePhase==.active |
| 1a/1b | budget starvation + warm-pass blanking → empty Reach map tonight | defaults table §2.9 |
| 2a/2b | BLE write-offs as phantom dead zones; positions at receive time | `probeAbandoned` kind; send-time fix |
| 2e | flat 15 s = 105 m edge resolution | loss-streak ladder 20/8/60 s |
| 3c | BLE gap indistinguishable from dead zone | breadcrumbs + radioLink markers |
| 4a/4b | 20-number glass HUD unreadable; no audio | 4-state blocks; tone player reuse |
| 7a | map never follows the rider | follow-me camera |
| 7b | Precise Location off = silent total loss, unrequestable | pre-flight + temp-full-accuracy + visible drop counters |

Pre-ride checklist (do at home): run one start/stop cycle to grant Location
(While Using, **Precise**) + Motion & Fitness; set your repeaters' positions in
contacts (the HUD distance field reads them); charge + power bank; phone out of
direct sun.

## 7. UI revision after the first field test (2026-08-30)

Rafael's first real ride failed on UX: the ride HUD rendered mid-screen, showed zero
live numbers without lock-on, and the radio pill went dead. A second adversarial pass
(UI/UX/HIG review + a pattern-mining pass over the v1 `personal`-branch Signal Survey
screen) reshaped the surface; the engines were untouched except one fix.

| Was | Now |
|---|---|
| HUD card stacked above a 211 pt control column → landed at 52–65 % screen height | Top **live strip** (`safeAreaInset`): pulsing dot, elapsed, probes·replies·lost, hexagons, a "No fix" chip when fixes are being rejected, 44 pt stop. Bottom inset holds only the focus blocks (or a quiet dashed lock-on hint). Map controls: 2 buttons, top-trailing (the v1 anatomy). |
| Counts hidden behind an invisible tap-to-expand | Strip is always visible; tap opens a real **run-detail sheet** (full counters, farthest reply per target, raw-sample count, Spot Check / Edit lock-on / End). |
| Radio pill rendered empty zero-bars "scanning" + an inert popover while the ride paused signal bars | Honest paused state: pause glyph on the label, "paused while a signal survey runs" row in the popover, and the Motion & Fitness prompt never arms mid-ride. |
| Start/Stop buried in the ⋯ menu once any coverage existed | Idle: labelled **Start Survey** button in a bottom control row (disabled label self-explains: "Connect to Start"). Start flows *into* the lock-on picker ("Start Without Lock-On" available). Stop lives on the strip. |
| White-on-green/orange focus blocks (≈2:1 contrast), fixed 34 pt type | Near-opaque system-background blocks, 6 pt state bar + soft tint carry the color, `.primary` numerals in a scaling text style. |
| Camera fought the rider: programmatic moves landed mid-pan; store reloads re-framed mid-ride | `MC1MapView` skips camera applies during gestures; both auto-frame triggers are dead while surveying; follow-me bumps only on actual movement. |
| Per-render `UserDefaults` (22 keys/call at 1 Hz) + inline overlay rebuilds every 2 s | Focus interval captured once on the session; overlays memoized behind `onChange`. Tab bar hidden during runs. |
| Debug panel led with an "Upload batching (M2)" section for a nonexistent feature | Section deleted. (Screen-awake/retention remain debug-only for now — a user-facing options sheet is still owed.) |

Data-integrity addition from the same review: adaptive TX power re-steps mid-ride, so
breadcrumb raw samples now stamp `txPowerDbm` (additive column) — uplink SNRs without a
power context are not comparable across a ride. Engine fix: `stopSession()` now bakes
the read-time-computed counters (`cellsProbed`, `targetCount`, focus states) into its
final snapshot; the completion sheet previously showed zero hexagons.

Deferred, recorded honestly: the cyan "uplink-only" focus state (needs a txHeard →
focus-state path the engine does not have), the HUD-only battery mode, the app-wide
mini-indicator on other tabs (v1 had one), per-repeater dead-zone map rendering, and a
user-facing Survey Options sheet.

Verified end-to-end in the simulator against the mock radio: onboarding → start-into-
lock-on → live strip counting → "No fix" chip firing when the static sim location went
stale → run-detail sheet → End Survey → completion sheet with scrubbed export.

### 7.1 Third field pass (2026-08-30, later): the v1 cell card and best-link colour

Rafael put the v1 Signal Survey screenshot next to v2 and the remaining gap was the
**cell card**: v1 told a cell's whole story in place (quality verdict, RX *and* TX with
bars and ranges, live last-heard, probe success ratio, per-repeater chips split
two-way vs heard-only) where v2 had a modal sheet and disabled taps mid-ride.

- `SignalMapperCellCard` restores that anatomy inline at the bottom of the map, live
  during rides (the pocket-touch tap guard is gone — v1's rule wins: data is one tap
  away, and a stray touch costs one ✕). Probe success (`replies/probes sent`) is now a
  first-class per-cell stat, possible only because M3.5 plumbed `probesSent`. The full
  sheet remains behind the card's "Cell Detail" link. The selected card re-resolves on
  every snapshot reload so its numbers tick instead of freezing at tap time.
- **Cell colour follows the best usable link, not the pooled average** (his call, and
  right: "can I get out of this cell" is a property of the best link — the average
  punishes a cell for every faint distant repeater it overhears). Heard layer colours
  by `maxSnr`; Reach by a new additive `maxTxSnr` column (aggregate → model → DTO →
  merge/relabel). The DTO's own average-based `quality` is untouched for any future
  wire use. His home cell: v1 showed "Good 5.7" *on the average too* — but v1's 3-tier
  palette painted good green, which is why v2's teal read as a regression. Best-link
  colouring makes a +12 dB home cell excellent/green under the 6-tier scale.
- The lone-repeater caveat he raised (one isolated repeater propping up a green cell)
  is answered the v1 way: the card's chips show exactly which repeaters back the
  number, two-way links first. A true mesh-reach qualifier stays an M2 concern.
- `safeAreaInset` gotcha for the record: its ViewBuilder Z-stacks loose siblings —
  the idle Start row rendered on top of the card until wrapped in an explicit VStack.

## §7.2 Fourth UI pass — the v1 card, properly (2026-08-30, field report 4)

Rafael, on the third build, with the v1 screen open beside it:

> "you have to check the code that was used before to build the old signal mapping
> interface, there are so many things you are missing from this. like being able to click
> on the different repeater 'buttons' to see the details for each one on the current cell.
> also why do I see 52/13 replies at 400% … also why do we still have that huge card at
> the bottom with the triangle and all the wasted space … we need to have a proper ui
> where we can see all the data at once."

This pass was written with `git show personal:MC1/Views/Tools/SignalSurvey/SignalSurveyView.swift`
open — `cellDetailCard`, `signalColumn`, `relayNodeSection`, `bottomOverlay` — rather than
from a description of it.

### The 400% was two different units

`activePacketCount` counts reply *packets*; `probesSent` counts *transmissions*. One
zero-hop discover is answered by every repeater in range, so 13 probes drawing 52 replies
is the system working. v1 hid this with `min(activePacketCount, probes)` — a clamp, not an
answer.

New counter, all the way through SurveyKit → store → coverage cell:
`AggregatedCell.probesAnswered` — transmissions that drew **at least one** reply. The
capture engine keys it on the send-time placement instant, and the ledger
(`answeredProbeSends`) lives on the **engine**, not the pending cell: replies to one probe
either side of a 30 s store flush would otherwise book that probe twice, and the display
clamp would round the lie up to a tidy 100%. Two regression tests pin both halves.

The card now reads `"85% (11/13) · 52 replies"` — the ratio and the packet count on one
line, so they can never look like a contradiction again.

### One statistic per number

The third pass shipped a defect in the same family as the 400%: the quality *word* was
graded on the cell's best reading while the *number* beside it printed the mean, so an
11 dB best with a 4.2 dB mean read "Excellent 4.2". Every leg now grades and prints the
same value — the best — with `avg 4.2` and the `1–11` spread on the context lines beneath.
A filtered leg never falls back to the cell's numbers (v1's rule: mixing one repeater's
label with every repeater's data is worse than showing nothing).

### Repeater chips are buttons

The piece three passes were missing. Tapping a chip sets `repeaterFilter` and the whole
card recomputes from that repeater's observations — v1's `selectedRelayFilter` /
`filteredCellStats`, with a "via <name>" bar carrying **Lock On** and **Clear**. Backed by
new per-repeater columns: `minRxSnr`/`maxRxSnr`/`minTxSnr`/`maxTxSnr` (the range v1 showed)
and `averageRssi`. Groups are v1's: Connected (2-way) then Heard (1-way), locked-on first,
strongest link first inside each — not chattiest.

Lock-on is a **visible** button in the filter bar, not a context menu: a 0.5 s stationary
press inside a horizontal scroll view is not an input a rider has at 25 km/h.

### The card follows the rider

`liveCell` tracks the H3 cell under the current fix, and its card is on screen during a run
without anyone tapping anything. Crossing a boundary clears a dismissal and re-identifies
the card (`.id(displayed.cell)`) so digits do not roll from the old cell's values into the
new one's. `cameraEdgePadding.bottom` is the **measured** inset height, so the rider's dot
is never centred behind the card.

Store cadence had to follow: the capture engine flushes every 30 s, so the ride's rebuild
went 60 s → 20 s. Even so the card is up to ~50 s behind, which is why the live rows above
it survive (below).

### The tall tiles are one line each

Three ~100 pt tiles containing a lone "▲–" became one row per repeater: state dot, name,
▲ uplink, ▼ downlink, age, distance. Unlocked, the rows show `heardStates` — whoever
answered most recently, straight off the engine's live snapshot. Deleting that in favour of
"Listening…" would have re-created the original complaint through a different door: a
hexagon just entered has no flushed rows, so the card cannot render and the live rows are
the only thing on screen saying the ride works. A target with no reading yet says "No reply
yet" instead of "▲– ▼–".

### Also, from the adversarial review

Dead-zone header restored (slashed antenna, "No Response", "Probe sent, no response") and
the headline now grades whichever leg the **map layer** is painting, so card and hexagon
never disagree. Card content scrolls above 320 pt rather than growing off-screen at
accessibility sizes. 44 pt targets on close / clear / details / lock-on. Route mix
(direct · flood) and per-repeater RSSI added. Radio-loss now has its own tone. Chips carry
the ambiguity marker, go monospaced when the hash is unresolved, and expose selection to
VoiceOver. `-0 dB` is gone. The detail sheet re-resolves against each rebuild instead of
freezing at open. The lock-on picker's search seed is cleared everywhere it is opened.

### Verification note

The simulator MCP panel crashed and would not re-attach this round, and synthetic clicks
were not accepted by Simulator.app, so this pass is verified by build (device + simulator),
157 passing tests, and a full adversarial review against the v1 source — **not** by driving
the ride screen in-simulator as the previous three passes were. The vertical budget is
arithmetic, not a measurement: at default type on a 852 pt screen the inset is ~86 pt of
live rows plus ≤328 pt of card, leaving ~240 pt of map with the camera padded to keep the
rider inside it.

## §7.3 Fifth pass — four field bugs from the ride screen (2026-08-30)

Reported against the §7.2 build, with screenshots.

### "Last Heard 5m ago" while the radio pill said 38 s

The periodic store rebuild lived inside `attachSurveyStream`, so it only existed **during
a survey**. Passive capture folds packets whenever the app is open, the store flushes
every 30 s, and an idle Signal Mapper screen loaded its snapshot exactly once — so a card
left open drifted arbitrarily far behind the repeater list in the toolbar pill, which is
driven live by `SignalBarsEngine`.

The refresh is now `SignalMapperCoverageModel.autoRefresh(appState:)`, owned by the
view's own `.task`, running for as long as the screen is up: 20 s riding, 45 s idle.

(The other half of the discrepancy is legitimate and stays: the pill ages every repeater
the radio has heard *anywhere*, while the card ages one *hexagon*. A cell you are not
standing in can honestly be minutes stale.)

### The same repeater name three times in one cell

Not a duplicate-key bug: `cell.repeaters` is keyed by path hash, and several distinct
hashes in a cell can resolve to the same node name — which renders as "Digitaino Chestnut
▼13 / ▼13 / ▼12" and reads like the list is broken. A name that cannot tell two rows
apart now carries the hash that can: `collidingNames` finds display names claimed by more
than one repeater in the cell, and those chips render as `Name 805D`. The ambiguity marker
stays for the separate case of one hash that several known nodes answer to.

### Redundant blocks, and recency ordering

The "HEARING NOW" rows and the card's repeater chips were listing the same repeaters,
one above the other. The strip now renders **only when it has something the card does
not**: locked on (live probe state, distance, unlock), or no card at all (a hexagon just
entered, nothing flushed). Chips are ordered **most recently heard first** — Rafael's
call, and the correct one: the left end of a horizontal row is where the eye lands, so it
holds what is happening now, not a season's champion.

### No way to unlock

Lock-on was reachable from three places and reversible only inside the picker. Each
locked-on row now carries its own ✕ (`onUnlock`), which drops that one target through
`setSurveyFocusTargets`.

### Card top scrolled away

The card's `ScrollView` had no anchor, and inside a bottom safe-area inset it settled on
the bottom edge — so the quality headline and packet count, the first things to read, were
the first things hidden. `.defaultScrollAnchor(.top)` pins them. Chips went from 44 pt to
36 pt (the one control class Apple itself ships short, ~34 pt for filter chips) and the
ceiling rose to 340 pt, so at default Dynamic Type the card no longer scrolls at all.

### §7.3b Second adversarial review of the same screen

Run after the fixes above, aimed at the "disjointed / on top of each other" complaint.
What it found, and what changed:

**The card was always exactly 340 pt.** `ScrollView` is greedy along its axis: given a
concrete proposal it returns the proposal, so `.frame(maxHeight:)` on one renders *every*
card at the ceiling — a short card as a slab of dead space, a tall one clipped mid-chip-row
with the next control flush against it. That is the mechanism behind both the cut-off card
top and the Start pill sitting on the chips, and `bottomInsetHeight` was measuring a
constant, so the camera padding was wrong in both directions too. Fixed with the pattern
`HeardRepeatsMapView` already uses: measure the content, take `min(measured, ceiling)`.
Header and footer are now outside the scroller entirely — the headline is the first thing
to read and the footer is the only route to the detail sheet, so neither may be the part
that scrolls away.

**Four surfaces, three materials, three margins, four radii, three animation clocks.**
That is what "disjointed" was, stated as numbers. Now: one container owns the gutter, the
spacing and the clock; every floating surface goes through `mapperHUDSurface` (opaque —
glass over a moving map failed the sunlight test in an earlier round, so coherence was
bought by making the strip and legend opaque, not by making the card glass).

**The legend and the map-controls column shared a band the bottom inset could squeeze to
nothing** — 34 pt of hard overlap while surveying with three lock-on targets, and on a
667 pt phone the band collapsed entirely. The legend moved out of the map ZStack into the
bottom stack, where it participates in the layout that is already being measured. Its
expanded card is now a bounded scroller with a pinned title row; unbounded, it grew off
the top of the screen and took its own close button with it.

**The run-detail sheet presented siblings from inside its own dismissal** — both "Lock On"
and "End Survey", the latter on every single ride. That is the iOS 26 presentation-teardown
family this project defers around everywhere else. Actions are recorded and run from the
presenter's `onDismiss` now.

**The de-clutter fix had silently disabled the radio-drop alarm.** The tone lived inside
the focus strip, which is now conditional; the alarm moved to `SignalMapperLiveStrip`,
which is on screen for the whole run.

Also: 9 pt `.system(size:)` text never scaled with Dynamic Type at all (now `caption2`);
chips keep a 36 pt pill inside a 44 pt target; the 12 pt gutters beside the panel were live
map taps that swapped the card for another hexagon's; camera re-framing is quantized to
8 pt so the inset breathing does not lurch the map at a red light; the camera's top padding
is measured rather than a magic 76; the cell detail sheet has a Done button like its
siblings.

**Known and deferred:** the repeater filter recolours the card but not the hexagon under
it, so "Excellent, via Chestnut" can sit over a yellow cell — the map renderer takes no
filter yet. And the map's OSM/MapTiler attribution button sits behind the tab bar on every
screen that hosts `MC1MapView` with `.ignoresSafeArea()`; that is shared map code and an
attribution obligation, tracked separately.
