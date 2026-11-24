# Upstream sync: MeshCore One 1.5.2 → 1.6.2 (dev 54d7b7e9)

Checked 2026-10-30; owner decisions made the same day (§6). Plan and trial-merge
findings; nothing merged yet. The 1.5 sync
record is docs/UPSTREAM_SYNC.md — its §3, §5 and §8 rules still apply.

## 1. Where we are

- The fork last took upstream `dev` at **af074f1b** (1.5.2) on 2026-10-04
  (`upstream-sync-1.5`, merged into `main` as 27db4e4e).
- Upstream has since shipped **1.6.0** (10-23) and **1.6.1** (10-27) from `dev`;
  `upstream/main` now holds a 1.6.2 merge whose tree equals `dev` 54d7b7e9. 1.6.2 has no
  GitHub release or tag yet.
- **129 commits** (88 fix, 16 feat, 11 ui, 4 test, 10 other), **879 files,
  +73.5k / −11.5k** — about twice the 1.5 sync. Half the added lines are tests.
- Not in `dev` yet: `upstream/feat/sensors` (one commit, "add meshcore sensor support",
  10-25) and `WIP/multiplatform`. Expect sensors in the next sync.
- `upstream-sync-1.5` has **uncommitted work from 10-18** (info sheets usable offline:
  notification level, channel/room favourite, nickname and avatar save without the
  radio; region edits wait for it). Four of its files conflict with this merge. It must
  be committed or shelved first (decision 3).

Trial merge of `upstream/dev` into `upstream-sync-1.5` (rerere off): **77 files, 117
hunks**, 8 of them modify/delete. The 1.5 sync was 67 / 111.

## 2. What upstream added

**Navigation (iPad and iPhone Duo).** The iPad sidebar is gone; a top tab bar replaces
it. Chats, Nodes and Settings are split views at every width, so the list and the open
page survive tab switches, rotation and resizing. Trace Path, Discovery, Rx Log and
remote admin keep running when you leave the screen. Initial iPhone Duo support.

**Chats.**
- Pins split from radio favourites: pin any DM, channel or room (phone-only), shown
  under "Pinned" / "Chats" headings. Existing favourite contacts start pinned.
- Mark read / unread, and a full swipe toggles it. Messages that arrive while the app is
  in the background stay unread.
- Drafts survive navigation and connection loss; a failed send puts the text back.
  A cancelled DM stays pending.
- Keyboard and timeline move together; jump-to-message works while paging and after
  deletions; messages show before link previews load; link previews fetch over https,
  redirects are validated, inline image size is capped.
- Delete is last in context menus. A "syncing messages" pill, and Ready shows only after
  the first catch-up.

**Notifications and shortcuts.** A quick reply from a notification for another radio is
refused. Shortcut recipients survive a reconnect. Live Activity unread totals refresh.
Channel regions apply to notification replies, queued sends and retries.

**Radio connection.**
- Bluetooth ↔ Wi-Fi switching on one node (firmware 1.18, node paired both ways), in the
  device sheet and a new Settings › Connection page. One Device row holds both links.
- Connection lifecycles isolated: teardown finishes before the next connect, a stopped
  session cannot write. Heartbeat keeps probing after an inconclusive answer; recovery
  works through either saved link.
- Power off from the app (no auto-reconnect); the phone's timezone is sent on firmware
  v14+. A reflash step appears when pairing keeps failing.

**CLI.** A local radio CLI (command 0x42, firmware 1.18) and a remote CLI to contact
radios, with a per-contact grant (flag 0x10) that blocking revokes. Wi-Fi settings page.
Completions match firmware 1.18.

**Contacts and Nodes.**
- Sort by Last Advert (falls back to Last Heard). Last Heard advances from synced adverts.
- Favourite changes are confirmed with the radio and disabled while it is not ready;
  **every sync now writes the radio's favourite flag onto the phone** (see §3 A).
