# Upstream sync: MeshCore One 1.6.2 → 1.7.1 (tag v1.7.1, 5e980a53)

Checked 2026-11-24; owner decisions made the same day (§6). Plan and trial-merge
findings; nothing merged yet. Earlier records: docs/UPSTREAM_SYNC.md (1.5) and
docs/UPSTREAM_SYNC_1.6.md — their §3, §5 and §8 rules still apply.

Findings marked **[read]** were confirmed in the code; **[inferred]** ones need a test.

## 1. Where we are

- The fork last took upstream `dev` at **54d7b7e9** (1.6.2) on 2026-10-30
  (`upstream-sync-1.6`). That branch is **138 commits ahead of `main` and not merged
  into it**; it is installed on the phone.
- Upstream has since tagged **1.7.0** (11-15) and **1.7.1** (11-16). Target is the
  **v1.7.1 tag** (owner choice). `upstream/dev` is 24 commits further (1.7.2 work:
  repeater status watchlist, expanded Rx Log packet view, MECP 1.4.1 decoding,
  background battery work) and is left for the next sync.
- **86 commits, 1,023 files, +77.1k / −23.6k.** One commit, d4b8be9e (#481, "own each
  bluetooth connection's recovery"), is 455 files and rewrites the connection layer.
- The uncommitted notification-sync work (the radio reports its rule caps, sync slot 4)
  was tested (40 package tests, app build) and committed as **35d47e20** on
  `upstream-sync-1.6`. `upstream-sync-1.7` is cut from it. Nothing is pushed.

Trial merge of v1.7.1 into 169c34e6 (tree 520d17a6): **76 conflicted files**. 1.6 was 78.
Also new upstream, not in this sync: `feature/mcoimg` (19 commits past dev).

## 2. What upstream added

**Connection.** Each connection attempt owns its own recovery; a stale attempt can no
longer write. `ConnectionManager` is split into `+Preparation`, `+Connect`, `+Removal`,
`+RadioErase`, `+SyncCompletion`; callbacks carry a `ConnectionSnapshot`. The radio pill
gets a Cancel / Stop Reconnecting menu during recovery. Sync status shows while pairing;
a stuck onboarding pair can be cancelled. Radio erase (factory reset, Forget with delete)
is persisted and retried until the radio is reached.

**Direct messages.** Retry settings in Advanced: 1–4 attempts on the path, then 0–4 by
flood (default 4 + 4 = 8 sends). Switches for flood fallback on DMs and on remote/room
logins. Retry progress counts the first send. A DM is not restarted after the radio
accepted it; ACK settlement is serialized and durable.

**Channels.** Flood scope is restored after a channel send. Channel resend keeps its
repeats; outgoing repeat details restored.

**Reactions.** Outgoing reactions are persisted in the send queue, sent once, and the
badge appears when the radio accepts.

**Blocks & Filters.** A new top-level settings page: blocked contacts, blocked channel
senders, and **Text Rules** for incoming messages (keyword or sender rules per
conversation, with a Recently Blocked list).

**Sensors and telemetry.** MeshCore sensor nodes (contact type 0x04): login, settings,
discovery. Retained telemetry on Device Info. Units follow the device locale.

**MECP.** Emergency-protocol readings (`MECP/…` text) are drawn as readable text in
chat, in 12 languages. Display only; the stored text is unchanged.

**Other.** Opt-in debug log collection (off by default, local export only, no upload).
Status Live Activity reworked. VoiceOver focuses the latest message and reads only the
draft. Confirmation dialogs anchored to their controls. Hops hidden when the path byte
is reserved (`MessageDTO.hopCount` is now optional). macOS idle crash fixed.
Upstream deleted its `docs/` folder.

**Data model.** Two new tables (`PendingRadioErase`, `RecentlyBlockedMessage`). New
optional or defaulted columns on Contact, Channel, RemoteNodeSession (`textRulesID`,
`textRulesOverrideRawValue`), Message (`reactionTargetMessageID`, `reactionSenderName`),
NodeStatusSnapshot (`selfRadioID`), PendingSend (5 columns). No renames, no removals, no
Device columns, still one flat `Schema([...])`. Lightweight migration **provided the
schema list is the union of both sides** (§3 E). No entity, attribute or AppStorage key
collides with the fork's. No MeshCore packet-code changes; fork sync IDs 1–4 are clear.

**Build.** Version 1.7.1. MessagingUI c2d2698. SwiftFormat 0.64.5. Simulator iOS 27.2
(installed here). Deployment target iOS 18 unchanged. No new dependencies. New bundle
resources: `MECP/Languages` (package), `Settings.bundle/Packages/MECP.plist`.

**Already fine (checked):** same-key remote-CLI-grant rule survives the auto-merge;
v-contact omission does not touch protected contacts; the Text Rules backfill is per
radioID and idempotent, safe with several Device rows; MeshWX reads only channel
datagrams and ACKs, so Text Rules and the plain-text send gate do not affect it;
`RemoteBotWeatherTransport` masks its attempt to 2 bits; reaction wire format is still
the fork's emitter and parser; the Live Activity rework drops nothing of the fork's; no
new "MeshCore One" strings or upstream support links.

## 3. Must fix in the merge (git does not flag these)

**A. Critical — a new radio on a known identity deletes its sibling's row [read].**
`registerConnectionDevice` (`PersistenceStore+Connection.swift:15`, called from
`ConnectionManager+Preparation.swift:63`) falls back to `fetchDevice(publicKey:)`,
copies the found row under the new id, repoints its Bluetooth peripheral, and deletes
the original. That is the takeover RADIO_SWAP R1 removed. Fix:
- Take an explicit adopt-row id. The public-key fallback adopts only a ghost, a backup
  shadow, a Wi-Fi-only row, or a legacy row on the same peripheral (1.6 §3 D rules);
  otherwise it creates a sibling row.
- Re-apply the fork's connect-time logic in `prepareConnection`, before registration:
  `siblingRadio`, `identityTemplate`, `reconcileGhostIdentity` / `fetchSiblingRadio`
  join, `tookOnIdentity`, and `armSwapGuard` in the same metadata job, before
  `buildServiceContainer`. `createDevice` regains `tookOnIdentity`.
- The contact-sync watermark reset for `tookOnIdentity` must be applied in the merge
  path too (it keeps `current.lastContactSync`).
- Both `wifiDeviceID` calls in `prepareConnection` pass host and port, or every Wi-Fi
  connect and recovery mints a new id and re-keys a row [inferred].
- Every BLE recovery now runs `prepareConnection`, so this logic must be idempotent.

**B. Critical — erasing one radio wipes every radio on the identity [read].** Factory
reset and Forget-with-delete end in `completeRadioErase`
(`PersistenceStore+RadioErase.swift:78`) → `stageDeleteAllDeviceData(radioID:)`: every
Device row and all history under that radioID. While an erase is pending (including a
failed one, across launches) `isRadioErasePending(radioID)` blocks connect and receive
for sibling radios too. Fix per decision 2. Also:
- `startRemoval` calls `deleteDeviceAndData` directly; route it through the fork's
  `forgetRadio` with the `otherRadios(sharingIdentityWith:)` guard.
- `ConnectionDeviceIdentity.matches` compares radioID / public key first, so forgetting
  a spare radio disconnects its connected sibling and blocks the identity's reconnects
  (`+Removal:149`). Compare by device id when siblings exist.
- `DangerZoneSection`: upstream's moved dialog lost the fork's `otherRadios.isEmpty`
  guard and shared-history message; restore them on upstream's copy and delete the
  fork's block (two dialogs on one binding otherwise).

**C. High — DM send budget against the fork's 4-send cap.** Upstream removed
`MessageServiceConfig.maxAttempts` / `floodAfter`; `DMSendBudget` defaults to 4 + 4 and
`AckCodeBuilder.attemptCount = 8`, with attempts 4–7 reusing ACK codes 0–3. The fork
capped at 4 because a v1.15 repeater drops an ACK code it already relayed, so a late
success can show Failed (not re-verified against current firmware). `RoomServerService`
also sends 4 + 4 now. Decision 1 takes upstream's budget; nothing to re-apply but the
doc note, and the fork's "sends exactly maxAttempts" test is rewritten against
`DMSendBudget`.

**D. High — reaction carriers.** Take upstream's `enqueueReaction`; the fork's path
calls `createPendingMessage` / `createPendingChannelMessage`, now internal. Re-add the
fork's `indexesAsReactionTarget` guard at `ChatSendQueueService+ChannelDrain.swift:63`,
or outgoing reactions become things you can react to. PendingSend rows left by the
fork's carriers have no `reactionTargetMessageID` and drain as ordinary messages
[inferred] — test an upgrade with a queued reaction. Behaviour per decision 3.

**E. High — schema list.** `PersistenceStore.swift:151-182`: union. Taking upstream's
side drops `MapperCellObservation`, `IdentityDeletion`, `SurveySession`,
`SignalSurveyPoint` and their rows; taking the fork's omits the two new tables.
Renumber the history comment (upstream v9→v10, v10→v11 become fork v12→v13, v13→v14).
`Message` gains columns from both sides; keep both in the model and the DTO.

**F. High — post-sync hooks.** `onDeviceSynced` is now `(ConnectionSnapshot, Bool)` and
fires once per link from `completeSync`. Keep 1.6 §3 E order inside upstream's closure,
after `isCurrent(snapshot)`: `evaluateNodeLocationStaleness`, notif reconcile (after
stale-node cleanup), `evaluateRadioSwapOffer`, `evaluateRadioSetUp`, then
`handleDeviceSynced`. Hooks take `snapshot.device` / `snapshot.services`. Same for
`configureAdaptivePower`, `wireSignalBars`, `wireSignalMapper`, which still read the
global `connectedDevice`.

**G. High — identity import.** `setOnPostIdentityImport` is gone; upstream's
`setIdentityImportHandler` → `importConnectionIdentity` replaces it. Move
`joinSiblingIdentity` there (when `stageGhostIdentity` returns nil) and arm the swap
guard. Import Key, Regenerate and the fork's radio set-up still rely on the
connect-time rejoin from A.

**H. High — config import screen.** Upstream's view model is caller-owned with injected
services and a recovery state. Port onto it: the `.records` source, `loadFromRecords`,
`makeRoomForChannels` (upstream's `applyConfiguration` omits it, silently disabling the
feature), `swapIdentityName`, `onClose`, slot notes, the `clearChannelSlot` step. Three
fork callers build their own model: `ContentView.swift:107`, `SettingsSubpage.swift:142`,
`NodeConfigImportView.swift:19`. `NodeConfigService` auto-merged wrongly: `makeWriters()`
ends with the fork's `settleSwapGuard` lines and lacks `clearChannelSlot`.

**I. High — `phoneLocationProvider` not passed.** `buildServiceContainer`
(`+Preparation:87`) and `establishSimulator` build `ServiceContainer` without it; it
defaults to nil, so nothing fails and location stamping on messages silently stops.

**J. Medium — settings routing.** Drop the fork's `BlockingSection` from Chats: blocked
lists now open only from Blocks & Filters, and the old rows would do nothing. Rooms get
`adaptivePowerService = { nil }`, `signalDataAvailable = { false }` after taking
upstream's dependencies, or they gain no-repeats detection.

**K. Medium — sibling writes.** Upstream writes name and observations to one row by id
(fine, matches 1.6 as-built). Keep the fork's `add/removeDeviceKnownRegion` (all rows);
upstream's still use `fetchLimit 1`. A new row is saved with `lastConnected = now`
before the connection commits; a cancelled attempt leaves it looking like the primary
or a ghost [inferred] — stamp `lastConnected` in `selectConnectionDevice` for new rows.

**L. Medium — radio pill.** `BLEStatusIndicatorView` stays deleted; port upstream's
`connectionActivity` menu into `RadioStatusControl` (decision 4). Without it nothing on
the pill stops a reconnect loop.

**M. Medium — channel resend.** `updateMessageHeardRepeats` / `deleteMessageRepeats`
are gone; `prepareChannelMessageResend` replaces them and runs only when the timestamp
is not preserved. Put `clearMessagePacketScope` in that same branch. Re-apply the send
fix stamps in `createOutgoingChannelMessage`, `createOutgoingMessage`, and at transmit.

**N. Low.** Text Rules run before reaction handling; upstream's sender rule drops that
sender's reactions silently. Decision 5 lets reactions through instead. A keyword rule can
hide a shared-route message. Message search matches MECP wire text, not the decoded
reading. Simulator name becomes "Sim". `MESHWX_BRIDGE_URL` debug start moves to
`establishSimulator`. Widget key "Open MeshCore One" in ko and pt (older gap).

## 4. Compile breaks after resolution

- `MessageDTO.hopCount` is `Int?`: `MessagePathDetailView.swift:268,285`.
- `SessionEventStreaming` gained `eventsTracked(filter:)`, `finishEvents(id:)`:
  `MockBenchmarkSession`, `MockSignalBarsSession`, `StubSignalBarsSession`.
- `RemoteNodeService.handleBLEDisconnection()` → `handleLinkDisconnection(radioID:)`
  (`ConnectionManager+Lifecycle.swift:680`).
- `AdvertisementEvent.contactUpdated` now has associated values: `.contactUpdated()`.
- `.identityChanged` needs a case in `beginDisconnect` (`+Connect.swift:66`).
- `MessageServiceConfig.maxAttempts`: `MessageStatusTextTests`, and delete
  `MessageServiceConfigTests` (upstream deleted it; the trial tree keeps the fork copy).
- `ChatViewModel.Dependencies` lost `session:`.
- `updateDevice*(radioID:)` and `updateExistingDevice` are gone; rewrite
  `SharedIdentityFavoriteTests.swift:139-140`. Delete `resolveEffectiveRadioID` and tests.
- `BLEStateMachineProtocol`: re-add `releaseCentralManagerForAccessoryPicker()` and the
  mock's counter.
- Channel-send tests that count `sentData` need one more command answered (scope restore).
- `L10n.swift` is generated: `swiftgen config run --config swiftgen.yml`, never hand-merged.

## 5. Conflict resolution notes by area

**Connection (10 files).** Take upstream's structure everywhere; fork logic moves per
§3 A, B, G. `ConnectionManager+Pairing`: re-apply the iOS 27
`releaseCentralManagerForAccessoryPicker()` call and 300 ms wait in `pairNewDevice`,
before `discoverDevice()`; keep `otherRadiosCarryingConnectedIdentity()`.
`clearPersistedConnection`: fork's handover computed before the clear, upstream's
`notifyingRequestID` condition kept. `DevicePersisting` / `PersistenceStore+Devices`:
keep swap-guard, sibling and `fetchDevices` methods, add `updateDeviceOCVSettings`.

**Messaging (17 files).** Take upstream for `MessageService*`, `ChatSendQueueService`,
`AckCodeBuilder`, `MessageServiceConfig`, `ChatViewModel+Reactions`. Re-apply:
`phoneLocationProvider` and `currentSendFix()`, §3 D guard, §3 M, the fork's v1.15
repeater note in `AckCodeBuilder`. `ChatViewModel+EventStream` `.messageFailed`:
`noteNoRepeatsInput(.sendFailed)` then upstream's `handleMessageFailure`.
`SyncCoordinator+HandlerHelpers`: upstream's `rxEntry` shape plus
`contentHash: rxEntry.contentHash`. `MessagingSessionOps`: keep `sendChannelData`.

**Persistence and services.** §3 E. `PersistenceStore+Contacts`: keep
`stageClearingIdentityDeletions`, save with upstream's
`saveContactChangesBindingRecentlyBlocked`. `AdvertisementService`: upstream's batched
flush with the fork's `keysKeepingHistory` keep rule inside it. `ServiceContainer`: both
sides' parameters. `Package.swift`: fork targets plus `resources: [.process("MECP/Languages")]`.
`MockPersistenceStore`: both sides minus removed methods.

**App.** `AppState` / `+Wiring` / `+ChatPrefetch`: upstream's snapshot-based wiring with
fork services added (§3 F). Chat views: union of parameters; `BubbleFooterRow` takes
upstream's `sendAttemptProgress`; `UnifiedMessageBubble` takes upstream's spoken text
plus the duplicate-count suffix; `ActionsDetailsSection` keeps the fork's block.
Re-delete `MessagePathDetailBlock`, `MessagePathMapView`, `ContributionRow`,
`BLEStatusIndicatorView` (fork deleted, upstream modified). `SettingsDetail` /
`SettingsSubpage`: union of cases. `MC1App`: both lines.

**What's New (12 locales).** Keep both sides' keys; credit link "1.6" → "1.7"; content
per decision 6.

**Docs.** Keep the fork's five (code cites `guides/Sync.md` and `guides/Messaging.md`);
prune links to the seven upstream deleted.

## 6. Owner decisions (1–5 decided 2026-11-24; 6–7 assumed)

1. **DM attempts: upstream's 4 + 4.** The fork's 4-send cap is dropped. Take
   `DMSendBudget` and `AckCodeBuilder.attemptCount = 8` as upstream has them, rooms
   included. Keep the v1.15 repeater note in the `AckCodeBuilder` doc comment as a known
   limit (a late delivery through an old repeater may show Failed). The plan had
   recommended keeping the cap.
2. **Erasing a radio whose identity is on another radio: that radio only.** Reset the
   hardware and remove its Device row. Shared history stays while a sibling carries the
   identity. A pending or failed erase is scoped to the device and never blocks a
   sibling's connect or receive (RADIO_SWAP R1). The last radio of an identity keeps
   upstream's full wipe.
3. **Outgoing reactions: upstream's.** DM reactions are sent once and the badge appears
   when the radio accepts. The fork's rollback code goes; the wire format stays the
   fork's.
4. **Radio pill: add upstream's Cancel / Stop Reconnecting menu** to `RadioStatusControl`.
5. **Text Rules do not hide reactions.** Reactions pass through sender rules: in
   `shouldSuppressChannelMessage` and `admitDirectMessage`, a message that
   `isReactionText` recognises skips the rule check. This differs from upstream.
6. **Version and What's New (assumed).** 1.7.1 everywhere including `MC1UITests` (new
   App Store Connect version, Beta App Review). Sheet: upstream's four items (Blocks &
   Filters, Direct messages, Node telemetry, Live Activity), credit link "1.7".
