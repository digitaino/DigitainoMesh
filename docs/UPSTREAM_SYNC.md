# Upstream sync: PocketMesh 1.4.1 → 1.5.2 (dev af074f1b)

Checked and merged 2026-10-04 on branch `upstream-sync-1.5` (see §8 for what was
built). Sections 1–7 are the plan and the trial-merge findings as written before
the merge.

## 1. Where we are

- Every fork branch last took upstream `dev` at **a22d46a7 (2026-08-28)**, two days
  before v1.4.0 was tagged. Most of 1.4.0 (incoming translation, sender avatars,
  failed sends in Chats) is already in the fork.
- Upstream has since shipped v1.4.1, 1.4.3, 1.5.0, 1.5.1 from `dev`; `dev` is now
  1.5.2. **104 non-merge commits, 445 files, +30.7k / −3.7k lines.**
- Upstream's release notes now link to `Avi0n/MeshCoreOne` (the project is being
  renamed "MeshCore One"). Our `upstream` remote URL still resolves.
- `v2`, `feature/signal-mapper` and `personal` have not moved since 2026-09-02. All
  41 commits since then are on `feature/meshwx`, which is what runs on the phone.

Trial merges of `upstream/dev` (conflicted files / hunks):

| Into | Files | Hunks |
|---|---|---|
| v2 | 52 | 83 |
| feature/signal-mapper | 56 | 90 |
| personal | 58 | 94 |
| feature/meshwx | 67 | 111 |

38 of v2's 52 files reappear with identical hunks in feature/meshwx. A cascade
(v2 → signal-mapper → personal → meshwx) would cost ~80–115 file resolutions and
four build/test cycles against 67 and one.

## 2. What upstream added that we would gain

- **Path Details** (1.5): every extra incoming flood path, Repeat Details on sent
  messages, path distance overlay, incoming heard-count setting.
- Tap a reaction badge to see who reacted.
- Chat opening up to 90% faster (height cache, channel-switch and UI perf work).
- iOS 27 swipe actions on chat rows; toolbar items named for overflow.
- Settings: advanced radio and path hash size moved to the Radio page; preset
  location; new/updated presets (HU, SK, CR, LVMesh, PhillyMesh at 919.5); presets no
  longer auto-selected or recommended.
- Repeaters: nested region hierarchy (gated to firmware 1.15+).
- Firmware 1.17 CLI completions and MCU temperature.
- Pairing: ASK discovery by service UUID (no name list), forget the ASK pairing when a
  device is deleted, confirm leftover pairings before scanning, Bluetooth recovery
  after forgetting the radio in iOS Settings.
- Contacts: review a QR before adding, copy hex / share URI.
- Map: cluster-nodes toggle.
- Korean localization; multiple-window support (iPad/Mac).
- Fixes: room sessions scoped to radioID, backup import skips duplicate message ids
  (same fix as ours), deleteContacts awaited, background advert updates deferred.

## 3. Must fix in the merge (semantic, mostly not flagged by git)

**A. Critical: 70b4bcfd wipes radio-swap channel history.** Upstream deletes a
slot's messages when `saveChannel`/`batchSaveChannels` sees a different **secret**
at the same (radioID, index), for every slot in `unconfiguredIndices`, for every
slot ≥ `pruneBeyond`, and on every `deleteChannel(id:)`. The swap guard only
suppresses the middle two. On a switch to a radio whose slot 9 holds a different
channel, the guarded sync would relabel slot 9 and **delete Survey's 46,820
messages** before the copy offer appears; the copy back would wipe it again; and
`vacateSlot` (which calls `deleteChannel`) would wipe the duplicate slot.
Fix: a `preservingHistory` path for `saveChannel`/`batchSaveChannels`, used by
`finalizeChannelSync` and its retry when `holdForSwap`, and by the copy/top-up
writers in `NodeConfigService.makeWriters`; `vacateSlot` keeps or moves the
messages without wiping. Unguarded syncs and user edits keep upstream's wipe.
Checked against the 2026-10-03 backup: all 33 slots on ADFB2581… have a channel and
no messages sit at an empty slot, so the "unconfigured slot" wipe finds nothing
today.

**B. High: 334d28d4 background 0x8F deletes contacts and their DMs.** Deletions
queued while backgrounded flush through `deleteContacts` (cascading DMs) on return
and on every `stopEventMonitoring` (every disconnect / radio switch), with no
favourite or has-messages check. 08eea456 only covers the foreground path. Apply
the same keep rule inside the store transaction; add a test.

**C. High: Scan / Set Up does nothing from the radio pill.** Upstream's
`DeviceSelectionSheet` now queues the action and runs it in
`handleDeviceSelectionSheetDismissed()`. The fork's `RadioStatusControl.swift:~281`
presents the sheet without that `onDismiss`, leaving `isPairingFlowActive` stuck
true, which also blocks auto-reconnect. Add the `onDismiss`.

