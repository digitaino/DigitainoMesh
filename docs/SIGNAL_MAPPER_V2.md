# Signal Mapper v2 — design (app + server)

Agreed with Rafael 2026-07-30. This is the "fresh design doc" that MIGRATION_PLAN.md
reserved space for (§3, "Signal mapper (future)"); it supersedes that section's hold on
re-importing SurveyKit/H3. Status: **M0 + M1 built (local capture and own-coverage map);
M2+ redesigned 2026-07-30 after the adversarial review in §10.**

Guiding idea: one capture core, two thin modes. Automatic mode is purely passive — it
maps the packets the app already sends and receives. Manual mode is a deliberate,
budgeted survey. Both produce the same value (H3 cell observations).

**On what "anonymous" means here** — precise wording, because the loose version is
false and the review proved it. An honest server records nothing that links two upload
batches to each other or to a person; there are no accounts, no device IDs, and no
persistent pseudonyms, so we cannot answer "what did this person contribute?" What we
*cannot* claim: that a compromised server learns nothing (it sees IP, arrival time and
payload before our policy discards them), or that the published dataset is
unidentifiable in the abstract. **Coverage data is self-linking**: one person's
contribution is a spatially connected, statistically distinctive object, and a naive
public map lets an outside observer reassemble it without ever touching the server.
§3 is built around that fact rather than around receipts alone.

---

## 0. Decisions log (2026-07-30)

| Topic | Decision |
|---|---|
| Server | Full TypeScript rewrite. `pocketmesh-survey-server/` (Vapor) becomes reference-only and retires after M5. |
| Hosting | Docker Compose (app + Postgres + Caddy) on the existing mesh.digitaino.com box. |
| Framework | Next.js (standalone output). React chosen because deck.gl / MapLibre ecosystem and examples are React-first. |
| Grid | H3, res 9 captured/stored (~174 m edges). **Published resolution is density-adaptive** (§5.3), not fixed. |
| Auto mode | Foreground-only passive capture with cached one-shot fixes. No new permissions, no background location. |
| Manual mode | Start/stop sessions + one-tap spot check, one shared probe engine. |
| Identity | Per-upload receipts only. No accounts, pseudonyms, streaks, or leaderboards. |
| Old data | Total fresh start. The v1 axial dataset retires with Vapor; nothing migrates. |
| Share links | Rebuilt on the new system (§5.5). Old `/r/:id`, `/m/:id`, `/p/:id` URLs die with Vapor; no redirects. |
| Public data | Display-only map, closed 5-field schema (§5.4). No bulk export. |
| Repeaters | Published coarsened to the cell centroid, no last-heard date, over-the-air opt-out (§5.6). |
| Decay | Recency-weighted stats; cells fade on the map after 6 months, leave it at 12. |

Added after the §10 review (2026-07-30):

| Topic | Decision |
|---|---|
| Anchor exclusion | Client detects high-dwell cells and excludes a **randomised disc** around them, at capture, with retroactive purge (§2.6). |
| Corroboration | A cell is published only after ≥2 independent batches ≥7 days apart have seen it (§5.3). Single-contributor cells never appear. |
| Publication cadence | Fixed slow schedule (weekly), all changes swapped atomically. No realtime/SSE, ever (§5.3). |
| Public schema | Presence tiers only — no counts, no min/max SNR, no float ratios, no repeater ID sets (§5.4). |
| Storage granularity | Persist **month**, not day, server-side; validate at day resolution in memory (§3 rule 4). |
| Receipts | Never in a URL path; server stores SHA-256(receipt) only (§4). |

The constants in §2.5 are beta-tunable defaults, not decisions.

---

## 1. Goals & non-goals

Goals: map real tx/rx coverage of the mesh; two capture modes; contributor anonymity
*with* full self-service deletion; negligible mesh and battery overhead; a TS server
that is easy to maintain; a hex-cell map site that looks good; an admin backend.

Non-goals (this iteration): background/wardrive location, accounts or gamification,
v1 data migration, old share-URL compatibility, raw-point upload (cells only),
anything Meshtastic.

---

## 2. Client — capture core

### 2.1 Observation model

`CellObservation` (new model in MC1Services, separate from the dormant Build 40
entities — see §6): H3 res-9 cell, UTC day bucket, direction (`rx` | `txHeard` |
`ack`), SNR/RSSI aggregates, route type counts, hop histogram, repeater `NodeHexID`s,
`active` flag. Aggregated locally per (cell, day) before upload.

Sources — all existing, **zero pipeline changes**:

- RX: `RxLogService.entryStream()` (`MC1Services/.../Services/RxLogService.swift:130`)
  — SNR, RSSI, hop count, path hashes, route type, dedup `packetHash` per packet.
- TX-heard: `HeardRepeatsService.processForRepeats` — our own messages heard being
  rebroadcast (free uplink-coverage data).