7. **Debug log collection (assumed).** Off by default as upstream; testers turn it on
   before reporting.

## 7. Order of work

1. Commit this plan with the decisions recorded.
2. `git merge v1.7.1` on `upstream-sync-1.7`, rerere on. Resolve in this order:
   persistence and schema (§3 E), MeshCore, messaging, connection, app, strings, docs.
3. §3 A and B with tests before anything else builds on them: a second radio with a
   known key creates a sibling row; erase and Forget leave the sibling and shared
   history; a pending erase does not block the sibling.
4. §3 C–M, then §4 until both packages and the app build.
5. Regenerate `L10n.swift`.
6. Tests: `swift test` for MeshCore and MC1Services, `make test-app`. (`make test-store`
   needs an iOS 18 runtime this Mac lacks.)
7. On the phone: upgrade from the installed 1.6.2 store (migration, a queued reaction,
   several radios on one identity), Bluetooth ↔ Wi-Fi, a recovery, a radio swap.
8. §8 "As built", beta notes, then merge to `main` on the owner's word.

## 8. As built (2026-11-24)

Branch `upstream-sync-1.7`, cut from `upstream-sync-1.6` at 35d47e20, rerere on. Nothing pushed.

| Commit | What |
|---|---|
| 35d47e20 | The notification-caps work (sync slot 4), tested and committed first, on `upstream-sync-1.6`. |
| 6cd1da91 | This plan and the owner decisions. |
| 52cf9d77 | The merge (76 conflicted files), with §3 A–N, §4 and decisions 1–7. |