- Discovered paths are written to the radio. Contact cleanup is batched. 144-byte
  contact updates. Search ignores the category filter. Tabs and scroll positions kept.

**Map.** Last-heard and hop-count filters with chips. The map colour setting applies on
every map. Mouse-wheel zoom. Offline maps: detail levels, correct bounds and sizes, topo
downloads disabled. Map labels in the app language.

**Tools.** Line of Sight uses great-circle geometry and keeps state on resize. The trace
hop pill sits at the top; stale trace batches stop.

**Settings and onboarding.** "Skip for now" on the preset step. Saved regions show in
Advanced. Presets: Canada provinces and BC; Australia and Czech matching fixed.
Management on one sheet. Missing translations filled in most locales.

**Protocol (MeshCore package).** Oversized frames throw (binary limits 165/176 B).
Fixes: signed DM author prefix; the Rx Log crash on region-scoped packets (unscoped
transport codes); MMA requests; hop hashes in region reply paths; auto-add detected from
the firmware code; large-frequency formatting crash; invalid CLI session numbers;
padding in owner info.

**Data model.** `Contact.isPinned` added; `Channel.isFavorite` and
`RemoteNodeSession.isFavorite` renamed to `isPinned` with `@Attribute(originalName:)`.
A one-time favourite→pin copy runs under `hasSplitChatPins`. All lightweight; no new
entities, no Device columns. The fork's own entities and columns are untouched.

**Build.** Version 1.6.2. MessagingUI revision bump. `MC1Tests` not parallelizable.
Upstream CI forces Xcode 27.1 — this Mac has 27.1 (27A9275).

**Already fine (checked):** `releaseCentralManagerForAccessoryPicker` (iOS 27 picker
fix) still called; every device-sheet presenter has its `onDismiss`; `contentHash` still
passed through sync handlers; the background 0x8F keep rule is untouched by the batched
cleanup; dead-twin pruning reads `lastAdvertTimestamp`, which upstream leaves alone;
MeshWX datagrams (≤157 B) fit the new frame limits; `SignalBarsSessionOps` unchanged;
reaction wire format untouched (304fa471 only fixes meshcore-open `r:` overflow); new
upstream chat fixtures key their text per message, so no duplicate-collapse failures
expected; no new "MeshCore One" strings. Upstream's `writePin` now writes the requested
value for an unlisted conversation — the fork's c2078a2f sheet fix is upstream now.

## 3. Must fix in the merge (git does not flag these)

**A. Critical — a radio switch un-favourites contacts, which can delete them and their
DMs (8ba4940d).** `applySyncedFavorite` (`PersistenceStore+Contacts`, batch save)
clears `isFavorite` on every synced contact whose radio copy lacks flag bit 0. A sibling
radio's copies have no flag (top-up only adds missing contacts), so the first sync
after a switch un-favourites them in the shared history. They then qualify for stale
cleanup (`Contact.swift`, `!isFavorite && recency < cutoff`), which deletes the contact
and its DMs, and `ContactService` records an IdentityDeletion that removes it from the
other radio too. Copy to This Radio then spreads the loss. Upstream's one-time
favourite→pin copy runs before any sync, so existing favourites are pinned (and safe
once F lands); the exposure is favourites set after the update. Fix per decision 1:
- On an identity with more than one radio (`deviceModels(radioID:).count > 1`),
  `applySyncedFavorite` leaves an existing row's `isFavorite` alone — neither sets nor
  clears it. New rows still take the radio's flag. Single-radio identities keep
  upstream's rule.
- After the contact sync on such a radio, write the phone's favourite flag to every
  contact on the radio whose flag differs (CMD_ADD_UPDATE_CONTACT), reusing the
  favourite-flag writer in `NodeConfigService` (~430); delete the dead
  `ContactService.migrateAppFavoritesToDevice`. Contacts the radio lacks are top-up's job.
- Tests: switching to a sibling keeps the phone's stars and writes them to the radio;
  un-starring on radio A is not undone by radio B's star; a single radio still follows
  its own flag.

