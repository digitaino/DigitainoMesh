# Signal Mapper v3 — raw-first (proposal, 2026-09-03)

Status: **proposal for Rafael's review, nothing built.** The v2 mapper (docs/SIGNAL_MAPPER_V2.md,
docs/ACTIVE_SURVEY_M3_5.md) is superseded by this once approved. The 2026-09-03 card rework is
parked on `wip/mapper-cell-card-2026-09-03` for reference only.

## 0. What this is for

One sentence: **know which repeaters my radio hears in each hexagon, which of them hear me, and how
far my packets get — and keep every observation so it can be looked at later.**

Decisions already taken (Rafael, 2026-09-03):

| Question | Answer |
|---|---|
| Storage | Raw-first, always on. Every observation is a row; map, card and export are queries over rows. No pre-aggregation is the source of anything. |
| Retention | 90 days on the phone, oldest rows go. Export before then to keep them. |
| Our own packets | Remembered, all of them (message, advert, probe, flood), so reach can be looked up on scope. |
| Public map | Someday. Every upload privacy rule (home-cell deletion, day-only timestamps) applies **at upload time**, never to the phone's own data or map. |
| Layers | Two: **RX** (repeaters we hear) and **TX** (repeaters that hear us). TX coloured by the SNR they reported for us; a neutral "heard you" fill where only an echo proves it. |
| Card | One row per repeater heard directly: name, last heard, RX latest / best / average, heard-us SNR. A reach line per hexagon from the observers. Nothing else. |
| Surfaces | Passive capture, cell card, two layers, probing, ride mode, manual transmit all stay — as ways to *produce* observations, owning no data of their own. |
| Consumer of exports | Undetermined. Export is one row per observation, CSV or JSONL, filterable by hexagon, date, repeater and packet type. |

## 1. Definitions (the whole vocabulary)

- **Heard directly.** For a **flood** packet, the last hop of its path is the repeater our radio
  received it from; its SNR and RSSI are *our* measurement of *that* repeater, and every other hop was
  measured by somebody else. For a packet with **no path**, we heard the sender itself (an advert's
  public key). A **direct**-routed packet with a path credits **nobody**: forwarders consume the path
  from the front, so its last entry is the destination side of the route, not the node we heard. This
  is CoreScope's capture rule, verified against firmware `Mesh.cpp`; today's capture engine credits
  the last hop of direct packets too, which is wrong.
- **Heard us.** A repeater heard our radio when (a) it is the **first hop** of an echo of our own packet,
  or (b) it answered a trace or discover and reported the SNR it received us at. Only (b) gives a number.
- **The three-hops case.** We send a flood; A hears us, B hears A, C hears B, and C's rebroadcast reaches
  us. We *heard C directly*. C never heard us; A did. C is RX evidence only; A is TX evidence.
- **RX layer.** A hexagon's colour is the best SNR at which we heard any repeater directly there.
- **TX layer.** A hexagon's colour is the best SNR any repeater reported for us there. If repeaters
  heard us there but none reported a number, a flat neutral "heard you" fill. If we probed and nobody
  heard us, the "no reach" fill.
- **Reach.** For packets sent from a hexagon, which observers on scope.digitaino.com heard them, and
  how far away the farthest was. Fetched on demand; stored as rows once fetched.
- **Now.** Ten minutes. "Last heard" is printed as an age; nothing is hidden by it.

## 2. The observation table

One SwiftData model, one row per event, in the existing `MapperRawLog` module and container
(own store, excluded from backup). The run-scoped raw log becomes *the* store: `runID` turns optional
(set only while a ride is open), `seq` stays as the correlation key, retention becomes 90 days, and
two indexes are added: `(cellRaw, timestamp)` and `(repeaterHexID, timestamp)`.

