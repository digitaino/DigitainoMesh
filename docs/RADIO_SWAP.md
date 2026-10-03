# Radio swap: one identity, any radio

Branch: `feature/meshwx`. Status: owner decisions taken 2026-10-03 (§5); P1 and P2 built the same day (§4.1, §4.2); P3 to P5 not built. Code references were read from source on that date.

Rafael's brief: *"I would be using the same key on both radios. so I want everything to transfer over. can we design a better process to do this? I would like to be able to swap radios easily and keep all the same contacts and conversations etc."*

## Decision

Your conversations belong to your identity (your public key), not to a piece of hardware. The app's records are the source of truth for that identity's contacts, channels and settings. A radio's contact table and channel slots are a copy that the app keeps topped up.

When a known key turns up on hardware the app hasn't seen, that is a **swap**. The app must never treat it as a reason to delete anything. Every radio that carries your key appears in the radio list under your node name, and switching between them is one tap.

## 1. What the process is today

The app already rejoins your history when a radio with a known key connects. The 2026-09-01 work made that ordering-proof and stopped the contact prune from deleting chats. That process still has seven steps. It needs the old radio alive, and two of the ways people naturally do it lose data.

### The safest recipe on the current build

1. Connect to the **old** radio. Settings → Backup & Restore → export a `.mc1backup`. This is insurance only. Never restore it on the same phone to "fix" a swap.
2. Still on the old radio, go to Settings → Device Configuration → **Export Config**. Turn on every section, including Node Identity. The file then carries the private key, name, LoRa settings, position, channels and contacts.
3. Danger Zone → **Forget Device**. Choose the option that keeps data. This step is required. Reconciliation refuses to merge into a row that still has a Bluetooth pairing (`PersistenceStore+Devices.swift:266`).
4. Power the old radio **off**. Two radios with one key both on air would split your DMs between them.
5. Pair the **new** radio. It shows up as a fresh, empty node for a moment.
6. Settings → Device Configuration → **Import Config**. Pick the file and leave every section on. The app writes the following, then moves your history onto this radio (`NodeConfigService.swift:542-662`):
   - key
   - name
   - position
   - other settings
   - channels
   - contacts
   - LoRa settings
7. Nodes → pull to refresh, so the app learns the contacts it just wrote.

**If the new radio already carries your key** (flashed with another tool), the app adopts your history the moment it pairs. On a build without P1, the forced full sync then deletes every contact you never messaged or favourited, with its nickname, avatar, block and mute, and drops channel rows for slots the new radio has empty. With P1 (§4.1), that sync deletes nothing. Either way, still run step 6 with Channels and Contacts on, so the radio can actually reach those contacts and channels.

### What goes wrong, and where

| # | Hazard | Where |
|---|---|---|
| H1 | The first full sync on new hardware deletes every contact the radio lacks unless it is a favourite or has messages. Nicknames, avatars, blocks and mutes go with them. The full sync is forced on pair, on a tap in the picker, and on a device switch. | `ContactService.swift:196-242`; `ConnectionManager+Pairing.swift:65`; `DeviceSelectionSheet.swift:192` |
| H2 | Channel sync deletes the app's channel row for any slot that is empty on the radio. The messages stay, filed by slot number. If a different channel later lands in that slot, it inherits the old channel's history and notification settings. | `PersistenceStore+Channels.swift:205-217` |
| H3 | Config export skips empty slots, so a file position is not a slot number. If your old radio had a gap (say channels at 0–5 and 7), import shifts every later channel down by one. That files history under the wrong chat. | `NodeConfigService.swift:400-413` |
| H4 | A known key on a new Bluetooth id takes over the history and **deletes the old radio's row**. The old radio's system pairing is then swept at the next pairing. Going back means re-pairing it from scratch, and the takeover happens again in reverse. | `ConnectionManager.swift:934-937`; `ConnectionManager+Pairing.swift:110-136` |
| H5 | If you pair the new radio before forgetting the old one, you get two rows with the same key and your history split across them. This stays split across reconnects. | `PersistenceStore+Devices.swift:256-268` |
| H6 | The contact-sync watermark carries over from the old radio's row. It is the old radio's clock value, so it means nothing on the new radio's table. | `ConnectionManager.swift:1244`; `SyncCoordinator+Sync.swift:794` |
| H7 | Export reads only from the radio. A dead or lost radio can't be exported, even though the app holds every contact frame and channel secret. The private key is never saved on the phone. | `NodeConfigService.swift:141-187`; `KeychainService.swift` |
| H8 | The Import Key and Regenerate sheets write a key without rejoining history. The rejoin only happens on the next connect. | `ImportKeyViewModel.swift:63`; `RegenerateIdentityViewModel.swift:106` |