**B. High — device settings land on an arbitrary sibling row (b8a47d40).**
`updateExistingDevice` (`PersistenceStore+Devices`) fetches by radioID with
`fetchLimit 1` and no sort; every settings and refresh write now goes through it. With
two radios on one identity the connected radio's row can go stale, and the next switch
copies the old name or LoRa settings back. Fix: hardware fields go to
`primaryDeviceModel(radioID:)`; `nodeName` and `defaultFloodScopeName` go to every row
in `deviceModels(radioID:)`. Test: a sibling's settings write reaches the connected row.

**C. High — channel swap guard released by a partial retry.** Upstream's retry path runs
`finalizeChannelSync` with `pruneBeyond: nil`; the fork's release block would drop the
guard after an error-free partial retry. Release only when `pruneBeyond != nil`. Gate
`vacateSlot` behind upstream's new channel gate and call `noteSlotMutation` there and in
`droppingDeletedChannels`, or a sync read taken before the vacate can restore the
duplicate slot. Pass `holdForSwap ? [] : unconfiguredIndices` and
`holdForSwap ? nil : pruneBeyond`. Test: a retry pass does not release the guard.

**D. High, latent — a Wi-Fi sibling gets no swap guard.** `wifiDeviceID` maps a Wi-Fi
connect onto the most recent Bluetooth row with the same key, so a Wi-Fi sibling radio
gets no row and no guard, and its channel sync wipes slot messages. Our radios are
Bluetooth-only today. Fix: match on the saved host:port; if several rows share the key
and none matches, mint a new id. Keep the fork's sibling rule when a Wi-Fi-only row is
later paired over Bluetooth.

**E. Medium — post-sync prompts can vanish.** `onDeviceSynced` now passes a Bool and
`handleDeviceSynced` returns early when stale cleanup starts. Put the fork's hooks
(`evaluateNodeLocationStaleness`, `reconcileNotifSync`, `evaluateRadioSwapOffer`,
`evaluateRadioSetUp`) inside the closure, before that call.

**F. Medium — keep rules ignore pins.** "Favourite" now means only the radio's bit; the
user's "keep this" signal is the pin. Add `|| isPinned` to the background 0x8F flush, the
prune, and `AdvertisementService`'s two keep checks. Test: a pinned contact with no
messages survives 0x8F.

**G. Medium — possible return of the popover teardown crash.** Upstream binds the Tools
stack path to `selectedTool`. A terminal disconnect clears the tool and pops the open
radio tool on the same tick that `RadioStatusControl` closes its popover — the trap the
fork's ToolsView comment names (TestFlight B8A782EC; see the iOS 26 popover memory).
Take upstream's binding and defer the disconnect's tool clear until the popover has
settled (~600 ms). Test: disconnect with a radio tool open does not pop it during the
dismissal.

**H. Medium — Weather alert taps on iPad.** `ToolsDetailColumn` is gone; route alert
taps through `selectedTool` so iPad (and iPhone) land on Weather, not the Tools list.

**I. Medium — collapsed duplicates can't be jumped to.** Retire the fork's
`PendingMessageScroll` for upstream's `PendingScrollTarget` (same bug, plus a request
id). Port `revealHiddenDuplicate` and the fork's flash into `ChatScrollRequestDelivery`;
today it returns nil for a target hidden in a duplicate run.

**J. Low.**
- Remote CLI grant (flag 0x10) in Copy to This Radio and config import: per decision 4.
- `WeatherAskControl` and `SignalMapperCoverageView` hide the tab bar; on iPad that now
  hides the top tabs. Hide only the bottom bar.
- Wheel zoom skips `onUserCameraMove`, so the mapper's follow-me fights trackpad zoom.
- `SharedRouteMapView` needs `isOffline:` (upstream fixed its own path maps).
- `ContactDetailView`: upstream's thin view drops the fork's `contactNotFound →
  removeLocalContact` fallback; port it into `ContactDetailState+Actions.deleteContact`.
