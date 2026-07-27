# DigitainoMesh v2 — migration plan onto upstream v1.3.0

Scope agreed 2026-07-27. Keep set: B1–B3, P1, T1, K1, Y1, C1–C4, C6, C7, O1, O3, I1, I3.
Dropped for now: all survey/crowdsource (S*), weather (W*), route sharing (R*), repeater
identity as a *feature* (N*), C5, C8, O2, I2. A redesigned signal mapper (app + server)
comes later and this plan keeps the door open for it.

Guiding rule, per Rafael: **no 1:1 copying.** Old code is a reference implementation and
a source of test cases, not a source of files. Every feature lands on upstream's current
architecture, built on shared subsystems, with tests. One solution per problem, reused
everywhere.

---

## 1. Rebase strategy: don't rebase — rebuild on a clean base

A literal `git rebase` of 254 fork-only commits onto v1.3.0 is the wrong tool:

- Upstream rewrote the ground under most of them (MapKit→MapLibre, the chat pipeline,
  LOS moved, onboarding redesigned). The conflicts wouldn't be resolvable line-by-line;
  they'd be re-implementations done inside conflict markers — the worst place to do them.
- We're deliberately dropping ~70% of the fork diff. Rebasing pays full conflict cost for
  commits we intend to throw away.
- Both sides rewrote `MeshCore` heavily (our diff vs upstream there alone is
  +17.8k/−22.5k). Merging that package is hopeless; porting our protocol deltas is easy.

**Branch plan:**

1. Tag the current state: `legacy/v1-final` on `feature/survey-v2` (and keep `personal`
   as-is). This is the permanent reference tree.
2. Create `v2` from `upstream/main` @ `3cd08543` (v1.3.0). This becomes the new mainline;
   `main`/`dev` get reset to it once v2 reaches parity on the keep list.
3. All porting happens as fresh, small PRs into `v2`. When a piece of old code is genuinely
   clean and self-contained (see §4), bring it over with `git checkout legacy/v1-final -- <path>`
   and adapt — that keeps authorship honest without pretending it's a merge.
4. Keep `upstream` as a remote and track it continuously from day one — small frequent
   syncs instead of another 4-month divergence. Adopt upstream's `.swiftformat`, `Makefile`,
   `ci/` instead of deleting them this time; add fork CI on top rather than replacing.

The 65 commits upstream already absorbed (BLE/pairing/DM hardening) need nothing — they're
in the base.

---

## 2. Shared subsystems first (the cohesion layer)

These are the "build once, use everywhere" pieces. Every feature in §3 consumes them;
none may roll its own. Build each as an isolated, tested unit before any feature UI.

### 2.1 NodeIdentity (new, distilled from legacy `RepeaterHexID` + resolver)
Even though N1–N3 were dropped as *features*, hex-ID handling is a load-bearing dependency
of the keep list: `SignalBarsService`, `RepeaterSignalListView`, `SignalBarsToolbarItem`,
the traffic heatmap's hop resolution, benchmark targeting, and O1's pubkey/hex search all
touch it. Legacy sprinkled prefix-matching logic ad hoc (e.g. `hasPrefix` both directions
inline in views).

- One value type + one resolver protocol in `MC1Services`: normalize, compare, prefix-match,
  resolve hash→contact with recency bias. Nothing else in the app may string-compare hex IDs.
- Port the legacy unit-testable core; drop the disambiguation UI (that was N2's feature
  surface, deferred).
- This is also the seed the future signal mapper will need — design its API without survey
  assumptions.

### 2.2 NodeSearch (new)
One search engine powering: O1 (contacts by name/pubkey/hex prefix), C1 (message search,
global + in-conversation), and every picker (benchmark target, watch target, path-hash
quick picker). Legacy had three separate ad-hoc implementations.

- `MC1Services` service over `PersistenceStore`: typed queries (`.contacts(matching:)`,
  `.messages(matching:in:)`), strict-hex detection, pubkey-prefix priority — the legacy
  ranking rules become test cases.
- Message search goes through upstream's persistence store as store-level queries
  (port the `MessageSearchResult` model + `PersistenceStoreProtocol` additions pattern),
  not in-memory filtering.
- One reusable UI component set: search field + result row + highlighter
  (`MessageSearchHighlighter` logic is portable; re-skin to upstream's design language).

### 2.3 Map layer (MapLibre, extend upstream — do not build a second map stack)
Upstream's `MC1MapView` / `MapCanvasView` / layer system is now the app's map system.
Rule: **zero `import MapKit` in v2 app code.** Only T1 needs a map in this scope, but the
future signal mapper is the real customer.

- Add a generic overlay contribution API to upstream's map (`MC1MapView+Layers` already
  exists — extend it): heat/segment/annotation layers that any tool can register.
- T1's segment rendering is the pilot; hex-cell heat rendering for the future signal
  mapper becomes a second consumer of the same API, not a new map.

