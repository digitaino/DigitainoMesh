# Weather tool UI — rework spec (v2)

Status: v2, 2026-09-14, after three adversarial reviews (first-time user and wording; severe
weather and data honesty; SwiftUI feasibility and state completeness). Replaces the first-cut
screen shipped in `5244d996`. §3 records every review finding that changed the design, and the
ones that were rejected, with the reason. Revised 2026-09-15 after three reviews of the built
screen (first-time user; honesty and airtime; SwiftUI engineering); §3.1 records those, and the
changes made the same day to match the bot's spec revisions 2 and 3 (R-1 to R-14). Alert
notifications were added on 2026-09-16 (§16), to Rafael's decisions (§3.1 N-1 to N-8). The screen
was **reshaped on 2026-09-16** to Rafael's answers to fourteen questions about its shape: §3.2
records every answer and what it overturned, and §4, §5 and §7 to §12 are written to it. That
build was then driven against Rafael's own restored data and he rejected it — *"it's atrocious"*;
§3.1.1 records the defects that drive and a second one found (U-1 to U-29) and what changed, and §4, §10,
§11 and §12 are written to those too.

## 1. Why the first cut failed

Rafael opened it on his phone (iPhone 15 Pro Max, live WX-AUS on the air) and asked why there
was a long list of observations already, why he had to scroll to find anything, what the
CT NJ NY TX tab bar was, and where the stations and the warnings came from. The phone's own
state file (`devicectl` copy, 23:25) answers each one:

| What he saw | Cause in the data | Cause in the UI |
|---|---|---|
| A long list of observations | The bot broadcasts its whole coverage batch hourly: 14 central-Texas stations | Every station a four-line row, no primary reading, no ranking that meant anything |
| Scrolling for everything | — | Seven sections at one level: warnings, 14 stations, three forecasts × 7 rows, a product panel |
| CT NJ NY TX tabs | Someone else on the mesh asked for Central Park NY and San Juan forecasts; answers are broadcast, so the phone kept them | The text section took its office from the newest forecast held (New York, OKX) and offered OKX's states plus the stations' Texas |
| "Where do the stations come from?" | Observation messages, type 4 | Nothing on screen named the source, the area or the time |
| "What would the warnings be from?" | Warning and digest messages for the bot's coverage; the phone had **no digest yet** | "No active warnings" shown while the app did not know |

Further defects in the same data:

- **The live bot's forecasts are daily, not 12-hour periods.** All three held forecasts start
  at period 0 with seven entries, each carrying a high and a low (Austin Camp Mabry: 102/77,
  100/78, 98/75, 97/73, 98/74, 99/76, 96/81). Spec §7 describes alternating day/night periods,
  one temperature each. The first cut labelled them Today / Tonight / Tomorrow night and
  showed only the high: "Tonight High 100°".
- **Placing the phone outside coverage ranked nonsense as "now".** In the simulator (location
  in California) the nearest of the 14 stations was Llano, the westernmost.
- WX-AUS's advert carries no position (0,0).
- *(Corrected after review.)* The radio's channel table does carry `#meshwx`, at slot 31 of 32,
  beside the legacy `#meshwx-discover` and `#aus-meshwx-v4`. An earlier draft said it was
  missing; that came from a query whose output was cut off.

## 2. Principles

1. **One place drives the screen**: where you are, or a town you searched. Alerts, current
   conditions and the forecast all answer for it, and the screen says which place it is.
2. **Silence is not calm.** *Narrowed by §3.2 Q13:* the green check is gone, and a place page
   says nothing at all on a quiet day. What the phone does not know is still said — in the radio
   row, which turns orange when the alert list is old or messages were missed (§10), on the radio
   page (§12), and by the out-of-area line (§8). The rule is unchanged; only where it is written
   has moved, and nothing anywhere reads as reassurance.
3. **Every number names its source and its age**, measured on the bot's clock (`now`, `ts`,
   `issued`), never on when the phone happened to read it out of the radio's queue.
4. **An answer on the channel is everyone's.** Other people's answers are kept and labelled
   as theirs; this phone's own requests are said to be public before they are sent.
5. **Asking costs everyone airtime**: one deliberate tap, a button that says what it asks,
   progress where you can see it, nothing automatic (picking a town is the tap for its forecast,
   §3.1 O-1), and no second request for anything the
   channel delivered in the last five minutes.
6. **Details one tap away, not one scroll away.** *Narrowed by §3.2 Q1 and Q3:* a place page is
   one list, top to bottom, answering "what's the weather here" — conditions first, alerts a
   banner when there are any. There are four drill-ins and no cards that open pages.

## 3. Review decisions

| # | Finding | Decision |
|---|---|---|
| A1 | A green check could sit beside a tornado warning one county over | **Adopted.** Alerts near the place (≤ 50 km) are rows in the card with distance and direction; the green check appears only when nothing is active anywhere in the bot's area |
| A2 | Ask buttons stay live when the answer cannot arrive (old firmware, no channel) | **Adopted.** Buttons are replaced by the blocking reason |
| A3 | The coverage centroid names "Brushy Creek" and a Georgetown forecast | **Adopted.** No centroid place; with no location the card asks "Where do you want weather for?" |
| A4 | A searched town sticks and answers tomorrow's "anything dangerous?" | **Adopted.** Searched places last for the visit; the header offers "Back to my location" |
| A5, M7 | "updated 2 min ago" reads as "everything is current" | **Adopted.** "WX-AUS heard 2 min ago"; time words cut to *as of*, *issued*, *heard* |
| A6 | Unknown state jargon; the button does not help when the feed is stale | **Adopted.** Plain reasons, button only where it can help (§7.4) |
| A7, M5 | Button feedback vanishes or never appears | **Adopted.** Status keyed by request, persists until the next tap, names the time |
| A8 | Asking is public and nothing says so; New York looks like a bug | **Adopted.** Footer under ask buttons; "Asked for by others nearby" section, 24 h expiry |
| A9, B5c | Outside coverage "none nearby" reads as calm | **Adopted.** "WX-AUS doesn't report on Dallas, so alerts there are unknown" |
| A10, M13 | Three answers do not fit above the fold on a storm night | **Adopted.** Promise alerts + Now only; cap alert rows at 2 + "N more" (storm warnings and unfinished upgrades never fold, §7.3) |
| A11 | Source of stations and warnings still not on screen | **Adopted.** Source lines on both cards and screens |
| A12 | Raw names ("Draughon-Miller Cntrl Tx Rgnl Arpt") | **Adopted.** Abbreviation expansion and suffix stripping |
| A13 | Seven verbs for one action | **Adopted.** Every radio request starts with "Ask" |
| A15 | METAR/TAF unreadable in "Reports" | **Adopted.** Moved into the station screen as "Pilot report (coded)" |
| B1 | Freshness by receipt time; clock skew ends warnings early | **Adopted** bot-clock ages. **Rejected** the clock-offset estimator for this cut: a covering alert that passed its expiry in the last 15 min stays as "Expired · no update received", which absorbs realistic skew without guessing an offset |
| B2 | Gap, missing identity or unfinished upgrade does not block the check | **Adopted** in the reducer (gap tracking, upgrade markers) and in §7.4 |
| B3 | A cached or older digest deletes newer warnings | **Adopted** in the reducer: a digest never removes or shortens a warning received after it was built (10 min margin, 2 min since the bot was found to keep no cache, R-3); an older digest is ignored. **Rejected** exact-length decoding: the reference codec accepts trailing bytes; the slot filter (M3) is the protection instead |
| B4 | One bot's data drives the card | **Adopted.** Alerts are the union across bots, deduplicated by identity |
| B5 | "Coverage" invented; the check claims more than was tested | **Adopted**: station footprint from multi-station batches in the last 24 h; the check requires the place inside it. **Adopted in part**: office coverage is only claimed *against* ("may not carry alerts for Bell County") when the bot has shown the offices it carries |
| B6 | Point test without uncertainty; old fixes; saved place far away | **Adopted.** Uncertainty radius, "near" rows, last-known location never earns a check |
| B7 | The design invites a request storm | **Adopted**: overheard answers satisfy the five-minute rule; no retry once the bot has been heard. **Rejected** random send jitter: overheard answers already collapse a storm to the first answer (the bot has no cache of its own, R-3), and jitter delays the one tap that matters. **Changed**: a bot not heard for 90 min gets a caption, not a block |
| M1 | Stale readings beat fresh ones; "59%" unlabelled | **Adopted** |
| M2, m1 | Forecast labels wrong after midnight; grouping hides storms | **Adopted.** Rows relative to now; merged flags; shape read from the data |
| M3 | Weather data accepted from any channel slot | **Adopted.** Only the slot holding the `#meshwx` secret |
| M4, M6 | Text shown under the wrong label; someone else's forecast settles yours | **Adopted.** Replies record the request that produced them; forecasts always asked by point index; "Home forecast" removed |
| M5 | Tornado warning folded behind shorter-lived warnings | **Adopted.** Fixed event priority (§7.2) |
| C-B1 | Pushing a screen detaches the model | **Adopted.** The model lives as long as the tool |
| C-B3 | Confirmation dialogs become popovers anchored to vanishing banners on iPad | **Adopted.** `.alert` only |
| C-M3 | Offline, every bot looks heard-only | **Adopted.** Bots read from the offline data store |
| C-M7 | ScrollView cards invisible on the default theme | **Changed.** The screen is an inset-grouped `List` whose sections read as cards; theming comes free |
| C-M8, M9 | Tables and geometry on the main actor; recomputation unspecified | **Adopted.** One snapshot built off the main actor on defined triggers |
| C-M11 | Value-based navigation links do not push in the compact stack | **Adopted.** Destination-closure links |
| — | Radio's configured position as a place source | **Rejected.** Often a home address or deliberately offset; an unlabelled hand-typed coordinate is exactly the false-calm path B6 describes |
| — | Tapping a station makes it primary | **Rejected.** Details only |
| — | Local notification for a new covering warning | **Adopted 2026-09-16**, opt-in and per place (§16, §3.1 N-1 to N-8). Warnings are broadcast on `#meshwx` as they happen, so filtering them on the phone costs the mesh nothing |

### 3.1 Implementation review decisions (2026-09-15)