- Delivery: `MessageService`'s `.anyAcknowledgement` stream (RTT via `tripTime`).

Hash→node resolution goes through NodeIdentity only — MIGRATION_PLAN §2.1's rule
("nothing else may string-compare hex IDs") stands.

### 2.2 Location tagging — cached-fix policy

`LocationService` stays one-shot / when-in-use / coarse. A new `FixCache` layer on top:

- A fix is usable if: age < 120 s, `horizontalAccuracy` ≤ 100 m, **and** the
  `MovementHintProvider` (CoreMotion, no GPS) reports no significant movement since
  it was captured.
- On movement, the next observation triggers one fresh one-shot request.
- **Speed-scaled age budget** (belt and braces, needs no permission): the tolerated fix
  age shrinks with the fix's own reported speed so that speed × age stays under
  `fixMaxDisplacement` (~150 m, about half a res-9 cell). A stationary phone keeps the
  full 120 s; a moving one gets proportionally less. This covers the case where the
  user declines Motion & Fitness, which would otherwise leave the movement clause
  permanently silent.
- Observations with no usable fix are **dropped**, not queued — guessing poisons cells.
- Foreground only. Packets received during background BLE are invisible to the mapper.

The gate has **three** rejection reasons — age, accuracy, displacement — and the two
movement mechanisms are deliberately redundant because they fail in different places:
`movedSinceCapture` catches the phone that was parked when the fix was taken (speed 0,
so the budget cannot help) and then started moving; the speed budget catches the phone
already in motion and is the only one that survives a declined Motion & Fitness prompt.
The clause is load-bearing, not decoration: at 15 m/s a 119 s-old fix that passes an
age-only gate attributes packets to a cell ~1.8 km — about five res-9 cells — behind
the phone.

**Motion & Fitness is a mapper dependency**, requested when the user enables capture,
not inherited from whatever signal bars happened to obtain. Declining is survivable but
degrades anchor detection to the volume threshold alone. Implementation note that must
not be "simplified" away: an unauthorized movement relay reports `.stationary` forever,
so the engine treats **nil hints as unknown, never as stationary** — anchor detection is
asymmetric by design, since under-counting dwell merely delays an anchor while
over-counting would declare a user's entire commute one.

No plist or entitlement changes. Battery cost is occasional one-shot fixes the app
already performs for other features.

### 2.3 Automatic mode

Opt-in toggle, default off. **Enabling shows the privacy explainer every time it is
turned on**, from whichever surface flips it — not only in the tool's empty state.
Purely passive: never transmits anything on the mesh. Uploads batch automatically per
§2.5 once opted in.

### 2.4 Manual mode — sessions + spot check

A session layer wrapping `SignalBarsEngine`'s probe plumbing (B1), exactly as
MIGRATION_PLAN §3 anticipated. Probe discipline (the "don't stress the mesh" rules):

- Directed traces to known repeaters (zero-hop ping for the direct link) — never
  flood, with one exception: a flood discover is allowed for a cell with no known
  repeaters, capped per §2.5.
- `SamplingPolicy` skips cells that already have fresh local or community data —
  the network cost of surveying shrinks as the map fills in. **The community half of
  that test reads month-granularity freshness only** (`current | aging | stale`), never
  a per-cell last-seen date: a 7-day freshness endpoint would be a public per-cell
  activity oracle and would contradict §3 rule 6. Local freshness may use exact days —
  it never leaves the device.
- All probes drain the `TokenBucket` budget (§2.5); the budget is shared with
  spot check.
- Spot check = a one-cell burst through the same engine. No separate code path.
- Sessions end with a completion sheet: cells collected, probes spent, explicit
  upload consent. Manual data uploads only from that sheet.

### 2.5 Tunable constants (live-tunable, deliberately open)

Final values are chosen from field testing, not this document. Debug/TestFlight builds
expose every constant below in a debug settings panel for live adjustment; release
builds ship the then-current values as compiled defaults. Values get locked (and this
table updated) before public deploy — see also §9 on post-beta remote tuning.

| Constant | Starting default |
|---|---|
| Probe rate in a session | 1 per 10 s sustained, burst of 3 |
| Samples per cell per session | 5 |
| Community-freshness skip | month-granularity tier (§2.4), not a day count |
| Flood discover | ≤ 1 per unknown cell per session |
| Fix max age / max inaccuracy | 120 s / 100 m |
| Fix max displacement (speed × age) | 150 m |
| Anchor: min distinct days | 5 |
| Anchor: stationary share | 0.6 |
| Anchor: observation-count trigger | 2000 |
| Anchor: disc centre offset | random 300–600 m, stable per install |
| Anchor: disc radius | random 700–1200 m, stable per install |
| Anchor: recompute cadence | every 20 flushes, and at engine start |
| Auto-mode upload batch | ≥ 25 cells or 24 h; jitter ±6 h; split into spatially scattered sub-batches, padded to size classes (25/50/100/250) |
| Local raw retention | purge observations older than 12 months |