- `HeardRepeatsService`: stamp `contentHash` after `admitSentEcho` returns and before
  yielding `.heardRepeatRecorded` (Packet Scope and `MapperSentPacketLogger` read it).
  Keep `isSentEcho` explicit.
- `PacketCodes`: put `runCliCommand = 0x42` inside `CommandCode`; a plain keep-both
  lands it in `FirmwareNotifMode`.
- `insertContactIfAbsent` (new advert path) doesn't clear IdentityDeletion records.
- The room info sheet shows a stale pin after reopening (upstream bug; writes are right).
- Quick replies: confirm a notification from one sibling can still be answered after a
  switch (upstream refuses another radio's replies; siblings share a radioID, so it
  should pass — check).

**K. Version.** `project.yml` auto-merges MARKETING_VERSION to **1.6.2** (three
targets; `MC1UITests` stays 1.5.2). Decision 2.

**Watch item.** Stock firmware's highest command is now 0x42 (`CMD_RUN_CLI_COMMAND`,
response 0x1D). The fork's custom sync registry uses 0x44–0x46 and responses 0x64–0x65;
only 0x43 is left between. Check stock firmware on every sync.

## 4. Compile breaks after resolution

- `MC1MapView` dropped `isDarkMode:` — fix TrafficHeatmapView, SignalMapperCoverageView,
  WeatherAlertMap, SharedRouteMapView (and ContactDetailView if kept).
