# MeshWX alert notifications: design

Status: design only, 2026-09-29. Nothing here is built. Line references are to the committed
trees: the app at `feature/meshwx` `824dd9eb`, the bot at `main` `e79b723`, and stock companion
firmware at tag `companion-v1.17.1`. Spec revision 12 (a warning's start time,
`docs/MESHWX_REV12.md`) was being written into both working trees while this was written; this
design uses its names (`begins_before` on the wire, `MeshWXWarning.beginsMinutes`,
`WeatherStoredWarning.beginsAt`, `WeatherFormatting.alertClock` and `alertWindow`) and changes
nothing it decides.

Why this exists: Rafael saw a Flood Watch in the Weather tool (`FA.A.EWX.8`, issued 2026-09-29
09:24 local, in effect from Wednesday evening through Friday evening, covering Austin TX) and said
*"we need to design a system where we get push notifications for alerts like this."*

This document supersedes nothing yet. Where it contradicts a recorded owner decision
(docs/MESHWX_UI.md §3.1 N-1 to N-8) it says so in §3.1 and asks in §8.

---

## 0. Summary

**Why no notification fired.** The app already has an alert notifier (docs/MESHWX_UI.md §16),
and it drops every watch on purpose. A Flood Watch is VTEC significance `A`, which ranks 7
(`WeatherAlerts.swift:124`), and the gate returns nothing for any rank above 6
(`WeatherAlertWatch.swift:166-170`). That is owner decision N-5 (2026-09-16, docs/MESHWX_UI.md:150:
*watches, advisories and statements, never*), pinned by the test `watchesNeverNotify`
(`WeatherAlertNotifierTests.swift:320-328`), and the Alert notifications screen says it in so many
words (`Weather.strings:1141`: "Watches, advisories and statements never do."). **No setting would
have changed that.** Three other gates would also have had to be open: a bell on a saved place or
on My location (nothing is watched by default, N-2), notification permission, and the app running
with the radio connected.

**Recommendation.** Replace the two-way "storm warnings plus a silent toggle" rule with one
per-phone level (*Storm warnings only* / *Warnings and watches* / *Warnings, watches and
advisories*) and three loudness classes: storm warnings sound, other warnings and watches show a
banner without a sound, advisories go to Notification Center only. Post one notification per alert
(not per place). With spec revision 12, a watch that starts later is announced as "from Wed 7:00
PM" and a local reminder, scheduled on the phone and needing no radio, fires when it starts. A
radio queue drained at reconnect produces at most one sound and one summary. No internet anywhere;
APNs is not part of the plan.

---

## 1. What happens today

### 1.1 From the bot to the lock screen

| Step | What happens | Where |
|---|---|---|
| 1 | The bot replays NWS products into per-zone VTEC state. An event is "active" while any zone's end time is ahead, **including zones whose start is days away**, so a watch for Wednesday is broadcast on Tuesday at issuance | `meshwx/meshcore_weather/protocol/vtec_events.py:50-51, 61-63, 117-119` |
| 2 | Each warnings run sends a Warning (type 1) for every new or materially changed identity (expiry to the minute, tags, zone set, vertex count; revision 12 adds the start). Wording-only reissues (NWS `CON` statements) send nothing, and nothing is sent when a watch's start time arrives | `schedule/executor.py:47-90`, `protocol/v5_builders.py:345-360` |
| 3 | New `TO.W`, `SV.W`, `FF.W`, `EW.W` go out once more, same content, new `seq`, 90 s later in code (the spec says "about two minutes"). A watch gets no repeat | `executor.py:24, 62-67, 76`; `v5_builders.py:30`; spec §3 |
| 4 | Every packet the bot hears no repeater echo for is resent once, byte for byte, same `seq` | spec §2.3 |
| 5 | A Cancel (type 2) only when an identity ends more than 5 minutes before its stored expiry; a Digest (type 3) every 3 hours and one minute after any cancel | `executor.py:79-88`; spec §4, §5 |
| 6 | The phone's companion radio receives the `GRP_DATA` frame. With the phone connected it pushes `MSG_WAITING` over BLE; with the phone away it queues the frame. **Stock companion v1.17.1 holds 16 frames and, when full, drops the oldest channel frame (text or datagram, any channel) to make room** | DigitainoMeshCore `companion-v1.17.1`: `examples/companion_radio/MyMesh.h:62-63`, `MyMesh.cpp:214-241` |
| 7 | The BLE notification wakes the app (`UIBackgroundModes` = `bluetooth-central`, `project.yml:125-126`), the session fetches the frame, and `WeatherService` stamps it live or backlog at arrival: backlog means `MessagePollingService.pollAllMessages` is draining the radio's queue, which is phase 3 of the connect-time sync | `WeatherService.swift:497-508`; `MessagePollingService.swift:63-70, 212-239`; `SyncCoordinator+Sync.swift:203` |
| 8 | The reducer applies it. An echo resend is a `.duplicate` (same `seq`, same fingerprint) and changes nothing; the 90 s repeat has a new `seq` and replaces the stored copy by identity | `WeatherStateReducer.swift:121-122, 338-367` |
| 9 | A live, non-duplicate message moves `lastLiveHeardAt`; a backlog one does not. Either way the service yields `.received(…, isBacklog:)` | `WeatherService.swift:732-746` |
| 10 | `WeatherAlertNotifier` (an actor in `ServiceContainer`, started before the drain so it sees the backlog too) picks out `warningStored`, `warningRemoved` and `digestApplied` | `ServiceContainer.swift:398-407, 499-505`; `WeatherAlertNotifier.swift:95-122` |
| 11 | Nothing watched: stop. Notifications not authorized: stop | `WeatherAlertNotifier.swift:124-125, 131` |
| 12 | For each watched place it places the warning (`here`, `near` within 50 km, `checking` while the 15 MB county and zone outlines load, `unplaced`, `elsewhere`) and ranks it (0 Tornado … 5 Severe Thunderstorm, 6 other warnings, 7 watches, 8 advisories, 9 statements) | `WeatherAlertNotifier.swift:159-180`; `WeatherAlerts.swift:44-129` |
| 13 | The gate: ranks 0-5 covering the place, sound; rank 6 covering, silent if the toggle is on; ranks 0-1 near, sound if the nearby toggle is on; **everything else, nothing** | `WeatherAlertWatch.swift:151-177` |
| 14 | The rules: expired never; no delivery means nothing (or a removal of what stood); backlog only for ranks 0-5; a repeat replaces silently; an escalation sounds again | `WeatherAlertNotificationRules.swift:123-184` |
| 15 | The poster adds a `UNNotificationRequest` with no trigger: `.active` plus the default sound, or `.passive` with none. No Time Sensitive or Critical entitlement exists (there is no `.entitlements` file in the project) | `WeatherAlertNotificationPoster.swift:30-53` |
| 16 | In the foreground a `.passive` weather notification is list-only; everything else gets a banner and a sound | `NotificationService.swift:888-898` |
| 17 | A tap is handed to `WeatherAlertNotificationTap`, the router selects the Tools tab and Weather, and the tool pushes the alert on the watched place's page | `NotificationService.swift:957-962`; `WeatherAlertNotificationRouting.swift:47-50`; `WeatherToolModel.swift:416-426` |