### 2.6 Anchor exclusion — the home-island defence

**The problem.** Passive capture volume is proportional to dwell time. A cell walked
through yields a handful of observations; a cell where the phone sits four hours a day
for a month yields tens of thousands. Unmitigated, the brightest cells on the map are
exactly where contributors live, work and sleep, and in a sparse mesh a res-9 cell in
open countryside *is* a property. This is the single most identifying property of
passive crowdsourcing and it must be handled on the client, before anything is stored —
the server cannot help, because it cannot count contributors (§3 rule 2).

**Detection.** A cell becomes an *anchor* when it has been seen on ≥ `anchorMinDistinctDays`
distinct days with a stationary share above `anchorStationaryShare`, or when its
observation count crosses `anchorObservationCount`. Both signals are already free: the
store is one row per (cell, day), so distinct days is a row count, and
`stationaryObservationCount` records how often the motion hint said "not moving" at
capture time. **No within-day timestamp mask** — a 15-minute presence bitmap is itself a
residency calendar and we decline to create one.

**Exclusion, with the pointer removed.** Each anchor gets a disc: centre offset from
the anchor cell by a random bearing and 300–600 m, radius random 700–1200 m, both draws
**stable per install** (a disc that moves or resizes between runs leaks more, not less)
and never uploaded or displayed. Observations inside a disc are dropped **at capture**,
before folding, and rows already stored inside a newly-detected disc are **purged
retroactively** — data gathered before detection must not survive on disk either.

The randomisation is the whole point. A fixed one-ring exclusion around the anchor
cell produces an enclosed void in otherwise-continuous coverage whose centroid *is* the
person's home: suppression becomes a labelled pointer, strictly worse than doing
nothing. Randomised centre and radius give the void's centroid a few hundred metres of
irreducible error, comparable to the cell size itself.

**Purge-before-detection is the load-bearing half.** The rows that make a cell
*detectable* as an anchor are on disk before it is detected, so refusing future capture
alone protects nobody. Recomputation therefore deletes stored rows inside a new disc
*and* drops matching in-flight pending cells — otherwise the next flush restores what
was just purged.

**Disc seeding.** The per-install seed lives outside the tunable constants deliberately:
`resetToDefaults()` must never reshuffle discs, or the voids move and reveal more than
they hide. Draws are keyed per cell so neighbouring anchors get uncorrelated discs, and
the geometry is never rendered, exported, or uploaded — the debug panel shows counts
only.

**Limits, stated honestly.** Dwell heuristics catch the home and the workplace; they
catch a partner's flat, a parent's house or a regular café slowly or not at all. In
low-density regions the right move is to suppress the whole coverage island rather than
punch a hole in it. And exclusion cannot defend against inference from *other people's*
data about a fixed node you own — see §10's residual risk.

Automatic anchor exclusion ships in M1.5. **User-defined privacy zones remain M2** and
are additive to it, never a replacement — §3 rule 5's default-on protection is the
automatic one, because an opt-in setting protects only the users who already understood
the risk.

### 2.7 Carries & rewrites

- **SurveyKit returns**: `git checkout legacy/v1-final -- SurveyKit/`, then prune —
  keep `SurveyGrid` (H3), `SamplingPolicy`, `SamplingTier`, `TokenBucket`,
  `RequestSigner`, `SignalQuality` + tests; delete `LegacyAxialGrid` and the v2.2
  wire DTOs (wire v3 replaces them). This supersedes MIGRATION_PLAN.md:150.
- Survey UI is a rewrite on MIGRATION_PLAN §2.3's map layer API (the second consumer
  after T1, as planned). Zero `import MapKit`.
- The 13 legacy `SignalSurvey/` view/VM files and both legacy upload services are
  reference-only: spec + test-fixture source, no file carries.

---

## 3. Privacy architecture

Four layers, because no single one holds. The review (§10) found that receipt
unlinkability protects the *metadata* while leaving the *payload* self-identifying, so
the defences now run from capture through publication.

**Layer 1 — capture (client).** Anchor discs (§2.6) keep high-dwell areas out of
storage entirely. The fix gate (§2.2) refuses stale, inaccurate or moved-since-capture
fixes. Raw GPS is bucketed to a cell immediately and never persisted.

**Layer 2 — upload (client).** Receipts, batch splitting and padding, jittered
schedule, spread-out deletion (§4).

**Layer 3 — ingest (server).** Minimal retention, month-granularity storage, no IP,
no batch-linking surfaces (§5.2).

**Layer 4 — publication (server).** Corroboration gate, density-adaptive resolution,
closed presence-only schema, fixed slow cadence (§5.3, §5.4). **This is the layer that
actually defends the public map**, and it is the one the original design lacked.

### Hard rules