**Where the build differs from the plan:**
- **§3 A:** `registerConnectionDevice` takes `adoptingRowID`, `armsSwapGuard` and
  `previousDeviceID`; `PersistenceStore.adoptsAsOwnRow` is the adopt rule (no methods, Wi-Fi
  only, or a Bluetooth link to this same peripheral). A new row is saved with
  `lastConnected = .distantPast`; selection stamps it. A cancelled new sibling row has no
  methods, so a later connect of that radio adopts it as its own.
- **§3 B:** `PendingRadioErase` stays keyed by radioID (unique column), so one erase per
  identity at a time; a second radio's erase while another is pending is refused. Scope is
  evaluated live: while another row with a connection method carries the identity, the erase
  blocks and removes only its own radio; the last radio gets upstream's full wipe.
- **Removal re-scopes after the system sheet.** Found by test: forgetting radio A while
  sibling B was still connecting (B's row not yet registered) matched B by key and
  disconnected it. `removeDevice` now scopes the context again after confirmation.
- **Decision 1 reached MeshCore too.** `sendMessageWithRetry` had the fork's
  `min(maxAttempts, 4)`; it is upstream's loop again, which room posts (4 + 1) need.
- **§3 H:** a new `NodeConfigRecordsCopyView` owns the `.records` view model for the swap
  sheet and Copy to This Radio, since upstream's import view takes a caller-owned model.
  `importConfig` settles the swap guard with `importedRadioID ?? radioID`.
- **§3 L:** the pill's recovery section (Cancel Connection / Stop Reconnecting, then Change
  Device) is in the long-press menu and is checked before `connectedDevice`.