Copying contacts to the new radio is **functional, not cosmetic**. A MeshCore radio can only decrypt a DM from a sender in its own contact table, because the shared secret comes from the sender's key. A new radio with an empty table cannot receive DMs from people you already talk to until they are written onto it.

## 2. What you would see

### A. Switch to another radio that has your key

This covers going back and forth between a handheld and a base station, or picking up a spare.

- The radio list shows both radios under your node name, for example "Digitaino · RAK 3401 · connected" and "Digitaino · T-Deck · last used 2 days ago". Tap the other one.
- The app sees your key on hardware it knows, or hardware it hasn't seen yet. It syncs **without deleting anything** (rule R2), then compares the radio with your records.
- If the radio is behind, one sheet says so, for example: *"This radio is missing 214 contacts and 6 channels. Copy them over? About 40 seconds."* It lists what won't fit, and favourites and messaged contacts never drop. If the LoRa settings differ, it says so separately, because a wrong frequency takes you off the mesh.
- Messages that queued on this radio while it was away are pulled into the same conversations.

### B. Set up a brand-new radio as you

- Pair it. Its key is unknown, and the phone already has your identity, so the app asks before the first sync writes anything: *"New radio. Set it up as Digitaino, or use it as a new node?"*
- Choose **Set up as Digitaino**. One confirmation lists what will be written: key, name, LoRa settings, position, other settings, every channel at its own slot, and your contacts. Favourites and contacts with history come first, and anything that won't fit is listed by name. A progress bar follows.
- When it finishes, the radio reconnects as you, with every conversation in place.
- The private key comes from the phone's Keychain (rule R5), so **the old radio does not need to be present**. If the key was never saved, the app falls back to "connect your old radio once" or "import a config file".

### C. Decide about the old radio

The setup ends with one question: **Keep as spare** (it stays in the list), **Forget** (history stays), or **Give it a new identity** the next time it connects. "Keep as spare" carries the reminder to keep it powered off while the other is in use.

## 3. Rules

**R1. One identity, many radios.** Each physical radio keeps its own Device row, keyed by its Bluetooth id. Rows that carry the same key share one `radioID`, and all history hangs off that shared id.
- On connect, a known key on new hardware creates a sibling row. It no longer deletes the old row (H4). It still absorbs ghost rows and backup shadow rows as today.
- These fields belong to the hardware and stay per row:
  - Bluetooth and Wi-Fi methods
  - firmware
  - `maxContacts` and `maxChannels`
  - `maxTxPower`
  - battery curve
  - contact-sync watermark
  - last connected
- These fields belong to the identity and are written to every sibling:
  - name
  - known regions
  - default flood scope
- `fetchDevice(radioID:)` has eight callers. It returns the connected row first, then the most recently connected one. `updateDeviceLastContactSync` moves to the Device id.
- **Forget** on a radio that has a sibling removes only that hardware. "Delete data" and factory reset ask before touching shared history.

**R2. A protected first sync.** The first sync on hardware this identity hasn't used before, or the first after a key change, runs in protected mode. In protected mode:
- the contact watermark is reset for that hardware (H6);
- the contact prune does not run (H1);
- no channel row is deleted for an empty slot (H2).

Protected mode ends once the swap sheet has run or been dismissed. This rule alone removes the data loss in today's process.

**R3. The app's records are a valid config source.** Build a `MeshCoreNodeConfig` from the store:
- Device row: name, LoRa settings, position, other settings.
- `Channel` rows, which already hold the 16-byte secret (`Channel.swift:27`).
- `Contact` rows through `toContactFrame` (`Contact.swift:275`), which already carries type, flags, path and coordinates.
- The saved private key.

It feeds the existing planner and executor unchanged, so it reuses the capacity rule, the protected-contact rule, coordinate tolerance and diff-gated writes. Export Config gains a "from this phone's records" source, so a dead radio can still be exported (H7).

**R4. Channels go to their own slot.** The app-sourced config carries each channel's slot index. History is keyed by slot index, so the planner writes to that slot and does not fall back to "first free".
- If the target slot already holds a *different* channel on the new radio, the swap sheet asks before overwriting. It never shifts history (H3).
- The index stays internal, so the JSON file format doesn't change for other apps.

**R5. The phone keeps the key.** The app already reads the private key on every connect, for RX-log DM decryption (`SyncCoordinator+Sync.swift:408-415`). Save it in the Keychain under the public key:
- device-only and readable after first unlock;
- never synced to iCloud;
- never written to `.mc1backup`;
- Face ID is required to show or export it.

Settings → Radio gets "Remember this identity on this iPhone" and "Forget saved key". Firmware built without key export still works through the fallbacks in flow B.

**R6. Ask before the first sync, not after.** A freshly paired radio with an unknown key holds at the "set up as…" question before `buildServicesAndSaveDevice` creates a new partition. This avoids the interim `radioID` whose rows are orphaned when the rejoin happens later (H5). Any path that writes a key (Import Key, Regenerate, config import) runs the rejoin immediately (H8).