1. **Raw GPS never leaves the phone.** Uploads carry cells and aggregates only.
   Enforced by test: no wire DTO has a lat/lon field, and no field parses as a
   sub-day timestamp. Note honestly that this is a claim about *fields*, not about
   inference — a res-9 cell in open countryside is an address, which is why layer 4
   exists.
2. **Receipts, not identity.** Each batch carries a fresh random 32-byte receipt
   generated client-side, kept in a device-only Keychain vault
   (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, excluded from backups and device
   transfer, pruned at 6 months). The server stores **SHA-256(receipt)** only, never
   the bearer secret, and the receipt travels in a request body — never in a URL path,
   where it would land in access logs. Deletion replays the vault (§4).
   *Structural consequence:* because batches are unlinkable, the server cannot count
   distinct contributors, so **server-side k-anonymity is impossible by construction**.
   Every person-level protection must therefore happen client-side (layer 1) or
   geometrically (layer 4). A receipt-count threshold is not a substitute and is
   actively inverted — one person uploading 40 batches over a year produces 40 receipts
   for their home cell, so counting receipts would preferentially publish anchors and
   censor genuinely-shared transit cells.
3. **Sensitive values are omitted from logs, not merely annotated.** OSLog's
   `privacy: .private` is the right tool where it exists, but the app's
   `PersistentLogger` takes a plain `String` and writes to an **exportable in-app debug
   log** — there is no privacy parameter to reach for, so coordinates, message content
   and similar values must be left out of the message entirely. Worth a lint rule.
4. **No IP retention — enforced by config and tested, not promised.** Caddy deletes
   `remote_ip`, `headers` and `uri` from access logs; Postgres statement/connection
   logging off; Docker log driver capped; no request logging in the app layer; error
   handlers never serialize the request. Rate limiting keys on
   `HMAC(rotating-hourly-secret, IP)` counters held in memory, never a timestamp list,
   never written to disk. **CI check:** issue a request from a known address, then grep
   every container log and the database for that octet string.
5. **Month granularity server-side.** Day-resolution plausibility checks run in memory
   at ingest; what persists is (cell, month). Nothing downstream needs finer — decay
   thresholds are 6 and 12 months and the display is monthly — and a retained per-cell
   day calendar is a residency record we decline to hold.
6. **Anchor exclusion is default-on** (§2.6), not an opt-in setting the privacy-naive
   never find. User-defined additional zones (M2) are additive to it, never a
   replacement; their geometry never leaves the device.
7. **No contributor surfaces, and the boundary is the API response.** The public
   schema is a closed allow-list (§5.4) asserted in tests against the **HTTP response
   body**, not against DTOs or components — tiles carrying fields the UI merely
   declines to paint are public regardless.
8. **Storage DTOs are deliberately not `Codable`.** `MapperCellObservationDTO` and
   `MapperRepeaterStats` carry exact timestamps for local aggregation; their only codec
   is private to the model file. `JSONEncoder().encode(rows)` does not compile, so M2
   must write a wire DTO that names every field it sends. The safeguard is structural,
   not a comment asking people to be careful.

### What we tell users, and the App Store label

"Data not linked to you" remains defensible for the *upload* design: no accounts, no
device IDs, nothing joins two batches. It is not a claim that the published dataset is
anonymous in the abstract — under GDPR, data permitting *singling out* is personal data
even without a name, and a coverage trace in a sparse area singles out. The layer-4
defences are what make the published dataset arguable; the residual risk we cannot
engineer away is stated plainly in §10 and must appear in the in-app explainer, not
only in a policy page.

---

## 4. Wire v3

**Upload** — `POST /api/v3/uploads`, body `{v, receipt, cells: [...], repeaters: [...]}`.
App-key HMAC over timestamp + body, byte-compatible with SurveyKit's `RequestSigner`.
Idempotent by receipt, and a repeat must be **indistinguishable from a fresh accept**
(same 2xx) — "duplicate receipt rejected" is a receipt-existence oracle.

Payload rules, each closing a specific finding:

- **No field may parse as a sub-day timestamp.** `earliest`/`latest`/`firstHeard`/
  `lastHeard` do not cross the wire. Asserted by test.
- **No raw counts.** Counts upload as buckets (1, 2–3, 4–7, 8–15, 16–31, 32+). Send a
  rounded average (0.5 dB) — never `sum` + `count`, whose float pair is effectively a
  device nonce, and never `dailyCounts`, which is a per-device activity calendar.
- **No per-contributor repeater ID sets.** The *set* of repeaters heard in a cell
  reflects one person's radio, antenna and exact spot; it is a high-entropy fingerprint
  that re-links batches without any metadata. Upload repeater involvement as counts;
  the map publishes the union across contributors (§5.4).
- **No per-install tuning values.** §2.5 constants are live-tunable per install in
  debug builds and must never be echoed in a payload — a beta tester with custom
  constants would be singled out in every batch. If constants ever become
  server-tunable (§9), they are global-only, never per-install.