### 2.4 Chat integration points (adopt upstream's architecture wholesale)
Upstream chat is now `ChatCoordinator` (+Registry, +Mutations, +Rebuild, +Reload),
`ChatSendQueueService`, `ChatTimelineWriter`, `DraftStore`, AsyncStream events. All chat
features (C1–C4, C6, C7) are implemented **inside** this architecture. Legacy
`ChatViewModel`/`ChatTableView` code does not come across (C5 was dropped — hold that line;
don't let fragments of it sneak back in with C2/C4).

### 2.5 Protocol layer (MeshCore deltas, re-ported cleanly)
The fork added firmware wire support that the keep list depends on: signal-bars
request/response (`SignalBarsBlob`), tapback wire format, notification-prefs blob
(`NotifPrefsBlob`), and the binary commands in `PacketCodes`/`PacketBuilder`/
`MeshCoreSession`/`RequestContext`. Re-port these as small, isolated additions to
upstream's MeshCore — one PR per wire feature, each with its parsing/round-trip tests
carried over. The blob codecs themselves (`SignalBarsBlob`, `NotifPrefsBlob`) are clean,
tested, dependency-free — carry-and-adapt candidates.

### 2.6 Component library (shared UI kit)
Fold O3 and the reusable bits of legacy components into one place, restyled to blend with
upstream's v1.3.0 design (which now has themes — components must be theme-aware):
`NodeKindBadge`, `MiniSparkline`, `StatusPill`, `CapsuleBadge`, `CountBadge`, swipe-action
modifiers. Anything used once doesn't belong here.

*Phase 1 finding (2026-07-27):* upstream's `MC1/Views/Components/` is already a rich kit
(30+ views incl. `NodeAvatar`, `GlassFilterBar`, `TintedLabel`, `SyncingPillView`). No
skeleton gets ported ahead of consumers — each legacy candidate is audited against an
upstream equivalent at the moment its first consumer lands (Phases 2–3), and only genuine
gaps come across. **Naming hazard:** upstream has `SignalBars.swift`, a BLE RSSI glyph for
device pickers. Our repeater signal-bars feature (B1–B3) must not reuse that type name —
engine is `SignalBarsEngine` (service layer), views get `RepeaterSignal…` prefixes.

---

## 3. Feature dispositions

Legend — **carry**: bring file(s), adapt, keep tests · **rewrite**: new implementation,
legacy is spec + test source · **delta**: upstream already has it; audit and add only
what's missing · **MapLibre**: rendering must be rewritten against §2.3.

| ID | Disposition | Plan |
|----|-------------|------|
| **I1** branding | carry | Bundle IDs, display name, icons, fork attribution, TestFlight detection, feedback links. First thing on `v2` so it builds and ships immediately. |
| **I3** signing/docs | carry | `project.yml` signing, `BETA_CHANGES.md`/`BETA_TESTER_NOTES.md`. Keep upstream's `Makefile`/`ci/`/`.swiftformat` this time. |
| **P1** adaptive TX power | carry | `AdaptivePowerService` imports only Foundation/os — cleanest service in the fork. Carry + tests; rebuild the settings section (`AdaptivePowerSection`) on upstream's settings hub. |
| **Y1** Wio notif sync | carry | `NotifSyncService` + `NotifPrefsBlob` (+ its test suite) carry well. Re-wire into upstream's mute flows (they've changed); rebuild the diagnostic screen. Depends on §2.5. |
| **B1** SignalBarsService | rewrite (service core salvageable) | The 968-line service mixes concerns (wire handling, ping tracking, name resolution, watch state). Split: wire codec (§2.5, carry) / `SignalBarsEngine` actor (state machine, testable, no UI types) / thin observable façade. Name resolution goes through §2.1, not inline. |
| **B2** TX SNR + power indicator + path-hash quick-picker | rewrite | UI rebuilt on upstream design; quick-picker consumes §2.2 search + §2.1 identity instead of its own matching. |
| **B3** viewer mode, CoreMotion hint, sync badge | rewrite | Behavior spec from legacy; implement against the new engine. CoreMotion hint isolated behind a `MovementHintProvider` protocol so the engine stays testable. |
| **K1** Repeater Benchmark / Watch | rewrite | VM logic (probe sequencing, history, comparison) ports as an engine with injected session; views rebuilt. Watch-target state moves off `AppState` globals (`watchedRepeaterHexID` lives in AppState today) into the signal-bars engine. |
| **T1** traffic heatmap | logic carry + **MapLibre** rewrite | `TrafficHeatmapViewModel`'s RxLog aggregation is map-independent except for MapKit types in its output — retarget output to §2.3 layer models. All 7 view files (annotations, pins, `TrafficMapRepresentable`, segment overlay) are MapKit and get rewritten as the pilot consumer of the map layer API. |
| **C1** message search | rewrite on §2.2 | Store-level queries + shared search UI. In-conversation scroll-to-result/highlight-flash re-implemented against upstream's timeline (legacy scroll code targeted our dropped `ChatTableView`). |
| **C2** reactions/tapbacks v2 | wire carry + chat rewrite | Wire format, length caps, hash-preservation rules and their tests carry (§2.5). Send path re-implemented through `ChatSendQueueService`; pending-reaction queue becomes part of that queue, not a parallel one. Badges/details/picker UI rebuilt; check upstream's long-press actions sheet for where "React" mounts. |
| **C3** swipe-to-reply + reveal timestamps | rewrite | Small gesture modifiers on upstream bubbles. Coexists with upstream's long-press sheet. Watch for conflicts with upstream's bubble a11y pass — replicate their VoiceOver custom-action pattern. |
| **C4** no-repeats retry card | rewrite | Detection logic (no repeats heard for a send) is an engine-level concern → signal-bars engine emits it; the card is a timeline affordance wired to `ChatSendQueueService` resend (same-power / escalated). Escalation policy shared with P1's adaptive power service — one power-decision component, used by both. |
| **C6** draft persistence | **delta** | Upstream has `DraftStore` with cross-restart persistence. Expected delta: none. Audit only; delete from keep list if confirmed. |
| **C7** mention ordering / scroll-to-mention | **delta** | Upstream shipped mention picker, off-screen mention tracking for the @ button, and append-not-replace. Audit remaining deltas: recency-first ordering nearest thumb, keyboard reset after selection, scroll-to-mention button. Implement only what's genuinely missing, inside upstream's mention system. |
| **O1** pubkey/hex search | fold into §2.2 | Not a standalone feature anymore — it's the contacts-facing mode of NodeSearch. Key-prefix display in rows joins §2.6. |
| **O3** badges/sparkline/swipes | carry into §2.6 | Restyle for themes. |