- `MC1MapView.updateCameraRegion` must not be private (NodesHistoryStateTests call it).
- `onDeviceSynced` is `(Bool) async`.
- `ChannelService` uses the removed `maxChannels`.
- `DeviceSelectionSheet` uses the removed `primaryConnectionMethod` (keep the fork's
  "· manufacturer" suffix on upstream's `dialTarget`).
- `HeardRepeatsService`: `repeatDTO` undefined and `HeardRepeatEvent(messageID:count:)`
  is not the fork's init — have `admitSentEcho` / `admitIncomingPath` return the DTO.
- `ChatViewModel.composingText` is gone (`handleReplyWithRoute`, reply) — use
  `draftEditor`; keep the fork's additive reply.
- `pendingMessageScroll` in ChatConversationView and ConversationListContent;
  ConversationListContent declares `searchText` twice; `mode` and
  `favoriteConversations` are gone; `ChatFilterPicker` needs `isSearching:`.
- `setFavorite` / `ChannelDTO.isFavorite` gone → `setChannelPinned` /
  `setSessionPinned` / `.isPinned`.
- `ContactsViewModel` NodeSearch calls need `referenceDate:`.
- `SettingsSubpage.isAdmitted` is exhaustive; add `.copyToRadio` (→ `.advanced`) and
  `.deviceNotificationRules` (→ `.notifications`), or the push is a silent no-op.
- Fork exhaustive switches over `MeshEvent` need `.cliReply`.
- `SnapshotConfigurationSession` (test) lacks the fork's `getSync` / `setSync` /
  `listSync`.
- `ChatViewModel.Dependencies` built in upstream tests lacks the fork's
  `notifSyncService`, `adaptivePowerService`, `signalDataAvailable` — give them defaults.
- `ChatTimelineTests`: `tail.isEmpty` → `== .endOfHistory`.
- `BLEStatusToolbarItem.swift` is restored by the merge and references the deleted
  `BLEStatusIndicatorView` — delete it.
- L10n.swift: regenerate (SwiftGen 6.6.3), don't hand-merge.

## 5. Conflict resolution notes by area

**Navigation.** Delete all six modify/delete files (MainSidebarView,
ChatsStackRootContent, ContactsDetailColumn, ToolsContentColumn,
SidebarNavigationLayoutTests, BLEStatusToolbarItem). Port: `signalMapperRideActive:` on
MainTabView's `clearPerDeviceSelection`; ContactsDetailColumn's radio pill into the
`destination(_:)` group in ContactsListView. NavigationCoordinator: take upstream, give
`clearPerRadioSelection` / `clearPerDeviceSelection` both `preservingConnection` and
`signalMapperRideActive`. ContentView: upstream's `productionShell` plus the fork's
location `onChange`, swap / set-up / stale-location sheets and their presentables.
MC1App: ours plus upstream's `.propagatingMapColorSchemePreference()`, or the map colour
setting stops working. AppState: upstream's closure with the fork's hooks inside (§3 E);
`clearPendingLinks(signalMapperRideActive:)`, the three `endSession()` calls, then
`resetRadioScopedToolWorkspaces()`. ToolDestinationView: upstream's signature plus fork
cases and `hidesRadioStatus`. SettingsSubpage: upstream's structure plus the two fork
pages, wrapped in `.radioStatusToolbar()`. Contacts presenters: take upstream, re-apply
`.radioStatusToolbar()` on Discovery, detail and blocked. AppearanceView: ours (no paid
themes). WhatsNewSheet: our support text plus upstream's heart icon. Fork screens stay
reachable: Benchmark, Traffic, Signal Mapper, Weather via `ToolSelection.allCases`;
Signal Mapper Data in Settings; Adaptive Power on the Radio page; Watch and signal bars
from the radio pill on every tab root.

**Map.** MC1MapView: union, `basemapIsDark` replaces `isDarkMode`; in
`updateCameraRegion` order: upstream viewport gate, version check, fork
`isUserInteracting` gate, `requestedCameraBounds`, animated flag with `canAnimate`,
`didApplyCameraCommand()`. LineOfSightView: take upstream, port the fork's pin-tap =
map-tap fallback into LineOfSightMapView. NodeLocationMapView: take upstream.

**Radio and persistence.** ConnectionManager: take upstream's `clearBondVerification` /
`clearPersistedConnection`; the fork's sibling handover goes only in the latter (compute
before clearing, persist after). Lifecycle: add `performChatPinMigration()`; disconnect
switch lists `.switchingDevice, .identityChanged, .powerOff`. Pairing: upstream's Wi-Fi
row retention and `clearPersistedConnection`, then the fork's `forgetRadio`.
PersistenceStore+Devices: keep the fork's `deviceModels` / `primaryDeviceModel` /
`fetchDevices(publicKey:)`, delete upstream's stray half-copy of `addDeviceKnownRegion`,
keep the swap-guard lines plus Wi-Fi adoption, then §3 B. ChannelService: upstream's
`commitObservedSync`, retry and gated `clearChannel` with `recordIdentityDeletion`
inside the gate, then §3 C. ContactService: upstream's gate and batched deletions; the
prune keeps the fork's keep and hold rules through `handleDeletion` /
`flushDeletionUpdatesIfNeeded`; `removeLocalContactOwned` keeps both
`recordIdentityDeletion` and `handleContactDeletion`; filter stale copies before
`reconcileBlockedRemoteCLI`. ServiceContainer: keep the fork's local
`messagePollingService` (weather uses it) plus upstream's `BinaryProtocolService` init.
PersistenceStore: add upstream's schema step to the history comment as v11→v12.
Mocks, DevicePersisting, PacketParser, MessagingSessionOps, +Migration: both sides.
StoreStateTests: take upstream's deletion.

