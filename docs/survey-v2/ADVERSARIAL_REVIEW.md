# Survey Mapping System — Adversarial Review (v1)

Date: 2026-07-18 · Branch: `feature/survey-v2`
Scope: iOS client (MC1 + MC1Services), `pocketmesh-survey-server`, web frontend.

This review is the "why" behind the v2 redesign in [DESIGN.md](DESIGN.md). Findings are
ordered by severity within each area. File references are to the state of the repo at the
time of review.

---

## A. Mesh traffic (the headline problem)

**A1 — Cell exit bypasses every cooldown.** `SignalSurveyViewModel.shouldProbe`
(`SignalSurveyViewModel.swift:2197`) returns `true` immediately when the current ~100 m hex
differs from the last probed hex, *before* the min-interval guard. At 110 km/h you cross a
cell every ~3.3 s, so the app transmits a discover + trace pair every ~3.3 s indefinitely.
The mesh cost of a survey is therefore proportional to driving speed — the opposite of what
a shared network wants.

**A2 — One "probe" is up to three transmissions.** `sendProbe`
(`SignalSurveyViewModel.swift:2257`) always sends a node-discover request *and* a trace,
then conditionally a channel flood message. There is no shared budget across the three; the
only global limiter is an 8 s flood cooldown (`minimumFloodInterval`), which does not apply
to discover/trace.

**A3 — Per-cell flood cap is racy.** The flood gate reads `floodMessagesSentPerCell`
(`:2306`) but does not increment it until `:2338`, after two `0.3 s` sleeps. Probes are
dispatched fire-and-forget from the loop (`:2165`) and manual probes run concurrently, so
several in-flight `sendProbe` calls can all pass the quota check for the same cell. The one
safeguard intended to protect the mesh can be exceeded under exactly the conditions (fast
movement, frequent triggers) where it matters.

**A4 — No speed adaptation anywhere.** `ProbeFrequency` presets are static
distance/interval pairs (`:51-78`). The two presets suited to driving are DEBUG-only, so
release users driving get either `normal` (probe every 50 m!) or `sparse` (100 m) — both
still cell-exit-bypassed per A1. Nothing consults `CLLocation.speed`.

**A5 — Probe engine lives in the UI layer.** The entire TX side (probe loop, budgets,
dead-zone bookkeeping) is inside a 2,551-line `@MainActor` view model holding raw
references to `BinaryProtocolService`, `MessageService`, `ChannelService` and
`LocationService` (`:789-796`). It is untestable without the view stack, dies with the
view's lifecycle, and mixes mesh-protocol policy with SwiftUI state.

## B. Client correctness

**B1 — Actor-reentrancy dedup race.** In `SurveyService.processForSurvey`, the existence
check (`surveyPointExists`, `:359`) and `saveSurveyPoint` (`:411`) are separate awaits with
further suspension points between them (location fetch hops to MainActor). Swift actors are
reentrant across suspensions, so two packets with the same dedup key can interleave and both
save. No DB uniqueness constraint on `(sessionID, packetHash)` backstops it; the dedup
`catch` swallows errors and falls through to save (`:367-369`).

**B2 — Two independently derived reference latitudes.** `gridReferenceLatitude` (set on
first recorded point) and `probeReferenceLatitude` (set when the probe loop starts) are
maintained separately (`SignalSurveyViewModel.swift:499`, `:825`). Near a 10° band boundary
they can disagree, bucketing probes and displayed cells into different grids.

**B3 — Aggregation logic exists twice and diverges.** Display cells come from
`makeGridCell` (`SignalSurveyViewModel.swift:1824`); upload cells from
`SurveyExportService.generateCellData` (`:168`). The two classify the same points
differently (the display path applies canonical-hex resolution; the export path does not),
so what the user sees is not what the community map gets.

**B4 — Inconsistent cell-size constants.** `HexGrid.size = 0.0005°` is "~100 m
flat-to-flat"; flood pacing assumes `cellDiameter = 100.0`; but the file export hard-codes
`cellSizeMeters: 50` (`SurveyExportService.swift:469`). Downstream consumers of exports get
a wrong cell size.

**B5 — `fatalError` on missing config.** `SurveyUploadService.apiKey` (`:44-49`) crashes
the app if the Info.plist key is absent — a hard crash for an optional community feature.

