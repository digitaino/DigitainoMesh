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
