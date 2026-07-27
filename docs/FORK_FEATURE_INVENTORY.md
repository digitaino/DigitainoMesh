# DigitainoMesh fork — feature inventory & upstream comparison

Generated 2026-07-27. Basis of comparison:

| | |
|---|---|
| Fork branch | `feature/survey-v2` @ `a9b23dc9` |
| Upstream | `upstream/main` @ `3cd08543` (v1.3.0, 2026-07-23) |
| Fork point | `7d571316` — 2026-03-19 |
| Our commits since fork | 323 (254 fork-only, **65 already patch-identical upstream**) |
| Upstream commits since fork | 893 |
| Our diff vs fork point | 523 files, +78,586 / −3,855 |
| Upstream diff vs fork point | 1,777 files, +263,063 / −118,722 |
| Files that exist only in our tree | 357 (≈255 genuinely new, ≈89 upstream moved/renamed them) |

## The single most important fact

**Upstream migrated MapKit → MapLibre Native on 2026-03-27** (`feat(map): migrate from MapKit to MapLibre Native (#253)`), eight days after our fork point.

- Our tree: 59 files `import MapKit`, and every map surface we built is `MKMapView` / `MKOverlayRenderer` / `MKAnnotationView`.
- Upstream: 17 files on MapLibre, a whole new layer/sprite/style stack (`MC1MapView`, `MapCanvasView`, `PinSpriteRenderer`, `MapTileURLs`, `MapSnapshotRenderer`).

Everything visual we built on maps — survey hex heatmap, community overlay, route maps, traffic heatmap, weather radar/warning overlays, LOS map — is a **rewrite**, not a port. That cost dominates the whole exercise and should drive which features you keep.

---

## Group 0 — Already upstream (no work required)

65 of our commits are patch-identical in `upstream/main`. This is the BLE/pairing/DM hardening body of work, and it means the reliability layer you care about is already in v1.3.0:

- BLE reconnect/pairing race hardening (~35 commits): claim cycles, auth-code preservation, ASK picker cancellation, circuit-breaker exemption, `switchDevice` cleanup, state-restoration claims, plus the whole pairing test suite.
- DM ACK lifecycle: `pendingAcks` keyed by messageID, filtered subscriptions, expiry checker, `.delivered` downgrade refusal, ACK grace handling.
- `fix(crypto)`: missing `.littleEndian` in `ChannelCrypto` timestamp decode.
- `fix(block)`: discard channel messages from blocked senders at ingestion.
- Device platform rules (GAT562, M5Stack, ThinkNode M5), R1 Neo / LTO OCV curves, DM acks picker, RxLog compound index, telemetry chart date format.

**Action: none.** Rebasing gets these for free.

---

## Group 1 — Signal survey & crowdsource platform

No upstream equivalent at all. This is the largest fork-only body of work.

| ID | Feature | Key files | Notes |
|---|---|---|---|
| S1 | Signal Survey tool — hex heatmap, active/passive probing, cell detail sheet | `MC1/Views/Tools/SignalSurvey/*` (13 files), `SurveyService`, `SurveyProbeEngine` | ~8k lines. Map layer is MKMapView. |
| S2 | Survey v2 engine — SurveyKit package, vendored H3 (`CH3`), adaptive sampling policy, speed-adaptive probing, TX budget | `SurveyKit/*` (56 files) | Newest, cleanest code you have. Map-independent. |
| S3 | Community upload — batched anonymous live upload, session dedup, gzip, v2.2 wire DTOs | `SurveyUploadService`, `SurveyUploadServiceV2`, `SurveyKit/Sources/SurveyKit/SurveyWire.swift` | |
| S4 | Dead-zone capture, persistence and display | survey VM + upload pipeline | |
| S5 | Session lifecycle — persist/resume, completion summary, export, lifetime stats, time filters | `SurveyCompletionSheet`, `SignalSurveyExportView`, `LifetimeStatsView`, `PersistenceStore+Survey` | |
| S6 | Community overlay on the main map — coverage filter, per-repeater metrics, cell↔repeater polylines, My Cell | `CommunityHexOverlay`, `SurveyHexOverlay`, `CoverageFilter`, `MapTimeFilter` | Full MapLibre rewrite required. |
| S7 | Contributor identity — public-key identity model, self-service portal, verification, auto-renew | `ContributorSelfService`, `ContributorVerificationService`, `ContributorProfileView` | |
| S8 | Background repeater location sharing to community server | `RepeaterSharingService`, `CommunitySharingSettingsView` | |
| S9 | Survey debug overlay + server admin dashboard | `SurveyDebugOverlay` + server repo | Server lives outside this repo. |

