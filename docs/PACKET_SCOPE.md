# Packet Scope — per-message observer coverage

Branch: `feature/packet-scope` (off `v2`). Status: v1 data layer + on-demand UI, 2026-08-31; coverage map with route draw-in, 2026-09-01.

The chat can ask a [CoreScope](https://github.com/Kpa-clawbot/CoreScope) observer
network (default: the AUS instance at `scope.digitaino.com`) what the mesh saw of a
message's packet: which observers heard it, at what SNR/RSSI, via which repeaters.
That is ground truth no phone or radio can see alone — the "did it actually get
out, and how far" answer.

## The join key, and why it is not `packetHash`

CoreScope groups observations under the **firmware content hash**:

```
SHA256( payloadTypeNibble ‖ [rawPathLenByte, 0x00 if TRACE] ‖ payload-after-path )[:8] → 16 lowercase hex
```

Route bits, version bits, transport code and path are all excluded, so every node
and observer that hears one transmission — through any path — derives the same
value (CoreScope `cmd/server/decoder.go ComputeContentHash`, which follows the
firmware; their issue #786 is why the full header byte is *not* hashed).

**Exception: TRACE.** Its raw path-length byte *is* folded in (as LE16, matching
firmware), and that byte changes at every hop — so TRACE packets are deliberately
**not** hop-invariant. Harmless here, since a TRACE never becomes a chat message,
but the "same value everywhere" rule above does not cover it.

The app's pre-existing `ParsedRxLogData.packetHash` is `SHA256(payload)[:8]` — no
type nibble — so it **never matches** observer-side hashes. It stays as the local
heard-repeats correlation key. The mesh-wide key is the new
`ParsedRxLogData.contentHash` / `RxLogEntryDTO.contentHash`.

Verified against live captures: `MeshCoreTests/ContentHashTests.swift` pins eight
real packets to the hashes the AUS observers computed for them — covering all four
route types (both transport-code routes, whose 4-byte code must be skipped), one
packet heard via two different paths, and a TRACE with a **non-zero** path-length
byte. The non-zero TRACE matters: with a zero byte, the implemented `[plb, 0x00]`
is indistinguishable from `[0x00, plb]`, a constant `[0x00, 0x00]`, or folding the
*decoded* hop count, so the original zero-byte fixture pinned nothing.

Beyond the fixtures, the formula was replayed against **3000 consecutive live
packets** spanning every route and payload type on the mesh: 3000 matches, 0
mismatches (2026-09-01).

## Where the hash lives

`Message.packetContentHash` (+ DTO, backup wire format — additive, legacy
envelopes decode to nil). It is copied out of the RxLog correlation **at ingest**
because RxLog entries are pruned (keepCount 1000) — within hours on a busy mesh.

- **Incoming (DM + channel):** `SyncCoordinator.lookupRxLogEntry` already
  correlated the message to its RxLog entry and threw the hash away; it now rides
  `RxLogLookupResult.contentHash` onto the row — **from the exact-timestamp match
  only.**
- **Not from the DM sender-prefix fallback.** That branch matches on a one-byte
  sender prefix inside a 30-second window and never checks the recipient, so it can
  land on a DM between two other people this radio merely overheard, or on an
  unrelated sender colliding 1-in-256. Every other field it fills is cosmetic and
  stays local if wrong; the content hash is the one value that *leaves the device*,
  and stamping a stranger's packet identity would both misreport coverage and POST
  a third party's packet to the observer network. It returns nil instead: a DM
  whose exact correlation missed simply gets no Network View.
- **Never from an ambiguous legacy row.** `payloadTypeBits` postdates the RxLog
  table and lightweight migration defaults old rows to 0, which is
  indistinguishable from a real REQUEST. `RxLogEntryDTO.contentHash` returns nil
  rather than minting a confidently wrong hash into a column that lives for years
  with no repair path.
- **Outgoing channel:** the phone never sees its own on-air bytes (the radio
  encrypts and assembles), so there is nothing to hash at send. But a repeater
  echo is byte-identical after path stripping — `HeardRepeatsService` stamps the
  echo's hash onto the sent message, first writer wins
  (`setMessagePacketContentHashIfMissing`).
- **Outgoing DM:** no echo correlation exists today → no hash, no Network View
  row. Candidate v2: hash the *expected ACK packet*
  (`SHA256(ackNibble ‖ expectedAck CRC)[:8]`) to watch the delivery confirmation
  propagate — needs a fixture test against a real ACK before promising it.

**Retries stamp one attempt, not all of them.** A retried message puts N distinct
packets on the air with N hashes, and `findSentChannelMessage` matches every
attempt's echo to the same row. First-writer-wins therefore records whichever
attempt's echo *arrived* first, which need not be attempt 1. Rather than pretend
otherwise, the view says so: when `sendCount > 1` the footer notes that each
attempt is a separate packet and this is the one an observer heard first.

## The API (verified live, 2026-09-01)

Public read, no auth, passes Cloudflare from URLSession. The client uses two
endpoints. `POST /api/packets/observations` with `{"hashes":[...]}` →
`{"results": {hash: [observation…]}}` is the lookup. `GET /api/observers` →
`{"observers":[…]}` is the roster — `id`, `name`, `iata`, `lat`/`lon` (null for
most: 7 of 16 AUS observers publish a position), plus telemetry the app ignores.
The roster carries nothing about the user; it is fetched once per open of the
Network View so located observers can be the far end of a route on the map.

Observation rows carry `observer_id`,
`observer_name`, `observer_iata`, `snr`, `rssi`, `path_json`, `resolved_path`,
`timestamp` (ISO 8601 with *and* without fractional seconds — parse both),
`raw_hex`. A hash absent from `results` means no observer heard it.

Sharp edges, all confirmed against the live instance:

- **`resolved_path` elements can be `null`** — ~30% of hop slots, and ~14% of
  observations omit the field entirely. It is positionally aligned with
  `path_json` (0 length mismatches measured). The element type **must** stay
  optional: decoding a null into `[String]` throws, and that failure takes down
  the whole batch response, not one row.
- **Observer ids differ in case between endpoints.** The roster reports them in
  uppercase hex, observation rows in lowercase. `PacketScopeObserver.id` is
  normalised to lowercase and the map lowercases the observation side before
  joining; without that, no observer would ever be placed.
- **`rssi: 0` means "not reported"**, not a 0 dBm reading.
- **One observer appears many times** — it hears the same transmission by
  different routes. Measured: 25 observations from 9 observers for one packet, up
  to 4.4× per observer; across 400 packets, max 40 observations / 10 observers.
- **Server cap is 200 hashes** per batch (401 → HTTP 400). This client caps at 100
  as a runaway guard; nothing caps the *response*, so it truncates at 500 rows.
- **No rate limiting server-side, anywhere.** Pacing is entirely the client's job.
- **`Cache-Control: no-store` on every route**, no ETag — every poll is a full
  transfer. Server-side TTLs still mean a fresh response ≠ fresh data.
- **`X-CoreScope-Load-Status: loading`** means the store is still warming and the
  data is incomplete.
- **No API version exists.** Empirically additive across releases, but there is no
  contract header to pin.

## Privacy stance

A content hash is exactly the "cross-mesh join key" the M3.5 mapper review banned
from the ride log (`docs/ACTIVE_SURVEY_M3_5.md`, enforced by
`MapperRawLogPrivacyInvariantTests`). Chat is a different bargain — the user asks
about *their own* messages — but the rules here are:

- **Opt-in, default off** (`packetScopeEnabled`), link-previews pattern; the
  settings footer says exactly what is sent.
- **The server URL is device-local** — deliberately *not* in `BackupUserDefaults`.
  Restore writes keys the device does not already have, without prompting, so a
  backed-up destination would let a crafted backup silently aim packet hashes at a
  host of its choosing. The toggle round-trips (it is a preference); the
  destination does not, so a restore always lands on the default instance.
- **No cross-host redirects.** A 307/308 preserves method *and body*, so without
  `PacketScopeRedirectGuard` the configured server could bounce the hash payload
  to any other host. Same-host redirects still follow; downgrades to http do not.
- **Enforced in `PacketScopeService`, not the views** — a disabled service throws
  before any request; no future call site can bypass the gate.
- **User-initiated fetches only**: opening the Network View sheet (which then
  live-polls briefly for a fresh message). Rendering a conversation never fires a
  request.
- **Only validated 16-hex hashes** ever reach the wire; HTTPS only; the base URL
  is user-configurable (`packetScopeBaseURL`) since coverage is per-instance.
- The mapper's raw-log ban is untouched and must stay: `MapperRawLog` rows carry
  no packetHash *and* no contentHash, ever.

## UI

`MessageActionAvailability.canViewPacketScope` (opt-in AND hash present) gates a
"Network View" row in the message actions sheet → `PacketScopeDetailView`,
presented as a full-screen cover like the path and repeats screens (a sheet's
swipe-down would fight panning the map). It polls every 6 seconds while the
message is under 3 minutes old, and lays itself out one of two ways:

- **Coverage map** (`PacketScopeCoverageBuilder`, `MessagePathMapCanvas`) when
  anything beyond the origin can be placed, with the observer panel floating
  over it in the path screen's glass panel.
- **List** otherwise — loading, unheard (the *unobserved ≠ undelivered* empty
  state), or heard only through repeaters and observers this phone cannot
  place. Same rows, same selection, in a `List`.

**The first version of this screen was rejected on a real mesh (2026-09-01):
"the map looks a bit crowded" and "the observers view is a wall of text".** An
adversarial review (three reviewers: map rendering, panel information design,
interaction model) found the causes — one polyline per route redrew shared
trunks N times, a badge per route piled ~20 pills on ~9 numbers, half the
routes ended on a repeater pin because their observer had no location, nothing
on the map was tappable, every arrival re-fit the camera, and the panel listed
every route as prose with the measured hop ellipsised away. The redesign:

**Map, default state.** The substrate is every *link* the packet crossed —
origin → hop, hop → hop, placed tail → observer, or origin → observer when
heard directly — drawn **once** through the map's weighted-overlay API with the
traffic heatmap's paint (systemBlue, width 1.5…6, opacity 0.3…0.9, white
casing), weight = routes crossing it ÷ the busiest link. The trunk everyone
heard through reads fat; a one-off spur reads thin. Links are never coloured
by signal: nothing in the data says how well an intermediate repeater heard
the packet. On top, exactly **one SNR-styled leg per located observer**: the
measured leg (tail hop → observer, or origin → observer when direct) of its
strongest route, straight. No badges. Pins carry names only: the observer
pin's label is its name (a label that changed with every poll minted a new
sprite and re-sourced every pin each time, to state a number the row and the
leg's badge already carry), and repeater pins are named but **not numbered** —
a repeater sits at different positions in different routes, so any global
number is wrong for all but one of them; numbering is a property of a focus.
Name pills are placed with `labelPlacement: .collide`, so MapLibre arbitrates
the pills that would overlap by `MapPoint.labelPriority`: origin (0) never
drops, observers (10 + strength rank) beat repeaters (1000).

**Placement rules** are the heard-repeats map's, with the observer where "us"
used to be. Origin: an outgoing message started at its send-time stamp, else
the live best location; an incoming one at its sender, pinned only when the
sender resolves to one located contact. Hops pin only when they resolve to one
unambiguous located repeater — the server's `resolved_path` full key first (a
full key cannot collide, so a hop whose 1-byte hash matches two known
repeaters still pins when the server names one this phone knows), then the
shared short-hash rule. **A gap is a gap:** a link is counted only between
points adjacent in the path, and a route's body splits where a hop could not
be placed, rather than bridging with a link nothing in the data says exists.
An observer without a location contributes nothing to the default state — its
row says "No location" (only once the roster has actually loaded; an empty
roster says nothing about anyone). Selecting it still draws the bodies of its
routes up to their last placed hop, since that is what is known. Pin ids derive from what the pin stands for (SHA-256 of
`origin` / `hop:<key>` / `obs:<id>`), so a poll that changes nothing
re-sources nothing.