**B6 — Unthrottled live upload.** Every recorded point spawns `Task.detached` → one HTTP
POST (`uploadLivePoint`). Driving at `driving` preset produces a POST per received packet
with no batching, coalescing, or backpressure; only the server's 429 limits it.

**B7 — Weak dedup key.** Composite key is `packetHash + lastHop` (`SurveyService.swift:351`),
collapsing distinct multi-hop paths that share a final hop.

**B8 — Magic numbers duplicated as raw values.** `backfillActiveProbeFlag` hard-codes
`PayloadType` raw values `11`/`9` inside a `#Predicate` (`PersistenceStore+Survey.swift:188`).
Packet parse offsets (6, 9, `0x90`, nibble `2`) are unnamed literals in `SurveyService`.

**B9 — RX hot path serialized behind MainActor.** `RxLogService` awaits
`surveyService.processForSurvey` inline per packet (`RxLogService.swift:425`), and that call
awaits a MainActor hop for GPS per packet — RX throughput is coupled to UI-thread
availability during a survey.

## C. Grid & data model

**C1 — Two spatial indexing schemes maintained in parallel.** The client uploads custom
flat-top axial `(q, r)` + reference latitude; the server *also* computes an H3 res-10 index
per cell (`Migrations/AddH3Index.swift`) for a half-finished "v2 aggregation." Two sources
of truth for "which hexagon is this," guaranteed to disagree at cell boundaries.

**C2 — The grid contract is enforced by copy-paste.** `HexGrid.swift` is duplicated into
the server by hand (per the original Crowdsource plan). Any drift silently misaligns client
and server cells. The web frontend carries a third, hand-ported JS copy of the vertex math.

**C3 — Single fixed resolution.** One hex size for all uses: live display, probe gating,
upload, community aggregation, and web rendering at every zoom level. No coarser tiers for
fast movement (the user-reported problem), no aggregation pyramid for zoomed-out map views
(the server returns up to thousands of 100 m cells for a country-level viewport).

**C4 — Session/stat blobs.** `SurveySession` persists `probesSentData` and
`completionStatsData` as opaque JSON `Data?` blobs — unqueryable, version-fragile.

## D. UX / HIG

**D1 — Three map implementations.** `SurveyMapRepresentable` (survey tool) and
`MKMapViewRepresentable` (Map tab) are near-duplicate MKMapView coordinators — separate
copies of tap ray-casting, overlay diffing, renderers, pins, selection. A third SwiftUI
`Map` screen (`CommunityMapView.swift`, ~440 lines) is dead code kept alive by a nested enum.

**D2 — SNR→color mapping triplicated and contradictory on one screen.** The user's own
hexes use a 3-tier palette (`SurveyHexOverlay.swift:36-46`), community hexes a 5-tier
palette (`CommunityHexOverlay.swift:29-38`), and the shared `SNRQuality+Color` token
(duplicated across two modules) collapses to 3 tiers. The info sheet documents a legend
("orange = Fair") the survey overlay never renders.

**D3 — Non-standard navigation.** Survey map sub-states hide the system back button and
substitute a custom chevron that clears state instead of popping
(`SignalSurveyView.swift:61-76`). Map controls anchor top-right with a hardcoded
`.padding(.top, 240)` while every other map screen anchors bottom-right.

**D4 — Hit targets & dismissal.** 24 pt close buttons (`:376-378`, `:397-399`) vs the 44 pt
HIG minimum; `RepeaterDetailSheet` has no Done/dismiss affordance at a fixed medium detent.

**D5 — Accessibility.** Three buttons on the whole screen have `.accessibilityLabel`; the
hex map (custom ray-cast tap handling) exposes no accessibility elements at all. VoiceOver
users cannot use the survey feature.

**D6 — Localization.** The survey layer is essentially all raw English literals — nav
titles, setup copy, errors, enum raw values — in an app that otherwise uses `L10n`.

**D7 — Inconsistent feedback.** Haptics only on manual probe; four different success/error
idioms across the five upload paths; unsystematic corner radii (10/12/16/20) and mixed
materials for equivalent panels.

**D8 — Five parallel upload paths.** Live per-point, completion sheet, export view, batch
upload view, and Settings each re-implement upload orchestration and contributor
verification (verification code triplicated).