### 1.2 Why `FA.A.EWX.8` did not notify

Taking the Flood Watch through those steps, with every gate as favourable as it could be:

1. It arrived as a Warning at issuance (step 1: the bot sends watches that start later, because
   the zones' end times are ahead). Revision 11 carries no start time, so the app holds it as in
   effect from the moment it arrived; "from Wednesday evening" was only in the NWS text and the
   bot's own text replies (v4 carried the start, v5 dropped it; `docs/MESHWX_REV12.md`).
2. It is zone-based, so placing Austin needs the outlines. If they were not loaded it was parked
   as `checking`, the outlines were parsed, and it was judged again (`WeatherAlertNotifier.swift:271-301`).
   So the notifier did real work for it.
3. Rank: `FA.A` is not one of the six storm warnings, so `MeshWXSeverity(vtec:)` reads the letter
   `A` and returns 7 (`WeatherAlerts.swift:121-124`).
4. Gate: `.here` with rank 7 falls through both `if`s and returns nil (`WeatherAlertWatch.swift:167-170`).
5. Rules: `guard let delivery else { return posted == nil ? .none : .remove }`
   (`WeatherAlertNotificationRules.swift:147`). Nothing is posted, nothing is logged.

Answers to the specific questions:

| Question | Answer |
|---|---|
| Settings off by default? | Yes, but irrelevant here. Bells are off until the user turns one on (N-2), and the *Other warnings* toggle is off by default (N-4). Neither toggle covers watches |
| Watches excluded? | **Yes, unconditionally.** N-5, the gate, the test and the screen's own footer |
| Only warnings? | Only the six storm warnings with sound, other warnings silently on a toggle |
| Only in the foreground? | No. The notifier runs at connection lifetime, foreground or background, with the tool closed. It needs the process alive and the radio connected (§4) |
| Only some places? | Only saved places with the bell on, and My location if its bell is on (matched against the last position the app took, which can be hours old) |
| Would it have notified from the queue at reconnect? | No, twice over: a backlog message notifies only for ranks 0-5 (`WeatherAlertNotificationRules.swift:148`) |

Whether any bell was on on Rafael's phone is not something I could read without the phone. It
does not change the answer.

### 1.3 Other things this reading found

These are not why the Flood Watch was silent, but a design that adds more notifications makes each
of them matter more.

1. **The late line is wrong.** A drained message was received by the radio while the *phone* was
   not connected to it; the radio was in range, or it would have nothing to queue. The shipped
   text says "Received late — sent while your radio was out of range." (`Weather.strings:1174`,
   `WeatherAlertNotification.swift:153`). It also breaks house style (an em dash).
2. **A live warning can be stamped late.** Auto-fetch starts only after the full sync
   (`SyncCoordinator+Sync.swift:404-406, 448-450`), so messages that arrive during its contacts and
   channels phases sit in the radio's queue and are drained in phase 3
   (`SyncCoordinator+Sync.swift:195-203`). A warning issued a minute ago is then worded as late.
3. **Taps with no radio connected probably go nowhere.** The notification centre's delegate is the
   per-connection `NotificationService`, assigned only when services are wired
   (`AppState.swift:692`; the per-connection lifetime is stated at
   `WeatherAlertNotificationRouting.swift:7`). The delegate is a weak reference, so after a
   disconnect, or on a cold launch from a tap before the radio connects, the tap is not delivered
   to `WeatherAlertNotificationTap`. Apple's documentation says to assign the delegate before
   launch finishes. *Unverified on device.*
4. **A Bluetooth restoration relaunch may not recreate the central.** `CBCentralManager` with the
   restore identifier is created by `connectionManager.activate()` (`AppState.swift:561`,
   `BLEStateMachine.swift:263-290`), which runs from `appState.initialize()` inside the root view's
   `.task` (`MC1App.swift:196-199`). There is no app delegate. The app's own comment says a
   background-launched intent "runs only `App.init` (no scene, no `.task`)" (`MC1App.swift:37-40`).
   If a restoration relaunch behaves the same, iOS relaunches the app and nothing takes the
   restored connection. §16.1 of the UI spec calls relaunch "unverified"; this makes it doubly so.
5. **Nothing guards the background time.** A zone-listed product in a background wake can trigger
   the 15 MB outline parse (`WeatherAlertNotifier.swift:271-301`) with no background task or
   expiring activity around it.
6. **The source line can change bots.** The subtitle is built from the bot whose copy was just
   evaluated (`WeatherAlertNotifier.swift:194`), while the tap target keeps the first bot
   (`:203`). A second bot's copy replaces "via WX-AUS" with its own name.
7. **The notifier parks and places warnings the gate will refuse anyway.** Placement runs before the
   rank check, so a watch can cause the outline parse in the background for nothing.
8. **Weather alerts are invisible from Settings.** Settings › Notifications lists chats, rooms,
   reactions, battery and discovery (`NotificationSettingsSection.swift:39-76`); the only way in is
   inside the Weather tool.
9. **On iPhone a tap lands on the Tools list**, not the alert (known, §16.6 of the UI spec;
   `WeatherAlertNotificationRouting.swift:12-18`).
10. **Out-of-coverage answers are pruned by the next digest.** The digest lists only the bot's own
    coverage (`executor.py:91-98`), and an identity the app holds that a digest omits is removed
    (`WeatherStateReducer.swift:439-449`). A warning someone fetched for a place outside coverage,
    and its notification, go at the next digest. From reading, not tested.
11. **Web**: `sw.js` has no `notificationclick` handler, but `main.js:147` registers it and the
    poster prefers the worker (`notifications.js:164-172`), so a click does nothing. The web
    notifications screen shows the iOS promise (`WeatherAlertNotificationsView.js:136`) instead of
    `web.notifications.promise` (`WeatherCopy.js:1066-1068`), so it says "while DigitainoMesh is
    running" in a browser tab.

---

## 2. Requirements, in the owner's terms

1. **"Push notifications for alerts like this."** A Flood Watch covering a place I care about
   reaches my lock screen with the phone locked and the Weather tool closed.
2. **No internet.** Everything arrives over LoRa through the companion radio. Apple push (APNs)
   needs a server and an internet connection on the phone; at most it could be an optional extra,
   and nothing in this design depends on it or plans it.
3. **Stock MeshCore firmware and stock apps.** No firmware change. The only wire change is
   revision 12's optional start time, which older apps skip.
4. **No airtime.** Nothing polls the radio or the bot, on a timer or otherwise. Notifications are
   derived only from what the bot already broadcasts. A local timer that fires a notification on
   the phone is not airtime and is allowed.
5. **Opt-in, per place** (N-1, N-2 stand). A bell on a place, nothing automatic.
6. **Loudness matches urgency.** A sound means act now. A watch two days out must not sound at
   3 AM, and a summer of Heat Advisories must not become noise.
7. **One alert, one notification.** Repeats, echo resends, updates, two bots and several watched
   places under one alert do not multiply it.
8. **Coming back is handled.** A phone that reconnects after six hours is told what still matters,
   once, with at most one sound, and never told old news as new.
9. **Honest words.** When it was issued, when it starts, when it ends, who sent it. Never an
   all-clear ("the warning ended" is not "the weather is fine", UI spec §16.4). Never a claim that the
   phone has everything.
10. **House style.** Matter-of-fact, no em dashes, no exclamation marks.
11. **The tap opens the alert**, with or without a radio connected.
12. **The web client** follows the same rules while its tab is open, and says it cannot do more.

---

## 3. Design

### 3.1 What this changes, against recorded decisions

| Decision | Today | This design | Why |
|---|---|---|---|
| N-1 per place | Bell per saved place and My location | **Kept** | |
| N-2 opt-in | Nothing watched until a bell is on | **Kept** | |
| N-3 storm warnings with sound, covering only | Ranks 0-5 | **Kept**, and proposed to **extend** to four short-fuse warnings (§3.2). Owner decision | They are act-now warnings the same way; Austin will rarely see them, a nationwide bot will |
| N-4 other warnings silent, off by default | `.passive`, toggle off | **Changed**: a banner without a sound, and on at the recommended default level. Owner decision | If a Flood Watch deserves a push, a Flood Warning cannot be quieter than it. `.passive` is Notification Center only: it does not light the screen, which is not a push in any sense Rafael meant |
| N-5 watches never | Never | **Overturned** by Rafael's request of 2026-09-29. Watches notify at the *Warnings and watches* level, banner without sound. Advisories become an opt-in, Notification Center only. Statements stay never | The request itself |
| N-6 nearby tornado toggle | Ranks 0-1 within 50 km | **Kept** | |
| N-7 My location is the last position | Last fix, age always shown | **Kept** | |
| N-8 near becoming here sounds again | Implemented, awaiting confirmation | **Kept**, still awaiting confirmation (§8) | |
| UI spec §16.4, one notification per warning **per place** | Per place | **Changed** to one per alert, naming every watched place it covers. Not an owner decision, but written in the spec | A Flood Watch covers most of a WFO's zones; four saved places around Austin would get four identical banners |
| UI spec §16.4, nothing scheduled | No scheduled notifications | **Changed** for start times only (revision 12): a reminder at the start. Nothing is ever scheduled for an expiry and there is still no all-clear | A watch issued Tuesday for Wednesday evening is exactly the case where the phone knows something useful about a future moment and the radio will say nothing then (the bot sends nothing at a start time, §1.1 step 2) |

### 3.2 What notifies: levels and classes

One **level** for the phone, chosen on the Alert notifications screen, applied to every watched
place. The nearby tornado toggle stays as it is.

| Level | Storm warnings | Other warnings | Watches | Advisories | Statements |
|---|---|---|---|---|---|
| Storm warnings only (today's behaviour, without the rank-6 toggle) | Yes | No | No | No | No |
| **Warnings and watches** (recommended default for a first bell) | Yes | Yes | Yes | No | No |
| Warnings, watches and advisories | Yes | Yes | Yes | Yes | No |

Each alert falls into one **class**, which decides how loud it is. The class is fixed by the event,
not chosen by the user; iOS's own settings (Focus, sounds off, Scheduled Summary) do the rest.

| Class | Events | iOS delivery | Where it can come from |
|---|---|---|---|
| **Act now** | Ranks 0-5 today: `TO.W`, `EW.W`, `FF.W` (catastrophic first), `SV.W` (tornado-tagged first). **Proposed additions**: `TS.W` Tsunami, `SS.W` Storm Surge, `SQ.W` Snow Squall, `DS.W` Dust Storm. `HU.W` Hurricane is an owner question (§8) | Banner and sound, `.timeSensitive` once the capability is added (§4.5), `.active` until then | Covering the place; ranks 0-1 also near, with the toggle |
| **Know now** | Every other warning (`FA.W`, `FL.W`, `EH.W`, `XH.W`, `HW.W`, `FW.W`, `WS.W`, `BZ.W`, `IS.W`, `FZ.W`, `HZ.W`, `EC.W`, `WC.W`, `TR.W`, `HU.W`, `CF.W`, `DU.W`, marine warnings…) and every watch (`TO.A`, `SV.A`, `FF.A`, `FA.A`, `FL.A`, `EH.A`, `HW.A`, `FW.A`, `WS.A`, `FZ.A`, `HZ.A`, `TR.A`, `HU.A`, `SS.A`, `TS.A`, …) | Banner, **no sound**, `.active` with `sound = nil`. Lights the lock screen; silenced by Sleep Focus like any ordinary notification | Covering the place only |
| **Quiet** | Advisories (`…Y`: `HT.Y`, `WI.Y`, `FA.Y`, `WW.Y`, `FG.Y`, …) | Notification Center only, `.passive` | Covering the place, at the advisories level only |
| **Never** | Statements (`SPS`, `RP.S`, `BH.S`) | Nothing | They stay on the dashboard |

By event, for Austin's common cases: a Tornado Warning sounds; a Tornado Watch shows a banner (it is
nearly always in effect when it arrives, and the warning inside it will sound). A Flash Flood
Warning sounds; a Flood Warning, a Flood Watch and a Flash Flood Watch show banners; a Flood
Advisory is Notification Center only, and only at the advisories level. An Extreme Heat Warning or
Watch shows a banner; a Heat Advisory, which Austin has most summer afternoons, is Notification
Center only at the advisories level and nothing otherwise.

The rank order the dashboard uses (`WeatherAlertPriority`) is unchanged; the class is a separate,
explicit table so that "which events sound" is one list the owner can read and amend.

The gate is checked **before** placement (fixes §1.3 item 7): an alert whose class the level
refuses is never placed, so it never loads the outlines.

### 3.3 Subscriptions and defaults

- Bells: unchanged. Per saved place and My location, off until turned on, permission asked at the
  first bell and at no other moment (§16.6 of the UI spec).
- The level: one value in `WeatherAlertSubscriptions`, replacing `notifiesOtherWarnings`. A phone
  that never touched the screen has no level stored; its default is decided in §8 Q2 (recommended:
  *Warnings and watches*).
- Existing phones: `notifiesOtherWarnings = true` maps to *Warnings and watches*. `false` maps to
  whatever the owner decides in §8 Q11 (recommended: *Warnings and watches* once, since the only
  phones with bells today are the owner's and he asked for this).
- Turning a bell off, lowering the level, or removing a place removes that place's delivered
  notifications for alerts it no longer qualifies for, and every pending start reminder that no
  longer has a watched place to be for.
- A per-place level (home: everything, office: storm warnings) is possible later; not proposed now
  (§8 Q9).

### 3.4 One alert, one notification

**The key is the identity** `(event, office, etn)` (spec §2.3). The request identifier becomes
`wx-<event>.<office>.<etn>`, for example `wx-FA.A.EWX.8`, with no bot and no place in it. The
ledger (`WeatherAlertPost`, one defaults blob) keeps one row per identity with the watched places
it was posted for and whether each was covered or near, so the per-place escalation (near becoming
here) still works. Rows written by today's build are read as one row per identity on first load.

| Case | What the phone sees | What happens |
|---|---|---|
| Echo resend | Same bytes, same `seq` | Reducer `.duplicate` (`WeatherStateReducer.swift:121-122`); the notifier never sees a change. The radio usually drops it first (MeshCore dedupes by packet hash) |
| 90 s life-safety repeat | Same content, new `seq`, update flag clear | Replaces the stored copy. If the words a notification would carry are unchanged, **nothing is posted** (today it re-adds silently, which also reorders Notification Center). If they changed, a silent replacement |
| Update, same alert | New `seq`, update flag set | Silent replacement with the new words. One the user dismissed is not brought back (today's rule) |
| Escalation (act now only) | Tornado tag rises, flood damage reaches catastrophic, near becomes here, or expiry extended with the last sound more than 20 minutes ago | Sounds again (today's rules, `WeatherAlertNotificationRules.swift:170-184`) |
| Extension of a watch or other warning | Later `expires` | Silent replacement: "until Sat 7:00 AM". Never a second banner |
| Zones added (`EXA`, `EXB`) so a watched place is newly covered | Update | For that place it is new: the class's normal delivery (banner for a watch). If a notification already stands for another place, it is replaced and a banner is shown once |
| Zones removed so a place is no longer covered | Update | That place is dropped from the notification; if none is left, it is removed |
| Two bots | Same identity from WX-AUS and another bot | One notification. The first bot to deliver it names the source line and keeps it (fixes §1.3 item 6) |
| Several watched places | One Flood Watch over Austin, Round Rock and San Marcos | One notification: "Austin, Round Rock and San Marcos · …"; four or more: "Austin, Round Rock and 2 more · …" |
| ETN reuse | Offices restart ETNs each year | The ledger forgets a row 6 hours after its alert expires (`WeatherAlertNotificationRules.swift:89`), so a new year's `FA.A.EWX.8` is new |
| Upgrade (watch to warning, warning to a worse one) | A new identity. If the old one ends, its Cancel says reason 0 (this bot never sends 2, spec §4) | The new identity gets its own class. The watch's notification stays while the watch is active (NWS keeps watches running while warnings are issued inside them) |

### 3.5 Start times (spec revision 12)

Revision 12 adds `begins_before`, two optional bytes after the issue time: minutes between the
start and `expires`, sent only when the product takes effect later than it was issued, and taken
from the earliest VTEC begin across the event's active zones (`vtec_events.py:61-63`). A moved
start resends the warning, like a moved expiry.

**What revision 12 already gives this design** (`docs/MESHWX_REV12.md` §1-§2): the start resolved
once at receipt into `WeatherStoredWarning.beginsAt`, so a digest that extends the expiry cannot
walk it forward (the trap documented for the issue time, `WeatherBotState.swift:17-25`); a later
copy without a start (an older bot) does not erase it; a value outside issuance-to-expiry is
dropped by the decoder; and notification bodies built with `alertWindow(…, countdown: false)`, so
the storm-warning notifications that exist today will already say "from … until …". This design
adds everything that happens *because* a start is known: whether to announce, when to remind,
and what an update does.

One consequence of deploying it: the bot's fingerprint gains the start, so the first run of a
revision 12 bot resends every active warning that has one. The phone reads each as an update to an
identity it holds. Under this design that is a silent replacement (the words change from "until …"
to "from … until …") and a reminder scheduled; never a second banner.

**At issuance, starting later** (start more than 60 minutes after the phone receives it):

- One banner for a know-now alert, words "from Wed 7:00 PM until Fri 7:00 PM".
- A **start reminder** is scheduled on the phone for the start time (a
  `UNCalendarNotificationTrigger`; no radio, no bot, no internet).

**At issuance, in effect or starting within the hour:** the class's normal delivery, words "until
Fri 7:00 PM"; no reminder.

**The start reminder.**

- Identifier `wx-<identity>#starts`, distinct from the issuance notification's, because adding a
  request under an identifier that is pending replaces the pending one: an update posted under the
  same identifier would cancel the reminder.
- Delivered as a banner without a sound (know now), like the issuance. Whether it should sound is
  §8 Q3.
- Its words say when the phone last knew the alert was still standing: "Last confirmed by WX-AUS
  Tue 3:10 PM." A scheduled notification fires whether or not the app is running, and if the
  cancel was sent while this phone could not hear it, nothing can take the reminder back. The
  sentence is what keeps it honest.
- Re-scheduled (same identifier, new words) every time the alert is confirmed: a new copy, or a
  digest that lists it (the notifier already re-reads posted identities on every digest,
  `WeatherAlertNotifier.swift:126-129`). That is local work on a message that arrived anyway.
- Removed when the alert is cancelled, dropped by a digest, stops covering every watched place,
  or falls below the level; when the bell goes off; and when the start moves into the past.
- When it fires, the issuance notification is redundant. It is removed at the next time the app
  runs (a background wake or a launch), not at the start, because nothing runs at the start.
- iOS keeps at most 64 pending local notifications per app (documented); start reminders are a few
  at most.

**Update, extension, cancel, expiry** for an alert with a start time:

| Event | Before the start | After the start |
|---|---|---|
| Update, words unchanged | Nothing | Nothing |
| Extension | Silent replacement of the issuance ("until Sat 7:00 AM"); reminder re-scheduled with the new end | Silent replacement |
| Start moved later | Silent replacement ("from Thu 1:00 AM"); reminder moved | n/a |
| Start moved earlier, still ahead | Silent replacement; reminder moved | n/a |
| Start moved to now or earlier | Reminder removed; the class's normal delivery now, words "until …" | n/a |
| Cancel (type 2) or dropped by a digest | Both notifications removed, reminder removed. No "cancelled" notification (today's rule, §8 Q8) | Notification removed |
| Expiry | Cannot come before the start | Nothing fires. What was delivered stays, naming its own end time (today's rule) |

**Bots older than revision 12**: no start time, so every alert is treated as in effect when it
arrives (today's behaviour). The words carry the issue time instead, so a watch that is announced a
day early is at least not dated wrongly: "Austin · issued 9:24 AM · until Fri 7:00 PM".

Known limit: an event's start is the earliest of its zones. If `EXA` later adds zones that start
later, a place in those zones is told the earlier start. Rare, and on the safe side.

### 3.6 Coming back: the drained queue and other late arrivals

**What actually arrives.** A phone away for six hours does not drain 40 alerts. Stock companion
firmware keeps 16 frames and, when full, drops the oldest channel frame of any channel to make
room (§1.1 step 6). Channel text on `#public`, the hourly observation batch and the three-hourly
digest all compete for those 16. What the phone gets is the newest few frames, often without the
warnings that started the evening, and at best a digest that lists identities it never received,
which have no geometry and cannot notify (today's rule, §16.3 of the UI spec). The design must be
quiet and honest about a partial picture; the caps below also hold if a future firmware keeps 40.

**New or late is decided by the issue time, not by the drain flag.** Revision 5's issue time is on
every current Warning (`WeatherBotState.swift:17-25`).

- Issued within 15 minutes of arrival: **new**, whatever the drain flag says. This fixes §1.3
  item 2: a warning queued during the connect-time sync is not called late.
- Issued earlier, or no issue time, and **drained**: **catch-up**.
- Issued earlier and **live** (the first copy this phone hears of an old warning: an update, a
  digest-triggered `>w` answer somebody asked for, a phone that just came into range): normal
  delivery for its class, plus the line "Issued 4:10 PM." It is active and the user has not been
  told; an act-now alert still sounds.

**Catch-up is decided once, at the end of the drain.** `WeatherService` yields a new
`.backlogDrained` event when the sync's `pollAllMessages` returns. During the drain the notifier
only records which identities the drained messages stored or ended. At the end it takes the
current state (so a warning followed by its own cancel in the same drain never notifies) and, for
alerts that are active, qualify for a watched place, and have never been posted:

1. **Act now**: each gets its own notification (it needs its own tap target), with "Issued 4:10
   PM. Your radio kept it until this phone reconnected." **Only the first sounds**; the others are
   silent. At most three individually; any more go in the summary.
2. **Everything else**: one alert gets its own banner-without-sound with the same line; two or more
   get **one summary notification** for the whole drain (identifier `wx-catchup`, replaced by the
   next drain's), no sound.
3. If the reducer recorded a gap in `seq` (the `needsDigest` flag that already turns the radio row
   orange), the summary or the single notification adds "Some messages were missed." Never a
   claim that the list is complete.
4. Start reminders for anything in the drain that starts later are scheduled as usual; one whose
   start passed during the absence is not, and its words are simply "until …" (`alertWindow`).
5. Everything drained is recorded in the ledger, so a live repeat afterwards is silent.

What stays as it is: an expired alert never notifies (`WeatherAlertNotificationRules.swift:136`),
cancels and digest removals take notifications away silently, and "listed, not received" never
notifies. The phone never asks the bot for anything on reconnect: principle 5 of the UI spec
(nothing automatic) and requirement 4.

### 3.7 Grouping and threading

- One thread for all weather notifications, `wx-alerts`, so a storm night is one stack in
  Notification Center, separate from chats. Today's per-place threads do not fit notifications
  that name several places.
- `relevanceScore`: act now 1.0, know now 0.5, quiet 0.1, so a notification summary features the
  worst one.
- No badge (today's rule, `WeatherAlertNotificationPoster.swift:22-24`).
- No actions in the first phases. A later action "Stop notifying about Heat Advisories" is the way
  to handle a noisy event without a settings screen (phase 5).

### 3.8 Wording

The words come from the app's string tables through `WeatherAlertNotificationCopy`, with the
English fallback in `WeatherAlertDefaultCopy` for a background launch with no scene (today's
arrangement). Times are revision 12's `alertClock`: the time alone today or within 12 hours,
weekday and time within 7 days ("Wed 7:00 PM"), month, day and time beyond, always in the phone's
own 12- or 24-hour format. The "from … until …" and "until …" parts are
`alertWindow(…, countdown: false)` (`weather.alerts.fromUntil`, `weather.alerts.untilOnly`), so a
notification and the alert it opens say the same thing. The examples use a US 12-hour clock and
illustrative times. The subtitle is always the source, "National Weather Service via WX-AUS",
unchanged.

| Case | Title | Body |
|---|---|---|
| Act now, covering (unchanged) | Tornado Warning | Austin · until 9:41 PM · radar indicated |
| Act now, nearby (unchanged) | Tornado Warning | 25 km N of Round Rock · until 9:41 PM · tornado observed |
| Act now, first heard long after issue | Severe Thunderstorm Warning | Austin · until 9:41 PM · 60 mph wind<br>Issued 8:52 PM. |
| Act now, from the drained queue | Flash Flood Warning | Austin · until 11:15 PM · radar and gauges<br>Issued 8:52 PM. Your radio kept it until this phone reconnected. |
| Know now, in effect | Flood Watch | Austin · until Fri 7:00 PM |
| Know now, starts later (rev 12) | Flood Watch | Austin · from Wed 7:00 PM until Fri 7:00 PM |
| Know now, older bot (no start time) | Flood Watch | Austin · issued 9:24 AM · until Fri 7:00 PM |
| Several places | Flood Watch | Austin, Round Rock and San Marcos · from Wed 7:00 PM until Fri 7:00 PM |
| Start reminder | Flood Watch in effect | Austin · until Fri 7:00 PM<br>Last confirmed by WX-AUS Tue 3:10 PM. |
| Quiet (advisories level) | Heat Advisory | Austin · until 8:00 PM |
| Catch-up summary | 3 weather alerts | Flood Watch, Austin, from Wed 7:00 PM<br>Heat Advisory, Austin, until 8:00 PM<br>Wind Advisory, San Marcos, until 6:00 PM<br>Your radio kept these until this phone reconnected. |
| Catch-up summary with a gap | 2 weather alerts | (as above)<br>Your radio kept these until this phone reconnected. Some messages were missed. |

Shipped strings that change, for house style and for accuracy:

| Key | Today | Proposed |
|---|---|---|
| `weather.notifications.late` | Received late — sent while your radio was out of range. | Issued %@. Your radio kept it until this phone reconnected. |
| `weather.notifications.disconnected` | Not watching — your radio isn't connected | Not watching. Your radio isn't connected. |
| `weather.notifications.disconnectedSince` | Not watching — radio disconnected since %@ | Not watching. Radio disconnected since %@. |
| `weather.notifications.otherWarnings` / `…Detail` | Other warnings / Flood, winter storm, wind and the rest, delivered silently. | Replaced by the level picker: header "Notify me about", rows "Storm warnings only", "Warnings and watches", "Warnings, watches and advisories" |
| `weather.notifications.stormsAlways` | Tornado, Extreme Wind, Flash Flood and Severe Thunderstorm Warnings covering a watched place always notify, with a sound. Watches, advisories and statements never do. | Tornado, Extreme Wind, Flash Flood and Severe Thunderstorm Warnings make a sound. Other warnings and watches show a banner without a sound. Advisories go to Notification Center only. Statements never notify. |
| `weather.notifications.empty` | No place is watched yet. Turn on the bell beside a place in Places, and a warning covering it will notify you. | No place is watched yet. Turn on the bell beside a place in Places to be notified about alerts covering it. |

The promise (`weather.notifications.promise`) stays; §4 below is the evidence it needs, and it is
revisited only after the on-device test. A new row in Settings › Notifications, "Weather alerts",
shows "2 places" or "Off" and opens the Weather tool's Alert notifications screen (fixes §1.3
item 8).

Every translation in `MC1/Resources/Localization/*/Weather.strings` and the web's `strings/*.json`
follows the English.

### 3.9 What a tap opens

- An alert or its start reminder: the alert's detail, on the page of the first watched place it
  covers (My location first, then pager order). The detail already reads live state and says the
  alert is gone if it has ended (`WeatherAlertDetailView.swift:60-62`), which is the right screen
  for a reminder whose alert was cancelled.
- The catch-up summary: the alerts list for the first place named in it.
- On iPhone, the route that pushes Weather instead of landing on the Tools list (`pendingTool` on
  `NavigationCoordinator`, one `onChange` in `ToolsView`, §16.6 of the UI spec). With start
  reminders the tap often comes with the app not running, so this matters more than it did.
- The tap must survive having no radio connected: a delegate installed at launch that handles
  weather taps itself and forwards everything else to the per-connection `NotificationService`
  once it exists (fixes §1.3 item 3). Chat behaviour is untouched.

### 3.10 `FA.A.EWX.8` under this design

Assume a bell on Austin, the *Warnings and watches* level, a revision 12 bot, and the phone in a
pocket with the radio connected.

| When | Radio traffic | Phone |
|---|---|---|
| Tue ~9:30 AM | Warning `FA.A.EWX.8`, zones around Austin, expires Fri evening, issued 9:24 AM, starts Wed evening | Banner, no sound: **Flood Watch** · "Austin · from Wed 7:00 PM until Fri 7:00 PM". Reminder scheduled for Wed 7:00 PM |
| Every 3 h | Digest listing it | Reminder re-scheduled: "Last confirmed by WX-AUS Tue 3:10 PM", then later times |
| Tue afternoon | NWS reissues the watch (`CON`), same times | Nothing on the air, nothing on the phone |
| Wed, if extended to Sat morning | Warning update, later expiry | Silent replacement; reminder re-scheduled with "until Sat 7:00 AM" |
| Wed 7:00 PM | Nothing (the bot sends nothing at a start) | Reminder fires, banner, no sound: **Flood Watch in effect** · "Austin · until Fri 7:00 PM / Last confirmed by WX-AUS Wed 3:10 PM." Fires even if the app was force-quit |
| Wed night | `FF.W` issued over Austin | Its own notification with a sound (act now). The watch notification stays |
| Fri 7:00 PM | Nothing; the next digest omits it | Nothing fires. The delivered notification names its end time |
| If cancelled Wed 2 PM and heard | Cancel, then a digest a minute later | Issuance notification and pending reminder removed. No notification |
| If cancelled Wed 2 PM and **not** heard | Nothing reaches the phone until its next connection | Reminder fires at 7 PM with "Last confirmed … Tue 3:10 PM". Opening it shows the watch as the phone last knew it; once the cancel or a later digest reaches the phone, the detail says the alert has ended |

### 3.11 The web client

What it can do, with the tab open and the radio connected over Web Bluetooth or Web Serial: run the
same notifier (a line-for-line port under `web/src/weather/` and `web/src/screen/`, per
`web/docs/PORTING.md`) and post through the page's `Notification` or its service worker's
`showNotification`, with the identifier as the `tag` so a repeat replaces rather than stacks, and
`silent` for a replacement (`web/src/platform/notifications.js:152-190`). Every rule change in §3
is ported with it. A start reminder can only be a page timer, so it fires only if the tab is still
open at the start.

What it cannot do, and must keep saying (`web.notifications.promise`): anything with the tab closed.
The radio link, the service and the notifier live in the page; a service worker has no Bluetooth or
serial access, and Web Push needs an internet connection and a push service. Whether a background
tab keeps receiving Bluetooth notifications under Chrome's tab freezing is unverified.

Two fixes ride with phase 1: a `notificationclick` handler in `sw.js` that focuses the page and
posts `{ type: 'meshwx.notificationclick', userInfo }` back, and the notifications screen showing
`notificationsPromise()` instead of the iOS sentence.

---

## 4. iOS platform mechanics and limits

Marked **unverified** where I am relying on memory of Apple's documentation or where only a device
can tell.

### 4.1 No internet, and APNs

Every notification in this design is a local notification (`UNNotificationRequest`), posted by the
app itself from data that came over LoRa, or scheduled by it earlier. None needs a network.
**APNs is not usable as the delivery path**: it needs a server to send and an internet connection on
the phone to receive, and the reason this tool exists is that neither can be assumed. It could at
most be an optional extra (the bot's Pi relaying to phones that happen to be online); it is not in
any phase, and nothing depends on it.

Worth saying in the same breath: the phone's own Emergency Alerts (WEA) arrive by cell broadcast,
need no internet, but need a cell tower. They carry the most dangerous warnings and no watches.
This tool matters most exactly when the towers are down.

### 4.2 Notifications from a Bluetooth wake

- While the radio is connected, each frame the radio pushes is a BLE characteristic notification,
  which wakes a suspended app declaring `bluetooth-central` and lets it run. The app fetches the
  frame, the service and the notifier run, and `UNUserNotificationCenter.add` posts. This is the
  same path the app's chat notifications already take with the phone locked.
- **Time budget**: Apple's Core Bluetooth programming guide says an app woken this way has "around
  10 seconds" to finish. Old documentation; the exact budget on iOS 26 is **unverified**. The
  notifier's work should run inside `ProcessInfo.performExpiringActivity` (Foundation, usable from
  the service package), so iOS is asked for time and an interrupted evaluation is finished at the
  next wake rather than lost.
- **The outline parse**: placing a zone-listed alert needs the 15 MB outlines. In a wake after a
  relaunch they are not loaded. Proposed: when a bell is turned on (in the foreground, where the
  outlines can be loaded), store the watched place's nearby county and zone codes with their
  distances. A zone-listed alert is then matched by code lookup in the background, reproducing
  today's `distance <= radius` rule exactly; polygon alerts need nothing loaded. My location
  refreshes its codes whenever a new position is recorded in the foreground. How long the parse
  takes on a phone is **unverified** and is a phase 0 measurement.

### 4.3 What state restoration covers, and what it does not

- **Suspended, radio connected**: works (the path above).
- **Terminated by the system** (memory pressure) with a connection or pending connection:
  Core Bluetooth state restoration relaunches the app into the background on the next event for
  that central. **Unverified here** for the reason in §1.3 item 4: the central is created from a
  SwiftUI `.task`, and a background relaunch may not run it. If phase 0 shows it does not, the fix
  is to create and activate the central from a launch path that runs without a scene (an
  application delegate adaptor's `didFinishLaunching`, or `App.init`). That touches the app's
  launch path, a shared subsystem, and needs the owner's go-ahead.
- **Force-quit by the user** (swiped away in the app switcher): iOS does not relaunch the app for
  Bluetooth events until the user opens it again (Apple Technical Q&A QA1962, from memory:
  **verify**). The BLE link ends, the radio queues, and nothing arrives. **Already-scheduled start
  reminders still fire**, because they belong to the system once scheduled.
- **Reboot**: whether restoration relaunches after a reboot, and whether that needs a first unlock
  (the app's store is protected until then, `MC1App.swift:95-105`), is **unverified**.
- **Radio off, out of range of the phone, Bluetooth off, Airplane Mode without Bluetooth**:
  nothing arrives; the radio queues what it hears (16 frames, §3.6).
- **Background App Refresh off, Low Power Mode**: whether either stops Bluetooth wakes is
  **unverified**; phase 0 tests both.

The screen's promise ("…while DigitainoMesh is running") is the honest summary and stays until
these are tested.

### 4.4 Scheduled start reminders

A `UNCalendarNotificationTrigger` request fires at its time with the app suspended, terminated or
force-quit, with no radio and no network. It cannot be withdrawn unless the app runs, which is why
its words carry "Last confirmed". Pending requests are listed and removed by identifier; iOS keeps
the 64 soonest per app (documented).

### 4.5 How loud a notification can be

| Level | What it does | Needs |
|---|---|---|
| `.passive` | Notification Center only; does not light the screen | Nothing (today's silent case) |
| `.active` | Banner, lights the lock screen, sound if one is set; held back by Focus and Scheduled Summary | Nothing (today's loud case) |
| `.timeSensitive` | As active, but delivered through Focus (when the user allows the app's Time Sensitive notifications) and outside Scheduled Summary; does not override the silent switch | The **Time Sensitive Notifications** capability, entitlement `com.apple.developer.usernotifications.time-sensitive`. To my knowledge it needs no approval from Apple; **verify** when adding it. The user can turn it off per app |
| `.critical` | Sound even with the silent switch and Focus on, at a volume the app sets | Entitlement `com.apple.developer.usernotifications.critical-alerts`, **granted by Apple on application** for uses such as public safety, plus the `.criticalAlert` authorization option and its own system prompt. Whether Apple grants it to a mesh weather tool is **unverified** |

Recommendation: Time Sensitive for the act-now class only (Apple's guidance is for things that need
attention now; a watch two days out does not). Critical Alerts are worth applying for, for
Tornado Warning, Extreme Wind Warning and catastrophic Flash Flood Warning (the "emergency"
cases), and Tsunami Warning if it joins the act-now class. The argument to Apple is the one in
§4.1: this is how the warning reaches a phone when cell service is down. If granted, it is a
separate opt-in toggle with its own system prompt, off until the user turns it on.

A custom sound for the act-now class (a bundled file, no entitlement) is possible and is an owner
question, not a recommendation.

### 4.6 Permission

- Asked at the first bell and nowhere else (today, `WeatherToolModel.swift:844-847, 894-913`).
  Denied: no bell turns on, and the screen offers Settings.
- Provisional authorization (quiet delivery without a prompt) is not used: it would put a Tornado
  Warning in Notification Center with no sound.
- Time Sensitive adds no prompt. Critical Alerts, if granted, prompt once, when the user turns on
  the toggle for them.
- `isAuthorized` is checked before any work (today, `WeatherAlertNotifier.swift:131`). Scheduling
  a reminder while notifications are denied is skipped the same way.

### 4.7 In the foreground

`willPresent` shows a banner and plays the sound for weather notifications that are not passive
(`NotificationService.swift:888-898`). That stays, including with the Weather tool open: a new
Tornado Warning should interrupt whatever screen is up. The delegate change in §3.9 keeps this
logic where it is.

### 4.8 Unverified, collected

1. Restoration relaunch reconnects the radio with this app's SwiftUI launch path (§1.3 item 4).
2. Force-quit ends Bluetooth relaunch until the next manual open (QA1962).
3. Relaunch after reboot, and before first unlock.
4. The background wake budget on iOS 26, and the outline parse time on a phone.
5. Background App Refresh off and Low Power Mode.
6. A tap with no radio connected, and a tap that cold-launches the app (§1.3 item 3).
7. Time Sensitive needs no approval; Critical Alerts would be granted.
8. Chrome background tabs and Web Bluetooth notifications.

---

## 5. Options, and the recommendation

| Option | What it is | For | Against |
|---|---|---|---|
| A. A watches toggle | One more toggle, "Watches", banner without sound; everything else as today | Smallest change; answers the literal request | A Flood Warning (rank 6) stays silent and off while a Flood Watch shows a banner; four places give four banners; nothing for start times or reconnects |
| **B. Levels and classes** | §3 in full: one level, three classes, one notification per alert, start reminders with revision 12, catch-up at drain end, and the platform fixes | Consistent loudness; scales from Austin's heat summers to a tornado night; honest about late and partial data; no airtime and no internet | More to build and test; overturns N-5 and changes N-4 (owner decisions, §8) |
| C. B plus Critical Alerts | Apply to Apple; a separate toggle for the emergency cases | The one thing that gets through the silent switch at night | Depends on Apple; cannot be planned on |
| D. APNs from the bot's Pi | A push relay for phones that are online | Would reach a force-quit app | Needs internet on both ends and a server: fails the first requirement. Rejected as a path; at most a later optional extra |

**Recommended: B, built in the phases below, with C applied for in parallel and never depended on.**

---

## 6. Phased plan

Smallest useful first. Every phase ports to the web client in the same change (PORTING.md).

**Phase 0. Find out what the phone really does (no code).**
The on-device checks in §7.4: background delivery with the phone locked, system termination,
force-quit, reboot, Background App Refresh off, Low Power Mode, a tap with no radio connected, the
outline parse time. And read whether any bell is on on Rafael's phone. The results decide whether
phase 4's launch-path work is needed.

**Phase 1. Watches notify.** Works with the bot as deployed; no wire change.
- The level (§3.2, §3.3), the class table, the gate before placement.
- Know-now delivery as a banner without a sound; quiet as `.passive`.
- One notification per alert across places; the stable source line (§3.4).
- Skip a re-post whose words are unchanged (the 90 s repeat).
- Older-bot wording with the issue time (§3.5, last paragraph).
- The backlog rule stays as today for this phase (drained non-storm alerts do not notify), so a
  reconnect cannot become a column of banners before phase 3 exists.
- String changes (§3.8), including the corrected late line.
- Tests (§7.1). The test `watchesNeverNotify` becomes "watches notify only at the watches level".
- Optional, small: the Time Sensitive capability for the act-now class.
- Web: the ported rules, the `notificationclick` handler, the promise string.

**Phase 2. Start times**, on top of revision 12 (which is being built now and brings the codec,
`beginsAt` in state, and the "from … until …" words).
- The announce-or-not rule for a start more than an hour ahead (§3.5).
- Start reminders: schedule, re-schedule on confirmation, remove on cancel, digest removal, bell
  off, level change; remove the issuance notification once the reminder has fired.
- The launch-time notification delegate (§3.9), because reminders are tapped with the app closed.
- The iPhone route that pushes Weather (§3.9).

**Phase 3. Coming back.**
- `.backlogDrained`; new versus late by issue time; catch-up at drain end with one sound, the
  caps and the summary (§3.6).
- Drained know-now alerts now notify, through the summary.

**Phase 4. Background hardening.**
- `performExpiringActivity` around the notifier.
- Stored county and zone codes for watched places (§4.2).
- If phase 0 showed it is needed: Bluetooth activation from a launch path without a scene (owner
  go-ahead, shared subsystem).
- The Settings › Notifications row.

**Phase 5. Optional.**
- Critical Alerts, if Apple grants the entitlement.
- A per-event mute action on the notification.
- Per-place levels, if asked for.

---

## 7. Test plan

### 7.1 Unit tests (no radio, no simulator)

In `MC1Services/Tests/MC1ServicesTests/Weather/WeatherAlertNotifierTests.swift`, against the
recorder poster, which gains `schedule`, `pendingIdentifiers` and `removePending`:

- A watch covering a watched place posts a banner without a sound at the watches level, and nothing
  at the storm level (replaces `watchesNeverNotify`).
- An advisory posts `.passive` only at the advisories level; a statement never posts.
- Each proposed act-now addition sounds; a Flood Warning does not.
- One Flood Watch over three watched places posts once and names all three; four places read "and
  2 more".
- A second bot's copy leaves the source line alone.
- The 90 s repeat with unchanged words posts nothing; with changed words, a silent replacement.
- Zones added so a place is newly covered: a banner for that place's first time; zones removed:
  the place is dropped, and the notification removed when none is left.
- Revision 12: a start more than an hour ahead posts "from … until …" and schedules
  `wx-<identity>#starts`; within the hour posts "until …" and schedules nothing.
- A digest listing the alert re-schedules the reminder with a new "Last confirmed".
- The first run of a revision 12 bot, resending a held watch with a start, replaces silently and
  schedules the reminder; no banner.
- A cancel before the start removes the delivered notification and the pending reminder, and posts
  nothing.
- The start moved to the past removes the reminder and delivers now.
- Bell off, level lowered and place removed each remove pending reminders.
- Drain: a warning and its cancel in one drain post nothing; ten drained alerts across two places
  post at most three act-now notifications, at most one sound, and one summary; a gap adds "Some
  messages were missed."; a warning issued a minute before a drain is treated as new.
- A live first copy of a warning issued an hour ago sounds (act now) and says "Issued …".
- Notifications denied: nothing posted and nothing scheduled.
- The ledger written by today's build is read as one row per identity.

The codec, the stored start (kept across a later copy without one, not walked by a digest) and
the `alertWindow` words are revision 12's own tests (`docs/MESHWX_REV12.md` §4), not repeated here.

### 7.2 The simulator, without waiting for weather

- **Seeded state**: `WeatherSeedScenarioTests` (in `WeatherSeedTrialTests.swift`) writes live-timed
  state files for the simulator, and revision 12 adds an `FA.A` watch that starts about 10 hours
  after the seed's clock to its storm scenario (`docs/MESHWX_REV12.md` §4). That checks the
  dashboard, the alert detail and the "gone" state. A state file produces no events, so it cannot
  make the notifier post.
- **Presentation and taps**: `xcrun simctl push booted com.digitaino.PocketMesh payload.json` with
  a payload carrying the weather `userInfo` keys (`type`, `wxEvent`, `wxOffice`, `wxEtn`, `wxBot`,
  `wxPlace`) shows the notification as iOS will and exercises the tap path, warm and from a cold
  launch, with and without a (simulated) radio connected.
- **The notifier end to end**: a DEBUG replay transport for iOS, the counterpart of the web's
  `ReplayWeatherTransport.js`, reading hex datagrams and a per-datagram `backlog` mark from a file
  named in the launch environment, with every time shifted so the newest is now. It exercises
  placement, the gate, the ledger, the drain summary and the real `UNUserNotificationCenter`.
- **Start reminders**: the same replay with a start two minutes ahead; lock the simulator and watch
  it fire; replay a cancel first and check it does not.

The simulator has no Bluetooth, so nothing about background wakes or restoration is tested there.

### 7.3 Safety rule for every device test

**Never transmit a made-up warning on `#meshwx`.** Every phone and web client on the channel would
raise it. Device tests use real traffic, or a private channel with a DEBUG-only build setting that
accepts that channel's secret as the weather channel, fed by a second companion radio.

### 7.4 Device, with a radio (phase 0 and after each phase)

- **Background delivery with real data**: somewhere in the US there is almost always an active
  warning or watch, and the bot answers place-named requests nationwide. Save a town under one,
  turn its bell on, choose the level that covers it, send one `>w <county>` for it, and lock the
  phone at once. The answer arrives in a few seconds and should notify on the lock screen. A few
  packets, sent by hand, once per build. For phase 0, on today's rules, that means a storm warning
  (short-lived, not always available) or, with *Other warnings* on, a rank-6 warning such as a Red
  Flag or Flood Warning, which today arrives silently and has to be looked for in Notification
  Center.
- **System termination**: a DEBUG action that ends the process while it is in the background (not
  a swipe), then the same request from a second device. Expect a relaunch and a notification; if
  not, phase 4's launch-path fix is needed.
- **Force-quit**: swipe the app away, repeat. Expect nothing, and the promise to be accurate.
- **Reboot**, before and after the first unlock.
- **Background App Refresh off** and **Low Power Mode on**: repeat the first test.
- **Taps**: with the radio connected; after turning the radio off; from a cold launch.
- **Drain**: turn Bluetooth off on the phone for a few hours across a digest, turn it back on,
  and check the summary, the single sound and the ledger. Compare what arrived with the bot's
  traffic log to see what the 16-frame queue kept.
- **Start reminder**: phase 2, with a real watch that starts later, or the private channel.
- **Outline parse**: time `MeshWXGeometry.preload()` in a background wake on the oldest supported
  phone.

### 7.5 Web

The ported rules under `web/test/` (Node), mirroring §7.1. By hand in Chrome: a tap on a
worker-shown notification focuses the page and opens the alert; the screen shows the web promise;
a background tab for 30 minutes still notifies (the unverified item 8).

---

## 8. Open questions for Rafael

1. **Watches notify** (overturns N-5). All watches at the *Warnings and watches* level, or only
   some (Tornado, Severe Thunderstorm, Flash Flood, Flood, Winter Storm, Hurricane)?
2. **Default level** for a first bell: *Warnings and watches* (recommended; turns other warnings
   on by default, changing N-4) or *Storm warnings only*?
3. **Loudness** of watches and other warnings: a banner without a sound (recommended), or one sound
   when they take effect (at arrival if already in effect, otherwise at the start reminder)?
4. **Start reminders**: yes (recommended), accepting that one can fire for a watch cancelled while
   the phone could not hear the cancel, worded "Last confirmed by WX-AUS Tue 3:10 PM"?
5. **One notification per alert** naming every watched place, instead of one per place (changes
   §16.4 of the UI spec)?
6. **Extend the sound class** (N-3) with Tsunami, Storm Surge, Snow Squall and Dust Storm
   Warnings? And Hurricane Warning, which has hours of lead time?
7. **Time Sensitive** for the act-now class: yes? **Critical Alerts**: apply to Apple, and for
   which events?
8. **A watch cancelled before it starts**: stay silent (today's no-all-clear rule, recommended), or
   a quiet "cancelled" update to the notification that said it was coming?
9. **Per-place levels** (home: everything; elsewhere: storm warnings only), or one level for the
   phone (recommended for now)?
10. **N-8** (a nearby warning that grows to cover the place sounds again) is still waiting for
    confirmation.
11. **Your phone today**: move existing bells to the new default level once, or keep *Storm
    warnings only* until changed?
12. **The launch path**: if phase 0 shows a restoration relaunch does not reconnect, may phase 4
    create the Bluetooth central from an application delegate (a shared subsystem)?