**Focus.** One value governs the map and the panel: `PacketScopeFocus` is
`.all`, `.observer(id)` or `.route(observerID:routeID:)`, so "a route selected
under no observer" cannot be represented and every entry point writes the
same thing. Entry points: an observer's row or its pin (toggles), a route row
in the ladder (a hop pill inside it too), a "distance · SNR" badge on the map
(`onBadgeTap`), the breadcrumb crumbs, the focus bar's ‹ / › steppers, and a
tap on the map background, which pops **one** level (route → observer → all)
so a stray tap while panning costs one recoverable step. `✕` in the focus bar
and the `All` crumb clear in one tap. Repeater hop pins are inert by design
(a focus axis reachable only from a map pin would be unreachable to
VoiceOver); on this screen a tap on one is routed to the map tap, so it pops a
level like the background does.

Focus is a **filter that removes, not a dimmer**. Routes of one observer share
their leading segments by construction, so three "dimmed" copies at 0.2
composited to ~0.5 and cancelled the contrast the model depended on;
`MapLine.opacity` no longer appears on this screen. Rules
(`PacketScopeCoverageBuilder.geometry(for:in:)`, pure, tested):

- **Route focus** draws only that route's `soloSegments` — bodies in
  `.messagePath`, the measured leg **straight** with the house chord-midpoint
  badge — and only its links in the `scope-links` overlay; every other link is
  dropped. Its placed hops take the `.repeaterRingWhite` sprite numbered by
  their **true path position** (a gap in the numbers is exactly where a hop
  could not be placed); every other pin recedes to `MapPoint.recessedEmphasis`
  with no label. The camera frames origin + placed hops + observer.