- **Canonical encoding**: fixed key order, fixed float formatting, no pretty-printing,
  batches padded to fixed cell-count classes. Shape is a fingerprint too.
- Batches are **spatially scattered subsets**, not contiguous traces (§5.2 explains why
  the old geo-speed envelope check had to go).

**Deletion** — `POST /api/v3/uploads/delete` with the receipt in the **body**. Constant
`204 No Content` whether or not it matched, so it is not an existence oracle. The server
tombstones and lets the aggregation job recompute affected cells **from surviving
observations** — never by subtracting the batch, because min/max SNR is not decomposable
and subtraction leaves a deleted batch's extremes visible in the cell forever.
Client-side, delete-all **spreads requests over hours by default** with visible progress
and an explicit "delete everything now (faster, less private)" escape: replaying the
whole vault in one burst hands a malicious server the complete set of one person's
batches in a single minute. Each request uses a fresh connection (`URLSessionConfiguration.ephemeral`)
or connection reuse defeats the spreading. **Never** batch multiple receipts into one
request body.

**Anti-abuse** (the app key is extractable from the binary — accepted): SNR/RSSI range
checks, per-batch cell cap reduced to ~500 (10,000 res-9 cells is ~1,000 km², physically
implausible for a foreground-only client), physics checks (reject repeaters implausibly
far from their advertised anchor; reject SNR improving with distance), and one generic
`400` for every validation failure — specific errors are an oracle. The real defence
against poisoning is the corroboration gate (§5.3), not input validation.

**Shared test vectors**: one JSON fixtures file of HMAC signatures + payloads consumed
by both the SurveyKit tests (Swift) and the server tests (TS). If either side drifts, a
test fails.

---

## 5. Server

New standalone repo, sibling to `pocketmesh-survey-server/` (own git, same pattern).
Working name: `mesh-mapper`.

### 5.1 Stack & deployment

Next.js (standalone output) + TypeScript end to end. Drizzle ORM + Postgres 16;
`h3-js` for indexing and rollups — no PostGIS/h3-pg dependency unless bbox queries
prove slow. Aggregation runs as a small worker script in the same container (cron
loop), not a queue system. Compose: `app` + `postgres` + `caddy`.

Hardening is configuration, and configuration is tested (§3 rule 3): Caddy log-field
deletion, Postgres `log_statement=none` / `log_connections=off` / terse errors, capped
Docker log driver, full-disk encryption, and **no CDN or edge proxy in front of
`/api/v3/*`** — an edge sees every request IP no matter what our Caddyfile says. If one
is ever added, the docs must say so plainly.

**Backups: do not back up `observations`.** Back up `repeaters` and admin curation only.
A nightly dump with 30-day retention would make "hard delete" a 30-day lie — the most
likely real deletion-completeness failure in the design. The observation set regenerates
by nature (people keep contributing) and its loss is survivable. `VACUUM` after purges;
no WAL archiving unless PITR is genuinely needed.

### 5.2 Data model & ingest

- `upload_batches(receipt_hash PK, month)` — SHA-256 only, no raw receipt, no
  `cell_count` (derivable, and a shape fingerprint).
- `observations(receipt_hash FK cascade, h3 res 9, month, direction, bucketed counts,
  rounded SNR/RSSI, route counts, hop mode, repeater refs)`
- `cells_published` + coarser rollups — materialized by the publication job with
  recency weighting; `hidden` flag for admin quarantine.
- `repeaters(pubkey PK, coarsened position, active_within_6_months, hidden, notes)`
- Share objects (§5.5).

**The geo-speed envelope check is gone.** It required each batch to be a spatially
coherent trace — which is precisely the property that lets an observer cluster batches
into one person's trajectory, and it forbade the fix (scattered sub-batches). It bought
little anyway against an attacker holding the app key. Physics checks replace it (§4).

Decay: cells older than 6 months render faded; older than 12, excluded. Raw
observations purge at 12 months.

### 5.3 Publication pipeline — the layer that protects the map

Aggregation is continuous; **publication is a separate, deliberately slow step**. Three
gates, in order:

**1. Corroboration.** A cell is published only once **≥2 independent batches, ≥7 days
apart**, have observed it. This is the highest-value rule in the design: it kills
map poisoning (a lone forged batch never renders), it makes single-contributor cells
structurally unpublishable — *your home cell, seen only by you, never appears at all* —
and it does so without counting contributors, which §3 rule 2 forbids. Cost: sparse
coverage appears slowly, which is the correct trade.

**2. Density-adaptive resolution.** Publish each cell at the finest resolution whose
underlying dwelling count clears a threshold (~50 dwellings), from a population table
held server-side. Roughly: res 9 in urban and suburban areas, res 8 in villages, res 7
or coarser in open country. Identifiability is driven by *how many homes share a cell*,
not by cell size — which is why the earlier "passive at res 8, manual at res 9" idea was
dropped (§10 rejected list). **No isolated islands**: a connected component whose total
dwelling count falls below threshold is coarsened until it clears, or withheld.