| Column | Meaning |
|---|---|
| `timestamp` | when it happened, full precision |
| `kind` | `heard` · `echo` · `probeReply` · `probeSent` · `sent` · `ack` · `observerSighting` · `breadcrumb` · `radioLink` |
| `cellRaw`, `latitude`, `longitude`, `horizontalAccuracyMeters`, `fixAgeSeconds` | where we were |
| `payloadType`, `routeType`, `hopCount`, `pathHashes` | what the packet was and the route it took (hops as hex, path order) |
| `repeaterHexID`, `repeaterPublicKey?` | the repeater this row is *about*: the last hop for `heard`/`echo`, the replier for `probeReply`, the observer for `observerSighting` |
| `rxSnr`, `rssi` | our measurement of that repeater (`heard`, `echo`, `probeReply`) |
| `txSnr`, `perHopSnrs` | the repeater's measurement of us (`probeReply` only) |
| `contentHash?` | for `sent` rows once the echo reveals it, and for `observerSighting` rows: the mesh-wide packet identity scope uses |
| `txPowerDbm`, `rttMs` | our transmit power; probe round trip |
| `rawHex` | the packet bytes as received, for scope's ingest and for re-decoding later (§9) |
| `runID?` | the ride this row belongs to, if any |

What is deliberately **not** stored: message text or payload bytes, other people's identities beyond
the hop hashes the packet already carried, and any aggregate.

**Our own packets.** A `sent` row is written when the radio confirms a send (messages, adverts,
probes, manual floods) with time, hexagon and type. The firmware builds the packet, so the app cannot
compute the content hash at send time; the echo (`echo` row) reveals it and the `sent` row is
back-filled. No hash is needed for reach: scope lists a node's own transmissions by public key and
time (below), so a `sent` row is matched by time alone.

## 3. Screens

**Map.** Two layers from the same rows, chosen in the nav bar and named on the card: "I hear them" /
"They hear me". Legend: colour scale, plus "heard you" and "no reach" swatches on TX. While a ride is
open, the ride's hexagons are ringed over dimmed history; that is a `timestamp >= run.startedAt`
filter on rows, nothing more.

**Cell card.** Tap a hexagon (or stand in one on a ride):

```
↓ I hear them · Excellent · 1,048 heard · last 8 s ago              ✕
Digitaino Central      12.5 / 13.0 / 6.1 dB     hears you 13 dB     8 s
Digitaino Chestnut     9.0  / 11.5 / 4.2 dB     heard you           2 min
K5TDC Solar            4.5  / 8.0  / 2.0 dB     —                   41 min
Reach: 6 observers heard packets sent from here, farthest 18 km   (Look up)
```

Rows: repeaters heard directly here, most recent first, each with RX latest / best / average, the
heard-us state ("hears you N dB" from replies, "heard you" from echoes, "—" for neither), and the age.
Tapping a row opens the repeater's detail: every observation of it in this hexagon, and scope's link
view for it if you ask. The reach line fetches only when tapped.

**Amended 2026-09-05** (Rafael, from the ride — three complaints against the card as shipped):

- **One repeater, one row.** MeshCore path hashes are 1 or 2 bytes wide depending on the packet, so
  one repeater reaches a hexagon under both widths and the card listed it twice — "Digitaino Central
  ABBA" and "Digitaino Central AB", which the colliding-names rule then suffixed with their hashes,
  making them look all the more like two nodes. The fold happens **at the query layer and on hex
  only**: within a cell, an id that is a proper prefix of *exactly one* longer id is that repeater at
  a narrower width and folds into it; an id that prefixes several stays its own row, because a single
  byte cannot say which one it is. All three passes of `repeaterRows` and the card's uplink fold key
  on that canonical id, so one accumulator gets both legs; the row carries the folded hashes
  (`aliasHexIDs`) so the repeater detail — and later, export — can find every row behind it. CoreScope
  answers this by excluding 1-byte prefixes from attribution altogether; we keep them, listed and
  unmerged, because a row we cannot merge is still evidence.
- **The card expands.** A chevron in the header toggles the scrolling middle between the three rows
  it has always shown and as many whole rows as fit in what the map can spare: the map container less
  the ride strip, less the panel's own chrome (measured as the panel's height minus the rows'), less a
  160 pt minimum map viewport — never fewer than three. It is one preference
  (`AppStorageKey.signalMapperCardExpanded`, backed up), not per-hexagon state, and the default stays
  collapsed. "We need to be able to see more information at the same time."