**D. High: signal mapper fake uplink.** Upstream raises a heard-repeat event for
every extra incoming path; `SignalMapperCaptureEngine` counts every such event as
"a repeater heard us here". Add an echo-vs-incoming flag to `HeardRepeatEvent`;
the mapper takes sent echoes only. Limit `requestObserverCountPass()` to outgoing.

**E. Medium: receiver pin.** Upstream places the receiver at the radio's configured
location, then the phone. The fork deliberately uses the receive-time phone fix
(cdda8eb5) with a cross-table ambiguity check. Port the fork's rule into upstream's
arrival map.

**F. Medium: channel text cap 147 → 139 bytes (98eaf3c4).** Shrinks the v3
reaction budget 114 → 106. MeshWX is unaffected (GRP_DATA, its own ≤157 B limit).

**G. Low.** Clear upstream's new `appliedRadioPresetID` in
`ConnectionManager.identityTemplate` (a new sibling radio shouldn't claim a preset
name). Upstream's slot-occupant handler closes the open chat and drops drafts on
every guarded relabel, i.e. on each radio switch. Acceptable.

**Kept from the fork:** the iOS 27 picker fix (6f7b6da4). Upstream never found the
CBManager cause; it only retries `pickerRestricted` on the next active scene.

## 4. Compile breaks git does not flag

- `ChannelService.vacateSlot` calls `draftClearHandler`, renamed upstream to
  `slotOccupantChangedHandler`.
- `DeviceSelectionSheet` `guard case let .saved` (rows are now `DeviceDTO`; use
  `device.manufacturerName`).
- Fork-only `MessagePathDetailView` doesn't pass the new `arrival:` to
  `MessagePathContent`.
- Auto-merged `SyncCoordinator+HandlerHelpers` channel branch omits `contentHash`;
  pass `rxEntry.contentHash`, not nil, or Packet Scope loses incoming channel
  messages.
- Merged `EnvInputs` is missing a comma.
- `MapControlsToolbar` now needs a `clusteringEnabled` binding:
  `TrafficHeatmapView.swift:171`, `SignalMapperCoverageView.swift:735`.
- Two `TestClock` types in MC1ServicesTests (fork `SignalBarsTestSupport.swift`
  vs upstream `Helpers/TestClock.swift`); rename the fork's (~12 files).
- Upstream's mention-first `ReactionParserTests` auto-merge in and fail until the
  parser accepts mention-first.

## 5. Conflict resolution notes by area

**Radio, channels, pairing.** PersistenceStore+Channels: take upstream's
transaction/rollback structure, move `stageClearingIdentityDeletions` inside the
`do` before `save()`, then apply fix A. ChannelService: keep the `holdForSwap`
block before upstream's `changedSlots`; `clearChannel` keeps upstream's
single-transaction delete plus the fork's `recordIdentityDeletion`.
ConnectionManager+Pairing: take upstream's
`systemAccessoriesMissingDeviceRecord`/`remove…`, drop the fork's stray sweep and
kept-associations list (upstream now blocks Scan until leftovers are forgotten;
forget + re-pair rejoins by key as a sibling, history safe); keep
`releaseCentralManagerForAccessoryPicker`; in the Settings-removal delegate put
upstream's `isDeviceConnectable` return first, then `forgetRadio`.
DeviceSelectionSheet: take upstream's `DeviceSelectionListBuilder` ("Set Up" rows
replace the fork's row-less accessory rows). BLEStatusIndicatorView: stays deleted;
port upstream's `onDismiss` to `RadioStatusControl` (fix C). ServiceContainer,
MockPersistenceStore, NodeConfigServiceTests, OpenRadioStatusIntent: keep both.
Forgetting one of two sibling radios is safe under upstream's ASK forget.

**Chats, paths, reactions.** ReactionParser: keep v3→v2→v1 and the strict emoji
check, add upstream's mention-first branch to `parseLegacy`. ReactionService:
emit per decision 1. docs/Reactions.md: rewrite by hand (git silently rewrote the
v1 example; byte figures stale). HeardRepeatsService: take upstream's split
(`recordSentEcho` / `recordDistinctPathIfNeeded`), move the fork's content-hash
stamp and detail/isFlood event into `recordSentEcho`, keep the fork's log line
(upstream logs 50 chars of decrypted text). SyncCoordinator+MessageHandlers: keep
the phone-fix gate and DTO fields, drop the fork's early `lookupRxLogEntry`.
Bubble callbacks: upstream's badge tap opens details, so the fork's `onReaction`
goes; keep resend-power, reply, duplicate-run and search callbacks. ChatTiledView:
both, plus `noteProgrammaticScroll()` in `scrollUserToBottom()`.
ConversationListContent: fork search + upstream scroll-away header.
MessagePathMapView: both sides define a struct with this name; keep the fork's
shared canvas/located-nodes code (used by Packet Scope, HeardRepeatsMapView,
tests), rename the fork's view `SharedRouteMapView`, take upstream's arrival view.
MessageActionsSheet/ActionsDetailsSection: per decision 2. Translation: two
switches now exist; keep upstream's `translationOffersEnabled`, migrate a stored
`false` from the fork's `messageTranslationEnabled`, retire the fork's.
BackupBatchInsert: same fix both sides, keep one. Simple both-sides merges:
HeardRepeatPersisting, PersistenceStore+Messages, EnvInputs, AppState+ChatPrefetch,
test stubs.

