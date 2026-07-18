# Survey v2 — Implementation Status

Date: 2026-07-18 · Branch: `feature/survey-v2` (both repos — the main app repo and
the nested `pocketmesh-survey-server` repo have a branch of this name)

## Landed on this branch

**SurveyKit** (new shared SPM package, used by app + server)
- Vendored uber/h3 4.4.1 (C target `CH3`), typed `SurveyGrid` API, base res 10
- `SamplingPolicy`: speed-adaptive tiers (fine/medium/coarse = res 10/9/8, with
  hysteresis + dwell), token-bucket TX budget (≤ 6 TX/min sustained), novelty
  gating, flood quota, manual-probe reserve, manual tier override
- v2.2 wire DTOs (single source shared with the server), `SignalQuality` scale,
  `SurveyLimits` validation, `RequestSigner` HMAC, `CellAggregator`,
  `LegacyAxialGrid` (v1 math, single implementation)
- 22 unit tests incl. a highway-drive simulation asserting the TX ceiling

**Client (MC1)**
- `SurveyProbeEngine` actor in MC1Services — owns all survey transmissions;
  view model forwards GPS and mirrors state (tier chip + TX budget gauge)
- Dedup reentrancy race fixed in `SurveyService`
- `SurveyUploadServiceV2`: batched, HMAC-signed, anonymous-by-default live
  uploads with on-device deletion receipts (45 s / 20-cell flush, requeue on
  failure)
- UX/HIG pass: tier picker replaces frequency presets; live tier+budget chip;
  one 5-tier SNR palette across own/community overlays + corrected legend;
  `CommunityMapView` dead code deleted (enum/helper relocated); 44 pt targets;
  RepeaterDetailSheet Done button; accessibility labels; start/pause/upload
  haptics; layers-menu `padding(.top, 240)` hack removed

**Server (`pocketmesh-survey-server`, nested repo)**
- Imports SurveyKit (path dep `../SurveyKit`; Docker context moved to repo root
  with a root `.dockerignore`)
- Ingest in one transaction; batch re-upload rolls back aggregates (was
  double-counting); pseudo hex_q/hex_r from H3 kills the legacy unique-constraint
  collision; SSE fires post-commit
- v2.2: optional contributor + receipt deletion endpoint; `client_ip` no longer
  persisted; `cell_observation_days`, `cell_repeaters.first_heard`,
  `cells.hop_histogram` (migration `AddTimeFidelityAndReceipts`)
- Multi-res reads: `GET /api/v2/cells?res=8|9` (h3-pg parent rollup)
- Auth: HMAC signatures accepted alongside the static key (constant-time);
  `ADMIN_API_KEY` wall on `/api/v1/admin/*` (warns-and-allows until the env var
  is set — see `.env.example`)
- v1 `/cells` fixed for Postgres (`STRING_AGG`, boolean literals); one
  `SignalQuality` threshold set everywhere; `deploy.sh` backs up Postgres
- 6 new endpoint tests (auth/wire), 16 total green

## Not yet done (planned next phases)

1. **Client community reads on v2** — the in-app community overlay still calls
   `/api/v1/cells` (now Postgres-safe). Flip `fetchCommunityCells` to
   `/api/v2/cells` with zoom-driven `res=`, and render mixed-res H3 boundaries
   via `SurveyGrid.boundary(of:)`.
2. **Batch/completion/export uploads on v2.2** — session-end and batch uploads
   still use the v1 payload (server keeps accepting it). Flip them to
   `SurveyUploadServiceV2.uploadSession` (incl. `known_repeaters` from contacts
   and opt-in attribution), then sunset the v1 upload path.
3. **Display grid on H3** — the on-map heatmap still buckets with
   `LegacyAxialGrid`; move display aggregation to `CellAggregator` +
   `SurveyGrid` so painted cells match uploaded cells exactly (review B3
   fully closed; today only upload-vs-live is unified).
4. **Setup sheet split** — move one-time decisions (channel, identity,
   attribution) out of the per-survey start sheet into a Survey Settings screen;
   collapse the five upload paths to two.
5. **Localization** — route survey strings through L10n.
6. **Map tab consolidation** — extract shared MKMapView coordinator helpers so
   `SurveyMapRepresentable` and `MKMapViewRepresentable` stop duplicating
   hit-testing/renderers.
7. **Server follow-ups** — Cloudflare Access JWT validation (the `CF_ACCESS_*`
   env vars), shared-store rate limiting/SSE if ever multi-instance, native
   TIMESTAMPTZ migration for legacy TEXT timestamps, admin N+1 cleanups.

## Known notes

- `MC1ServicesTests` currently fails to compile on this branch for a
  **pre-existing** reason unrelated to survey work (`ValueTracker` missing in
  `ConnectionManagerResyncLoopTests.swift`) — reproduced with all survey changes
  stashed.
- The server repo is nested and gitignored by the app repo; its SurveyKit path
  dependency reaches into the parent working tree (`../SurveyKit`). Deploys on
  the iMac Pro must check out both repos in this layout (as the Docker build
  context now assumes).
- `ADMIN_API_KEY` should be set in the server `.env` promptly; until then admin
  auth remains edge-only (server logs a warning per admin request).
- H3 4.4 cell scale: res 10 ≈ 130 m across (edge 75.9 m), res 9 ≈ 350 m,
  res 8 ≈ 920 m.
