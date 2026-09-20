# MeshWX revision 10: one design for the bot, the iOS app and the web client

Owner's asks, 20 September 2026, after an afternoon on the phone with the national map:

1. "4 of 7 parts arrived": *should allow me to re-request the missing data.*
2. *This "on the map" vs "what the phone holds" is weird.*
3. *Can we go from national alert map to just alert map, and have a way for the user to select
   which areas they want to request the warnings for. One, a few, or all. That way we don't
   default to sending everything.*
4. *Forecast works in chat (`forecast santa fe nm`) but not in the app. I thought we were using
   the same engine.*
5. *Your requests is way too long of a list.*
6. *A way to see all the GRP_DATA traffic on a channel like we do a chat.*
7. The iOS app and the web client stay in sync: same rules, same names, same words.

This file fixes the wire and the names so three codebases can be changed at once. The bot's spec
(`meshwx/docs/MeshWX_v5_Spec.md`) becomes revision 10; `protocol.json` becomes version 14; the
screen decisions are folded into `docs/MESHWX_UI.md` (§3.1 rows U-35 to U-40, §12, §17) by whoever
implements them. The web client follows `meshwx/web/docs/PORTING.md`: the Swift names below are
the JS names.

## 1. Wire (spec revision 10)

Nothing already on the wire moves, with one deliberate exception (1.2, the `total` byte), taken
because no revision 9 client has shipped to anyone.

### 1.1 `>part`: the missing packets of a multi-packet answer

Request text: `>part <group> <idx>[,<idx>…]`, decimal, e.g. `>part 212 1,4,6`. `group` is the
`group` byte of an Area sweep (type 10) or a Text (type 6); each `idx` is a packet or chunk number.

The bot keeps the transmitted bytes of its last **8** multi-packet answers for **10 minutes**
(`PARTS_CACHE_S = 600`), keyed by `group` as stamped at transmission. It answers by sending the
named packets again: identical bytes except a new `seq` in byte 0. Not available, request letter
`p`, reason 0 when it no longer holds that group or none of the indexes exist.

Limits: the per-sender 5 s rule and the hourly 60-packet budget apply (each resent packet counts).
The five-minute sweep cooldown does **not** apply and is not restarted: it is not a new sweep.
The same `(group, idx)` is resent at most once every 30 s whoever asks, so ten phones missing the
same packet cost one packet.