- **Simulator name** stays upstream's "Sim" (it comes from `MockDataProvider`).
- **A re-pair of the same radio under a new Bluetooth id** still leaves the old row as a
  sibling until it is forgotten, as before the merge; upstream re-keys the row in place.

**Upstream tests changed to the fork's rules:** `ConnectionRegistrationRekeyTests` and
`ConnectionRemovalConfirmationTests` (sibling rule; the Wi-Fi-only rekey-in-place case is
kept), `CanonicalIdentityConsumerTests` and `AdvertisementCleanupContractTests` (a
radio-deleted contact with messages is kept), the DM sender-rule reaction test (decision 5),
`ConnectionControlMenuTests` (the fork's pill). `ConnectionTestRadioTransport` answers the
fork's sync commands with "unsupported", as stock firmware does: without it ten app suites
timed out on the 5-second sync-slot and notification-caps probes.

**Tests (this Mac, Xcode 27.2, iPhone 17e / iOS 27.2 simulator):**
- MeshCore: 621 passed.
- MC1ServicesTests in chunks of 20 suites: 4,223 passed, none failed. Six CoreBluetooth
  suites abort `swift test` on the Bluetooth TCC check (BLEStateMachine, BondSuspectRecovery,
  DiscoveryWatchdog, EmptyGATTHold, BondShieldRefresh, ConnectionManagerBLEHealth), the
  known abort.
- MC1Tests (StoreKit suites skipped): 4,039 tests, 56 failed expectations in 17 suites.
  Fail the same way on pristine v1.7.1 in a clean worktree: AppConnectionOwnership,
  CLIProvenanceContract, ConnectionControlMenu, DiagnosticsSectionCollection,
  NodeConfigImportTailPresentation, OutgoingRepeatDetails, PairingRecoveryOwnership,
  RadioWiFiContractAdmission, RepeatRowAccessibility, SettingsTabNavigation (Connection).
  Recorded for 1.6: ChatChannelInfoPresentation, ChatPinInfoSheet, ChatsSearchFilter,
  GlassFilterBar, SearchFilterSpacing, NeighborSNRMapBuilder, SettingsTabNavigation
  (Support). Passed when rerun alone: one test each in NodeConfigImportRecovery,
  OfflineMapService and SettingsTabNavigation (Blocked Contacts).
- `make` needs GNU Make 3.82+, which this Mac lacks; the recipes were run by hand.
  `make test-store` still needs an iOS 18 runtime.

**Migration.** A copy of the phone's store opened with the merged schema on the Mac before
the install: integrity ok, every count identical, the two new tables added.

**Installed on the phone 2026-11-24 13:30** (52cf9d77, Debug, 1.7.1 over 1.6.2). Backups:
`phone-backups/2026-11-24-before-upstream-sync-1.7-install/` (10:59) and
`…-1325-before-upstream-sync-1.7-install/` (13:29), integrity ok. After the first launch
and connect (`…-after-1.7.1-first-launch/`): integrity ok; devices 6 = 6 (both rows of the
shared identity kept, the connected one active); channels 87, messages 130,279, repeats
119,201, reactions 1,042, rooms 21 unchanged; contacts 812 → 813 (one new advert);
favourites 81, contact pins 79, channel pins 20 unchanged; no pending erase.

**Still open (needs the phone or the owner):**
- Several radios on one identity: connect the sibling, then Forget and factory reset on one
  and check the other and the shared history.
- Bluetooth ↔ Wi-Fi, a recovery with Stop Reconnecting on the pill, a radio swap and Copy to
  This Radio through the reworked import screen.
- An 8-send DM through a v1.15 repeater (decision 1's known limit); a reaction to a DM and a
  channel message; a Text Rule with a reaction from the same sender.
- iPad layout pass.
- `fastlane beta` (new App Store Connect version: Beta App Review).

**Done 2026-11-24 after the install:** beta notes (BETA_CHANGES.md) and the What's New
sheet (884c5bde: the fork's "Forget one radio, keep the rest" first, then upstream's four
items, 12 languages); `upstream-sync-1.7` merged into `main` as 5d541471 (which also
brings in `upstream-sync-1.6`); `main` and both sync branches pushed.
- Next sync: `upstream/dev` is 24 commits past 1.7.1 (repeater watchlist, expanded Rx Log,
  MECP 1.4.1, background battery work).