**Chats.** ChatViewModel+ConversationList: take upstream's pin code (the stale-sheet fix
is in it); port the fork's test as "setPinned saves an unlisted **room** from a stale
sheet copy" (upstream covers channels only). ChatViewModel: keep `observerCountTask`,
drop `prefetchTimeout`; upstream's init then the fork's `noRepeatsDetector`.
ChatViewModel+Reactions: keep the fork's send-queue carrier, rollback and failed-carrier
code. ReactionParser: one guard `isValidReactionEmoji(emoji), !sender.isEmpty`.
ChatConversationView: keep `messageSearch` / `jumpTask` and `SharedRouteMapSheet`, drop
`draftSaveTask`, one pending-scroll mechanism (§3 I). ConversationListContent: upstream's
init and Pinned/Chats sections, then the fork's message search section; show the search
empty state only when message search is empty too. ChatTiledView,
ChatComposerTextView, ChatConversationMessagesContent: both sides.
ChatTimeline+Paging: fork's `OlderPage` with upstream's guard. MessagePathDetailBlock,
MessagePathMapView: `git rm` (nothing references them). ContactsViewModelTests: take
upstream's whitespace-search behaviour, drop the fork test that contradicts it.
MessageServiceConfigTests: ours (4 attempts).

**Strings.** WhatsNew.strings ×12: keep both, then per decision 2. Upstream adds 12
"MC1" strings, all `whatsNew.iPhoneDuo.description` — replace with DigitainoMesh
(Korean "MC1은" → "DigitainoMesh는"; Portuguese "O MC1" → "O DigitainoMesh"). No
"MeshCore One" this time.

**Data.** The two renames and one new column are lightweight. Before the phone: restore
a copy of the latest phone backup into the simulator, run the new build, compare
contact / channel / message counts and pins. A new `.mc1backup` restored into an older
fork build loses channel and room pins.

## 6. Owner decisions (decided 2026-10-30)

1. **Favourites on a shared identity: radios follow the phone.** Any rule that only
   picks a winner leaves sibling radios disagreeing. Instead the phone is the record for
   an identity with more than one radio, and writes its stars to whichever sibling
   connects, so phone and radios agree after every connect (§3 A). This also gives every
   radio the favourite flag that overwrite-oldest spares (docs/RADIO_SWAP.md). A star
   changed outside this app on a sibling radio is put back at the next connect. A single
   radio keeps upstream's rule (its flag reaches the phone).
2. **Version: 1.6.2 with a curated 1.6 What's New.** Set `MC1UITests` to 1.6.2 too.
   Sheet: keep pins, read/unread, iPad tab bar, map filters, Bluetooth/Wi-Fi (firmware
   1.18); drop or rebrand iPhone Duo ("MC1"); credit link "1.5" → "1.6"; reword "More
   changes" (its link was replaced by ours). New App Store Connect version, so external
   testers wait for Beta App Review.
3. **The uncommitted 10-18 work: test, then commit before the merge.** Contents: info
   sheets save without the radio (notification level, channel/room favourite, nickname,
   avatar, block, delete message), region edits wait for the radio, DM favourite toggle
   reverts on failure, five tests; plus an unrelated MeshWX spec paragraph (bot radar
   broadcast during precipitation) — commit that separately. In the merge the
   channel/room favourite part becomes pins and the DM revert yields to upstream's
   7ef0596d / 92e53dc5; the rest stays fork value.
4. **Remote CLI grant: keep it only for the same key.** Copy to This Radio and config
   import carry flag 0x10 when the target radio has the same public key (same node to the
   mesh); strip it for any other radio. Test both.

## 7. Order of work

1. Back up the phone store (devicectl recipe in memory).
2. Decision 3; then branch `upstream-sync-1.6` from `main`; `git merge upstream/dev`
   (rerere on). Do all edits in the main session — the 1.5 sync showed resumed
   read-only agents get blocked editing a shared tree.