App rule: offered, never automatic. Offered when an assembly is incomplete, its newest packet
arrived at least **15 s** ago (the bot's own echo resend has had its chance) and its first packet
no more than **10 minutes** ago. After that the ordinary ask (the whole map, the whole report) is
the only offer. A `>part` request is never refused by the app's five-minute "already answered"
rule. It settles as answered when any asked-for index arrives from the bot asked.

### 1.2 Scoped Area sweep

Request: `>wmap [all] [states]`. `states` is up to **15** two-letter codes from `index.json`
`states`, run together or separated by spaces or commas: `>wmap TX`, `>wmap all TXOKLA`,
`>wmap tx, ok`. No states = the whole country, as in revision 9. An unknown code: Not available
reason 1. The app always sends the compact form (upper case, no separators) so 15 states fit the
40-byte request.

Answer: type 10 as in revision 9, with two additions.

- **`total` byte, bit 7 = scoped.** `total & 0x0F` is the packet count (1 to 8); bit 7 set means
  the sweep covers only the states its scope entries name. It is set on **every** packet of a
  scoped sweep, so a phone that lost packet 0 still knows it is not looking at the country.
- **Scope entries.** A scoped sweep's packet 0 begins with one entry per requested state:
  `event = 0` (no event has code 0), kind zone, `start = 0`, `run = 1`; `XXZ000` is the Weather
  Service's own way of writing "all of state XX". They sort before every alert entry and count
  toward the 38 per packet. A state named in the scope with no alert entries has nothing active
  at that level: that is an answer, and the reason the scope is on the wire at all.

Reference JSON (vectors): `"scoped": bool` and `"scope": [state index, …]` are added to every
decoded Area sweep; `"entries"` holds alert entries only (scope entries are lifted out by the
decoder and put back, first, by the encoder). National: `scoped: false, scope: []`.

Cooldown: per state. The bot records, per state, when a sweep last covered it and whether with
advisories. A national sweep covers every state. A request is refused (Not available reason 4)
when **every** state it asks for was covered in the last 5 minutes at the same or a higher level
(`all` is higher than plain); a national request is refused when a national sweep at that level
went out in the last 5 minutes. Budget: a national sweep still needs 8 packets left in the hour;
a scoped one is built first and needs its own packet count left.

### 1.3 `>f <lat>,<lon>`

`>f 35.687,-105.938`: decimal degrees, the app sends 3 decimals. The bot answers with the nearest
point **it holds a forecast for**, exactly as a typed `forecast santa fe nm` does after resolving
the place. `point` is the bundle index when that point is in the bundle, else `0xFFFF`.
Recognised by the comma: two signed decimals. Out of range: Not available reason 1.

Why: `pfm_points.json` was built from one day's products and has no point at all for nine
offices (ABQ, AFC, BOU, GUM, HFO, PIH, PPG, PQE, PQW). The app asked for nothing because it knew
no point within reach, while the bot held a forecast 15 km away. The bundle gains the missing
points (appended, so no index moves; `pfm_points.json` `version` 2) **and** the app stops
depending on the bundle being complete.

## 2. Names (Swift; JS per PORTING.md)

### MeshWX target
- `MeshWXWire.sweepScopeEvent = 0`, `.sweepScopedBit = 0x80`, `.sweepTotalMask = 0x0F`,
  `.maxSweepScopeStates = 15`, `.partsCacheSeconds = 600`.
- `MeshWXAreaSweep.isScoped: Bool`, `.scope: [UInt8]` (state indices named by this packet's scope
  entries), `.entries` = alert entries only.
- Encoder `areaSweep(..., isScoped:, scope:)`.

### Requests (`WeatherRequest`)
- `.areaSweep(includesAdvisories: Bool, states: [String])`, `states` empty = national, sorted,
  upper case. Wire: `>wmap`, `>wmap all`, `>wmap TXOK`, `>wmap all TXOK`.
- `.parts(group: UInt8, indexes: [UInt8], of: WeatherPartsKind)` with
  `WeatherPartsKind = .areaSweep | .text(subject: UInt8)`. Wire: `>part 212 1,4,6`. The kind is
  for the log's wording only.
- `.forecastAt(latitude: Double, longitude: Double)`. Wire: `>f 35.687,-105.938`.
- `WeatherReplyKind` gains `.parts(group: UInt8)` and `.forecast(point:)` already accepts any
  point for `forecastAt` (paired by the bot asked, then by distance: 80 km, the existing
  `forecastSubstituteKilometres`, from the asked coordinate when the answer's point is bundled;
  any `0xFFFF` answer from the bot asked while the request is pending).

### State (`WeatherBotState`)
- `areaSweeps: [WeatherAreaSweepAssembly]` replaces `areaSweep` (decoding an old file lifts the
  single value into the array). Newest first. Retention, applied by the reducer on every store:
  a **national** sweep drops every sweep older than it; a **scoped** sweep drops older scoped
  sweeps whose scope it fully contains; at most 8 are kept.
- `WeatherAreaSweepAssembly.isScoped: Bool` and `.scope: [UInt8]?`: `[]` national, the state
  indices when scoped and packet 0 is held, `nil` when scoped and packet 0 is missing.
- `unbundledForecasts: [String: WeatherStoredForecast]`, keyed by the asked coordinate as the wire
  wrote it (`"35.687,-105.938"`), at most 12, oldest dropped. A forecast that arrives with point
  `0xFFFF` and no pending `forecastAt` request from this phone is kept under `"?"` (one slot) for
  the Cached screen only and never shown as a place's forecast.

### Screen rules (`Services/Weather/Screen/`)
- `WeatherAlertMapPicture.make(sweeps:states:now:)` →
  `{ parts: [Part], entries: [Entry], coversWholeCountry: Bool }`.
  `Part = { group, builtAt, includesAdvisories, wasCut, isScoped, scope: [UInt8]?,
  stateCodes: [String] (what this sweep is the newest word on; empty for "the rest of the
  country"), receivedPackets, totalPackets, missingIndexes, firstReceivedAt, lastReceivedAt }`.
  Rule: for each state the newest sweep (by `builtMinutes`) whose scope includes it wins, and only
  that sweep's entries for that state are drawn. A scoped sweep whose scope is unknown (packet 0
  missing) contributes its entries but wins no state. `entries` carry the index of their part.