**3. Fixed slow cadence.** Publish weekly, all accumulated changes swapped atomically.
Continuous republication is a linkage oracle: an observer polling the map sees each
batch's cells change together and reassembles one person's day. Upload jitter does not
help — it randomises *when* a batch lands, not *that its cells land together*. Cadence
is a privacy parameter; treat it as one.

**Never realtime.** No SSE, no websockets, no per-cell live push. The legacy server
shipped a public unauthenticated `GET /api/v2/events` firehose streaming each cell as it
was ingested — a batch-linkage oracle requiring no server compromise at all. This
prohibition exists so nobody re-adds a "live map" in good faith.

**Rollup integrity invariant:** every parent's statistics are recomputed strictly from
*published, unhidden* children, atomically on hide. Otherwise subtracting visible
children from a parent recovers exactly the cells someone asked to have removed.

### 5.4 Public schema — a closed allow-list

Per cell, the public API returns these five fields and **nothing else**:

```
q     : excellent | good | fair | poor | veryPoor    // SignalQuality, already 5 buckets
mode  : mostlyDirect | mixed | mostlyFlood           // bucketed, never a float ratio
hops  : 0 | 1 | 2 | 3plus                            // modal hop, never a histogram
reach : 1 | 2 | 3plus                                // repeater count, never the ID set
fresh : current | aging | stale                      // month-derived, never a date
```