3. Resolve per §5; apply §3 A–K and §4; decisions 1, 2, 4.
4. `xcodegen generate`, SwiftGen, build the app and both test targets.
5. Tests (MC1ServicesTests via `swift test` filtered in chunks; full run still aborts):
   - Fork: RadioSwapGuard, ChannelHistorySwap, ChannelServiceSwapGuard,
     ChannelServicePipeline, RadioSwapCopy, IdentityDeletion, NodeConfig*,
     RadioSwapPromptState, RadioSetUpPromptState, AdvertisementService, ContactServiceSync,
     BackupIntegration, DuplicateMessageGrouping, ChatDuplicateRun,
     ChatMessageSearchNavigator, ReactionParser, PacketScope*, MessagePacketContentHash,
     MapperSentPacketLogger, SignalMapper*, Weather*, ToolsViewPath, NotifSyncService.
   - Upstream: ChatPin*, ChatViewModelReadState*, ConversationUnread*,
     ChatDraftEditor, ChatSendAdmission, NotificationQuickReply*,
     ChatScrollRequestDelivery*, ContactServiceFavorite*, ContactDeletionBatch,
     SyncedAdvertRecency, ChannelServiceWriteOrdering, PersistenceStoreBatchSync,
     DevicePublicKeyDeduplication, ConnectionManager{LaunchTransport, Teardown, PowerOff,
     Promotion, WiFiHeartbeat, AdoptionRace}, DeviceSelection*, NavigationCoordinator,
     NavigationState, SettingsRouteAdmission, NodesHistoryState, MapViewModelAdvancedFilter,
     OfflineMap*, LineOfSight*, WhatsNewCatalog, MeshCore V118*.
   - New: §3 A (sync can't drop a sibling's favourite), B, C, F, G, H, I tests; setPinned
     on a stale room sheet; a sent echo stamps its hash before the event.
   - Expected red, not regressions: upstream favourite-sync tests (fix per decision 1),
     ChatsSearchFilter "no matches" until the empty-state gate changes, the known-red list
     in the merge memory (NeighborSNRMapBuilder fallback, accessibility-in-detached-window
     tests, StoreKit on iOS 26, full MC1Services TCC abort).
6. Simulator: migrate a copy of the phone backup (§5 Data); iPad layout pass (tab bar,
   Weather, mapper ride, alert tap, Settings pages).
7. Phone: pair and scan from both entry points; switch Wio Tracker ↔ RAK 3401; check
   favourites, pins and per-slot channel counts against the backup before and after;
   disconnect with a radio tool open.
8. Fast-forward `main`, update the beta notes, then `fastlane beta`.

## 8. As built (2026-10-30)

Branch `upstream-sync-1.6`, cut from `main` 27db4e4e, rerere on. Nothing pushed.

| Commit | What |
|---|---|
| 7c82202e, d60e5058 | Decision 3: the 10-18 work, tested (15 + 138 tests) and committed first. |
| 305efc21 | This plan. |
| c48e796c | The merge (78 conflicted files), with §3 A–C, E, F, H–K and decisions 1, 2, 4. |
| 77dd8030 | §3 D and H6: a radio's own Wi-Fi-only or legacy row is adopted, not a sibling; a Wi-Fi connect picks the row at its address. |
| 552561d7 | Stale-node cleanup reaches the radio before the fork's post-sync prompts. |
| 72ab4c2f | Test fixtures (fork prune rule, flood-scope-first send order, Support page). |

**Where the build differs from the plan:**
- **§3 B:** every refresh and settings write goes to the most recently connected row (the
  connected radio). Name and flood scope are not copied to sibling rows: each row says what
  its radio actually has, and the swap profile is captured from the outgoing radio's row.
- **§3 E:** upstream's `handleDeviceSynced` runs first and the fork's prompts after it. It
  only returns early (it does not end the closure), and cleanup-first is the pre-merge order.
  The notification-rule sync waits for a cleanup that just started.
- **§3 G:** kept the fork's one-way Tools stack (a clear from outside never pops the open
  tool, so no popover teardown) and made it follow a tool *named* from outside. That fixes
  §3 H on iPhone and iPad without the deferred-clear timer.
- **§3 I:** upstream's `ChatScrollRequestDelivery` now expands a collapsed duplicate run when
  the target is a hidden copy; a delivered jump flashes the bubble like a search jump.
- **§3 A:** the dead `ContactService.migrateAppFavoritesToDevice` stays (upstream code, unused
  upstream too). The write uses the synced frames after blocked-contact CLI revocation, so it
  cannot restore a revoked grant.