**Build, settings, strings, map.** project.yml: keep MARKETING_VERSION 1.3.0
(a19145f7 rule); accept xcodeVersion 27.0 (matches this Mac), MessagingUI bump, en_US
test pin, ASK name list removal. Info.plist ×2: take ours, delete
`NSAccessorySetupBluetoothNames`, keep `UIApplicationSupportsMultipleScenes`,
`plutil -lint`. MC1App: ours + `logToolbarResumeProbe`. L10n.swift: regenerate
(SwiftGen 6.6.3). Chats.strings ×9: upstream's 5 new keys, drop unused
`chats.path.map`. Settings.strings ×7: keep `adaptivePower.*`, drop
`advancedRadio.repeatMode` (+footer). AdvancedSettingsView: remove
`AdvancedRadioSection`/`PathHashModeSection` (moved), keep AdaptivePower and
SignalBars. SettingsSubpage/SettingsDetail/AppStorageKey/BackupUserDefaults/map
files/test mocks: union of both sides. ContactsViewModelTests: one
`publicKey: Data? = nil` parameter, reorder call sites.

**Korean.** 1,092 fork keys missing (Weather 553, Tools 233, Localizable 143,
Settings 123, Chats 35, Onboarding 4, Contacts 1). Missing keys fall back to
English (`L10n.tr` passes the English as `value:`); nothing enforces coverage.
Ship with English fallback; fix the 8 branding strings ("MeshCore One" → ours) in
the merge; translate later with the Portuguese backlog.

**What's New.** Upstream's catalog now holds only a 1.5 entry linking upstream's
release. At our 1.3.0 nothing shows. Keep it that way unless we write our own.

## 6. Owner decisions

1. **Reaction emit format.** Live problem, merge or not: since v1.4.1 (2026-09-09)
   stock apps accept a reaction only when the emoji field is exactly one emoji, so
   our v3 `👍 reacted to "…" @[X]` shows on current stock apps as chat (and pings
   the person mentioned); our parser rejects upstream's mention-first
   `@[X]👍`, so their reactions show to us as chat with a self-mention ping.
   Options: (A) emoji-first `👍@[X]` — tapback on 1.3.0 through 1.5.x and ours,
   loses the readable snippet; (B) mention-first — tapback on 1.4.1+, chat on
   1.3.0; (C) keep v3 — tapback only on ≤1.4.0. Recommended: **A**, keep parsing
   v3/v2/v1 and add mention-first.
2. **Path Details vs the fork's heard-repeats map** (one solution per problem).
   Recommended: adopt upstream's arrival data and map as the single solution,
   retire `HeardRepeatsMapView`, keep receive-time phone fixes for pins, and host it
   in the fork's full-screen cover (Reply-with-Route, Network View and the Message
   Journey plan depend on the cover). Costs upstream's inline
   `MessagePathDetailBlock` and its two preview test suites.
3. **Branch strategy.** Recommended: turn on `rerere`, merge once into
   `feature/meshwx`, leave `v2`/`signal-mapper`/`personal` frozen (merge upstream
   into `v2` later only if it is still wanted; rerere replays 38 files).
4. **Adaptive Power placement.** Upstream moved TX power to the Radio page;
   Adaptive Power would stay in Advanced. Recommended: move it next to TX power.

## 7. Order of work

1. Back up the phone store (recipe in memory: ios27-picker-and-device-debugging).
2. `git config rerere.enabled true`; branch `upstream-sync-1.5` from
   `feature/meshwx`; `git merge upstream/dev`.