- **The pill, per cell.** The header carries the nav-bar radio pill's two columns — RX bars over the
  number, TX bars over the number — for the **best link in this hexagon right now**, and tapping it
  opens that repeater. The pill is hidden for the length of a ride on the grounds that the card
  replaces it, and until now the card did not. Best is the highest `rxLatest` among rows whose **downlink
  reading itself** (`lastHeardAt`) is inside §1's ten minutes — not rows that are merely fresh by
  evidence, because a probe reply keeps a repeater fresh for as long as it answers and a two-hour-old
  8 dB would otherwise beat a thirty-second-old 1 dB (review, 2026-09-05) — falling back to the
  strongest reading of any age and then to the newest row, so a quiet hexagon still says something
  true. Graded on SurveyKit's six-step `SignalQuality`, like everything else on
  this card. Two things the pill carries stay off it: the adaptive-power step, which is on the ride
  strip, and the repeater's hash, which the pill needs because a nav-bar cluster has no other way to
  name what it means — here the same repeater is listed in full a few points below and a tap opens
  it, so the hash was the one part that could go and give the verdict line back its room. The readout
  is fixed-size and takes layout priority, so a short row truncates the verdict word rather than a
  number; at accessibility Dynamic Type sizes it is not drawn at all, because the rows underneath
  print the same two numbers and a four-line header says less than a two-line one.

**Ride mode, probing, manual transmit.** Unchanged in purpose, simplified in form: they write rows
and show what they are doing. The run detail and completion sheet become queries over the ride's rows.

## 4. Reach from the observers

Read from the CoreScope source (github.com/Kpa-clawbot/CoreScope, `cmd/server/routes.go`,
`db.go`, `node_reach.go`, `rx_coverage.go`, docs/client-rx-coverage.md), not from its README:

- `GET /api/packets?node=<pubkey>&since=<iso>&until=<iso>` lists a node's **own transmissions**
  (exact match on an indexed `from_pubkey` column) with every observer that heard each one, its
  SNR/RSSI, path and time. This is the per-hexagon reach query: our radio's public key plus the
  minute around each `sent` row. It covers packets nobody repeated, as long as an observer heard them.
- `GET /api/traces/{hash}` — every sighting of one packet, when the hash is known.
- `GET /api/nodes/{pubkey}/reach?days=` — who hears a node directly (count, average SNR) and
  per-neighbour we-hear / they-hear counts. The repeater detail's link view.
- `GET /api/nodes/{pubkey}/rx-coverage?bbox=&z=` and `GET /api/rx-coverage` — scope's own hex
  coverage map of where **mobile phones** heard a node, built from crowdsourced receptions (§5).

Per hexagon, on demand: query our transmissions for the times of the `sent` rows from that hexagon;
each observer sighting becomes an `observerSighting` row, so exports carry it and repeated lookups
are free. The card line shows observer count and the farthest located observer. Nothing is fetched
without a tap; only our public key, times and hashes leave the phone.

## 5. Export, and the off-client system that already exists

Share sheet → one file, CSV or JSONL, one row per observation with every column above, plus
optional filters before export: hexagon(s), date range, repeater, packet kind. A "delete rows older
than" control next to it, and the table's size in Settings.

**CoreScope is already the public map.** It ingests receptions from *mobile companion apps* over
MQTT (`meshcore/client/{PUBLIC_KEY}/packets`: raw packet hex, SNR, RSSI, GPS with accuracy,
timestamp), applies exactly the "heard directly" rule above server-side, stores them in
`client_receptions` (rx_pubkey, heard_key, snr, rssi, lat, lon, rx_at) and draws per-node hex
coverage on each node's Reach page. The reference client is an Android PWA (`corescope-rx`); there
is no iOS one. Its documented caveat: contributions are world-readable and a per-contributor view can
reconstruct that contributor's movements. The Austin instance has to enable `clientRxCoverage` and
an ACL-capable broker for this to be on.