- **Decision 4:** records-built configs carry the node's key in `recordsPublicKey`, which is
  never encoded, so exports are unchanged.
- **Keep rules (§3 F)** also cover Remove Non-Favorite Nodes and the import planner's
  protected contacts.
- **§3 J:** Weather and the mapper ride use `hidingBottomTabBar`, which leaves an iPad's top
  tab bar alone. Wheel zoom reports a user camera move. `SharedRouteMapView` passes
  `isOffline`. Contact detail saves nickname and avatar through the offline store and deletes a
  contact the radio no longer holds.
- **Not done:** `insertContactIfAbsent` still leaves IdentityDeletion records (low; a re-added
  contact has a newer `lastModified`, so it is not treated as stale). The room info sheet's
  stale pin display is upstream's bug. Quick replies were checked: upstream compares
  `radioID`, which siblings share, so they still work after a switch.

**Tests (this Mac, Xcode 27.1, iPhone 18 Pro Max / iOS 27 simulator):**
- MeshCore: 583 passed.
- MC1ServicesTests in chunks of 20 suites: all pass except six CoreBluetooth suites
  (BLEStateMachine ×3, BondLossPairingRecovery, BondShieldRefresh, ConnectionManagerBLEHealth)
  that abort `swift test` on the Bluetooth TCC check, the known pre-existing abort. Weather
  and remote-CLI suites time out only under parallel load and pass alone.
- MC1Tests (StoreKit suites skipped; they hang on iOS 27 and belong on iOS 18 per
  `make test-store`): 3,813 tests, 3,795 passed. The 18 failures are in nine suites. Seven fail
  the same way on pristine `upstream/dev` built in a clean worktree (ChatChannelInfoPresentation,
  ChatPinInfoSheet, ChatKeyboardLift, ChatsSearchFilter, CompactComposerKeyboardGap,
  GlassFilterBar, SearchFilterSpacing): this simulator's keyboard and accessibility tree. Settings
  tab navigation fails Connection upstream too, and Support the same way on the fork's page.
  NeighborSNRMapBuilder is the known fork fixture conflict (merge memory).
- New tests: shared-identity favourites (5), pinned contacts kept (2), remote-CLI grant (4),
  retry keeps the channel guard (1), stale room and channel pin sheets (2).
- Migration rehearsal: the 2026-10-04 phone store opened in the simulator under this build.
  Devices 5, contacts 682, channels 91, messages 111,699, repeats 71,040, reactions 923 and
  per-slot message counts (57 groups) identical before and after; 86 favourite contacts and
  16 favourite channels came through as pins.

**Installed on the phone 2026-10-30 12:07** (6df94dc5, Debug). Backup taken first over Wi-Fi
(it worked this time): `phone-backups/2026-10-30-before-upstream-sync-1.6-install/`, integrity ok.
After the first connect (Wio):
- Store integrity ok. All 61 per-radio/per-slot message groups present; three grew by 9 new
  channel messages in total, none shrank. Reactions 1,036 = 1,036; repeats grew.
- Pins: 79 contacts (= the 79 favourites, which keep their star), 20 channels (= the 20
  channel favourites), rooms 0 (none were favourites).
- Contacts 689 → 679: the full-sync prune's swap guard kept all 29 contacts the Wio doesn't
  list; then the owner's 7-day stale-node cleanup removed 10 of those (none favourite, pinned or
  with messages). Intended behaviour, same rule as before the merge.

**Still open (needs the phone or the owner):**
- iPad layout pass: only checked that the build launches on an iPad simulator.
- §7 step 7, rest: switch Wio Tracker ↔ RAK 3401 and check stars on both radios (the RAK
  isn't at hand); pair and scan from both entry points; disconnect with a radio tool open.
- Push the branch, fast-forward `main`, then `fastlane beta` (a new App Store Connect version:
  Beta App Review for external testers). Beta notes are in BETA_CHANGES.md.