## Group 2 — MeshWX weather system

No upstream equivalent.

| ID | Feature | Key files |
|---|---|---|
| W1 | MeshWX protocol decoder v3/v4 + COBS framing | `MC1/Utilities/MeshWXDecoder.swift` (2,919 lines) |
| W2 | Weather tab UI — card pager, favorites, sections, search, city weather | `MC1/Views/Weather 3/*` (`WeatherView.swift` is 3,496 lines) |
| W3 | Radar — `0x11` sparse/RLE multi-chunk message type, radar loops, overlay + renderer, persistence | `WeatherRadarOverlay`, `WeatherRadarRenderer`, `RadarLoopView` |
| W4 | Warnings — zone geometry store, overlay, 60s auto-expire, filter | `WeatherWarningOverlay`, `ZoneGeometryStore` |
| W5 | Weather bot transport — DM/channel toggle, retries, response timeout, `#meshwx` auto-provision, `MSG_NOT_AVAILABLE` | `WeatherCache`, `WXBundleLoader` |
| W6 | `meshwx-web` — web + Electron viewer |
| W7 | `Vendor/meshcore-weather` submodule (server side) |

Caveats: the folder is literally named `Weather 3` (with a space); `WeatherView.swift` at 3.5k lines and `MeshWXDecoder.swift` at 2.9k lines are the two worst debt hotspots in the fork. Radar/warning overlays are MapKit.

## Group 3 — Route & path mapping + web sharing

Partially overlapping with upstream now.

| ID | Feature | Upstream status |
|---|---|---|
| R1 | Message route map / contact route map / heard repeats map | Upstream built its own message path map (with distance pill) and a repeater neighbors map, on MapLibre |
| R2 | Server-hosted route sharing — short URLs, web pages, SSE live updates, location privacy options, hop numbers | **Unique** |
| R3 | Reply-with-Route + shared route cards in chat | **Unique** |
| R4 | Path Map Generator tool + `/path` web creator page | **Unique** |
| R5 | Route parsing/aggregation core — `RouteAggregator`, `RouteDistanceCalculator`, `SharedRouteParser`, `HexPathParser` (+ unit tests) | **Unique**, map-independent, cheap to port |

## Group 4 — Repeater identity & resolution

Infrastructural, map-independent, and the thing that makes survey + route features trustworthy. No upstream equivalent.

| ID | Feature |
|---|---|
| N1 | `RepeaterHexID` — consistent 1-byte hash IDs, longest-form retention for multi-byte firmware |
| N2 | Hash-collision resolver with recency bias, disambiguation UI, persisted user corrections |
| N3 | Stale discovered-node filtering (7-day), repeater declutter, hidden-repeater tombstone fix |

## Group 5 — Signal bars

No upstream equivalent.

| ID | Feature | Files |
|---|---|---|
| B1 | `SignalBarsService` + live per-repeater signal list + toolbar item | `SignalBarsService.swift` (968 lines), `RepeaterSignalListView.swift` (669 lines) |
| B2 | TX SNR display, TX power indicator, path-hash quick picker | `TxPowerIndicator`, `SignalBarsBlob` |
| B3 | Viewer mode + engine parity, CoreMotion movement hint, sync badge | |

## Group 6 — Other fork-only tools & services

| ID | Feature | Upstream status |
|---|---|---|
| P1 | Adaptive TX power — `AdaptivePowerService`, PA curve support, settings section | **Unique** |
| T1 | Traffic heatmap tool (`MC1/Views/Tools/TrafficHeatmap/*`, 7 files) | **Unique**, MapKit |
| K1 | Repeater Benchmark / Repeater Watch — history + comparison views | **Unique** (~1.2k lines) |
| Y1 | Wio L1 notification sync — `NotifSyncService`, `NotifPrefsBlob`, mute-flow wiring, diagnostic screen | **Unique** |