**D9 — Setup sheet overload.** One sheet mixes passive explanation, probing, TX power,
flood quota, channel creation, live upload, contributor identity, verification and debug
toggles — most of which are one-time decisions, not per-survey decisions.

## E. Server

**E1 — The H3 migration stopped halfway.** The server already runs Postgres + PostGIS +
h3-pg with a v2 API (`SurveyV2Controller`) keyed on H3 res-10 indices and a MapLibre +
deck.gl frontend that renders H3 directly — but no shipping client speaks v2. The iOS app
still uploads axial `(q, r)` to v1. Every layer therefore maintains both schemes.

**E2 — v1 reads break on production Postgres.** `getCells` uses `GROUP_CONCAT` and
`hidden = 0` (`SurveyController.swift:510`, `:481`) — SQLite-only SQL. Production is
Postgres, so the endpoint the current iOS community overlay calls 500s there. Dev/test
(SQLite) exercises a different code path than production entirely; v2 returns 501 on SQLite.

**E3 — Admin API has no application-level auth.** The whole `/api/v1/admin/*` tree —
including destructive merge/purge/delete and an endpoint exposing contributor client IPs —
is protected only by Cloudflare Access at the edge; no CF-Access JWT validation exists in
code (`.env` defines `CF_ACCESS_*` vars nothing reads). Two lesser admin endpoints *are*
API-key-guarded, showing the model was never unified. Any request reaching the origin has
unauthenticated admin control; the localhost port binding is the sole backstop.

**E4 — v2 batch re-upload double-counts.** v2 deletes `cell_contributions` audit rows on
re-upload but deliberately does not roll back `cells` aggregates
(`SurveyV2Controller.swift:60-72`) — aggregates drift upward on every re-upload. v1 gets
this right; v2 regressed it.

**E5 — Latent unique-constraint collision.** v2 inserts cells with
`hex_q=0, hex_r=0, reference_latitude=center.lat` while the v1
`UNIQUE(hex_q, hex_r, reference_latitude)` constraint still stands: two H3 cells whose
centers share a latitude collide on insert despite distinct `h3_index`.

**E6 — Aggregate mutation is non-transactional in v1.** Read-modify-write on `cells`
(upload and all delete paths) has no transaction; concurrent uploads can lose updates and
drift aggregates away from their `cell_contributions` audit rows.

**E7 — Single-instance in-memory coordination.** Rate limits, Ed25519 challenges, and SSE
fan-out live in process-local actors — correct today, silently broken the day a second
instance runs.

**E8 — Query anti-patterns.** N+1 loops in `getContributors`; `deleteRepeater` loads every
`cell_repeaters` row into memory; `normalizeRepeaters` is O(N²); v1 `getStats` loads all
distinct IDs into memory. All timestamps are ISO-8601 TEXT with lexicographic comparison —
no native time types or time indexes.

**E9 — Quality thresholds disagree.** `CellModel.snrQuality` (strict `>` at 10/5/0/-10)
vs the inline SQL and v2 controller (`>=` at 10/0/-10/-15). The same cell can be labeled
differently by different endpoints — and differently again by the two iOS overlay palettes
(D2).

**E10 — Unauthenticated public write.** `POST /api/v1/public/paths` persists records with
no key at 10/min/IP — a storage-abuse vector.

**E11 — Operational drift.** `deploy.sh` backs up `data/survey.sqlite` while production
data lives in the Postgres volume — deploys back up nothing meaningful. Domain, ports, H3
resolution, validation limits, resolver weights are hard-coded across files. One test file
exists (RepeaterResolver); zero coverage of HTTP endpoints, ingest, aggregation, or auth.

**E12 — API-key comparison is not constant-time** (`APIKeyMiddleware.swift:18`), and a
single static key serves all clients with no revocation story beyond one rotation slot.

---

## Summary

The system works, but it is three generations of ideas stacked without a scaffold:
a passive RX pipeline in an actor, an active TX engine in a view model, a copy-pasted grid
contract, two spatial indexes, five upload paths, and three map implementations. The v2
design addresses these with one shared geometry/DTO package, one client engine actor with
an explicit mesh TX budget and speed-adaptive resolution, one versioned server API, and one
map component.