**R7. One radio on air per key.** The swap sheet and the spare-radio row both say it in plain words. If the radio is on, it receives DMs and queues them; they appear when you next connect it. Optional and not yet verified: watch the RX log for an advert that carries our own key but isn't ours, and warn that "your other radio appears to be on".

**R8. Nothing here goes on the wire.** Every write is a stock companion command: import private key, set name, set radio params, set channel, add contact. This works on stock firmware and leaves other apps unaffected. Firmware built without private-key import or export degrades to the file fallback.

## 4. Build phases

| Phase | What | Fixes | Size |
|---|---|---|---|
| P1 | Protected first sync on new hardware or a new key (R2), and the watermark reset. **Built 2026-10-03** | H1, H2, H6 | Small; contact and channel sync gates plus tests |
| P2 | Config from the app's records, slot-exact channels, and a "Copy to this radio" action in Settings (R3, R4) | H3, H7 (data half) | Medium; planner input and one screen. **Built 2026-10-03** |
| P3 | Keychain key custody, and "Set up as …" at pairing (R5, R6) | H5, H7 (key half), H8 | Medium |
| P4 | Sibling rows: every radio in the list, one-tap switching, Forget-one semantics (R1) | H4 | Largest; Device lookups, delete paths, picker |
| P5 | Same-key-on-air warning (R7, optional) | none | Small, if the RX log shows it |

P1 is worth building before your next swap even if nothing else is. P1 to P3 cover a one-way replacement. P4 is what makes going back and forth one tap.

### 4.1 P1 as built

**Arming.** `ConnectionManager.buildServicesAndSaveDevice` computes `tookOnIdentity`. It is true in three cases:
- a known public key on a radio id with no row;
- a ghost rejoin on connect;
- a stored key different from the radio's.

`createDevice` then zeroes the watermark, and `armSwapGuard(id:)` sets `SwapGuard.all` before any sync runs. If arming fails, the connect fails rather than syncing unguarded. `reconcileGhostIdentity` arms the guard too, which covers the config-import rejoin.

**Storage.** `Device.swapGuard` is a `UInt8` and is model-only. It is not in `DeviceDTO` and not in `apply`, so it never appears in a backup, and a stale snapshot cannot release it. The precedent is `knownRegions`.

**Holding back.**
- `ContactService.pruneOrphans` keeps cache contacts while `.contacts` is held.
- `ChannelService.finalizeChannelSync` passes no unconfigured indices and no capacity prune while `.channels` is held.
- A failed guard read holds back too.

**Releasing.** Each part is released by the first sync of that part that would delete nothing. For contacts, that means a complete snapshot, with the existing prune preconditions. For channels, it means a pass with no read errors.

**Tests.**
- `RadioSwapGuardTests`: store rules, ghost rejoin, `createDevice` watermark.
- `ContactServiceSyncTests`: three guard cases.
- `ChannelServiceSwapGuardTests`: three cases.

**What P1 does not do**, and which phase covers it:
- **A slot holding a different channel on the new radio is still overwritten in place.**
  - The app has to show what the radio will actually send to, so the overwrite is necessary.
  - The displaced channel's secret leaves the app, and stays recoverable only from the old radio, a config file or a `.mc1backup`.
  - P2 must ask before this sync overwrite, and stash what it displaces.
- **The guard can stay armed indefinitely on a radio that cannot hold everything** (more contacts than `maxContacts`).
  - This is benign: the app keeps contacts the radio lacks, and nothing is deleted.
  - Contacts removed from the radio by another app are not pruned from the phone either.
  - P2's top-up and swap sheet decide when to release.
- **H3, H4, H5, H7 and H8 are unchanged.** Config import still files channels by file position. A known key on new hardware still deletes the old radio's row. The private key is still not kept on the phone.

**Known-red tests found while verifying, not caused by P1:**
- `SyncCoordinatorTests` "Full sync prune removes a favourite absent from a complete device set" asserts the pre-2026-09-01 behaviour, which deleted favourites. HEAD's rule keeps them, so the test is stale.
- The full `swift test` run aborts on the macOS Bluetooth privacy (TCC) check in `ConnectionManagerBLEHealthTests`, as recorded on 2026-08-30.

### 4.2 P2 as built

**The identity profile.** `IdentityProfile` holds the identity's name, LoRa settings, position, other settings and channel layout, slot by slot. It is stored on the Device row as `swapProfile`, model-only like `swapGuard`.
- `armSwapGuard(id:previousDeviceID:)` captures it from the previous radio's row and from the channel rows before any guarded sync touches them. `reconcileGhostIdentity` captures it from the ghost.
- If the previous radio's own swap was never settled, its stored profile carries forward, because its rows may already mix two radios' channels.
- A forget-and-re-pair carries both the guard and the profile into the ghost.
- **Why this is needed:** the connect that arms the guard rebuilds the Device row from the new radio's `SelfInfo`, and the first guarded sync relabels any slot where the new radio holds a different channel. Without the profile, "copy from the phone" would copy the new radio back onto itself.