- **Observer focus** draws its drawable routes in full, fanned as before, with
  exactly one badge (the best route's); the links they use stay at full paint
  and the rest recede to a casing-less `scope-links-context` overlay. With one
  drawable route its hops number as in route focus; with several, positions
  conflict and the pins stay plain.
- **Where nothing can be drawn** — an observer with no published location whose
  repeaters could not be placed either, roughly half a real instance's
  observers — the map is left **exactly as it was**, the camera does not move,
  and the panel says why (`notOnMapRoute` / `notOnMapObserver`). The builder
  publishes `drawableRouteIDs`, so a route row shows `mappin.slash` **before**
  the tap and the panel and the map can never disagree. The builder no longer
  drops routes with no drawable segment (that mismatch between the ladder and
  the map was the mechanical cause of "I tapped and nothing happened").
- A focused route with a body but no drawable leg (the unlocated observer's
  case) gets a readout badge at the body's end carrying its dB, so two routes
  that differ only in unplaceable tails still read differently; the body is
  **not** recoloured — SNR colour means "the observer measured this hop", and
  nothing measured it. Badge text stays digits and units (the glyph server
  has one font); every sentence lives in the panel.

**Camera.** A focus owns the camera while it exists (`cameraFocus` on the
canvas): every automatic re-fit — the poll-driven `pathSignature` fit and
both style-load fits — yields to it, and to a user who has panned
(`onUserCameraMove`; `isCenteredOnUser` cannot serve, since a gesture sets it
to *false*). The focus id embeds a digest of the framed coordinates, so a poll
re-fits only when a hop finally resolves. One settle re-fit 350 ms after the
focus fit, because the panel's height is reported after layout. Reduce Motion
suppresses camera animation in the shared map view.

**Order stability.** Entering a focus freezes the panel's order — observers and
each ladder — for the life of the focus; new observers append at the tail with
their `New` chip. A poll therefore cannot move a row or re-rank a ladder under
a reaching finger. **Deliberate trade, freshness for stability:** during a
focus the `BEST` chip can disagree with row order. A sort change re-freezes
around the new order and scrolls the focused row back into view.

**Cost of a focus change.** Pin ids are content-derived, but
`updatePointSource` compares the whole array and replaces the source wholesale,
so a focus change is one re-source of the fixed point set (~35 features). That
is cheap because label sprites are cached by name — toggling a label off and
back on mints nothing.

**`.collide` acceptance check.** Collision mode enrols our pills in the style's
single collision index alongside the basemap's own label layers. MapLibre
Native places layers in reverse render order, so ours — added last — should
take priority; that is a runtime property of the vendored binary, not
provable here. **Verify on device over downtown Austin at the metro fit that
the origin and observer pills draw.** If basemap labels ever suppress ours, the
bounded fallback is: in `updateLabelPlacement`, when switching to `.collide`,
set `iconIgnoresPlacement` / `textIgnoresPlacement` on every symbol layer the
app does not own. That removes basemap labels from the index without hiding
them, and a style reload undoes it.

**Panel.** A fixed shape in every state, so nothing appears or disappears
under the thumb: `Heard by 9` + the sort menu (icon plus the current option;
"Farthest" is offered only when something has a distance), then the breadcrumb
(`All › SOCO T1000e › via …`, always present, each crumb a target), then —
with nothing focused — `best 12.2 dB · shortest 2 hops · farthest ≥ 23 mi ·
4 heard directly · still arriving` (farthest is a lower bound whenever a
heard observer has no location) and the one line that teaches the model. In a
focus, a **focus bar** follows: the route's hops as numbered pills (an unplaced
hop wears `mappin.slash`) or the observer's name; the figures (`13.8 dB · 2
hops · ≥ 12 mi drawn · heard by 3 observers by this path · +1.4 s`); a caveat
only when there is one; and ‹ › (step through the frozen ladder, wrapping
across observers), an observers toggle (a true full-map view is its second
tap), and ✕. The panel has a **total height budget** (45% of the screen; 30%
in route focus, which keeps the tapped row and its ladder on screen while the
map gains height; 0 with observers hidden) and the list gets what the header
leaves, so a focus never takes room from the map.

Rows are two lines: signal bars (`cellularbars` at `SNRQuality.barLevel`, the
repeat-row idiom), name, seconds after the first observer (`+1.3 s`, not a
wall-clock time that reads the same on every row), and chips — dB, hops, `×3`,
`No location`, distance from origin. The ladder's RSSI line is labelled as
what it is — the observer's **best** RSSI, a separate reception's maximum.
Route rows are 44 pt, two-line cells: a persistent leading glyph that states
the consequence before the tap (`mappin.and.ellipse` when the map can draw the
route, `mappin.slash` when it cannot), the hops as **wrapping** numbered pills
(no nested horizontal scroll view competing with the tap), then a `Best route`
chip, the dB in its quality colour, the hop count, and `+N hops not on the
map` when the tail is unplaced. Selection is never colour alone: a leading
accent bar and weight carry it. Sort: strongest (the fold's order), fewest
hops, first heard, farthest. Every focus transition is announced to VoiceOver
— branched on drawability, so "Showing the route to X" is never said of a map
that did not change — and the map carries the same sentence as its
accessibility label. Haptics: selection on focus, light impact on ‹ ›, success
on the first load and on Copy summary (toolbar; plain text built from the
summary, the rows and the resolved names only, so the packet identifier is
not even in scope).

**Arrivals.** The first successful fetch draws at once. What a later poll adds
— new links, new observer legs — animates over 0.5 s (links thicken from
nothing, legs grow from their tail) and the observer's row wears a `New` chip
for 20 s. Reduce Motion keeps the chip and skips the animation. Route and pin
identity are stable, so re-resolution never re-draws.

**Canvas additions** (`MessagePathMapCanvas`, all defaulted, siblings
untouched): `overlays`, `cameraCoordinates`, `onPointTap`, `onMapTap`,
`cameraFocus`, `labelPlacement`, `onBadgeTap`, `accessibilitySummary`. Shared
map-layer changes underneath, all inert for existing callers: the path and
trace line layers honour the per-feature `segmentOpacity`; `MapPoint.emphasis`
(1 or 0.25, discrete, part of `==`) and `MapPoint.labelPriority` are emitted as
feature attributes and bound as icon/text opacity and as the collision sort
key; `MapLabelPlacement` (`.overlap` is byte-for-byte the old placement);
badge pills now follow their text's overlap flags; pin icons are hit-tested
inside a 44 pt square with nearest-wins, name pills as an exact-point probe
after them, and `.badge` points never count as pins; `onUserCameraMove`;
Reduce Motion on every programmatic camera move.

Known minor behaviours, reviewed and left: a newly heard link appears at the
ramp's minimum width and thickens rather than growing from nothing (the
observer leg's draw-in and the `New` chip carry the arrival). An arriving link
or leg draws in every focus state, so the `New` chip never advertises
something the map hid.

Deferred, deliberately: an always-on footer chip ("heard by N") on bubbles would
require persisted observation summaries plus `MessageItem` rebuild plumbing (the
bubble is `Equatable` on its item) — and auto-fetching per rendered message is
exactly what the privacy stance rules out. Revisit only with a design that keeps
fetches user-initiated.

Also deferred, with the trade-offs recorded (2026-09-01):

- **Repeater focus** (tap a hop pin to filter to every route through it). A
  third focus axis reachable only by tapping a map pin is unreachable to
  VoiceOver, and it needs its own panel filter, focus-bar figures, builder
  index and strings. Revisit with map accessibility, and give it a panel-side
  entry point (a "via <repeater>" affordance on the focus bar's hop pills).
- **Line hit-testing on the map.** Needs a per-feature `lineID` on every line,
  a rect query with nearest-polyline ranking, and a builder-published
  `focusByLineID` map — `routeID` is `"observerID|hops"` and both halves can
  contain `-`, so no prefix or suffix parse is safe. The rows, the observer
  pins and the badge tap already cover its entry points.
- **Per-route timestamps / RSSI on `PacketScopeReception.Route`.** Only a
  per-route RSSI line would have needed them; RSSI stays observer-wide and is
  labelled as its best. Three more stored properties on a `Hashable`
  wire-folded type would churn equality on every poll.
- **A heavier `MapLine.LineStyle` for the focused route.** Once focus removes
  the competing lines the focused route is the only line on the map. If a
  metro-wide fit later proves it unreadable, insert it above `lineMessagePath`
  and below `lineTraceUntracedCasing` — never above `lineTraceGood`.
- **A `MapPoint.PinStyle.observer` sprite.** `.pointB` is the deliberate
  choice; a new style needs registration in `allSpecs` before `renderAll`.
- **A shared floating panel with detents** across this screen,
  `MessagePathDetailView` and `HeardRepeatsMapView`. The largest blast radius
  proposed anywhere, and a grabber on a cover risks stealing the pan or
  reintroducing dismissal. The height budget stays local.
- **Dark-mode label pills and Dynamic Type on map label sprites.** Both real
  gaps; each deserves its own change.
- **Map pins as accessibility elements.** The right eventual fix; frames must
  be recomputed on the debounced `regionDidChangeWith`, never on
  `mapViewRegionIsChanging`. The interim is complete: announcements branched
  on drawability, the map's `accessibilitySummary`, and a panel from which
  every focus is reachable by row.
- **`stringsdict` plurals** for `heardBy` / `hopCount`. Needs real plural
  categories from a translator for pl/ru/uk; the singular-key precedent
  (`hopOne`, `routeOne`, `tailUnknownOne`) covers the common case.
- **Observer noise floor / IATA on the map.** `WireObserver` decodes only
  id/name/iata/lat/lon; noise floor is server work plus a schema change.
- **A tappable reach histogram or a propagation timeline.** A second filter
  axis would fight the single-focus model; the timeline re-encodes the `+1.3 s`
  offsets the rows already show.

- **Pinning repeaters this phone has never heard** from the server's node
  table. `GET /api/nodes/{pubkey}` is ~80 KB per repeater (it embeds 20 recent
  adverts); the full `GET /api/nodes?limit=500` is 286 KB. Worth it only with a
  slimmer endpoint or a cached roster; today the map is a lower bound, like the
  path screen's polyline.
- **Colouring legs by link history** from `GET /api/nodes/{pubkey}/reach`
  (~12 KB per repeater, cached 5 min server-side: we-hear / they-hear counts,
  bottleneck direction, bidirectional flag, coordinates inline). One request per
  hop on the route, user-initiated by the map opening, through the same gate.
- **The websocket firehose** (`/ws`, every packet with hash, observer, SNR,
  path, resolved path; non-browser clients pass its origin check). Sub-second
  updates, and filtering by hash locally would mean the server never learns
  which packet the user cares about — but it is every packet on the instance,
  ~5,300/hour with several observations each. The 6 s poll-diff covers the
  live window well enough to leave this alone.