So the "public map someday" step is not a server to build; it is publishing our rows in that payload,
under our radio's key, when Rafael turns it on. The v3 row keeps the raw packet hex for that reason
(the server decodes it itself), unless decided otherwise in §8. Rows that leave the phone that way
are exactly the ones scope's rule keeps: flood last hop or 0-hop advert, with a fix.

## 6. What goes

`MapperCellObservation` and its builder (aggregates), the anchor purge on the device (the policy code
stays for the future upload step), the run-only scoping of the raw log, the 30-day retention, the
ride/all-time baseline diff, and the chip-based card.

## 7. Build order

1. **Store.** Promote `MapperRawLog`: optional `runID`, `sent`/`observerSighting` kinds, `contentHash`,
   indexes, 90-day retention, size readout. Migrate nothing from aggregates (they are lossy).
2. **Capture.** Every existing producer (passive RX, echoes, probe replies, ACKs, sends) writes rows
   always, not only during rides. Hash back-fill from echoes.
3. **Queries.** Per-cell RX/TX summaries and the repeater rows, computed from rows off the main
   actor and cached per snapshot. Tests against fixed row sets.
4. **Map + card.** Two layers, the card above, the ride ring filter.
5. **Export.** CSV/JSONL with filters; delete-older-than.
6. **Reach.** `sent` rows → traces → sightings; the card's reach line; repeater detail with scope's
   link view.

Each step ships on its own; the map is usable after step 4, the data is safe after step 1.

## 8. Decided after review (Rafael, 2026-09-03)

- **Repeater detail** is a chart of RX SNR and heard-us SNR over time for that repeater in that
  hexagon, with the raw rows below it.
- **The ride completion sheet stays, simplified**: hexagons covered, repeaters heard, probes
  answered, and an Export button, all computed from the ride's rows.
- **Scope**: checked the source. Packets-by-source-node-and-time exists (§4); no ask needed.

## 9. Decided after reading CoreScope (Rafael, 2026-09-03)

- **Design for publishing, publish later.** Rows carry everything scope's client-reception payload
  needs; an opt-in publisher under the radio's own key is a later step, once the Austin instance has
  `clientRxCoverage` and an ACL broker on.
- **Keep the raw packet bytes on each row** (`rawHex`): scope decodes them itself, and a later tool
  can re-decode anything. About 100 more bytes a row; foreign payloads stay encrypted.

## 10. Mockups (approved choices, 2026-09-03)

Mockups reviewed at claude.ai/code/artifact/90e91f01-efa6-436f-82d3-288436bd0afc (private).
Choices: **row style A** (two lines: name and age, then `↓ now · best · avg` and the hears-you
state); the Data screen as drawn; the ride screen as drawn. The one-line style B and the "more"
line are rejected for now. Uplink wording stays `hears you N dB` / `heard you` / `—`.

Amended 2026-09-04: the `↓`/`↑` that led each figure is now drawn by the bars glyph in front of it
(`RepeaterSignalGlyph`, the arrow it already carries), not spelled in the string — the words are
unchanged, the direction is still stated, and the row is no wider for having gained the bars. Row
order stays most-recent-first and there is no "strongest" marker: both were re-raised on 2026-09-04
and re-rejected.

## 11. Next

Step 1 of §7 (the store) is the next piece of work, and it is the one that makes the data safe. It
touches only `MapperRawLog` and the capture producers; nothing on screen changes until step 4.

## 12. Progress

**Steps 1 and 2 built 2026-09-03** (uncommitted at the time of writing; app suite 2624 tests, the
five known unrelated failures only; MapperRawLog 51 tests, mapper package suites 132).

- `MapperRawSample.runID` is optional; new columns `pathHashes`, `rawHex`, `contentHash`,
  `messageID`; kinds `sent` and `observerSighting`; indexes on `(cellRaw, timestamp)`,
  `(repeaterHexID, timestamp)` and `timestamp`; retention 90 days and row-level (rows outside any
  ride expire too); `seq` is global across launches (`nextSeq()`).