**Channel release.** The channel guard is now released only when nothing would be deleted *and* the radio holds every profile channel in its own slot (`IdentityProfile.channelsOutOfPlace`). Before P2, a relabelled slot released the guard, and the identity's channel was lost from the records.

**Config from the phone's records.**
- `NodeConfigService.recordsConfig(radioID:sections:)` builds a `MeshCoreNodeConfig` from the profile while the guard is armed, and from the Device row and channel rows otherwise.
- Every contact comes from the store. A favourite gets the radio's favourite flag, so overwrite-oldest spares it.
- TX power is capped at this radio's maximum.
- The private key is never included.
- Channels carry `ChannelConfig.slot`. It is excluded from the JSON coding keys, so files are unchanged.

**Slot alignment.** `planChannelAlignment` is pure and unit-tested. For each of the identity's slots:
- **Already in place:** nothing is written.
- **Empty slot:** the channel is written there.
- **One of your channels sitting in the wrong slot:** your channel is written to its own slot. The slot it vacated is reused or emptied (`ChannelService.vacateSlot`, which keeps the messages), because firmware files a message under the first slot whose secret matches.
- **The radio's own channel in your slot:** this needs **Make Room for Your Channels**, which is off by default.
  - With it on, the radio's channel moves to a free slot, or is removed if none is left. Both cases are listed in the confirmation.
  - With it off, your channel is left off and reported. So is any slot whose occupant could not otherwise reach its home slot.
- A slot past this radio's last one is reported, not shifted.
- A file config without slots still uses the old first-free-slot planner.

**Screens.**
- Settings → Device Configuration → **Copy to This Radio** reuses the import screen with the phone's records as its source. Name, channels and contacts start switched on. Radio, position and other settings start off, with their difference shown: one tap aligns them (decision 3). A profile captured from a restored backup's row carries factory defaults in exactly those fields, so a radio must never be retuned to them unasked. The channel and contact counts come from a planner preview.
- Export gains **From This Phone's Records**, so a file can be made without the old radio.
- After the first sync on a radio whose guard is armed with a profile, the same screen opens as a sheet (`RadioSwapPromptState`, owner decision 2). It is offered once per arming: closing it records the profile's capture date per radio. An offer the connection ended before showing comes back next connect. It yields to the connection alerts and What's New, and the stale-location alert yields to it.

**Not built in P2:**
- The quiet top-up on later switches. Before P4, every switch re-arms the guard, so every switch asks; the top-up belongs with P4.
- A "keep this radio's channels as mine" action, which would release the guard without copying. Until then a declined copy leaves the guard armed, which is harmless.

**Verification.** 1,076 services tests pass across the sync, contact, channel, persistence, device, import and swap suites. Two notification-sync tests time out only when the whole set runs in parallel; they pass on their own. The app target's offer, location-prompt and import-screen suites pass too. In the simulator, the copy screen can't be driven past "Checking this radio…" because the simulator's mock transport never answers reads. The on-radio check is outstanding.

## 5. Owner decisions (taken 2026-10-03)

Rafael: *"yes on all of them and yes I will probably be going back and forth. keep it as spare, I guess?"*

1. **Keep the private key on the phone: yes.** Use the protections in R5: device-only, no iCloud, not in backups, Face ID to view or export.
2. **Copy or ask: ask the first time each radio is used, then top up quietly.**
   - A slot that holds a different channel is never overwritten without asking.
   - LoRa settings are never changed without asking.
3. **LoRa settings belong to the identity.** They are copied during setup. When they differ on a later switch, the app shows the difference with one tap to align.
4. **Build P4: yes.** Rafael expects to go back and forth between radios, so one-tap switching is in scope.
5. **Old radio default: Keep as spare.** Tentative ("I guess?"); revisit when P3's closing question is built.

## 6. Open checks before building

- That key export and import are both enabled on your RAK 3401 and the new radio's firmware. Both worked on 2026-09-01; check the new radio.
- Whether a DM heard by both radios (both on at once) shows up twice when the second radio's queue drains. That depends on message dedupe on receive.
- Stale code found while mapping this:
  - `setActiveDevice` has no production callers, so every row keeps `isActive = true`, and the comment at `PersistenceStore+Devices.swift:239-247` relies on behaviour that no longer exists.
  - `ContactService.migrateAppFavoritesToDevice` is dead code.
  - The `exportPrivateKey` doc comment says 32 bytes; the parser returns 64.