## Group 7 — Chat enhancements

| ID | Feature | Upstream status |
|---|---|---|
| C1 | Global + in-conversation message search, highlight flash, scroll-to-result, expandable results | **Unique** |
| C2 | Reactions / tapbacks v2 — human-readable format, length caps, pending queue, hash preservation on long messages | **Unique** |
| C3 | Swipe-right-to-reply + iMessage-style swipe-to-reveal timestamps | **Unique** (upstream went with a long-press actions sheet) |
| C4 | No-repeats retry card — same-power and escalated resend | **Unique** |
| C5 | `ChatTableView` (UIKit-backed list), duplicate count badge, `MessageDisplayState` | **Conflicts** — upstream rewrote chat around `SendQueue` actor + `ChatRenderState` + `AsyncStream` |
| C6 | Draft persistence across navigation | **Superseded** — upstream `feat(chats): persist composer drafts across navigation and restarts` |
| C7 | Mention ordering / live update / scroll-to-mention | **Superseded** — upstream shipped a full mention picker + tap-resolution system |
| C8 | Send DM from channel sender, "Send DM" under Reply | **Already upstream** |

## Group 8 — Contacts / paths

| ID | Feature | Upstream status |
|---|---|---|
| O1 | Search by public key, strict hex prefix matching, key prefix in node rows | **Unique** |
| O2 | Saved paths sheet/detail, path edit metrics | Partly upstream — the Add Hop picker rewrite was adopted |
| O3 | `NodeKindBadge`, `MiniSparkline`, contact swipe actions | Cosmetic, cheap |

## Group 9 — Branding & fork infrastructure

| ID | Feature | Notes |
|---|---|---|
| I1 | DigitainoMesh rebrand, fork attribution, TestFlight detection, feedback links | Keep |
| I2 | Radio preset onboarding cards | **Superseded** — upstream redesigned onboarding with a region step |
| I3 | Personal signing config, removed upstream CI, `BETA_CHANGES.md` / `BETA_TESTER_NOTES.md` | Keep; note upstream added `.github`, `Makefile`, `ci/`, `.swiftformat` you dropped |

---

## What you gain by moving to upstream v1.3.0

Independent of your own features, rebasing brings:

- **MapLibre map stack** — vector tiles, offline snapshots, map filters, camera persistence, discovered pins, settings hub
- **Themes + IAP** (Support Development, Appearance, All Themes bundle)
- **iPad `NavigationSplitView` sidebar + macOS support** (`DevicePairingService`, `DeviceScannerSheet`)
- **App backup & restore** (incl. themes, regions, discover list)
- **Siri / Shortcuts intents**, deep links (`meshcore://`), camera QR handling, What's New sheet
- **Chat overhaul** — SendQueue actor, persisted send queue, link previews, inline images with dimension prefetch, map thumbnails, relative day separators, VoiceOver/a11y pass
- **Per-message region scope**, region filtering UI, tri-state flood scope, region-aware presets
- **Remote node GPS + location history + neighbors map**, telemetry history overhaul, airtime rows, CLI terminal tab
- **Localization** — Italian added, service-layer strings localized at the view boundary
- Contact profile pictures, node ID prefixes, hops sorting, discover-trace boundary probes

---

## Recommended porting order

1. **Rebase onto upstream v1.3.0.** Drop groups 0, C6, C7, C8, I2, O2, and the LOS files (upstream moved LOS to `MC1/Views/Tools/LineOfSight/` and evolved it past ours).
2. **Port map-independent cores first** — S2 (SurveyKit), R5 (route parsing), N1–N3 (repeater identity), Y1, P1, C2. These are pure logic with tests and rebuild cleanly.
3. **Rewrite map surfaces against MapLibre** one at a time, highest value first: S1/S6 → R1/R2 → T1 → W3/W4.
4. **Rewrite, don't port, the two debt hotspots** — `WeatherView.swift` and `MeshWXDecoder.swift`. Split the decoder into per-product parsers with fixture tests; rebuild the weather UI from the protocol types up.
5. Re-add fork infra (I1, I3) last, restoring upstream's `Makefile` / `ci/` / `.swiftformat` rather than your deletions.
