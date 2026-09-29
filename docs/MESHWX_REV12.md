# MeshWX revision 12: when a warning starts, one design for the bot, the iOS app and the web client

Owner's report, 29 September 2026, with a screenshot of a Flood Watch detail: *in the watch here it
starts tomorrow through friday but the wording is weird. we see "until oct 2" but then it says in
81 hours.. it's just weird.* Then: *yes do revision 12.*

The screen said **until Oct 2 at 19:00 · in 81 h 28 min**. Two faults, one on each side of the
radio:

- **The phone could not know the watch had not started.** It was issued Tuesday 09:24 for
  "Wednesday evening through Friday evening". The bot knew the start (its text replies already
  said "Flood Watch Wed 7PM–Fri 7PM", `core/render_text.py`), v4 carried it on the wire, and v5
  dropped it without a word in any document. The phone showed a watch two days from starting as
  in force now.
- **The countdown knew only hours.** `WeatherFormatting.untilLine` put "in 81 h 28 min" beside a
  date that already said when it ends, and the same clash exists at small sizes ("until 23:41 ·
  in 40 min" reads as two different moments).

The bot's spec (`meshwx/docs/MeshWX_v5_Spec.md`) is revision 12 as of this change: section 3
(the field), 10.2 and 10.5 (how to show it), 14 item 15, and 16 (the changelog). `protocol.json`
is version 16. The web client follows `meshwx/web/docs/PORTING.md`. Revision 11's contract is
`docs/MESHWX_REV11.md` and nothing in it moves.

Also fixed on the bot in the same change, with no client work: a warning's full text (`>wt`) was
cut at 500 characters by a leftover v4 limit in `protocol/warnings.py`, silently, far below the
eight packets a Text reply may take. The watch above stopped at "WHEN: From". It now goes out whole
up to the reply limit, and when that limit bites the cut flag says so (spec 8.1, revision 7), which
both clients already show.

## 1. Wire (spec revision 12, section 3)

After the issue time (flags bit 1), **when two more bytes follow it**:

| Size | Field | Meaning |
|---|---|---|
| 2 | `begins_before` | u16 LE, minutes between the start and `expires`. Start = `expires − begins_before`. 65535 saturates, as `issued_before` does |

- **Found by length.** The flags nibble is full (bits 0 and 1, then the data source in 2 and 3
  since revision 7). Every decoder before revision 12 reads the issue time at its fixed place
  after the area list and stops, and GRP_DATA delivers the exact length, so a revision 11 app
  never sees these bytes. A revision 12 decoder reads them when at least two bytes remain after
  the issue time, and ignores anything after them (a later revision's).
- **Valid only strictly between issuance and expiry:** `0 < begins_before < issued_before`.
  Anything else is ignored, as if absent. The bot never sends such a value.
- **Sent only when the product takes effect later than it was issued.** A warning in effect from
  issuance carries nothing new; an old bot sends nothing new. Both read exactly as revision 11.
- **The start is the earliest VTEC begin among the event's active zones.** The issue time the bot
  compares it with is the event's creation, kept across continuations, so once a watch has a
  start every later copy of it carries one.
- **Material change:** a moved start (to the minute) resends the warning, like a moved expiry.
- **Never shed to fit a packet**, like the issue time.

Vector: `warning_upcoming_watch` in `meshwx/docs/meshwx_v5_vectors.json` (26 vectors now), 28 bytes,
the real case: FA.A.EWX.8, issued at `NOW`, starts 2016 minutes later (33 h 36 min), expires 4896
minutes after issuance. Its decoded dict has `begins_min`; every other warning vector now decodes
with `begins_min: null` and no byte of any existing vector moved.

## 2. Names (Swift; JS per PORTING.md)

### MeshWX target

- `MeshWXWarning.beginsBeforeMinutes: UInt16?`: the raw wire value, **nil when absent or not
  valid** (the decoder applies the rule above, so an invalid value never reaches anything else).
- `MeshWXWarning.beginsMinutes: UInt32?`, computed: `expiresMinutes − beginsBeforeMinutes`, the
  twin of `issuedMinutes`.
- `MeshWXWire.warningBeginsSize = 2`, `MeshWXWire.beginsBeforeSaturatedMinutes: UInt16 = .max`,
  beside the issue-time constants.
- `MeshWXEncoder` writes it under the same conditions as the bot (`issuedBeforeMinutes` present
  and `0 < beginsBefore < issuedBefore`), so seeds and tests can make one.
- **JS**: the decoder's warning object gains `begins_min` (absolute Unix minutes or `null`), the
  bot's name, because the web decoder's output is compared against the vectors' `decoded` dicts;
  constants per PORTING.md.

### State (`WeatherBotState`)

- `WeatherStoredWarning.beginsAt: Date?` (JS `beginsAt`), stored and resolved once, exactly like
  `issuedAt` and for the same reason: a digest can extend the expiry
  (`WeatherStateReducer.applyDigest`), and a start stored relative to it would walk forward.
- In the reducer: `beginsAt: warning.beginsMinutes.map { Date(unixMinutes: $0) } ??
  existing?.beginsAt`. A later copy without a start (a second, older bot) does not erase one.
- Codable with `decodeIfPresent`: state saved before revision 12 decodes with no start.

### Words (`WeatherFormatting`, app layer; web the same functions)

- `alertClock(_ date:, now:, calendar:, locale:) -> String`: a moment an alert starts or ends.
  **Today, or within 12 hours ahead:** the time alone ("19:00", "7:00 PM"). **Within 7 days
  ahead:** abbreviated weekday and time ("Fri 19:00", "Fri 7:00 PM"). **Beyond:** abbreviated
  month, day and time, as `clockTime` does today. Always the phone's own 12- or 24-hour format
  from the locale; never a hard-coded pattern.
- `alertWindow(beginsAt:, expiresAt:, now:, calendar:, locale:, countdown: Bool = true) -> String`,
  replacing `untilLine` everywhere it is called:

  | Case | Text (English) |
  |---|---|
  | `beginsAt` later than now | "from Wed 19:00 until Fri 19:00" (`weather.alerts.fromUntil`) |
  | In effect, ends within 12 hours (≤ 720 min), `countdown` true | "until 23:41 · 40 min left" (`weather.alerts.until` with `weather.alerts.left` as its second argument) |
  | In effect, ends later, or `countdown` false | "until Fri 19:00" (`weather.alerts.untilOnly`) |

  The time left is the existing duration words ("40 min", "1 h 20 min", "2 h"), minutes rounded
  up as today. Nothing counts down to an expiry that has not begun.
- Notifications use `alertWindow(..., countdown: false)`: "40 min left" in a notification centre
  is stale the moment it is read. Their existing `weather.notifications.until` stays for anything
  else that uses it.
- Expired and superseded alerts keep their own lines, unchanged.

### Strings

Already added to all 11 `Weather.strings` (`MC1/Resources/Localization/*.lproj`), beside
`weather.alerts.until`; regenerate `MC1/Resources/Generated/L10n.swift` and the web's JSON tables
from them, do not re-add them:

| Key | English |
|---|---|
| `weather.alerts.untilOnly` | `until %@` |
| `weather.alerts.fromUntil` | `from %1$@ until %2$@` |
| `weather.alerts.left` | `%@ left` |

`weather.alerts.until` (`until %1$@ · %2$@`) is unchanged; its second argument is now "40 min
left" instead of "in 40 min".

## 3. Screens (both clients)

Everywhere an alert says when it applies (the place page's alert strip, the alerts list rows, the
alert detail card, the alert map's callouts, notification bodies, and anything else that calls
`untilLine` today) shows `alertWindow`. Nothing else about those screens changes in revision 12:
ordering, colours, the map's fills and the banner's choice of alert are as before. An alert that
has not started is still an alert about the place; the words are what said the wrong thing.

The detail card from the screenshot reads, for that watch on Tuesday morning:

```
⚠ Flood Watch
Covers Austin, TX
from Wed 19:00 until Fri 19:00
issued 09:24
```

and from Wednesday 19:00, "until Fri 19:00", and from Friday 07:00, "until 19:00 · 12 h left".

Record the decision in `docs/MESHWX_UI.md` as §3.1 row **U-49** (the report, the two faults, and
this rule), and update §7.3's example line.

## 4. Seeds and tests

- iOS: add the watch to the storm scenario in `WeatherSeedTrialTests.swift` (an FA.A that starts
  about 10 hours after the seed's clock and ends about 58 hours after), so the simulator shows the
  "from … until …" line without real weather. Seqs must stay contiguous with the scenario's
  others (a gap trips `needsDigest`).
- Both clients: the new vector decodes, and re-encodes where the suite re-encodes; every
  `alertWindow` case in 12- and 24-hour locales, including a start or end just after midnight
  (within 12 hours: time alone), exactly 12 hours (countdown), and 7 days out (date); the reducer
  keeps `beginsAt` across a later copy without one; saved state from before revision 12 loads.

## 5. Not in revision 12

- No change to ordering, the banner's choice of alert, the map, or what notifies. The alert
  notification design is its own document (`docs/MESHWX_ALERT_NOTIFICATIONS.md`, in progress) and
  will build on `beginsAt`.
- No start on Cancel, Digest or Area sweep: a digest recovers identities and expiries, and the
  phone gets the start from the Warning itself.