- Store API: `fetchSamples(cellRaw:since:until:limit:)`, `fetchSamples(repeaterHexID:…)`,
  `fetchSentSamples(…)`, `setContentHash(messageID:contentHash:)`, `storageSummary()` (≈400 bytes
  a row, measured against a real store), `deleteSamples(olderThan:)`.
- The recorder exists whenever capture is wired, with no run; a ride only labels rows with its
  run id (`setRunID`). `MapperSentPacketLogger` (app target) writes `sent` rows from the message
  event stream and from adverts, and back-fills the content hash on the first echo. Probe
  transmissions stay `probeAttempt` rows.
- **Attribution follows §1**: direct-routed packets with a path credit no repeater (they still
  fold into the cell and write a row with `repeaterHexID` nil); 0-hop adverts credit the
  advertiser; echoes keep both ends. This already changes what the *current* card lists.
- The full export tier carries the new columns; the scrubbed tier is unchanged.

Deviations to know: `rawHex` is populated on `heard` rows only — echoes and probe replies carry
no packet bytes in the events the app receives; the size readout in Settings is step 5's; there is
no manual flood transmission in the app beyond messages and adverts.

**Step 3 built 2026-09-03** (MapperRawLog 80 tests; app suite unchanged at 2624 with the five known
failures).

- `MapperCellSummary`, a derived, rebuildable per-cell table in the MapperRawLog module: RX
  best/sum/count/last over rows with a repeater *and* a reading (direct-routed rows never feed RX),
  TX best/sum/count/last over probe replies, echo/probe/sent/heard counts, first/last. Folded on
  insert in the same transaction; rebuilt (never subtracted) for cells that lost rows to retention;
  `rebuildAllSummariesIfEmpty()` is the launch call (wired in step 4). One fold implementation
  serves insert and rebuild, and a test asserts the cache equals a fresh fold after inserts and a
  purge. The DTO has no coordinates, names or hashes, and is not Codable.
- `MapperCellQueries` over one cell's rows: `repeaterRows` (one per repeater heard directly:
  latest/best/average RX, RSSI, `hearsYou` from the latest reported `txSnr`, `heardYou` from echoes
  whose first hop is that repeater, `link(at:)`, 600 s freshness), `cellHeadline`, `reach` (distinct
  observers case-insensitively over `observerSighting` rows joined by content hash;
  `fetchObserverSightings(contentHashes:)` added). `probesAnswered` counts reply rows, not answered
  attempts — the probe tag is not a column — so a broadcast discover answered by several repeaters
  legitimately exceeds `probesSent`.

**Step 4 built 2026-09-03** (app suite 2645 with the five known failures; 21 new tests).

- The map reads `MapperCellSummary` through a pure `SignalMapperSnapshotBuilder`: Hear =
  `SignalQuality(rxBestSnr)`; Reach = reported quality when `txSnrCount > 0`, else `heardYou`
  (flat neutral fill with a brighter hairline — `MapOverlay` has no fill pattern), else `noReach`,
  else absent; weight = `heardCount` relative. Ride rings from the summaries: fresh when
  `firstAt >= run.startedAt` (3 pt), touched when `lastAt >= run.startedAt` (1.5 pt), fills dimmed
  while a run is open. The legend is back on the map (it had silently stopped rendering) with the
  All time / This ride lines and the two Reach swatches.