Dropped-but-adjacent guardrails:
- **N2 disambiguation UI** stays out, but §2.1 keeps the persisted-corrections storage
  schema in mind so re-adding it later isn't a migration.
- **Signal mapper (future)**: everything it needs from this phase is §2.1, §2.3, and the
  B1 engine's probe plumbing. Do not re-import SurveyKit/H3 now; when the mapper returns
  it starts from a fresh design doc, reusing those subsystems.

---

## 4. Carry-vs-rewrite test (apply to every file)

Carry (then adapt) only if **all** hold:
1. No UI-framework imports in a logic file (MapKit/UIKit in a "service" = rewrite).
2. It has tests, or tests can be carried with it.
3. It doesn't duplicate a §2 subsystem or an upstream capability.
4. Under ~500 lines and single-purpose. (`SignalBarsService` at 968 fails; its blob codec passes.)

Known-clean carries: `AdaptivePowerService`, `NotifSyncService`, `NotifPrefsBlob`+tests,
`SignalBarsBlob`+tests, `MessageSearchResult`, tapback format logic+tests, O3 components,
branding/config.

Known must-rewrites: every `*Representable`/`MK*` file, everything that touched
`ChatViewModel`/`ChatTableView`, `RepeaterSignalListView` (669 lines, prefix-matching
inline, AVFoundation in a list view), benchmark views.

---

## 5. Port order

Each phase ends green: builds, tests pass, app usable on device.

**Phase 0 — base & identity (small)**
Branch `v2` from v1.3.0 · tag `legacy/v1-final` · I1 + I3 · CI building fork-signed
TestFlight from `v2`.

**Phase 1 — protocol + foundations (medium)**
§2.5 MeshCore deltas (signal-bars wire, tapback wire, notif-prefs wire; one PR each,
tests first) · §2.1 NodeIdentity · §2.6 component library skeleton.

**Phase 2 — services (medium)**
P1 carry + settings UI · Y1 carry + re-wire + diagnostic screen · B1 engine rewrite
(uses Phase 1 wire + identity).

**Phase 3 — signal surface (medium)**
B2 + B3 UI on the new engine · K1 benchmark/watch engine + UI · C4 retry card
(engine event → chat affordance).

**Phase 4 — chat (large)**
C2 reactions through `ChatSendQueueService` · C3 gestures · C6/C7 delta audits (do these
first — they may vanish) · then C1 message search once §2.2 lands.

**Phase 5 — search & tools (medium)**
§2.2 NodeSearch · O1 folded in · retrofit pickers (B2 quick-picker, K1 target picker)
onto it · T1 heatmap: logic retarget + first §2.3 MapLibre overlay consumer.

Phase ordering rationale: protocol and identity underpin everything signal-related;
chat features wait until we've lived inside upstream's chat architecture a bit (Phases
0–3 give that exposure cheaply); NodeSearch comes late enough to serve both its consumers
(C1, O1) but before T1 closes out the scope; T1 goes last because it pilots the map API
that nothing else in this scope needs.

---

## 6. Testing bar

- Engines/services: unit-tested with injected transports/clocks (follow upstream's
  seam patterns — `iOSMeshTransport`, `AccessorySetupKitServicing` — which originated in
  this fork and are now upstream).
- Wire codecs: round-trip + malformed-input tests (carry legacy fixtures).
- Chat behaviors: coordinator-level tests in upstream's existing chat test style.
- Ranking/matching (§2.1, §2.2): legacy behavior converted to table-driven tests before
  the rewrite, so the rewrite has a spec.
- No feature PR merges without tests for its logic layer. Views stay thin enough that
  this is cheap.