- `WeatherPartsOffer.make(assembly:kind:now:)` → `WeatherRequest?` by the 15 s / 10 min rule, for
  both `WeatherAreaSweepAssembly` and `WeatherTextAssembly`.
- `WeatherAreaSelection`: `{ isWholeCountry: Bool, states: [String] }`, persisted per device
  (`weather.areaSelection`). Default on first use: the state of the page's place, or the whole
  country when the page has no place. More than 15 states asks for the whole country, and the
  screen says so before the tap. `request(includesAdvisories:)` → `WeatherRequest`.
- `WeatherAreaSweepCost.packets(for selection:, advisories:, held: WeatherAlertMapPicture)`:
  from the newest held national sweep, `ceil((entries in those states + states) / 38)`, at least
  1; with none held: 1 per 4 states, at least 1; national: the last national sweep's count, else
  4 (7 with advisories). Shown as "About N packets".
- `WeatherForecastCard`: with no bundled point within reach the card is `.missing` with an ask
  (never `.noPointNearby`) whenever the place has a coordinate; `.noPointNearby` is gone.
  A held `unbundledForecasts` entry whose asked coordinate is within 25 km of the place is that
  place's forecast, labelled "Forecast point chosen by WX-AUS". `WeatherUpdatePlan` asks
  `.forecastAt` in that case.
- `WeatherTrafficEntry = { id, at, direction: .received | .sent, isBacklog, channelIndex,
  dataType, botID?, seq?, type?, flags?, length, snr?, pathLength?, hex, isDuplicate }` and
  `WeatherTrafficLog` (a ring of **300**, persisted next to the weather state, written by
  `WeatherService` for every datagram on the weather slot, decodable or not, and for every
  Request datagram this device sends). `WeatherTrafficSummary.make(entry:tables:)` →
  `{ title, detail }` from the decoded message: "Observations · 13 stations",
  "Alert map · part 3 of 7 · 38 areas", "Request from 0A1B2C · >o KAUS", "Not available · f ·
  unknown location".

## 3. Screens (both clients)

**Alert map** (was "National alert map"; §17). The status card lists one line per `Part`:
"Texas, Oklahoma · as of 13:40 · 2 min old" and "The rest of the country · as of 13:20", each with
its own level (warnings and watches, or also advisories), its own "cut" line, and, when packets
are missing, "4 of 7 parts arrived" with **Ask for the 3 missing parts** (`WeatherPartsOffer`)
and the cost, "3 packets". With nothing national held the card says which states the map covers
and that the rest of the country was not asked for: an unshaded state outside the scope is
unknown, never clear. Under the map: **Areas to ask for** (opens the state picker: search, whole
country at the top, multi-select, Done), the level picker (as today), the cost, the ask button
whose title names the selection ("Ask for Texas and Oklahoma", "Ask for the whole country").

**Tapped area** (§17.3). One card, titled with the area's name, UGC code as the quiet value:
the alerts this device holds that touch the area, as ordinary alert rows; then, only when the
map's event for the area is not among them, one row for it: the event name and "On the map as of
13:20. Details not received." Then the ask ("Ask WX-AUS for the details", "Ask again"). No
"On the map" card and no "What this phone holds" card.

**Text reports.** A reply with a missing chunk gets the same parts offer ("Ask for the missing
part", "1 packet") above the ordinary ask.

**Forecast card.** "No forecast point near X" no longer exists. The empty card says there is no
forecast for the place yet and Update asks for one.

**Radio page.** *Your requests* shows the newest **3**; "All requests (27)" pushes the whole
list. The `#meshwx` card gains **Channel traffic**, which pushes a chat-style timeline of
`WeatherTrafficEntry`: received on the left under the bot's name, this device's requests on the
right, oldest at the top, opened scrolled to the newest; each bubble is the summary's title, then
"159 B · seq 212 · SNR 12 dB · 2 hops · 13:35" (what is known), "from the radio's queue" when it
was backlog, "duplicate" when it was one. Tapping a bubble pushes its decoded fields and its hex.
A "Clear" action empties the log.

Strings: new keys in `Weather.strings` for all 11 locales (the web converts them with
`tools/strings-to-json.mjs`); `weather.areaMap.title` becomes "Alert map". No em dashes in new
English strings; matter-of-fact wording.