- The card is row style A over `MapperCellQueries.repeaterRows`, names resolved app-side, rows past
  10 minutes at 55 %, scrolls after three rows, This ride | All time while a run is open, no reach
  line yet (extension point marked). The Reach layer's row leads with `↑ hears you N now · best ·
  avg`, folded app-side from probe replies only. Tapping a row opens
  `SignalMapperRepeaterDetailView`: Swift Charts line (you hear it) + points (it hears you), then
  the raw rows, frozen at tap time. `SignalMapperCellDetailSheet` is deleted.
- The completion sheet counts hexagons, repeaters heard directly and probes from the run's rows.
- "Delete Captured Coverage" now also deletes the raw rows; the confirmation says so.
- The old aggregate writer still runs; only the reads moved. Launch order:
  `reconcileOrphanRuns` → `purgeExpired` → `rebuildAllSummariesIfEmpty`.

**Step 5 built 2026-09-03** (app suite 2658; MapperRawLog 89 tests).

- `MapperSampleFilter` (since/until/cellRaws/runID/repeaterHexID/kinds) with `countSamples`,
  keyset-paged `fetchSamples(matching:after:limit:)`, `distinctRepeaterHexIDs`,
  `deleteSamples(matching:)`, `latestRunID`.
- `MapperObservationExport`: CSV (RFC 4180, CRLF, 24 columns: seq, timestamp, kind, runID, cell,
  latitude, longitude, horizontalAccuracyMeters, fixAgeSeconds, payloadType, routeType, hopCount,
  pathHashes, repeaterHexID, repeaterName, repeaterPublicKey, rxSnr, rssi, txSnr, perHopSnrs,
  contentHash, txPowerDbm, rttMs, rawHex) and JSONL (same keys, nil omitted), streamed in pages of
  5 000 to the backup-excluded export directory as `mapper-observations-<date>.csv|jsonl`.
- Settings › Signal Mapper › Data (`SignalMapperDataView`): rows and size, oldest kept, keep-for
  30/90/180/365 bound to `MapperTuning.rawRetentionDays`; export with dates, This ride (by latest
  run id), repeater, kinds, format and a live count; the publish toggle disabled with the mockup's
  footer; delete-older-than behind a confirmation that states the count. Summaries rebuild on
  every delete.

**Empty-card field defect fixed 2026-09-04.** A ride HUD read "0:28 · 3 probes · 12 replies · 2
lost" over a cell card reading "Unknown", "0 readings of you" and "Nothing heard here this ride"
(Rafael's screenshot). Two independent causes, and a third defect found while in there.

*The two GPS gates disagreed.* The probe engine planned transmissions on its own `usableFix()`
(present, not moved, inside the flat `fixMaxAgeSeconds`); the capture engine placed the results on a
stricter test that also demanded horizontal accuracy and a speed-scaled age. During GPS warm-up —
the first minutes of every ride — probes flew, the HUD counted the replies, and every row they
earned was written with `cellRaw` nil. The store's cell fetch is an equality match, so those rows
were unreadable by the card and by the summaries **for ever**.

- **Owner decision:** record the position rather than throw it away. §2 gives the observation table
  `horizontalAccuracyMeters` and `fixAgeSeconds` precisely so a consumer can filter by quality
  later; dropping the row is the one choice nothing downstream can undo.
- `MapperFixGate` is now the single definition both engines read. Two nested verdicts: **placeable**
  (a fix exists, not moved-away-from, inside the flat age budget, resolves to a cell) and
  **confident** (placeable, plus the speed-scaled age budget and the accuracy limit). The probe
  engine plans on *placeable*, so if a probe is sent its reply can be placed.
- A raw row carries the placeable cell whatever the verdict, with `gateOutcome` beside it. Read a
  row as: confidently placed when `cellRaw != nil && gateOutcome == .accepted`, doubtfully placed
  when `cellRaw != nil` and the outcome is anything else, unplaced when `cellRaw` is nil. No new
  enum case, no schema change. `MapperProbePlacement` gained `outcome` so no reader can go on
  assuming acceptance, and the probe engine's raw rows stamp it instead of a hardcoded `.accepted`.
- The strict gate is untouched everywhere it was strict: the `(cell, day)` aggregate fold, the
  anchor discs, and the dead-zone `probesSent` denominator. `ingestProbeResult` treats a doubtful
  send placement exactly as it always treated a missing one (falls back to the current fix), so the
  aggregate path is unchanged bit for bit. Cell **summaries** do fold doubtful rows — a summary is
  by definition a fold of the rows that are there, and the cache-equals-fresh-fold invariant is what
  makes it trustworthy.
- The failure is loud now (ACTIVE_SURVEY_M3_5 §2.7): `SignalMapperRideSession.CaptureFixHealth`
  carries the capture engine's `droppedNoFix/Stale/InaccurateFixCount` as a **delta per sampling
  window** (a cumulative counter cannot say "right now", and the engine restarts on every rewire),
  sampled off the probe engine's snapshot stream. The strip's chip says "Fixes rejected" when a
  window placed nothing and a fix existed, and keeps "No fix" for the probe engine's own
  `skippedNoFixCount > 20`. The two counters are deliberately not merged.
- **Amended in the integration pass (2026-09-04).** The verdict was "this window dropped something
  and placed nothing", and a window is however long it was between two probe-engine snapshots —
  which is about two seconds, and which any bursty mesh satisfies several times a minute. The chip
  and the card's empty-state reason both hang off it, so both blinked through healthy rides. The
  refusal now has to be *sustained*: `CaptureFixHealth` carries `rejectingSince`/`lastRefusalAt` and
  only announces once the run spans `sustainedRejectionSeconds` (10 s). Measured refusal to refusal
  rather than against the wall clock, so silence cannot age one bad fix into an alarm; a window that
  places anything clears the run outright, and an engine rebuild re-seeds it. `isQualityRejection`
  became a property of the run rather than of the last window, so the chip does not change its mind
  about which problem it is describing mid-run. Covered by `SignalMapperCaptureFixHealthTests`,
  which the original had none of.

*Nothing refreshed the card when rows landed.* `MapperRawLogStore.rowArrivals()` is an
`AsyncStream<Void>` per subscriber, yielded once per `insertSamples` batch **after** the save (never
inside the transaction), buffering the newest signal only. `SignalMapperCoverageModel`
`observeRowArrivals` wakes on it, sleeps 750 ms so a burst collapses, then rebuilds the card through
`reloadCard` directly — not through `setCardTarget`, whose unchanged-target guard exists to stop a
re-render clearing the card mid-fetch. The map rebuild (`reloadMap`, split out of `load`) is limited
to once per 5 s. The timer is now the belt rather than the braces: `autoRefresh` loads *first* and
sleeps after (it slept before its first read), and the riding cadence is 10 s. The live card also no
longer waits for a summary — `SignalMapperMapCell.placeholder(_:)` gives a just-entered hexagon
geometry and no claims, same `cell` id, so the real cell replaces it without re-identifying.

Raising the card's rebuild rate from twice a minute to once every 750 ms took
`resolutionCandidates` up with it, and that is two unbounded SwiftData fetches queued on the same
actor the ride's own recorder writes rows through. The pool answers "what is this repeater called",
which changes on a minutes-scale event, so it is now held for 20 s and keyed by radio (integration
pass, 2026-09-04).

*The reply-only repeater.* `MapperCellQueries.repeaterRows` passes 2 and 3 folded with optional
chaining, so a repeater that reported an SNR for us, or that an echo proves heard us, produced **no
row at all** unless we had separately measured it — silently deleting the asymmetry the card exists
to show. All three passes mint rows now. `MapperRepeaterRow` gained a non-optional `lastEvidenceAt`
(sorting and `isStale` read it) and made `lastHeardAt`/`rxLatest`/`rxBest`/`rxAverage` optional, nil
meaning *never measured*. The card prints "not heard directly here" on Hear and an em dash on
Reach's trail rather than inventing 0 dB; the repeater detail drops its observations section when no
row in the hexagon is about that repeater. A direct-routed packet still credits nobody and a middle
hop still credits nobody.

*Honest empty state.* `SignalMapperCardEmptyReason` distinguishes "nothing captured yet this ride"
(the ride total is zero), "nothing heard here this ride" (this hexagon only) and "GPS too poor to
place anything here" — one short line, chosen in that order of blame.

Tests: `MapperCellQueriesTests` (reply-only and echo-only rows, `lastEvidenceAt` sorting/ageing, a
doubtful row read back like any other), `MapperCellSummaryTests` (doubtful placements fold and the
cache still equals a fresh fold), `MapperRawLogStoreTests` (empty batch announces nothing, rows
readable when the signal lands, every subscriber hears every batch), `SignalMapperFixGateTests`
(accuracy-only and speed-stale fixes place their raw row and fold nothing; no-fix and moved-away
place nothing; placeable == plannable), `SignalMapperProbeEngineTests` (a probe planned on a
doubtful fix writes attempt and reply rows that carry a cell), `SignalMapperCardBuilderTests`
(reply-only repeater with an uplink and no downlink) and a new `SignalMapperCoverageModelTests`
(arrival rebuilds the card past the unchanged-target guard; a burst collapses to one rebuild; a
summary-less hexagon still gets a card).

**Ride chrome and row strength, 2026-09-04** (three complaints from Rafael, all on the ride screen).

*"The discover, trace and flood buttons take up too much space."* `SignalMapperTransmitBar`'s three
pills are a `ViewThatFits` over two candidates — the same three buttons, labelled and icon-only —
so a 393 pt phone gets glyphs where it used to get "Dis…" and iPad keeps the words. The
`ViewThatFits` wraps the buttons **only**: the row's trailing spacer is infinitely compressible, so
a candidate measured with it in scope would always "fit" and the fallback would be dead code. The
words are still the accessibility labels. The verdict caption ("Sent" / "Refused") moved into a
zero-layout overlay on that spacer, because it used to change the panel's height, and the panel's
height is what the ride camera insets by — a manual send moved the map.

*"Hide the signals pill while surveying."* **Owner decision:** the pill only, not the navigation
bar. Hiding the bar would take the title, both menus and — with the tab bar already hidden for a
ride — the only way off the screen. `radioStatusToolbarItems(placement:isHidden:)` keeps the
`ToolbarItem` declared and `RadioStatusControl` mounted and unmodified (the hosted-toolbar identity
rule that dee5cb65 and 7696caf5 both turn on), and hides it as a *value*: zero width, zero opacity,
no hit testing, hidden from VoiceOver. `ToolDestinationView` decides it, so it is scoped to this
tool and to a running ride; every other screen keeps the pill and the connection route it carries.
The one datum the pill held that no cell card can — the adaptive-power step — is now a chip on the
live strip, gated exactly as the pill gates it (`isEnabled`, same red/orange/green rule) and spoken
in the strip's own accessibility label, because the strip's button hides its children.

*"A better way to visualize the different signal levels from each repeater inside a cell."* Visual
weight, not more text. Each row gained the app's existing bars glyph on both legs and a 3 pt rail of
the row's colour down its leading edge. Both are `accessibilityHidden`; the numbers are unchanged
and still read out. Two rules make them honest:

- **One scale.** `SignalQuality.barLevel` bridges SurveyKit's six steps onto `cellularbars`, and
  `RepeaterSignalGlyph` gained a `coverage:` entry point beside its `SNRQuality` one (it now holds
  the level and the colour rather than an enum, so neither scale is privileged). The card grades on
  the six-step scale because that is what the hexagon under it is painted with — the four-step scale
  folds `excellent` and `good` into one green, so a mint hexagon would have drawn green bars.
- **One number.** Both the glyph and the rail grade `best` — the number the hexagon is coloured from
  — even though the sentence beside them leads with `now`. The rail follows the layer on screen
  (downlink on Hear, uplink on Reach) or it would contradict the leg its own row leads with. An
  uplink with nothing reported is `unknown` and draws `↑?`; it never borrows the downlink's value.

Also: `SignalMapperPreviewFixtures` gained rows covering every step of the scale and a reply-only
repeater, so one preview shows all six rail colours and both uplink glyph states.

Tests: `SignalMapperRowStrengthTests` (six distinct bar levels, bar level agrees with rank, the rail
reads the layer's own leg, an unreported uplink is unknown rather than the downlink, a row's rail
equals the hexagon its own reading would paint).