Deleted from the public surface, each for a concrete reason: **min/max/best SNR** (the
range grows as √(2 ln n), so publishing extremes recovers the observation count to
within about half a decade — dwell density leaks even with counts hidden); **any float
ratio** (its reduced fraction's denominator *is* the count); **hop histograms** and
**repeater ID sets** (fingerprints that re-link contributors); **direction**
(`txHeard`/`ack` mark cells the contributor *transmitted from*, joinable against anyone's
radio log of the same publicly-observable rebroadcasts to map a pubkey to a cell);
**any count**; **first-seen**; **any date finer than month, on any field**.

Per-repeater coverage remains genuinely useful for network planning — publish it as a
separate coarse layer aggregated as the **union over all contributors**. The union is a
network fact; the per-contributor subset is a fingerprint.

Rendering: MapLibre GL + deck.gl `H3HexagonLayer`, cells by bbox and zoom. Rate limiting
and anti-scrape are defence in depth only — a tile API is a bulk export endpoint that is
merely inconvenient, so every privacy property must hold against someone holding a full
local copy of the published data.

### 5.5 Admin

`/admin` on a separate hostname behind strong auth (passkey, or long secret + TOTP),
**failing closed** if the secret is unset — the legacy middleware failed *open* with a
warning nobody reads. In Next.js, protect the route handler, not just the page.

Legitimate scope: aggregate volume dashboards with no per-batch rows; quarantine/hide by
**cell**; repeater curation; delete-a-batch **by hash** for incident response; app-key
rotation (accept current + previous key, roll on app update — no per-client key fetch).

**Batch inspection is removed from the design.** A console listing batches with their
cell sets is exactly the tool for de-anonymising contributors by hand; shipping it would
make the "not linked to you" claim indefensible regardless of intent. If incident
response ever truly needs it, it goes behind a logged, time-limited break-glass flow
that is disclosed in the privacy explainer.

### 5.6 Repeater layer

Repeaters advertise identity and position on the mesh already, but republishing that
is not a null act: an advert is ephemeral, radio-range-limited and requires a receiver,
while a map entry is global, searchable, archived and cross-referenced with coverage
shape. That is an aggregation harm even when every input is "public." So:

- Positions are **snapped to the published cell centroid**, never republished exactly.
- **No first/last-heard dates** — a last-heard on a home repeater is an occupancy
  signal. A single `active within 6 months` flag replaces them.
- Honour any position-precision or no-position preference present in the advert.
- Opt-out is **self-service over the mesh** (a flag the node advertises), not
  "email the admin" — reactive opt-out requires knowing the map exists.
- Consider opt-*in* for repeaters whose advertised position falls on a residential
  parcel.

### 5.7 Share links v2

Shared routes / paths / repeater maps become first-class rows that render as overlays
on the same map stack — a shared route is the public map plus a route overlay with
per-hop SNR, not a separate page system. New short URLs under one namespace. The
chat-side parsing (`SharedRouteParser`, route cards) already exists on v2 and stays;
only the "share to web" leg is new. Old Vapor URLs die when Vapor stops; no redirects.

**Origin-hop redaction.** Hop 0's SNR to a repeater at a known position is a range ring
around the sharer; two shared routes through different repeaters trilaterate them.
Publish routes from the first repeater onward, and confirm explicitly ("this publishes
your approximate location") before sharing.

### 5.8 Vapor decommission

Vapor stays up read-only until M5 ships. Then: private archive dump of its DB, tear
down, retire `/api/v1` and `/api/v2`. The old dataset is not carried into the new map.

---

## 6. Build 40 remnants (client)

`SurveySession`, `SignalSurveyPoint`, and the dormant `Message` location/txPower
columns stay exactly as they are — the fresh-start decision does not touch on-device
data. **The legacy rows are never read into the v2 capture pipeline or uploaded** —
they are old-scheme data and stay out of the new system entirely. Plan: a later build
ships a one-time "export legacy survey data" (JSON) in Settings, for the user's own
records only; a build after that removes the entities (which deletes the rows, per
the warnings in those files). Never drop the entities before the export build has
been out for a while.

---

## 7. Build order

Each phase ends green: builds, tests pass, shippable.

**M0 — foundations.** SurveyKit restore + prune (§2.7) · `CellObservation` model +
store · `FixCache` · capture core behind a debug flag · debug tuning panel for the
§2.5 constants. Carried grid/policy/bucket tests green; new capture-core tests with
injected clock + fix provider.

**M1 — auto mode + own-coverage layer.** Passive capture end to end, hex layer via
the map layer API rendering *your own* local cells. Real user value with zero server.
Shipped a user-facing toggle in the release Tools list, not just a debug flag.

**M1.5 — privacy hardening (from §10). ✅ Done 2026-07-30.** Fix-gate movement clause +
speed-scaled age budget · mapper owns its motion permission · anchor detection,
randomised exclusion discs, retroactive purge · storage DTOs de-`Codable`d · sensitive
values removed from logs · privacy-invariant tests. All client-side; no server needed.
SurveyKit gained spherical helpers (`distanceMeters`, `coordinate(from:bearing:distance:)`,
`cells(within:of:)`) for the discs — add them to §2.7's keep-list.

**M2 — server MVP.** Compose stack + tested logging config · wire v3 upload/delete
(bucketed, timestamp-free, body-receipt) · ingest + publication pipeline with the
corroboration gate, density ladder and weekly cadence · closed-schema public map ·
app gains upload, Keychain receipt vault, spread delete-all, "your public footprint"
preview (§10) before first upload.

**M3 — manual mode.** Session engine + spot check + completion/upload sheet.

**M4 — admin + repeater layer** (§5.5, §5.6).

**M5 — share links v2 + Vapor retirement.**

---

## 8. Testing bar

- Engines: unit-tested with injected transports/clocks/fix providers
  (MIGRATION_PLAN §6 patterns).
- Wire v3: round-trip + malformed-input tests on both sides from the shared fixtures
  file (§4).
- **Privacy invariants as tests** — these are the ones that must never go red:
  - No DTO contains a lat/lon field; no field parses as a sub-day timestamp.
  - The **public API response body** matches the §5.4 allow-list exactly (assert on
    the HTTP response, not on DTOs or components — a field the UI declines to paint
    is public anyway).
  - No mapper row retains a `messageID` (coverage must not be joinable to
    conversations).
  - A cell with observations from one batch is **not** published; it becomes published
    only when a second batch ≥7 days later arrives (corroboration gate).
  - Hiding a cell changes its parents such that its statistics are not recoverable by
    differencing the rollups.
  - Delete → re-aggregate leaves no trace of the deleted batch, **including min/max
    extremes** (recompute from survivors, never subtract).
  - Anchor discs are stable across recomputation; observations inside are dropped and
    pre-detection rows purged.
  - **Log-leak CI check**: request from a known IP, then grep every container log and
    the database for that address.
- Server: integration tests against ephemeral Postgres (Docker) covering
  upload → aggregate → publish → query → delete → re-aggregate.

---

## 9. Open items

- Final repo name + bootstrap for the TS server.
- App-key rotation: accept current + previous key, roll on app update. **Settled
  against** a remote-config key list — that would add a per-client fetch with its own
  timing and identity surface.
- Beta comms: fresh-start announcement; old contributions retire with the old map.
- Privacy nutrition label + App Review notes update alongside M2; a short DPIA note
  is worth having with someone qualified (§10 residual risk).
- Whether §2.5 constants become server-tunable after beta — if so, **global only,
  never per-install** (§4).
- Population table for the density ladder (§5.3): source, licence, size, and whether
  the client ever needs a copy or the server-side table suffices.
- Receipt-vault backup policy: currently device-only Keychain, so restoring onto a new
  phone loses the ability to delete past uploads. Decide and document deliberately.
- **Lint/format gap:** `.swiftformat` and `.swiftlint.yml` don't exclude `SurveyKit/`,
  a carried 4-space-indented package, so every file in it fails `--lint` including ones
  nobody has touched. Either exclude the path or schedule one dedicated reformat pass —
  don't let it happen incidentally inside a feature diff.

---

## 10. Adversarial review (2026-07-30)

Three independent reviews — a public-map deanonymiser, a hostile-server/protocol
adversary, and a code-vs-promises audit of the shipped M0/M1. The design changed
substantially as a result; this section records *why*, so the reasoning survives.

### The two findings that reshaped the design

**The payload is self-linking.** Receipts make batches unlinkable at the metadata
layer, but a person's contribution is a spatially connected object with distinctive
per-cell content (the exact set of repeaters heard, the statistical shape). An observer
holding a scrape of the published map can cluster it back into per-person footprints
without touching the server. Unlinkable metadata over self-identifying payload is not
anonymity. → §5.4's closed schema, §4's no-repeater-sets rule.

**Publication timing is a linkage oracle.** If the map republishes shortly after each
batch is ingested, an observer polling it sees one batch's cells change together —
recovering exactly the trajectory receipts were meant to hide, from outside, with no
compromise. Upload jitter is no defence: it randomises *when* a batch lands, not *that
its cells land together*. → §5.3's fixed weekly cadence and the standing no-realtime
prohibition.

### Attacks the current design answers

| Attack | Answer |
|---|---|
| Home island from dwell density | Anchor discs at capture (§2.6) + corroboration gate (§5.3) |
| Sole-contributor attribution in sparse areas | Corroboration gate + density ladder + no isolated islands |
| Count recovery from min/max SNR, float ratios, histograms | Closed presence-only schema (§5.4) |
| Suppression hole as a pointer to home | Randomised disc centre and radius (§2.6) |
| Batch clustering via publication timing / SSE | Weekly atomic swap; realtime prohibited (§5.3) |
| Repeater-set fingerprinting | Union-only repeater layer; no per-cell ID sets |
| `txHeard` joined against a radio log to map pubkey → cell | `direction` never published |
| Map-diff occupancy signals ("this house is empty") | Month granularity + weekly cadence + no last-heard on repeaters |
| Poisoned/forged coverage, targeted fake islands | Corroboration gate — a lone batch never renders |
| Delete-all burst as a confession | Spread deletion, fresh connection per request (§4) |
| Receipt leaking through access logs | Receipt in body, SHA-256 at rest, `uri` stripped from logs |
| Admin console as a de-anonymisation tool | Batch inspection removed (§5.5) |
| Rollup differencing to recover hidden cells | Rollup integrity invariant + test (§5.3, §8) |
| Subpoena/breach yields more than expected | Backups exclude observations; logging config tested (§5.1) |

### Rejected, with reasons

- **Resolution laddering** (passive at res 8, manual at res 9) — my earlier proposal,
  and wrong. Identifiability tracks dwellings per cell, not cell size, so it helps in
  cities where you were already safe and not at all in the rural case that matters.
  It also creates a provenance distinguisher (an res-9 cell means "a human deliberately
  stood here"), and it inverts, because the first place people survey is their own
  house. Replaced by the density ladder.
- **Fixed one-ring anchor suppression** — creates a labelled void whose centroid is the
  home. Kept only in randomised form.
- **Rotating per-epoch pseudonyms** to enable server-side k-anonymity — a month of
  linked cells *is* a trajectory. Strictly worse for this threat model.
- **Threshold cryptography** (reveal only what ≥k clients reported) — the only true path
  to k-anonymity, but it wants two non-colluding servers, doesn't fit a single
  self-hosted box, and is Sybil-able by anyone who extracts the app key. Recorded as
  the honest alternative; not attempted.
- **Server-side k-anonymity by counting receipts** — inverted (§3 rule 2).

### Residual risk — say this to users, in the app

Some exposure is inherent and cannot be engineered away. The in-app explainer (§2.3)
should say approximately this, not bury it in a policy page:

> Coverage data is collected where you are, and you are mostly at home. We exclude the
> areas where you spend the most time, we only publish a place once other people have
> been there too, and we publish at a resolution based on how many homes are in the
> area — a city block at ~350 m, open countryside at kilometres. But publishing a
> coverage map still means publishing that *someone* was in an area. In a city that
> says almost nothing. In the countryside it can mean one household.
>
> One thing we cannot fix: signal strength falls off with distance, so measurements
> spread around a fixed transmitter point back at it — typically within a few hundred
> metres — no matter what we suppress, and they can come from *other people's*
> contributions, not just yours. If you run a fixed node at home it already broadcasts
> its position on the mesh; this map doesn't create that exposure, but it does make it
> easier to find. **If your safety depends on your address staying private, don't run a
> fixed node there, and leave automatic mapping off.**

### Doc-accuracy fixes made in this pass

The preamble's "the server never learns who produced them" was false against a
compromised server and is now scoped to an honest one. §3 rule 1's "raw GPS never
leaves the phone" is true but was doing rhetorical work it can't support — it is a claim
about *fields*, not about inference. §3 rule 4's claim that jitter makes arrival time
uncorrelatable was overstated and is now scoped to a network-position observer. §2.4's
7-day community-freshness window contradicted §3 rule 6 by requiring a public per-cell
freshness oracle, and now reads month-granularity tiers.