| # | Finding | Decision |
|---|---|---|
| I-B1 | With no station batch held, a list from a bot that doesn't cover the place earned the green check | **Adopted.** `coverageUnknown` status (§7.4); empty coverage never reaches "none" or the check |
| I-B2 | A Tornado Warning 8 km away folded behind two Heat Advisories whose outlines were loading | **Adopted.** Order §7.2, fold §7.3 |
| I-B3 | "Ask for alerts" sent `>w` whenever any bot had something outstanding, and could repeat | **Adopted.** Decided from the source bot (`WeatherAlertRequests`): `>d` for a gap, `>w <identity>` for one missing, `>w <county>` for several or an unfinished upgrade. `>w` answers fill a five-minute slot, bypassed while something is still outstanding. **Kept** the 10-min gap margin: a `>d` served from the bot's cache can predate the gap (§14 Q3). *Superseded by R-3 and R-6* |
| I-B4, I-B17 | Messages drained from the radio's queue at connect filled the five-minute slots and counted as hearing the bot | **Adopted.** Backlog is marked while the poller drains; it updates state but fills no slot and is not "heard" (`lastLiveHeardAt`). Slots also skip duplicates and ignored older lists, and carry the content's own time |
| I-B5, I-B10 | Any text reply with the right subject was taken as this phone's, and text had no slot | **Adopted.** Settled and owned only on a content match (§12); a complete owned reply fills a slot |
| I-B7 | Cross-bot dedupe by receipt time could replace an extended copy with an expired one | **Adopted.** Active copy first, then the later expiry |
| I-B11 | "Add #meshwx" could overwrite a user's channel in slot 1 before the channel sync finished | **Adopted.** The banner and the write wait for channel sync; the slot is re-read from the radio before writing |
| I-B14 | A place far from every forecast point got that point's forecast as its own | **Adopted.** 115 km reach (§9) |
| I-B15 | "Asked for by others nearby" has no distance filter | **Rejected.** Retitled "Other people asked WX-AUS about"; no nearness claim is left to filter |
| I-A3 | "Weather radio 041D" shown everywhere | **Rejected.** Simulator artefact (no contacts); the phone names the bot from its contact |
| I-C2 | The 30 s tick ran a full rebuild with database and disk reads | **Adopted in part.** The rebuild stays (expiry on time depends on it) but reads cached inputs; no tick while inactive. Rebuilding only at computed time boundaries **rejected** as fragile |
| I-C5 | The compact/regular shell swap (rotation, Split View) destroyed the model | **Adopted.** The model is held for the tool visit outside the view |
| I-A | First-time user review: on a storm night Now fell below the fold; "none has arrived" read as "no alerts"; "radio" meant two things; rows never said they covered you; a purple crosshair pin; taps with no visible result | **Adopted.** Source footer folded into the status line, one-line header, "Alerts for Austin", "your radio" only for the user's device, answer confirmations with "nothing new", a bottom pending bar, plainer picker, station and detail wording. Drawing the coverage footprint on a map: not in this cut |
| O-1 | Rafael, 2026-09-15: search was hard to find, picking a town fetched nothing, and San Juan showed no current conditions | **Decided by Rafael.** A "Search a town" button under the header's second line. Picking a place asks for its forecast once, from the first build that shows it, when no fresh forecast is held and nothing blocks asking: the only request without its own button, and picking is the tap. With no held reading within 80 km, the Now card names the nearest bundled station within 80 km and offers "Ask for current conditions" (`>o <ICAO>`). The picker also finds stations by airport-code prefix |
| R-1 | With a snapshot and nothing blocking, every request read "No weather radio to ask yet" and nothing was sent, picking a town included | **Adopted.** Only a missing snapshot means no bot |
| R-2 | The bot's `seq` started at random on every restart and a resend lands 8–10 s late, behind newer packets: a restart read as reordering set its warnings aside, and a reused `seq` was dropped as a copy | **Adopted.** Up to 32 behind is out of order; further behind, or the newest `seq` with new content, is a restart that starts a new stream and counts as a gap. Copies match `seq` and a content fingerprint. Out of order, a warning is stored unless held or cancelled in the last hour, a cancel always applies, a digest takes the build-time check |
| R-3 | Spec revision 2: the bot keeps no answer cache | **Adopted.** Digest margin 10 → 2 min (clock difference only). The five-minute rule stays as airtime etiquette ("already received") but never holds back an alert request while a gap newer than the held answer is outstanding, nor once a list built now could clear a gap the held list could not |
| R-4 | A full digest lists the 25 soonest expiries and cuts the rest; the app removed those | **Adopted.** With 25 entries, a held warning expiring at or after the last entry is kept |
| R-5 | `>w <identity>` settled on any warning, `>w <area>` on any warning or on a digest that never follows it, bare `>o` never on a batch of one, `>f <point>` never on a substituted point | **Adopted.** By identity; by the warning's own area list; any batch from the bot asked; the point, or from the bot asked `0xFFFF` or a point within 80 km |
| R-6 | "Missed messages" never cleared: `>w <county>` finds no zone-coded warning, `>w` and `>w <county>` stop at six, and every tap spent airtime | **Adopted.** One `>w <identity>` per tap, most important first (priority, the place's office, identity), named on the button ("Ask for Tornado Warning"); one the bot says it lacks is passed over, then `>d`. An unfinished upgrade keeps `>w <county>`, a plain gap `>d` |
| R-7 | "In coverage" was a batch station within 80 km. Stations reach 96 km but WX-AUS relays zones within 120 km, so places 176 km out could get the green check | **Adopted.** Per bot: inside the convex hull of its stations, or within 20 km of one (§6) |
| R-8 | `feed_health` above 60 said "New alerts may not reach you" on every quiet night; it counts only the home office (spec §5) | **Adopted.** 255 keeps that wording and its place; a quiet office says it is normal on a quiet night but the feed could be down, withholds "none" and the check, and sits below every status that asks for something. National centres (NHC, WNS) and, until the bundle lists them, office-0 convective watches are no evidence of the offices a bot carries |
| R-9 | Silence has three causes the app cannot tell apart: range, the per-sender limit, the hourly packet budget | **Adopted.** "…may be out of range or busy." / "…didn't answer at 11:26 PM. It may be busy." |
| R-10 | Spec revision 3: unknown observation fields sent as unknown, sky 15 for no cloud or weather group, visibility rounded down; forecast `first` from the issue date; `METAR <ICAO>` / `TAF <ICAO>` replies | **Adopted.** Unknown fields hidden, no icon for sky 15, "under 1 mi"; a day missing one temperature at the window's edge is still a day (only an odd `first` or singles in their slots read as periods); text matching already took both openings |
| R-11 | A late copy of a warning was refused whenever its identity was held, so the bot's resend of a missed update was dropped | **Adopted.** Each held copy keeps its `seq`; a late one is refused only when the held copy came in a message up to 32 ahead in the last 10 minutes, or the identity was cancelled in the last hour |
| R-12 | After every missing warning got Not available, the `>d` that ends the per-tap asks waited out the five-minute rule | **Adopted.** `>d` is sent like `>w` while the list names a warning this phone lacks |
| R-13 | The bot cuts a warning's area list to 30, 12 or 6 runs, or drops it, so `>w <county>` could never settle | **Adopted.** From the bot asked, a warning with 0, 6, 12 or 30 runs settles a county request |
| R-14 | Forecast days are dated in the phone's time zone, not the point's (spec §7); a variable wind reads as north (the wire has no unknown direction) | **Open.** Only near midnight across zones; the wind needs a wire change |
| I-B18 | On a real phone the status line read "WX-AUS may not carry alerts for Travis County (NWS Austin/San Antonio)" — the bot's own home county. The two Austin-area advisories had just expired, only a Fort Worth warning was left, and the phone was holding an Austin/San Antonio forecast discussion at the same time. It also fires only for a place that has already passed the coverage test (§6), so the screen contradicted itself | **Adopted.** Nothing produces `.officeMayNotBeCovered`. The offices a bot has *shown* are whichever products happen to be active this hour: that is the weather, not the bot's coverage, and a quiet hour is not evidence against a place. The case, its copy and `showsOffice` stay for the coverage the bot is to advertise (§14 Q2), which is evidence; the §7.4 row is suspended until then. **Un-suspended 2026-09-15**: the bot now states its coverage and its offices (spec §7A), so the row is back and is decided from that statement alone — every bot that could answer must have stated its offices, uncut, and none may carry the place's (`WeatherCoverage.uncarriedOffice`) |
| O-2 | A searched place vanished on leaving the tool (§3 A4), so the same town had to be found again on every visit | **Adopted.** Saved places, kept on the phone: newest choice first, one row per place, at most twelve, swipe to remove (§5). A4 still holds for the *screen* — the tool opens on the phone's own location, never on a saved place |
| O-3 | Ten ways to change the place: the header's title chevron, a "Search a town" button, "Back to my location", and a *Use my location* / *Search a town* pair inside both the Now and Forecast cards | **Adopted.** One **Places** control in the header, whose first row is My location; the title is no longer a button and the cards carry no place buttons (§4, §10, §12) |
| O-4 | Updating existed only in the states that happened to show an ask button: each card grew and lost its own by threshold, and picking a town sent a forecast request by itself (O-1) | **Adopted.** One **Update** per screen, always in the same position, planning the minimal request set from what is missing and naming it before it sends (§11.1). **O-1 is overturned**: picking a place sends nothing, because Update is right there. No pull-to-refresh: a button can say what it will ask for, a gesture cannot |
| O-6 | The About sheet answered "what is this?" but nothing about *this* radio or *this* channel: it claimed the bot's area from the stations it happened to report this hour, said nothing about what had been asked or heard, and left the phone's growing pile of other people's answers invisible | **Adopted.** It is replaced by the weather radio's own page (§12): how it works, what the bot *states* it covers, this phone's own requests, and what the channel has carried — with the radios, the channel row and Clear kept as they were. Nothing on it says who asked for anything |
| O-7 | Everything the channel carried was kept and nothing said so, and only readings were ever pruned: texts and forecasts grew without bound | **Adopted.** One disclosed row, "Cached from the channel (37) ›", at the foot of that page and nowhere else, grouped with counts (§12). Retention is real, not implied: texts and forecasts get the age and the ceiling readings already had (48 h, 24 each), and what a screen would still show survives both — the newest reply per subject and per own subject, and the newest forecast this phone asked for |
| O-8 | A freshly opened tool could not tell "outside the area" from "nothing said yet" for up to three hours, and withheld the check and the out-of-area requests all that time | **Adopted.** `>cov` (§11.1), one packet, asked once per visit while the bot has been heard and has stated nothing. Answers §14 Q4 |
| N-1 | Rafael, 2026-09-16: what does a notification subscription attach to — a county, a forecast zone, a place? | **Decided by Rafael.** By place: every saved place in Places gets a bell, and so does My location. There is no county or zone picker to get wrong, and the placement rules the card already uses (§7.1) decide coverage |
| N-2 | Should the first saved place be watched automatically, so the feature is not invisible? | **Decided by Rafael: opt-in only.** Nothing is watched until the user turns on a bell, and no subscription is ever created for them. A warning that arrives because the phone quietly signed itself up is worse than one that never arrives |
| N-3 | Which warnings are worth interrupting for | **Decided by Rafael.** The six storm warnings — ranks 0–5, Tornado through Severe Thunderstorm — **with sound**, and only when the warning covers the watched place (`.here`) |
| N-4 | Everything else that is still a warning (rank 6): flood, winter storm, wind | **Decided by Rafael.** An opt-in toggle, **off by default**, delivered **silently** — Notification Center, no sound, no banner |
| N-5 | Watches, advisories and statements (ranks 7–9) | **Decided by Rafael: never.** They stay on the dashboard, where they can be read rather than reacted to |
| N-6 | A tornado warning that misses you by ten kilometres | **Decided by Rafael.** Ranks 0–1 within 50 km that do not cover the place (`.near`) are a second opt-in toggle, **off by default** |
| N-7 | My location, when the app only has a fix while it is in use | **Decided by Rafael.** Matched against the **last position the app knows**, which can be hours old. Its age is on the watched row always, and nothing is ever worded as following the user (§16.2) |
| N-8 | A warning the user was told was *near* them updates to cover them. The owner's escalation list — tornado tag, catastrophic flood damage, an extension past 20 minutes — does not mention it, and it is the moment the nearby toggle exists for | **Decided by the implementation, for Rafael to confirm.** Near becoming here sounds again. Everything else about a repeat stays silent |
| O-5 | Outside the bot's area every card said so and offered nothing to do about it | **Adopted.** Update also asks by the place's own zone and county — the bot serves place-named requests nationwide — but only on a verdict of `.outside`; a cut zone list, outlines still loading, or a bot that has stated nothing are `.unknown` and send nothing (§6, §11.1) |
| P-1 | Rafael, 2026-09-16: swipe to another location, open the forecast discussion, and it shows the discussion for the other location. The tool is a pager of places, but the model held **one** snapshot and **one** context, and every screen reached from a page read the model rather than the page it was opened from: the text reports picked by subject and ignored the request's own office or state, the state override was visit-wide (pick Texas on one page and every page sent `>storm TX`), the stations list, the station and alert details, the alerts list, the radio page, Cached, Update and the pull all answered for whichever page was built last. A swipe flipped the title synchronously while the build was still the old page's, so Update in that window sent the previous place's requests under the new name; a bell could trim the page you were standing on; and a selection left naming a page that was gone spun every page for ever | **Adopted.** One snapshot **per page**, keyed by a `WeatherPageKey` stamped into the snapshot and the context from the build request, and a `WeatherPageScreen` (that build plus the model) handed down into every drill-in, so a screen answers for the page it was opened from and the compiler says so. The model keeps the page on screen and its two neighbours, pre-built at idle priority — the spinner window mostly disappears — with the place facts kept per page so swiping back is free. Text reports match `assembly.request` (office and state), falling back to subject only for an *overheard* reply, labelled as answered for an unknown area; `>hwo` and `>space` are presented as the bot's products and every screen names the bot an item actually came from (`item.botID`). Update, the pull, `isUpdating` and the status caption are per page, through one tracked run so a pull and a tap cannot overlap; a bell trims nothing; every write to the saved list resolves the selection and writes it back; a tapped notification switches to the place it was raised for, through one enum-driven destination (§13) |

### 3.1.1 Adversarial walkthrough of the built screen, 16 September

Rafael's verdict on the build that came out of §3.2: *"it's still disjointed and weird… it's
atrocious… it's just terrible design."* A walkthrough drove the tool in the simulator against his
own restored data (73 screenshots) and a second drive checked the fixes. Each row is a defect that
walkthrough found and what was changed.

| # | Finding | Decision |
|---|---|---|
| U-1 | Four saved places became one, renamed to an airport's town and moved to its coordinates, after the app was killed mid-swipe | **Adopted.** A save-before-load race: `WeatherToolModel.savedPlaces` is empty until `start` reads the store, and a pick in that window persisted a one-place list over everything saved. Every change is now a `WeatherSavedPlaces.Edit` value applied by `WeatherSavedPlacesStore.apply` **to the list the store holds**; the model never writes a list it did not first load, and a write that would drop a place nobody asked to drop is refused outright. Only `.remove` may take a row out, and only the ceiling may shorten a list that just grew |
| U-2 | A Places row read "86° Partly cloudy · 3 h old" for a place whose own page said "No current conditions" | **Adopted.** One rule for both: `WeatherConditions.isGood(kilometres:isStale:)` — within `goodReadingKilometres` and not stale — decides the page's temperature *and* the row's. The row's separate 80 km reach is gone; with no good reading it shows "—". This narrows §3.2 Q9's "dimmed with 3 h when stale": a row is a hint, but a hint that contradicts the page it opens is worse than no hint |
| U-2a | 2026-09-18, field report: Wimberley, TX asked for conditions, the batch came back carrying San Marcos (KHYI) at 06:56, and the page still showed no temperature. KHYI is the nearest station there is, **25.5 km** off — half a kilometre past the cliff — so no answer could ever be shown. Worse, the page offered to ask about KHYI while Update, holding a fresh KHYI reading, called everything current: the page and the plan each worked the rule out on their own and had drifted | **Owner decision: label it.** From 25 to **`labelledReadingKilometres` = 40 km** a fresh reading is shown, attributed: "Nearest report: San Marcos, 26 km away" above the number, and the foot line keeps only "As of 6:56 AM" (`WeatherConditions.nearby`). 25 km and under is still the weather *here*, shown bare. Beyond 40 km the page says no station is near enough and **asks for nothing**, since an answer from there would be refused again. A Places row follows (`isShowable`), naming the station: "79° Cloudy · San Marcos". `WeatherUpdatePlan` now reads its readings step off `WeatherConditions.make` itself, keeping only its own 70-minute refresh age, so the page and the packet cannot disagree again |
| U-3 | Picking KAUS pushed the station **and** saved a place called "Austin, TX", so a second Austin page appeared; TJSJ made a page called "Eleanor Roosevelt" | **Adopted.** An airport code opens the station screen and nothing else (`WeatherPlacePickerAction.station`). No page, no saved place, no move of the pager. The `WeatherPlace` that used to be built from a station is deleted |
| U-4 | Edit mode offered only drag handles, a swipe on a row opened the place, and picking a place moved it to the front over a manual order | **Adopted.** Swipe-to-delete is a `swipeActions` destructive button on the row itself; drag-to-reorder is `onMove` with no Edit mode; the Edit capsule is gone. `WeatherSavedPlaces.remember` puts a **new** place at the front and leaves a place already on the list exactly where it is — picking is "show me this", not "reorder these". A drag is written back by id, not by index, so it can be applied to a list that has grown since |
| U-5 | Every station screen printed the blocking reason twice, one line apart | **Adopted.** `WeatherUpdateControl.caption` already returns the reason when there is one, so the separate `requestBlocked` view was the same sentence twice. The reason is the caption |
| U-6 | "Pull down to ask WX-AUS for KAQO" while every request was blocked, and a pull that did nothing at all | **Adopted.** With a `requestBlock` the empty state names the station without offering the pull (`Conditions.askBlocked`), and a pull says why it sent nothing — the reason in the bottom bar for four seconds, with a warning haptic (`WeatherToolModel.noteBlockedPull`) |
| U-7 | The radio row sat under the pager's dots and the tab bar and could not be read; the dots were inside the scroll; content ran under the tab bar; and Places and Update shared the title bar with the app's radio status pill | **Adopted, one change.** **Update · the dots · Places** move into a bottom bar of the tool's own (`WeatherBottomBar`), attached as a bottom safe-area inset outside the scroll — Apple Weather's layout (since §3.1.2 V-2, the system's own bottom toolbar, with the tab bar hidden). The list is then inset by exactly that bar plus the tab bar and its last row can be scrolled to; the dots are drawn (`WeatherPageDots`) rather than `TabView`'s, so they are never over a row; and the navigation bar carries nothing of the tool's, so the place's name has the strip to itself |
| U-8 | Places measured from the page behind it ("Llano, TX — 3,559 km" for an Austin user who opened it from the San Juan page); the station screen printed its name and distance three times over | **Adopted.** Places and its search measure **from the user**, falling back to the page only with no fix at all and saying so ("Distances from San Juan"). A station screen measures from the page it was opened from and names it, once: the headline is the station, one line is "under 1 km N from Austin", and `WeatherCopy.stationReport` carries only the message the reading arrived in |
| U-9 | Round Rock and Austin showed the same seven forecast rows with nothing to say they were one Camp Mabry forecast | **Adopted.** `WeatherForecastCard.Summary.kilometres` carries the point's distance from the place, and the header names both: "Forecast · Austin Camp Mabry · 20 km · issued 4:00 AM" — the shape the empty state has always used. The separate "from Austin Camp Mabry, 4 km" row is gone, being the same sentence twice |
| U-10 | The Places sheet's "Cancel" implied a commit step that does not exist, the filled blue "Edit" capsule was the loudest element in the tool, and the sheet repeated the "This phone can't tell who asked" footer | **Adopted.** One **Done**. No Edit. The footer is said once, on the radio page under *How it works* |
| U-11 | The radio row opened a **sheet** while every other row on the same page pushed | **Adopted.** Everything reachable from a place page pushes; Places is the only sheet, because it is the one screen about the tool rather than about a place. `WeatherRadioView` lost its own `NavigationStack` and its Done button |
| U-12 | One tap produced three names for one place: "Austin" in the title, "Austin, TX" in Places, the station's own town in the source line | **Adopted.** `WeatherFormatting.placeName` is the one label function, used everywhere a place is named, and it keeps the state — which is what tells two Austins apart. `shortPlaceName` is gone |
| U-13 | The Llano page was three separate refusals stacked down the screen | **Adopted.** The 25 km rule is unchanged — it is not the complaint. When the page would say no to both the weather and the forecast, `WeatherEmptyPlace` makes it one calm card: what is nearest, and the one thing to do about it (ask, the reason it cannot, or that there is nothing in reach to ask for) |
| U-14 | An answer that came off the channel read exactly like one this phone asked for | **Adopted** for what the phone can actually tell. A forecast carries `requestedHere`, so a forecast this phone never requested says "heard on #meshwx" in its header, and so does an overheard text. Readings carry no such flag on the wire and claim nothing |
| U-15 | An overheard text sat under a blurb naming **this page's** office, and the five products attributed in two different currencies — the discussion named an office, the outlook named the radio | **Adopted.** One rule: a blurb says what the product is and nothing about where a copy came from; the header directly above the text attributes it, read off the reply actually on screen — the area when the request names one, then "heard on #meshwx · area unknown" for one nobody here asked for, then the radio and the receipt time. The "Somebody else on the mesh asked for this" footer went with it, being both a second copy and a claim that somebody asked |
| U-16 | The radio page said the same thing three times: "Heard on #meshwx", "19 weather stations", "Cached from the channel (29)" | **Adopted.** What was heard and what is cached are one pile: *Heard on #meshwx* is now the newest-first view **inside** Cached, chosen with a segmented control. The page reads How it works · What it covers · Your requests · Nearby stations · Alerts in the area · Alert notifications · Cached from the channel · the channel · the radios · Clear |
| U-17 | The alerts map carried a disclosure chevron over its corner, and the "you" marker was the pink dropped pin on a map whose whole subject is red and orange warnings | **Adopted.** The map header is a button with a pushed destination, not a `NavigationLink`, so there is no chevron on something that is not a row; the place is the neutral location-fix dot |
| U-18 | A pushed station or alert was built from `model.screen` — "the page the pager is on" — and a tapped notification selects its page and names its alert in the same turn, so the destination could be built against the page being left | **Adopted.** `WeatherStationTarget` and `WeatherAlertTarget` carry the page id, and the pager's one `navigationDestination` resolves `model.screen(for: push.pageID)`. Every drill-in now answers for the page it was opened from, which is what §3.1 P-1 set out to make true |
| U-19 | On a first open with no location permission, Places auto-presents over a page that says "Choose a place in Places to see weather for it" — the same instruction twice, one of them modal, with a Forecast header over a third copy | **Adopted.** The auto-present stays (§3.2). Under it the page offers the one thing the sheet does not: "See the weather where you are." and the tap that asks for location. The Forecast section is not built at all when there is no place |
| U-20 | Over the DEBUG bridge the tool blocked itself on the **radio's** firmware: with the simulator's mock radio (firmware 8) Update stayed disabled saying "Your radio's firmware can't ask for weather" while the bridge beside it was announcing the bot and answering | **Adopted.** The firmware claim is about the transport the request goes out on, and over a bridge that is not the radio. `WeatherScreenSnapshot.make` sets `firmwareSupportsWeather` with the rest of the link's override, beside `isRadioConnected` and the announced bot. Over a radio the link is nil and old firmware is the block it always was |
| U-21 | Update was a 17 × 20 pt tap target beside a 44 × 44 Places, and the three Places bells were 26 × 31 | **Adopted.** The minimum belongs on the **button's own label**, which is what Places had right and the others had on a container or approximated with padding. `WeatherUpdateControl`'s icon label and the bell image both carry `frame(minWidth: 44, minHeight: 44)` and `contentShape(.rect)`; the frame on the bottom bar's container is gone |
| U-22 | A search for "San Juan" offered "San Juan, PR" twice, indistinguishably, as its first row and its last | **Adopted.** `places.json` holds the municipio and its zona urbana 7 km apart, and spec §9.1 strips "ZONA URBANA" from the second, so both rows read alike. `WeatherPlaceSearch.collapsingDuplicates` keeps the first of any rows that read the same word for word within 15 km, and leaves two towns of one name that are genuinely apart as the two places they are |
| U-23 | With no fix, search rows carried no distance at all and stood in an order — the table's population ranking — that nothing on screen explained | **Adopted.** The anchor falls back past the snapshot to the selected page's saved place, which a page has long before it has a build. With nothing at all to measure from a row says "Distance unknown" rather than dropping the only thing telling two rows apart, and `WeatherPlaceSearch.ordered` puts the list A to Z, which is an order the reader can see |
| U-24 | The blocking sentence three times on one page — the caption, the orange banner and a line inside the empty-place card — and a fourth copy per button on every station screen | **Adopted.** A blocking reason is said **once per screen**. On a place page the banner carries it whenever there is one and the caption stands down (`WeatherPlacePageView.bannerSaysTheBlock`); with no banner — a radio merely offline, a bot with no advert — the caption is the only voice and keeps it. `WeatherCopy.emptyPlaceAction` returns nil while blocked, so the card says what is nearest and stops. `WeatherAskButton.showsBlockReason` is false on the station screen, whose Update control already says it: METAR and TAF stay as the disabled buttons they are, with the reason in their accessibility value |
| U-25 | One weather site read three ways in one drive: "Austin-Camp Mabry" on the honesty line and in Cached, "Austin Camp Mabry" in the forecast header, "Austin Camp Mabry, TX" in Places | **Adopted as far as the bundle allows.** Every name on screen goes through `WeatherNames.displayName`, and a forecast point is shown by `WeatherNames.pointLabel` — the state stays on, as it does for a place (U-12) — so the header, the Places row and the empty card's nearest line are one call and cannot disagree. The station keeps its own spelling: `stations.json` writes "AUSTIN-CAMP MABRY" and `pfm_points.json` "Austin Camp Mabry-Travis TX", and a rule that dropped that hyphen would also give "Austin Bergstrom" and "Draughon Miller". Three spellings down to the two the bundle itself holds; making them one needs an alias in the bundle, not in the app |
| U-26 | "Luis Munoz Marin International Airport-San Juan": a forecast point whose tail is a town, not a county and state, was not normalised at all | **Adopted.** `WeatherNames.withoutQualifier` drops a trailing "-…" once, whatever the tail is, when it is a county and state **or** the head is a name on its own — more than one word. The state is kept when there is one. The old `WeatherFormatting.pointLabel` fallback that read "San Juan · Luis Munoz Marin International Airport" is gone with it: the card above already names the place |
| U-27 | "Nearest station TJIG, 1 km · Nearest forecast point Luis Munoz Marin International Airport-San Juan, 12 km" — one clause for a pilot, the next for a reader | **Adopted.** `WeatherCopy.emptyPlaceNearest` names both, the station from the table. The airport code is on the station's own screen, which this card's Update opens onto |
| U-28 | Searching in Places took **Done** away and left a ⊗ in its place, beside the field's own clear button | **Adopted.** `searchPresentationToolbarBehavior(.avoidHidingContent)`: the one button that closes the sheet stays put while the field is up |
| U-29 | A pushed screen had no bottom inset for the app's floating tab bar: the station screen's "as of 12:55 PM" and its "Airport reports (coded)" header sat under it | **Adopted.** The place pages get their inset from the tool's own bottom bar; every pushed destination — station, station list, alert, alerts list, reports, state picker, radio page, Cached, notifications — took `weatherTabBarInset()`, the tab bar's own height above the home indicator. **Superseded by §3.1.2 V-2**: the tab bar is hidden for the tool, and the inset is gone |

### 3.1.2 Visual pass against the Human Interface Guidelines, 16 September (afternoon)

Rafael, on the build that closed §3.1.1: *"there is a ton of dead black space not being used… the
'toolbar' showing the dots for each page… the titles/headers size/fonts don't make sense… study
Apple design standards and human interface guidelines… the little icon we have to click to get
into the saved locations list or to add a new location… ridiculously badly thought out."* The
screen was captured in dark mode before and after; each row is what was wrong and what the page
does now. The information architecture of §3.2 is untouched — the same things are on the page, in
the same order — this is how they are set.

V-7 is a later row and not a visual one: the owner's decision of 17 September about how a request
travels. It is recorded here because it answers the field record this pass left behind, and
because it changes nothing a reader of this section can see.

| # | Finding | Decision |
|---|---|---|
| V-1 | A third of the screen was empty: a lone grey caption under the title bar, then the temperature in a settings-style card with a 52 pt number beside a word | **Adopted.** The weather is a **hero on the canvas** (`WeatherConditionsSection`): centred, no card, the temperature at 80 pt thin, the condition and today's high and low under it, the details and the station line in footnote, and the Update status last — Apple Weather's own block. A place with no good reading sets the ask as the block's statement, in body type, rather than as a footnote (a "--°" placeholder was tried and, at 80 pt thin, drew as two long dashes and a ring). The first page carries a "MY LOCATION" eyebrow with the arrow the dots use, once it has a place — before that the title already says it |
| V-2 | The tool's glass capsule — ↻, three 7 pt dots, a list glyph — floated above the app's glass tab bar: two bars stacked at the foot of every page | **Adopted.** The tab bar is hidden for every screen of the tool (`weatherToolChrome()`, as Chats does inside a conversation), and the controls are the system's bottom toolbar (`WeatherBottomToolbar`): on iOS 26 two glass buttons and the dots floating bare between them, My location's dot the location arrow. `weatherTabBarInset()` and the 49 pt it reserved (U-29) are gone with the bar they dodged |
| V-3 | Section headers were the list's own title-sized grey text, and the forecast's — point, distance, issue time, "heard on #meshwx" — ran to three lines floating between two cards | **Adopted.** Cards are labelled the way Apple Weather labels them: a small-capitals row **inside** the card (`WeatherCardLabel`) — "FORECAST", with "ISSUED 4:02 PM" at its right — and the point the rows are for is the card's last line, in footnote (U-9 kept). No section headers on the page |
| V-4 | A list glyph in a corner was the only way to the places, and nothing said that it was how a place is added | **Adopted.** The title is a menu: the pages, ticked, then "Add or edit places…". The toolbar buttons are words — **Places** and **Update** — not glyphs. Both open the same one sheet (U-11) |
| V-5 | The refresh caption sat above the weather as if it were the page's first fact | **Adopted.** It is the hero's last line, under the station line, where a status belongs; it still stands down when a banner says the same thing (U-24) and keeps `weather.page.caption` for the tests |
| V-6 | The radio row was a bare sentence | **Adopted.** It leads with the antenna glyph, in the same tint as its text |
| V-7 | *(Rafael, 17 September, on the field record behind V-5's status line: seven of forty requests were lost on the route to a bot that was on the air and answering everyone else, while every answer — a flood — got through.)* **"Send the requests over the channel as flood as well."** | **Adopted, and it is the protocol now** (spec §7B, revision 6; docs/MESHWX.md, "Requests"). A request is a **Request datagram flooded on `#meshwx`**, which needs no stored route: one send, the same bytes once more after 10 s, never a third. The DM ladder of §8.2 survives only as the fallback for a radio that cannot send a datagram at all, and the fallback is silent. Nothing on the screen changes: the same statuses, the same wording, the same one answer for everyone listening |

### 3.2 Owner's answers, 16 September

Rafael was asked fourteen questions about the shape of the screen and answered all of them. This
is the design; §4 to §12 are written to it. The right-hand column records what each answer
overturned — in every case something §3 or §3.1 had adopted after a review, which is why it is
written down rather than argued again.

| # | Question | Rafael's answer | What it overturns |
|---|---|---|---|
| Q1 | What does the first screen answer? | **"What's the weather here."** Conditions and forecast first; alerts are a banner when there are any | §2 principle 6 and §3 A10, which promised *alerts and Now* above the fold and made the alerts card the first thing on the screen |
| Q2 | One place or many? | **Many, like a weather app** | §3 A4 and §3.1 O-2: the tool opened on the phone's location and a saved place was one tap away in a sheet. Places are now the screen itself |
| Q3 | Cards that open pages, or one page? | **One page, top to bottom.** The only drill-ins are detail screens: a station, an alert, a text report, the radio page | §3.1 C-M7's card-shaped sections, and the "details one tap away" reading of §2 principle 6 that made every section a door |
| Q4 | Any way through to the radio's chat? | **Completely separate.** No shortcut, no commands shown | Nothing built; it closes the question for good |
| Q5 | How much does the screen say about where a number came from? | **One line under the temperature**: "Camp Mabry · 6 km · as of 8:24 PM", and tapping it opens the station. The forecast header says "issued 4:02 PM". A warning banner says "until 9:41 PM". Nothing more unless tapped | §3 A11 and §8's source lines on *both* cards, plus the alerts card's own source footer: three sentences about provenance on one screen |
| Q6 | How is it refreshed? | **Pull-to-refresh and an Update button**, the same planner either way. The pull names what it asks for; with nothing needed it sends nothing and says "Everything is current · WX-AUS 4:25 PM" | §3.1 O-4's "No pull-to-refresh: a button can say what it will ask for, a gesture cannot". A caption above the list says it for the gesture |
| Q7 | A severe warning covering the place? | **A banner, always the same size**: one strip naming the warning and its end time, opening the alert. No big card, ever | §7.3's card, §3 A10's two-rows-plus-more fold, and §3.1 I-B2's never-fold rule for storm warnings — the strip is one row whatever the weather |
| Q8 | What else lives on the page? | **Below the forecast, only text reports.** Nearby stations, alerts in the wider area and radio and coverage information move to the radio page | §8's stations footer, §7.3's "N elsewhere" footer, and §10's ⓘ |
| Q9 | What does a Places row show? | **Temperature and condition, greyed when old**: "San Juan · 86° Cloudy", dimmed with "3 h" when stale, "—" when nothing is held. The bell stays | §3.1 O-2's "88° · 12 min old", which led with an age rather than with the weather |
| Q10 | How is the radio page reached? | **A row at the bottom of the place page**: "WX-AUS · heard 2 min ago · alerts as of 8:02 PM ›", **orange when the alert list is old or messages were missed**. That row is the only place on the page that mentions the alert list | §10's ⓘ, and §7.4's status line, whose eleven cases all lived on the alerts card |
| Q11 | No good reading? | **No temperature at all**, only the ask: "No current conditions for Llano. Pull down to ask WX-AUS for KAQO." Good = the nearest held reading within 25 km and not stale | §8's 80 km primary station and its "stale (3 h old)" small-type row, and §3.1 O-1's 80 km nearest-bundled-station wording |
| Q12 | How are places switched? | **Swiping sideways with dots.** My location first; the Places list is for adding, removing and reordering | §3.1 O-3's single Places control as the *only* way to change the place, and §5's "newest choice first" ordering, which would move pages under a swiping finger |
| Q13 | What is said on a quiet day? | **Nothing.** No green check, no "no alerts" line, no status line | §3 A1's green check, §7.4's `.clear` and `.noneHere` rows, and part of §2 principle 2 — the honesty is now in Q10's row and on the radio page, not on the page |
| Q14 | Outside the push area? | **The page looks the same.** Refreshing also pulls alerts by zone and county; a warning that comes back is the same banner; and one quiet line under the temperature reads "Warnings aren't pushed here — pull to check." The app never says "no alerts for <place>" | §3 A9's "WX-AUS doesn't report on Dallas, so alerts there are unknown" as a *status line*, and §3.1 O-5's per-card version of it |
| — | First open, before location permission | **Opens the Places list.** No prompt until the user taps My location or adds a place | §5's "Locating…" on arrival as the first thing a new user sees |

## 4. Information architecture

A weather app: one page per place, swiped sideways with dots, My location first (§3.2 Q2, Q12).
Each page is one scrolling list, top to bottom — no cards that open pages. The only drill-ins are
detail screens, and there are four of them: a station, an alert, a text report, the radio page
(Q3). **All four push.** Places is the only sheet in the tool, because it is the one screen that is
about the tool rather than about a place (§3.1 U-11).

**The chrome is the system's** (§3.1.2 V-2, V-4). The place's name is the title, and the title is
a menu (`toolbarTitleMenu`): tapping it lists the pages, the one on screen ticked, and ends in
"Add or edit places…", which opens Places — the answer to "how do I change the place" that a bare
list glyph in a corner never was. **Places · the page dots · Update** live in a bottom toolbar of
the system's own (`WeatherBottomToolbar`), in the same three positions on every page — Apple
Weather's bottom edge: on iOS 26 two glass buttons with the dots floating bare between them, and
My location's dot is the location arrow, as it is there. Both buttons are words. The app's tab bar
is off the screen for every screen of the tool (`weatherToolChrome()`), the way it is inside a
conversation and during a mapper ride: a glass capsule of the tool's own floating above the app's
glass tab bar was two bars stacked at the foot of every page. The list is inset by exactly the
system bar, the dots can never sit on top of a row, and the navigation bar carries nothing else
of the tool's, leaving the title the strip it shares with the app's radio status pill.

```
Llano ⌄  ‹ the title is the place, and a menu of the pages ›          (radio status pill)
├── MY LOCATION                                            ← the first page only
│        86°                                               ← the ask, as a sentence, when none is good (§8)
│     ☁︎ Cloudy · High 92° · Low 71°                        ← on the canvas, not in a card
│   Camp Mabry · 6 km · as of 8:24 PM ›  ────────────────── Station
│   Warnings aren't pushed here — pull to check.           ← only outside the radio's area (§6)
│   Everything is current · WX-AUS 4:25 PM                 ← what a pull would ask for (§11)
├── ⚠︎ Tornado Warning · until 9:41 PM        +2 more ──── Alert detail
├── FORECAST · ISSUED 4:02 PM                              ← a label inside the card (§9)
│   Today 102° / 77°   …
│   Austin Camp Mabry · 6 km                               ← the point it is for, always
├── WEATHER SERVICE TEXT REPORTS
│   Forecast discussion ─────────────────────────────────── Text
│   Hazardous weather outlook · Storm reports · Rainfall totals · Space weather
└── ⌁ WX-AUS · heard 2 min ago · alerts as of 8:02 PM ───── The radio page (pushed)
                                                            ├── How it works · What it covers
                                                            ├── Your requests
                                                            ├── Weather stations
                                                            ├── Alerts in WX-AUS's area (map + list)
                                                            ├── Alert notifications (§16)
                                                            ├── Cached from the channel (37)
                                                            │     ├ By kind
                                                            │     └ Newest first ‹ what was heard ›
                                                            ├── #meshwx · Weather radios
                                                            └── Clear received weather
[Places]            ➤ ○ ○ ○            [Update]            ← the system's bottom toolbar; no tab bar

Places (sheet, from the bar or the title menu) My location · the saved places, each with its reading, its
                                     bell, a swipe to remove and a drag to reorder · search (town,
                                     ZIP, airport code) · Heard on #meshwx.  One **Done**.
                                     → an airport code opens that station's screen and saves
                                       nothing at all (§3.1 U-3)
```

Every section is on every page. Nothing appears or vanishes with a threshold or with the coverage
verdict, with exactly two exceptions: the banner, which is there only when an alert covers the
place, and the out-of-area line, which is there only on a verdict of `.outside`. The page's shape
can therefore be learned, which is the whole of Q3 and Q7.

**Code**: `WeatherToolView` is the pager (`TabView`, `.page` style, index dots) and the toolbar;
`WeatherPlacePageView` is one page; `WeatherConditionsSection` the temperature block;
`WeatherForecastSection` the forecast; `WeatherPlacePickerView` the Places sheet;
`WeatherRadioView` the radio page. `WeatherPages` decides the pages and their order,
`WeatherConditions` what the page leads with, `WeatherWarningBanner` which alert the strip names,
`WeatherRadioRow` what the last row says and whether it is orange — all four in MC1Services and
tested on macOS (§13).

## 5. The place

`WeatherPlace` = kind (`current`, `lastKnown`, `searched`), coordinate, label, uncertainty
radius r (km). One page answers for one place.

- **Current location** (the first page, always): the phone fix. Resolved once per appearance, with
  up to 5 s "Locating…" if no fix yet; a late fix replaces the place only if the user has not
  swiped away. r = max(accuracy, 0.5 km) + min(1 km per minute of age beyond 5 min, 25 km).
- **Last known**: a phone fix older than 60 min. Never earns a claim about alerts.
- **Searched**: a town from `places.json`, a US ZIP from `zips.json` (the ZIP's own point, labelled
  as the bot labels it: "Austin, TX 78701"; docs/MESHWX.md), or a weather station found by its
  airport code and named by its town, r = 5 km. Picking one **sends nothing**.
- **None** (location undetermined, denied, or never fixed): the My location page reads "Choose a
  place in Places to see weather for it." with one **Use my location** button. Denied reads
  "Location is off · Settings".

**First open, before permission**: the tool opens the **Places list** (§3.2). Nothing prompts for
location until the user taps *My location* there or on the page, or adds a place — swiping to the
My location page never prompts. It is the one moment a location prompt can happen, as turning on a
bell is the one moment a notification prompt can happen (§16.6).

**Saved places** (`WeatherSavedPlace`, `WeatherSavedPlaces`, `WeatherSavedPlacesStore`). Every pick
is kept on the phone and becomes a page, at most twelve.

**Nothing ever writes a list it did not first load** (§3.1 U-1). Every change is a
`WeatherSavedPlaces.Edit` value — remember, remove, reorder, watch — handed to
`WeatherSavedPlacesStore.apply`, which reads the stored list, applies the edit to *that*, and
writes it back. The model's own copy is empty until `start` has read the store, and a pick in that
window used to persist a one-place list over everything saved: on a real phone four places became
one, renamed to an airport's town and moved to its coordinates. `apply` also refuses any write that
would drop a place nobody asked to drop — only `.remove` may take a row out, and only the ceiling
may shorten a list that has just grown.
 Identity is what the place *is* — the ZIP,
the station's wire index, or the coordinate to about 100 m — so a town found by search and the same
town offered by the channel are one row and one page.

**The list's order is the pager's order.** A place the list does not yet hold goes to the front; a
place it already holds **stays exactly where it is** when it is picked again (§3.1 U-4) — tapping a
row to look at it is not a request to reorder the pager, and sliding it to the front rewrote an
order the user had dragged into place and renumbered every dot. A drag in Places rewrites the
order and nothing else moves on its own (`WeatherSavedPlaces.moving`), and the drag is written back
**by id**, so it can be applied to a list that grew while the sheet was open. This
replaces the "newest choice first" sort of the 15 September cut: re-sorting on every pick would
shuffle the pages under a swiping finger, which is the one thing a pager must never do. A watched
place still never falls off the end of the twelve.

The visit's page is kept on the model (`WeatherToolModel.selectedPageID`), so a pushed detail
screen, a rotation and the compact/regular shell swap all come back to the place the user was
looking at. Only the page the snapshot was built for shows its weather; a page being swiped past
shows its name and what the phone already holds for it (`WeatherPlaceRowReading`), and fills in
when the swipe settles.

Label: nearest place of ≥ 1,000 people within 25 km, title-cased with its state; else the
nearest station's city; else "this location".

## 6. Coverage

**The bot's own statement decides** (Coverage, spec §7A): its circle and the zones it lists. That
is the only message that describes coverage, and the reason it exists — inferring it from the
hourly stations and from the offices of whatever warnings happened to be active told a real phone
that WX-AUS "may not carry alerts for Travis County", the bot's own home county (§3.1 I-B18).
A place is **inside** on the stated circle, on a stated run, or on a statement with no area filter
at all.

Failing a statement, the **footprint** the bot has demonstrated, which is the fallback for a bot
that has stated nothing: the stations it reported in multi-station batches received in the last
24 h (a batch of one is somebody's single-station request and says nothing about coverage). A
place is in that footprint when it lies inside the convex hull of the bot's stations, or within
20 km of one of them, which also covers a bot with one or two stations. The bot relays alerts for
zones within about 120 km of its home, but its batch is the ≤ 14 nearest reporting stations,
the farthest about 96 km out for WX-AUS: the hull stays inside the alert area, so a place
between the two is called out of coverage rather than calm (§3.1 R-7). Out of coverage, every
card says so rather than answering from far away.

**"Outside" needs evidence** (`WeatherCoverageVerdict`). A statement whose zone list the bot had
to cut says "not listed", never "not covered"; outlines that have not loaded place nothing; and a
bot that has said nothing and reported nothing knows nothing. All three are `.unknown`, and
`.unknown` is never read as outside — not by the status line (§7.4) and not by Update, whose
zone-and-county requests go out only on `.outside` (§11.1).

## 7. Alerts

### 7.1 Placement

Alerts are the union of all bots' held warnings, deduplicated by identity: an active copy
beats an expired one, then the later expiry wins. Each is placed relative to the place:

| Placement | Rule |
|---|---|
| **here** | Its polygon contains the place or passes within r; or one of its areas (county or zone) contains the place or passes within r |
| **near** | Its outline is within 50 km; carries distance and compass direction |
| **checking** | It names areas and the outlines are still loading |
| **unplaced** | No polygon and no outline for any of its areas — never "not here" |
| **elsewhere** | Everything else in the bot's area |

Upgrade markers (spec §4 flag 2) are placed by the upgraded warning's geometry and shown as
"Upgraded — replacement not received", only when no bot still holds a copy of the warning. A *here*
alert that expired less than 15 min ago stays as "Expired 3 min ago · no update received".

### 7.2 Order

Tornado Warning, Extreme Wind Warning, Flash Flood Warning with catastrophic damage tag,
Severe Thunderstorm Warning with a tornado tag, Flash Flood Warning, Severe Thunderstorm
Warning, then other warnings, watches, advisories, statements.

On the alerts list, rows sort *here* first; then by that rank across every other placement, so a
Tornado Warning 8 km away sits above a Heat Advisory whose outlines are still loading; then
*checking* and *unplaced* before *near*; then soonest expiry. Recently expired rows sort last.

### 7.3 The banner

**One strip, always the same height** (§3.2 Q7). It is above the weather, below the refresh
caption, and it is the only thing about alerts on the page.

- Only `.here` earns it: an alert whose outline has not loaded, or one that names no area at all,
  is never read as covering the place. Those are on the alerts list, where they can be read rather
  than reacted to.
- The one it names is the most important covering the place: live before recently expired, then
  the §7.2 rank, then the soonest expiry (`WeatherWarningBanner`).
- It carries the event's colour and icon, its name, and "until 9:41 PM · in 40 min" — or, for an
  upgrade whose replacement never came or one that has just expired, what became of it instead.
- Any others covering the place are "+2 more" at the trailing edge, on the same line.
- Tapping it opens the alert's detail.

There is no card, no fold and no row cap: the strip is one line whatever the weather. The card of
the 14 September cut grew with the storm and moved everything under it, which is what Q7 refused.

### 7.4 The status line

**Not on a place page.** On a quiet day the page says nothing at all: no green check, no "None for
your location", no status line (§3.2 Q13). The eleven cases below are evaluated as before and
shown on the **alerts list**, on the radio page, where the alert list is accounted for.
`WeatherCopy.alertStatus` returns nothing for `.clear` and `.noneHere`, so the two lines that read
as reassurance are gone from the app altogether.

Evaluated in this order; the first that applies wins.

| Condition | Line | Action |
|---|---|---|
| No place | "Choose a place to see which alerts cover it" | — |
| Place out of coverage | "Dallas is outside WX-AUS's area, so alerts there are unknown." | — |
| No digest from any covering bot | "This phone hasn't received WX-AUS's alert list yet, so it can't tell whether any alerts are active. The list comes every 3 hours." | Ask for alerts |
| Feed never received (`feed_health` 255) | "WX-AUS hasn't received anything from the Weather Service. New alerts may not reach you." | — |
| Your radio not connected | "Your radio isn't connected. Last alert list as of 11:02 PM." | Connect caption |
| Gap, missing identity or upgrade marker | "This phone missed messages from WX-AUS. Some alerts may be missing." | Ask (from the source bot's state) |
| Digest built more than 3 h 15 min ago, or before this radio session started | "Last alert list as of 8:02 PM." | Ask for alerts |
| Last-known location | "Your location is 3 h old." | Update location |
| No multi-station batch from any bot in 24 h | "WX-AUS hasn't sent its station report yet, so the area it covers isn't known. It comes about every hour." | — |
| Every bot that could answer has stated its offices, none cut, none carrying the place's | "WX-AUS may not carry alerts for Bell County (NWS Fort Worth)." | — |
| Alerts here/near/checking/unplaced | (rows speak) | — |
| Home office quiet (`feed_health` above 60) | "WX-AUS hasn't had anything from its home Weather Service office for 5 h. That's normal on a quiet night, but its feed could also be down." | — |
| Alerts only elsewhere, or nothing anywhere | (nothing) | — |

The honesty those last two rows used to carry is now the **radio row** (§10): on a place page an
old or missing alert list, or messages missed, turns that row orange. Silence on the page is never
silence everywhere; it is one row from being accounted for.

## 8. The temperature block

A temperature on the page is a claim about the weather *here*, so it is shown only for a reading
good enough to make it. **Good** is:

> the nearest reading the phone holds is within **`WeatherConditions.goodReadingKilometres`
> = 25 km** of the place, and is not stale.

From 25 km out to **`WeatherConditions.labelledReadingKilometres` = 40 km** a fresh reading is
still shown, **attributed to its station** — "Nearest report: San Marcos, 26 km away" above the
number — and never as the town's own (§3.1 U-2a). Past 40 km nothing is shown and nothing asked.

**This is the tunable** (§3.2 Q11). Readings still reach 80 km
(`WeatherPrimaryStation.maxDistanceKilometres`) for the **stations list**. Twenty-five kilometres
is the distance at which the app is willing to print one number and call it the temperature here.
Lowering it shows the ask more often; raising it back to 80 puts the 14 September screen's
"Nearest report · 40 km NW" behaviour back.

**A Places row obeys the same rule** (`WeatherConditions.isShowable(kilometres:isStale:)`, §3.1 U-2
and U-2a), and names the station when the page does: "79° Cloudy · San Marcos".
The row used to reach 80 km and show whatever it found, stale or not, so Places read "86° Partly
cloudy · 3 h old" beside a page that said "No current conditions" — the list and the page
contradicting each other about the same town, one tap apart. A row with no good reading shows "—".
This narrows §3.2 Q9's "dimmed with 3 h when stale": a row is a hint, but a hint that contradicts
the page it opens is worse than no hint.

`WeatherConditions.make` decides, from the primary station and the nearest bundled station:

| Case | The page |
|---|---|
| A good reading | A hero on the canvas, centred, no card (§3.1.2 V-1): the temperature at 80 pt thin, then the sky icon (night variant after sunset hours) and condition word, then today's "High 92° · Low 71°" from the forecast held, then "Feels like 91° · Wind SSE 12 · Humidity 59%" in footnote. All observation fields from that one station |
| Fresh, 25 to 40 km | The same hero, led by "Nearest report: San Marcos, 26 km away" in subheadline above the number; the foot line says "As of 6:56 AM ›" only. When a nearer bundled station exists, Update asks for it by code while the page keeps what it holds |
| Held, but stale, or beyond 40 km with a nearer station to ask | **No temperature at all**: the block is the statement "No current conditions for Llano. Pull down to ask WX-AUS for KAQO." |
| Nothing in reach, a bundled station within 40 km | The same ask, naming that station |
| Nothing within 40 km worth asking | "No weather station near Dallas. Nearest: Temple, 190 km." Update asks for no reading |
| Nothing ever received | "No current conditions yet. WX-AUS broadcasts them every hour." |

The station the ask names is **the station Update would send for**, always: near-but-stale asks
about that same station, too-far asks about the nearest bundled one — and `WeatherUpdatePlan`
makes the same choice (§11.1), so the sentence on the page and the packet on the air can never
name different stations. With a `requestBlock` the sentence **stops offering the pull** and names
the station only (§3.1 U-6): telling someone to pull while a disconnected radio makes the gesture
inert is the app describing a screen it does not have.

**A page that would say no to everything says it once** (`WeatherEmptyPlace`, §3.1 U-13). When
there is no good reading *and* no forecast for the place's point, the temperature block and the
forecast are replaced by one card: "No weather for Llano yet.", what is nearest ("Nearest station
KAQO, 18 km · nearest forecast point Burnet Airport, 43 km"), and the one thing to do about it —
pull or Update, the reason nothing can be asked, or that there is nothing in reach to ask for. The
25 km rule that produces all three refusals is unchanged; this is how it reads, not what it
decides.

**The one line under it** (§3.2 Q5): "Camp Mabry · 6 km · as of 8:24 PM" — the station, how far it
is, the reading's own time on the bot's clock. Tapping it opens the station's screen. Since the
bot's revision 5 each reading carries when *that station* reported (the batch's `ts` less the
station's age), so "as of" is per station and true of the number above it. Nothing else about
provenance is on the page: which radio carried it is said once, by the radio row.

**The out-of-area line** (§3.2 Q14): on a verdict of `.outside` (§6), one quiet line under the
block — "Warnings aren't pushed here — pull to check." The app never says "no alerts for Dallas",
which it cannot know; it says what is not pushed, and what to do about it.

## 9. Forecast

- Point: the nearest bundled forecast point to the place, within 115 km. That reach is the 99th
  percentile of every bundled place's distance to its nearest point (median 23 km, p95 68 km);
  about 1% of places lie beyond it, mostly in New Mexico, Utah, Idaho and western Alaska, and
  get "No forecast point near Albuquerque". A held forecast for a different point within 10 km
  of the place is used instead, and says so ("from Austin Camp Mabry, 4 km").
- Shape from the data (`MeshWXForecastLayout`): **days** (what the bot sends, spec §7 revision 3:
  even `first`, entry `i` dated the issue date plus `first / 2 + i`, and a day missing one
  temperature at the window's edge is still a day) → one row per day with high/low;
  **periods** → day and night paired into one row, flags merged (thunder, wintry, windy, fog
  from either half), the higher rain chance with its half ("70% tonight"); **mixed** → one row
  per entry, labelled by its period id, every temperature shown.
- Rows are labelled against *now* (Today, Tonight, Tomorrow, weekday); rows that have ended
  are dropped.
- **Label "FORECAST · ISSUED 4:02 PM" inside the card, and its last line "Austin Camp Mabry · 6 km"** (§3.1.2 V-3) — the point it is a forecast
  *for*, how far that point is from the place, and its age (§3.2 Q5, §3.1 U-9). A forecast is for a
  point, and two towns twenty kilometres apart share one: Round Rock and Austin showed the same
  seven rows with nothing on either page to say they were one Camp Mabry forecast rather than two
  that happened to agree. The empty state has always named the point it would ask for; the filled
  one names the point it got. The place itself is named by the title bar, not repeated here; a
  forecast older than 12 h reads "issued 14 h ago", which is what a pull plans for. A forecast this
  phone never asked for adds "· heard on #meshwx" (§3.1 U-14) — the wire does not say who asked,
  but the phone knows what *it* asked, on that last line.
- Nothing held for the place's point: "No forecast for Austin yet."; when the point is more than
  10 km away, "The nearest forecast point is Midland, 60 km." Beyond 115 km: "No forecast point
  near Albuquerque." and no ask.

## 10. The radio row, and banners

The **last row on every page**, and the way to the radio page (§3.2 Q10):

```
WX-AUS · heard 2 min ago · alerts as of 8:02 PM                                    ›
```

- "Heard" counts live traffic only; with nothing heard live this session it reads "not heard yet".
- The alert list's own build time, on the bot's clock; with none held, "no alert list yet". The
  row never leaves the list out — it is the only thing on the page that mentions it, so saying
  nothing would be saying nothing at all.
- **Orange** when the list is old (past its 3 h 15 min cadence) or missing, or when this phone
  missed messages from the radio — a gap, a warning the list named that never arrived, or an
  unfinished upgrade (`WeatherRadioRow.needsAttention`). Nothing else on the page changes colour
  with the data, so orange here reads as the one thing worth opening.

There is no ⓘ, no place control and no header: the title bar names the place, Places and Update
are in the tool's bottom bar (§4), and this row is the way to everything about the radio. **It
pushes**, like every other row on the page (§3.1 U-11); it used to present a sheet, so one list of
rows had two navigation grammars and two ways back.

Banners, at most one, above the weather, for the cases where the radio itself blocks everything:

| Condition | Banner |
|---|---|
| Firmware below v1.15 | "Your radio has firmware 1.14. Weather needs MeshCore 1.15 or newer." |
| Channel sync finished, no slot holds the `#meshwx` secret, and no weather datagram this session | "#meshwx isn't set up on your radio." + Add channel (`.alert` confirmation; after dismissal the chosen slot is read back from the radio and written only if empty) |
| No weather bot known and nothing heard | "No weather radio heard yet. They appear as nodes named like WX-AUS." |

Your radio not being connected is said in place of the Update button and by the alerts list's
status line, never by a banner. A bot heard on the channel without an advert is named "Weather
radio 041D" and cannot be asked: "Can't ask until it announces itself".

## 11. Requests

### 11.1 Update, and the pull

**Two gestures, one planner** (§3.2 Q6). Pulling the list down and tapping **Update** in the
tool's bottom bar (§4) run the same `WeatherUpdatePlan` and send the same packets;
`WeatherToolModel.refresh()` is the awaited version of `update(_:)`, so the pull's own spinner
lasts exactly as long as the run.

**Every request is flooded on the channel** (§3.1.2 V-7, spec §7B, docs/MESHWX.md "Requests").
What the planner decides to ask for goes out as a Request datagram on `#meshwx`, which needs no
stored route to the bot: one send, the same bytes once more if nothing has answered in 10
seconds, and never a third. A radio too old for that — or one with no `#meshwx` slot — sends the
DM of §8.2 instead, with its three-send ladder; the fallback is silent and nothing on the screen
says which path a request took. Either way the answer comes back on the channel, to everyone.

The plan is named before it is sent, in the status line under the weather (§3.1.2 V-5), and
the button's `accessibilityValue` repeats it: "Asking WX-AUS for: alert list,
readings". The 15 September cut refused a gesture on the grounds that "a button can say what it
will ask for, a gesture cannot" (§3.1 O-4); the caption is how the gesture says it.

`WeatherUpdatePlan` reads the plan off the state the phone holds:

| Item | Asked for when | What is sent |
|---|---|---|
| alerts | no list is held; the list was built more than 3 h 15 min ago; or a gap, a warning the list named that never arrived, or an unfinished upgrade is outstanding | `>d`, or the missed-messages request of §7.4 (`>w <identity>` by priority, `>w <county>` under an upgrade) |
| alerts outside the bot's area | the evidence puts the place **outside** — a complete statement, or a footprint from a bot that has stated none (§6). `.unknown` never fires it | `>w <zone>` then `>w <county>` for the place's own codes — the bot serves place-named requests nationwide |
| readings | read off `WeatherConditions` (§8, §3.1 U-2a): a nearer station than the one shown or held, within 40 km; or the reading was read more than 70 minutes ago (an hourly batch plus ten); or none is held. Nothing when no station within 40 km could answer with something the page would show | `>o <ICAO>` for the station the page named; bare `>o` when a stale station is in the bot's **newest** batch; bare `>o` when nothing at all is held, which brings the whole batch for one packet |
| forecast | none is held for the place's point, or it was issued more than 12 h ago | `>f <point>` |
| what it covers | the bot has been heard, has stated no coverage, and has not been asked on this visit | `>cov`, sent last |

**A pull that can send nothing says so** (§3.1 U-6). With a `requestBlock` the gesture cannot
reach the radio, and a gesture that silently does nothing reads as a broken screen: the reason
appears in a capsule over the foot of the page for four seconds with a warning haptic, and the empty state above stops
offering the pull.

Nothing is planned for anything the channel delivered in the last five minutes; that reads
"WX-AUS answered in the last 5 minutes", which is not a claim that it is current. A gap is never
held back by that rule (§3.1 R-3). With nothing to ask for, the button is disabled and the caption
says "Everything is current · WX-AUS 4:25 PM" — the time is the **oldest** of the things checked,
so the sentence is true as of it, and the pull sends nothing. The steps go out five seconds apart,
the spacing the service enforces; a step refused inside the window waits it out once rather than
being dropped. Progress shows in the caption, and in the bottom bar on a screen whose control does
not speak for it.

Ask buttons are left only where they ask for something the screen is not otherwise about: the
missing-warning button on the alerts list, METAR and TAF on a station screen, "Ask for full text"
on an alert, "Ask for latest" on a product screen. A place page has none: the pull and Update are
the only way it spends airtime.

**"Everyone listening on #meshwx gets the answer"** is said once, on the radio page, in
*How it works* — where the whole of how asking works is explained. It also sits under the first
ask button on each secondary screen that has one, because that is where airtime is actually spent.
It is no longer repeated per card on the place page, which had three copies of it.

### 11.2 Status

- Labels: "Update", "Ask for latest", "Ask for full text", "Ask for METAR (conditions)",
  "Ask for TAF (forecast)", and "Ask for Tornado Warning" for one warning by identity.
- Status is keyed by the request, so any button for it shows it, and a bar at the bottom of the
  screen shows it when the sender is not on screen. A request's path — flooded datagram or the
  DM fallback (§11.1) — is never named: the user asked a bot a question, and how it went out is
  not their problem. Only the shape differs underneath, two sends over 20 s against three over
  45 s; the copy is one line either way and is settled separately from this document:
  - pending: "Asking WX-AUS…"; the one resend: "Asking again…"; on the DM ladder,
    the flood after the route is forgotten (docs/MESHWX.md, "Requests"): "Asking again by flood…"
  - answered: "WX-AUS answered at 1:32 AM", with "· nothing new" when nothing it carried changed;
    a forecast or readings answer with nothing newer than what is shown: "No newer forecast from
    WX-AUS" / "No newer readings from WX-AUS". A complete text reply this phone owns, under 5 min
    old, replaces its button with "WX-AUS answered at 1:32 AM".
  - already received live in the last 5 min: "Received 40 s ago · list as of 3:02 PM". Airtime
    etiquette only: the bot keeps no cache and would rebuild the answer. A slot is filled only by
    a message the reducer applied and that was heard live (not drained from the radio's queue).
  - timed out, bot silent: "No answer at 11:26 PM. WX-AUS may be out of range or busy."
  - timed out, bot heard: "WX-AUS was heard but didn't answer at 11:26 PM. It may be busy."
  - timed out, the radio confirmed the bot's radio received the request: "WX-AUS received the
    request, but no answer reached this phone by 11:26 PM. It may be busy, or its answer was lost."
    Only ever a DM: a datagram has no acknowledgement — the answer is the acknowledgement — so a
    flooded request times out as "silent" or "heard", never as "received".
  - not available: "WX-AUS has no data for that yet" / "…didn't recognise that place" /
    "…can't do that" / "…had an error" / "…is busy, try again in a few minutes"
  - your radio refused the send: "Your radio couldn't send this at 11:26 PM."
  - rate limited: "Wait a few seconds between requests"
  - Outcomes persist until the next tap on that button or 5 minutes.
- Other buttons while a request is pending: disabled, "Waiting for another answer…".
- Offline: "Connect your radio to ask WX-AUS" in place of the button.
- Bot not heard live for 90 min: caption "WX-AUS not heard since 8:02 PM — it may not answer".

## 12. The other screens

Four drill-ins from a place page, and what the radio page holds (§3.2 Q3, Q8).

- **Alert detail** (from the banner, from the alerts list, or from a tapped notification): map
  (location layer only when authorized; beside the details only when the column is at least 700 pt
  wide; the place is a neutral location-fix dot, never the pink dropped pin — on a map whose whole
  subject is warning polygons in red and orange, a hot-pink marker for *you* reads as one more
  warning, §3.1 U-17), "Covers Austin" / "Doesn't cover Austin (25 km N)" / "Not sure it covers Austin", the
  until-time, then **"issued 1:29 PM"** — when NWS issued the product, which the wire has carried
  since the bot's revision 5, so a radio out of range for three hours still says when the warning
  was issued rather than when this phone happened to hear it. "received 1:28 AM" is the fallback,
  for a bot older than revision 5 and for an issue time the wire had to saturate, which is a
  ceiling rather than a time (spec §3). Then the office, "Ask for full text" above Details (tags)
  and Areas ("County" / "Forecast zone"). An alert no longer held reads "No longer held by this
  phone", with no reason claimed; the narrative shows only when it answered this phone's request
  for this identity.
- **Station** (from the line under the temperature, or from a Places search by airport code): the
  station's own name as the headline, its code and state, then **one** distance line — its true
  distance **from the page this screen was opened on**, named: "under 1 km N from Austin, TX"
  (§3.1 U-8) — and which message the reading arrived in, "in WX-AUS's 9:40 AM report". Each fact
  once: the name and the distance used to be printed three times between the headline, the source
  line and that line. Then **Update** in the same position as the bar's, the readings the report carried under "as of 1:13 AM" — that station's own report
  time, not the batch's — and "Airport reports (coded)" with "Ask for METAR (conditions)" and
  "Ask for TAF (forecast)"; a report shows "received 11:02 PM". A station the bot's hourly batch
  does not carry says why it is old: "Answered on request, not in the hourly batch". A station
  nothing has ever arrived for still has a screen, reading "No reading from this station yet."
- **Weather Service text reports**: five rows on the place page, each opening its product
  directly — Forecast discussion, Hazardous weather outlook, Storm reports, Rainfall totals, Space
  weather. **One attribution rule for all five** (§3.1 U-15): the blurb says what the product *is*
  and nothing about where a copy came from, and the header directly above the text attributes it,
  read off the reply actually on screen — the area when the request names one ("NWS San Juan",
  "Texas"), then "heard on #meshwx · area unknown" for one nobody here asked for, then the radio
  that sent it and when it arrived. The blurbs used to attribute in two different currencies on
  adjacent rows — the discussion named a Weather Service office, the outlook named the radio — and
  the discussion's office was **the page's**, so a Fort Worth discussion overheard on an Austin
  page sat under "NWS Austin/San Antonio". A blurb cannot describe a text it has not seen. Each
  product screen shows the latest text that answered this phone's request, or labels one nobody
  here asked for;
  missing-part markers; Ask for latest; texts show "received 11:02 PM", never "as of". Storm
  reports and rainfall are asked for by state, so the state row is on their own screens — the index
  screen that used to hold it was a card that opened a page of cards.
- **Places** (the tool's only sheet, from the bottom bar; `.searchable`, prompt "Town, ZIP or
  airport code"). **One button, "Done"** (§3.1 U-10): "Cancel" implied a commit step that does not
  exist — every change here is already saved — and the filled blue "Edit" capsule beside it was the
  loudest element in the whole tool, for a mode that is no longer needed. In order: *My location*,
  with its label and the reading the phone holds for it; *Saved places*, each with its distance,
  its **reading** — "86° Mostly cloudy" by the page's own rule, "—" when nothing good is held
  (§3.2 Q9 as narrowed by §3.1 U-2) — a **bell** (§16), a **swipe to Remove** and a **drag to
  reorder**, both with no mode to enter; then the search's results — town rows with state and
  distance; a 5-digit ZIP or ZIP+4 instead shows one row, "Austin, TX 78701" with its distance, or
  "ZIP code 20500 isn't known"; a search that matches nothing reads "No matching place", the field
  taking three kinds of thing; weather stations whose airport code starts with a three- or
  four-character query (up to five, nearest first), and **picking one opens that station's screen
  and nothing else** — no page, no saved place, no move of the pager (§3.1 U-3). Last, quietly,
  *Heard on #meshwx*: forecast points held that this phone did not request, received in the last
  24 h. "This phone can't tell who asked" is **not** repeated here; it is said once, on the radio
  page under *How it works*.

  **Distances are the user's own** (§3.1 U-8): the list and its search measure from the phone's
  fix, whatever page the pager is on. Opening Places from the San Juan page used to measure from
  San Juan, so an Austin user reading a list of Texas towns was told Llano was 3,559 km away. Only
  with no fix at all do they fall back to the page on screen, and then the section says so —
  "Distances from San Juan".

  Picking anything sends nothing. Picking a place the list already holds shows its page and leaves
  it exactly where it is in the order (§3.1 U-4).
- **The radio page** (**pushed** from the radio row; `WeatherRadioView`): one screen for the radio
  and the channel, titled with the radio's own name, holding everything the place page gave up
  (Q8). In order (§3.1 U-16): *How it works* · *What it covers* · *Your requests* · *Weather
  stations* · *Alerts in its area* · *Alert notifications* · *Cached from the channel* · the
  channel · the radios · *Clear*.
  - **How it works** in four plain lines — your request goes out as a private message to the
    weather radio, its answer is broadcast on `#meshwx`, every phone listening keeps it, asking
    costs airtime everyone shares. This is where "answers are public" is said (§11.1).
  - **Alerts in WX-AUS's area**, with a count, opening the alerts list: a non-interactive map
    header that opens the full map on tap; sections Here, Can't place yet, Near, Elsewhere; the
    §7.4 status line; and "Missing from this phone" with "Listed, not received" rows for the source
    bot's missing warnings and one button naming the one it asks for. A row the bot said it lacks
    reads "Listed, but WX-AUS didn't have it when asked" and is passed over.
  - **Weather stations**, naming every row it will show ("19 weather stations, 14 in WX-AUS's
    area"): the station the page is showing first, then by distance from the place, in two sections
    named for where the reading came from — "From the hourly report" and "From answers on the
    channel" — never for who asked, which the phone does not record. Each row carries that
    station's own "as of".
  - **Alert notifications** (§16.6), with how many places are watched.
  - **What it covers**, from the bot's own statement and nothing weaker (spec §7A): the stated
    circle, how many forecast zones, the Weather Service offices, the hourly station cap — a list
    the bot had to cut reads "and more it didn't list", never a denial — with the receipt time,
    since the statement carries none of its own. Having said nothing is not having said "nothing":
    "WX-AUS hasn't said what it covers yet." with **Ask what it covers**.
  - **Your requests**: this phone's own, newest first, each with when it went out and how it
    ended. Persisted, at most 40 rows and a week, and only what actually went on the air.
  - **Weather radios** as inline rows with checkmarks, "Choose automatically" only with two or
    more; `#meshwx` slot and last weather message; **Cached from the channel (37) ›**; "Clear
    received weather".
- **Cached from the channel** (`WeatherCachedView`), from the radio page and nowhere else: what the
  phone is holding from the channel, in two views of one pile chosen with a segmented control
  (§3.1 U-16).
  - **By kind**: grouped with counts — station readings, forecasts, airport reports, warning
    narratives, and warnings for places elsewhere. Each row names the thing, its content time and
    when it arrived, and opens the screen that shows it in full where there is one.
  - **Newest first**: what *Heard on #meshwx* used to be, as a section of the radio page above two
    other counts of the same pile. What the channel carried in the last 24 h, at most 30 rows,
    scheduled broadcasts and answers in one list and not told apart. An hourly batch is one row
    however many different times its stations reported, keyed by the batch's own time
    (`WeatherChannelHistory`): per-station times would otherwise turn one message into fourteen
    rows. Each row carries the content's own time where the message has one and the receipt time
    always, under "This phone can't tell who asked."


### 12.1 Where the data came from, and a reply cut for the air

Since revision 7 every message that carries weather says where the bot got it (spec §2.2, the
flags nibble's bits 3-2): off its own GOES dish, from NOAA over the internet, or both. The app
says it in one quiet line in the footnote voice — "From the GOES satellite", "From the internet",
"From GOES and the internet" — never a badge and never a colour, because it is provenance and not
a warning. It sits under the text on a **product screen**, under the point line on the
**forecast** card, and under the issuing office on **alert detail**.

A radio that has not said shows **nothing at all**. There is no fourth phrase for "didn't say", so
a page fed by a bot older than revision 7 reads exactly as it did. A Cancel never carries it — the
whole of that message's nibble is the reason the warning ended (spec §4) — so nothing is ever
inferred from one.

A text reply the bot had to cut adds a second clause on the same line, joined with a middot: "The
rest didn't fit on the radio." That is a different claim from the missing-part marker in the body.
A marker is a chunk the air ate and Ask for latest may fill it; this is the whole reply that radio
will ever send for that request, and the bot now cuts at a sentence boundary rather than mid-word,
so the text ends where a sentence does.

## 13. Engineering

- **Lifetime**: the model is held for the tool visit outside the view, so it survives pushes and
  the compact/regular shell swap, and is not detached on `onDisappear`. The page the pager is on
  is held there too (`selectedPageID`), so the visit comes back to the place it was looking at;
  `attach` is idempotent under `.task(id: servicesVersion)`; its tasks live in a holder that
  cancels them on deinit.
- **Snapshot, per page**: a page's views read one `WeatherScreenSnapshot`, rebuilt off the main
  actor on a service event, place change, bot change, location sample change, geometry load, or
  scene activation. A 30 s tick rebuilds with a fresh clock from cached inputs (contacts,
  channels, offline state, place facts), and does not run while the scene is inactive.

  The tool is a pager of places, so **one snapshot is not enough**: with one of them, every
  screen reached from a page shows whichever page was built last (§3.1 P-1). A build is asked for
  a page and belongs to it for good — `WeatherBuildRequest.pageID` goes in, and a
  `WeatherPageKey { pageID, place }` is stamped into both the `WeatherScreenSnapshot` and the
  `WeatherScreenContext` that come out. Truth travels with the value; there is no separate "which
  page is this" flag to read at the wrong moment.

  The model keeps a `[pageID: WeatherPageBuild]` cache — the page on screen and the two a swipe
  can reach, evicted beyond that — and builds the neighbours at idle priority, refreshing one
  older than 15 s, so a swipe lands on a page rather than on a spinner. `WeatherPlaceFacts` are
  cached per page and kept for every page: they are the 35,000-place label lookup, the area codes,
  the nearest station and the state code, and they are what makes swiping back free.

- **`WeatherPageScreen`**: the build for one page plus the model, and what every drill-in takes
  instead of the model — `WeatherReportProductView(screen:product:)`,
  `WeatherStationsView(screen:)`, `WeatherStationDetailView(screen:index:)`,
  `WeatherAlertDetailView(screen:identity:)`, `WeatherAlertsListView(screen:)`,
  `WeatherRadioView(screen:)`, `WeatherCachedView(screen:)`, `WeatherAskButton(screen:…)`,
  `WeatherUpdateControl(screen:plan:)`. It reads the page's build back by id while the model
  holds it, so an answer arriving with a detail screen open shows on it, and falls back to the
  build it was opened with once that page has been evicted from under it. `model.snapshot` and
  `model.context` remain, defined as *the page the pager is on*, for the screens that are about
  the visit rather than about a place: Places, the notifications screen, the pending bar.

- **Per page, not per visit**: Update and the pull plan from `model.plan(for: pageID)` (empty, so
  disabled, until that page has a build); `WeatherUpdateRuns` keys the spinner and the status
  caption to the page that started the run and allows one run at a time, so a pull and a tap can
  never overlap and the loser's cleanup cannot put the winner's spinner out. The storm-reports
  and rainfall state is `reportState(for: pageID)`. Text reports are chosen by
  `WeatherReportSelection`, which matches the reply's own `assembly.request` — office and state —
  and only ever falls back to the subject for a reply nobody here asked for, labelled as answered
  for an unknown area.

- **A push carries its page**: `WeatherStationTarget` and `WeatherAlertTarget` name the page a
  station or an alert was asked for from, the pager's one `navigationDestination` builds the
  destination from `model.screen(for: push.pageID)`, and nothing reads "the page the pager is on"
  to decide what a pushed screen is about (§3.1 U-18). A tapped notification selects its page and
  names its alert in the same turn, so a destination that asked the pager could be built against
  the page being left, and "Covers Austin" would then be about Round Rock.
- **A page can never vanish under the pager**: every write to the saved list goes through one
  place that resolves `selectedPageID` through `WeatherPages.selection` and **writes it back**;
  `WeatherSavedPlaces.setting(watched:)` trims nothing, because a bell adds no row. A tapped
  notification's `placeID` selects that place's page before the alert is pushed
  (`WeatherPages.pageID(forWatchedPlaceID:)`), and the pager has one enum-driven
  `navigationDestination(item:)` rather than two `isPresented` destinations that could both be
  true.
- **Tables and geometry**: warmed off the main actor; GeoJSON loaded only when an area-based
  alert is held, once, shared.
- **Location**: a value struct projected from `LocationService`; `onChange` on it, never on a
  `CLLocation`; the map's location layer gated on authorization; no automatic permission prompt.
- **Presentation**: `.alert` for confirmations; sheets for picker and About; destination-closure
  navigation links; no menus that tear down their host.
- **Accessibility**: sections `.contain` with a summary element; request status in
  `accessibilityValue` plus an announcement when it settles; scaled temperature; tags as one
  truncating `Text`.
- **Pure types** (MC1Services, `Services/Weather/Screen/`, macOS-testable): `WeatherPlace`,
  `WeatherLocationSample`, `WeatherCoverage`, `WeatherAlertPlacement`, `WeatherAlertStatus`,
  `WeatherAlertPriority`, `WeatherAlertFolding`, `WeatherAlertRequests`, `WeatherPrimaryStation`,
  `WeatherForecastRows`, `WeatherForecastCard`, `WeatherNames`, `WeatherRequestStatus`,
  `WeatherScreenSnapshot`, `WeatherUpdatePlan` (§11.1), `WeatherSavedPlace` / `WeatherSavedPlaces`
  (§5), `WeatherPage` / `WeatherPages` (§4), `WeatherConditions` / `WeatherNearbyStation` /
  `WeatherPlaceRowReading` (§8, §12), `WeatherWarningBanner` (§7.3), `WeatherRadioRow` (§10), `WeatherAlertSubscriptions` / `WeatherAlertWatch` / `WeatherAlertGate` and
  `WeatherAlertNotificationRules` (§16); `WeatherTextMatch` beside the service. The saved list is
  one JSON blob under one defaults key (`WeatherSavedPlacesStore`), and it moved into the service
  layer when the alert notifier started reading it: a watched place is a saved place with its
  bell on, and there is one of it. Tested against the phone's real state and the kit vectors.

## 14. Questions for Rafael

1. **Forecast shape**: WX-AUS sends seven daily entries with both temperatures and
   `first_period` 0. Is that the intended v5 shape (then spec §7 needs updating, and what does
   `first_period` mean for days), or a bot bug? *Answered by spec revisions 2 and 3: whole days,
   `first` counted from the issue date at the point.*
2. **Alert coverage**: what decides which alerts WX-AUS relays — its NWS offices, a radius, a
   county list? The app currently infers coverage from the stations it reports. Advertising the
   offices in the protocol would let the app say "No alerts" with confidence. *Answered: zones
   within 120 km of home, and storm warnings whose polygon touches that circle; the stations
   reach about 96 km (§3.1 R-7). Advertising the area was the open half, and spec §7A answers it:
   the bot states its circle, its zones and its offices every 3 h, and the app reads that
   statement before any inference (§6).*
3. **Cached digests**: spec §8.2's five-minute answer cache can re-send an alert list that a
   newer warning has already overtaken. The app now protects itself; should the bot also drop
   its cached `>d` answer whenever its warnings change? It would also let the app clear "missed
   messages" with the first `>d` answer instead of waiting for a list built 10 min after the gap.
   *Answered by spec revision 2: the bot has no cache; the margin is 2 min (§3.1 R-3).*
4. **Should Update be able to ask for coverage?** *Answered: yes, and built (§3.1 O-8).* `>cov`
   is a case in `WeatherRequest` with an answer slot of its own, and a fourth item in the plan
   (§11.1). The staleness half of the sketch was **rejected**: a statement describes the bot, not
   an hour, and never goes stale (§6), so it is asked for only while none is held — once per visit,
   so a bot that does not answer is not asked on every tap.
5. **Notifications**: should a new warning covering your location notify you when the screen is
   closed (opt-in)? It needs a severity threshold decision. *Answered 2026-09-16 and built (§16):
   opt-in per place, storm warnings with sound, other warnings a silent toggle, watches and
   advisories never. §3.1 N-1 to N-8 record every answer; N-8 is the one thing the
   implementation decided and wants confirming.*
5. **Text replies don't say what they answer.** A chunk carries only its subject, so another
   phone's `>storm OK` looks like this phone's `>storm TX`. The app guesses from the words, and
   state codes such as IN, OR, OK and ME are ordinary words in upper-case NWS text; the forecast
   discussion has no key at all, and a `>wt` narrative carries no office or tracking number.
   Could the bot echo the request's argument in the first chunk (`STORM TX`, `AFD EWX`,
   `SV.W.EWX.42`)? *In part: since revision 3 `>metar` and `>taf` replies open `METAR <ICAO>` /
   `TAF <ICAO>` and never carry another station's report; the others are still open.*

## 15. Not in this cut

A stations map; request jitter; a phone-to-bot clock-offset estimator; forecast points' own time
zones (day labels use the phone's); widgets. Alert notifications were on this list until
2026-09-16 (§16).

## 16. Alert notifications

Warnings are **broadcast** on `#meshwx` as they happen, with no request behind them, so every
phone on the channel already has them. Filtering them against a place and raising a local
notification costs the mesh no airtime at all — which is why this exists at all, and why it asks
the radio for nothing.

### 16.1 What it can honestly promise

The app declares only `bluetooth-central` background mode and restores its central, so while the
radio is connected and in range, datagrams keep arriving and being ingested with the app
backgrounded or the phone locked, and a notification can be raised from there. **Nothing arrives
if the app is force-quit, or if the radio is off, disconnected or out of range.** There is no
critical-alert and no time-sensitive entitlement, so the loudest a warning can be is a normal
notification with a sound. Whether iOS relaunches the app into the background after terminating
it is **unverified** and is the on-device test. The screen's footer says exactly this, and it is
deliberately conservative until that test:

> Alerts arrive only while your radio is connected and in range, and while DigitainoMesh is
> running. This is not a substitute for a NOAA weather radio or your phone's emergency alerts.

### 16.2 Subscriptions

One bell per place, and nothing else: every saved place in Places has one, and so does *My
location* (§3.1 N-1). **Nothing is watched until a bell is turned on** (N-2) — saving a place
does not watch it, and no subscription is ever created for the user.

A watch is the saved place's own row (`WeatherSavedPlace.isWatched`), so there is one list and
not two: removing the place removes the watch, picking it again from a search keeps the bell, and
a watched place never falls off the end of the twelve (`WeatherSavedPlaces.ordered`) — the
ceiling is there so the sheet stays a list of places, not a way to lose a warning. The two
toggles and whether My location is watched are `WeatherAlertSubscriptions`, one JSON blob under
one defaults key.

**My location** is matched against the **last position the app knows** (`WeatherLastPosition`),
which can be hours old, because the app only has location while it is in use. `LocationService`
records each fix — but only while that bell is on, and at most one a minute; turning the bell off
deletes the stored position. The place is built through `WeatherPlace.location`, so an old fix
carries the uncertainty its age has earned (a kilometre a minute, capped at 25 km) and a
three-hour-old position matches generously rather than pretending to be current. Every row that
shows it shows its age, and nothing anywhere says the phone is being followed (N-7).

### 16.3 What notifies

| Rank (`WeatherAlertPriority.rank`) | Covering the place (`.here`) | Within 50 km (`.near`) |
|---|---|---|
| 0–5 Tornado, Extreme Wind, catastrophic Flash Flood, tornado-tagged Severe Thunderstorm, Flash Flood, Severe Thunderstorm | **Sound** (N-3) | ranks 0–1 only, with the *Tornado warnings nearby* toggle, off by default (N-6) |
| 6 every other warning | **Silent**, with the *Other warnings* toggle, off by default (N-4) | — |
| 7–9 watches, advisories, statements | **Never** (N-5) | never |

`.checking` and `.unplaced` notify nothing: a warning the phone cannot place is never read as
"here". A warning only *listed* in a digest and never received has no geometry and never
notifies — it stays the dashboard's "Listed, not received" row.

### 16.4 One notification per warning per place

The request identifier is `wx-<botID>-<event>.<office>.<etn>@<placeID>`
(`wx-4C7A-TO.W.EWX.42@zip:78701`), threaded per place. The bot in it is the one that delivered
the copy first, so two bots holding the same warning update one notification instead of posting
two.

- A **repeat or update replaces** it, silently: no sound, `.passive`, which keeps it out of the
  banner in the foreground too. One the user has already dismissed or opened is not put back.
- It **sounds again only on a real escalation**: the tornado tag rises, flood damage reaches
  catastrophic, the warning grows to cover a place it was only near (N-8), or the expiry is
  extended and the user was last told more than 20 minutes ago — measured against the expiry they
  were told, not against the last silent replacement.
- A **cancellation or a removal by a list removes** the notification. There is never an
  all-clear: "the warning ended" and "the weather is fine" are different sentences and the phone
  only knows the first.
- An update that **no longer covers** the place removes it too — a shrinking polygon is a
  cancellation for that place.
- **Nothing is ever scheduled for a future expiry.** An expired warning never notifies, and one
  already posted stays as it is: it names its own end time.
- A warning **drained from the radio's queue at connect** (`MessagePollingService.isDrainingBacklog`,
  the same mark the five-minute rule reads) notifies only while it is still active and only for
  ranks 0–5, and says so: "Received late — sent while your radio was out of range." An expired
  one notifies nothing.

What has been posted is remembered across launches (`WeatherAlertPost`, one defaults blob,
pruned six hours after a warning expires), because the phone can be relaunched between a warning
and its repeat.

### 16.5 Wording

Title the event ("Tornado Warning"); subtitle the source ("National Weather Service via WX-AUS");
body the place, the end time and the one tag the warning is being called for — "Austin · until
9:41 PM · radar indicated", or "25 km N of Round Rock · until 9:41 PM · tornado observed" for a
nearby one. A late one adds its line underneath. The words come from the app's own tables through
`WeatherAlertNotificationCopy`; `WeatherAlertDefaultCopy` in MC1Services is the English of the
same entries and stands in for a background launch with no scene, the way
`NotificationStringProvider` has an English fallback for every chat notification.

### 16.6 The screen

**Alert notifications**, reached from the radio page (§12). The Alerts card that used to carry
the other way in is gone (§3.2 Q8, Q13); a place's bell is in Places, beside the place:

- the watched places, each with what can reach it now — "Watching · radio connected", or "Not
  watching — radio disconnected since 8:42 PM" when this visit saw the radio go, and without a
  time when it did not — and, for My location, the age of the position it is matched against;
- **Also notify me about**, with the two toggles and the line that says what always notifies and
  what never does;
- the footer of §16.1.

Turning a bell on is done in **Places**, beside the place. **Permission is asked for at that
moment and at no other** — never when the tool opens. Denied, no bell is turned on: the sheet
says notifications are off for the app and offers Settings.

**Tapping** a notification leaves what it named in `WeatherAlertNotificationTap`, opens the Tools
tab and names Weather as the open tool; the tool takes it when it next appears and pushes that
alert's detail. On iPad that lands on the alert, because the Tools columns render from
`NavigationCoordinator.selectedTool`. On iPhone the compact `ToolsView` seeds its stack from that
selection once and is deliberately one-way afterwards, so the tap lands on the Tools list and the
alert opens as soon as Weather is opened. A route that pushed it would need a `pendingTool` on
`NavigationCoordinator`, the way `pendingChatContact` works, and one `onChange` in `ToolsView` to
append it to the path.

### 16.7 Where it runs

`WeatherAlertNotifier` is an actor in `ServiceContainer`, beside `WeatherService`, started and
stopped with its event monitoring. It cannot live on `WeatherToolModel`: that exists for one
visit to the tool, and the whole point is a notification with the tool closed. It subscribes to
the service's events, reads the watched places from the same store the Places sheet writes, and
reads state back from the service — the reducer has already applied the warning by the time the
event arrives. A warning with no polygon needs the bundled outlines, which are 15 MB loaded on
demand: it is parked, the outlines are loaded once, and it is judged again.

The common case is two lines: nothing in the message touched a warning, or nothing is watched, and
the evaluator reads no state at all.