3. Resolve per §5; apply §3 fixes A–G and §4 breaks; decisions 1, 2, 4.
4. `xcodegen generate`, SwiftGen, build the app and both test targets.
5. Tests: fork suites (RadioSwapGuard, ChannelServicePipeline + SwapGuard,
   RadioSwapCopy, IdentityDeletion, ContactServiceSync, AdvertisementService,
   NodeConfigImportPlanner/NodeConfigService, KnownRegion, BackupIntegration,
   DuplicateMessageGrouping, SignalMapper*, RadioSwapPromptState); upstream's new
   suites (PersistenceStoreBatchSync, ChannelSlotOccupantChanged,
   ChatCoordinatorRegistry, PairingStrandedAssociation,
   ConnectionManagerDeleteDevice, SystemPairingSetupAppState, AdvertisementService,
   ReactionParser, MessagePathArrival, MessagePathDetailSelection). New tests: a
   guarded relabel keeps slot messages; an unguarded secret change still wipes;
   vacateSlot keeps messages; background 0x8F keeps favourites and messaged
   contacts; deleting one of two sibling radios keeps history; Scan from the radio
   pill reaches the picker; an incoming extra path never counts as heard-us.
   Known red, not merge regressions: TCC abort in the full MC1Services run,
   notification-sync timeouts under parallel load, StoreKit suites need iOS 18.
6. On the phone: pair/scan from both entry points, switch Wio Tracker ↔ RAK 3401,
   check channel message counts per slot against the backup before and after.
7. Fast-forward `feature/meshwx`, then commit.

## 8. As built (2026-10-04)

Owner said "go" to all four recommendations. Branch `upstream-sync-1.5`, cut from
`feature/meshwx` c22a1d23, rerere on:

| Commit | What |
|---|---|
| c5992a8d | The merge (67 conflicted files). Fork route map renamed `SharedRouteMapView`; `HeardRepeatEvent.isSentEcho` added; fork `TestClock` → `SignalBarsTestClock`. |
| 15f69561 | §3 A: while the channel swap guard is armed a slot change only relabels; `vacateChannelSlot` moves a duplicate slot's messages (dedup keys rewritten) to the slot holding the same secret. Tests: `ChannelHistorySwapTests`. |
| 13e01619 | §3 B: the background 0x8F flush keeps favourites and contacts with messages. Two upstream fixtures that gave the deleted contact a message adjusted. |
| 39e314d9 | §3 C: the radio pill's device sheet has the dismiss hook. |
| 18b9d467 | §3 D: the mapper takes only sent echoes as "heard us". |
| 3084f1a9 | Decision 1: reactions sent as v1 emoji-first; v3/v2/v1 both orders still read. docs/Reactions.md rewritten. |
| 0e4da979 | Translation: the fork's switch retired for upstream's `translationOffersEnabled`; `TranslationSwitchMigration` carries an "off". |
| f8660a77 | Decision 4: Adaptive Power on the Radio page beside TX power. |
| c2254c86 | "MeshCore One" → DigitainoMesh in upstream's new strings (all locales; Korean particles adjusted). |
| 26f9f488 | Decision 2 (see below). |

**Where the build differs from the plan:**
- **Decision 2 kept the fork's map, not upstream's.** The fork's full-screen path
  screen (MessagePathDetailView on MessagePathMapCanvas) now takes the message's
  repeat rows and shows upstream's arrival capsules over the map; the selected
  arrival drives the map, hop list, copy and Reply with Route. Keeping the fork's
  canvas keeps the receive-time receiver pin (§3 E) with no port, and it is the same
  canvas the Network View uses. Upstream's MessagePathDetailBlock, preview map and
  snapshot pipeline, and arrival MessagePathMapView were removed with their tests.
- **HeardRepeatsMapView stays** for sent messages: it shows every echo at once,
  which upstream's one-capsule-at-a-time view does not replace. Incoming paths and
  "who heard me" are different questions, each with one screen.
- **§3 G not needed:** `appliedRadioPresetID` only breaks ties between presets whose
  settings match the radio's, so a sibling copying it cannot show a wrong name.
- **`requestObserverCountPass()`** still runs on incoming extras; it only nudges the
  observer-count loop forward.

**Still open:**
- On-phone check (§7 step 6): pair/scan from the radio pill and the radio list,
  switch Wio Tracker ↔ RAK 3401, compare channel message counts per slot with the
  2026-10-04 backup.
- Korean is missing ~1,090 fork strings (English fallback); translate with the
  Portuguese backlog.
- Strings only upstream's removed path views used are orphaned (harmless).
- `feature/meshwx` not yet fast-forwarded; nothing pushed.

**Version bump (owner, 2026-10-04):** MARKETING_VERSION 1.3.0 → 1.5.2 so upstream's 1.5
What's New presents (it keys on major.minor above the stored baseline). The path item is
reworded in all 12 locales to describe the fork's View Path with arrival tabs; the "See
all new changes" link still opens upstream's v1.5.0 release notes. This lifts the
a19145f7 hold: the next `fastlane beta` upload is a new App Store Connect version, which
needs Beta App Review before external testers get it (internal testers do not).
