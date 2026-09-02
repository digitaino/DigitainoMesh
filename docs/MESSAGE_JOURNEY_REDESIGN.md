# Message Journey — redesign of the long-press message sheet and its evidence screens

Branch: `personal`. Status: adversarial review + design panel, 2026-09-02. Not yet implemented beyond Phase 0 items (2)–(3).

Rafael's brief: *"now we have two different systems for seeing 'what a message has done'. we have the heard repeats (view path) that we get from the message itself and the 'network view' from the scope api. so this is confusing and I want to redesign it so that it is easy to understand what the user is seeing. I dont know if we should combine the systems? or leave them separate but it needs to be more obvious."*

How this document was produced: five readers mapped the sheet and the three systems from source; six adversarial reviewers (comprehension, information architecture, sibling-screen consistency, states and dead ends, interaction and lifecycle, provenance and trust) produced 100 findings; three verifiers (code truth, user impact, iOS convention) confirmed, refuted or merged every one, leaving 65; three designers answered from three framings (merge / separate-but-explicit / hybrid), three judges scored them, and one synthesis produced the spec below. Baseline screenshots were taken in the simulator from a restored phone backup.

## Decision

COMBINE THE QUESTION, LAYER THE EVIDENCE, KEEP THE TWO VOCABULARIES APART. One entry per message, one screen behind it, one map — with two labelled sections in one panel: "What your radio saw" (free, offline, drawn the moment the screen opens) and "What the observer network saw" (opt-in, over the internet, inert until the rider presses a button that names the cost). Nothing merges at the data layer, no count or colour is ever shared between the two, and the observer half performs no network request until that button is pressed — which is strictly stricter than what ships today, where opening the Network View fetches on appear.

Concretely: the sheet's three rows (View Path, Network View, Repeat Details) collapse to ONE row, titled with the rider's own question — "Where did this go?" for a message they sent, "How did this arrive?" for one they received — moved above the composing actions so it is the first thing under the emoji strip. It always says something true from local data before it is tapped, including in the state the owner opens the sheet for (a channel send with no echo), where today the sheet is completely mute. Behind it is one fork-only screen, MessageJourneyView, whose map always carries the local evidence and whose observer layer is drawn over it only after the explicit lookup.

Spine: the hybrid design ("One Question, One Screen, Two Layers"), which two of three judges scored first and which is the only submission that closes all nine P0s and fixes F088 at the source. Grafted in: the merge design's live sheet row with its "Listening for repeater echoes…" window, its per-row role line, its host-named cost sentence, its Settings-only consent stance, its Copy artefact rules, its F054 fix and its honest direct-routed wording; the separate design's normative vantage table, three-kinds-of-absence taxonomy, executable privacy assertions, loopOutcome enum, and the seven-line deletion of "Heard: N repeats". Two judge-flagged errors in the winning plan are corrected here (MapSnapshotRenderer needs no hunk; MC1MapView+Layers does), and one architectural improvement is added that no design proposed: the surviving fullScreenCover stays attached to ActionsDetailsSection's own VStack, so the presenting context and both deferral mechanisms are byte-for-byte what ships today.

## Rationale

Rafael's words were "two different systems for seeing what a message has done… this is confusing… it needs to be more obvious." The honest reading is that he does not have two features with a naming problem. He has one question — did it get out, how far, through what — and the app makes him ask it three times, in three vocabularies, and then hands him two numbers ("Heard: 3 repeats" and "Heard by 9") that were never about the same population and differ by six.

So: combine, but only at the level of the question. Separating them further (better labels, same three screens) is cheaper and was seriously argued, but it pays F036 in full — the two halves of "did it get out, how far" still can never be seen in one frame — and F036 is his complaint restated as an architecture. Merging the figures would be worse: an echo is proof the uplink from here works, an observer report is proof a stranger far away heard a copy, and one headline over both would be a lie. The middle is the right answer: one entry, one screen, one map, two provenance-labelled sections, and no sentence, count, colour, pin or distance shared between them.

Three things make this safe rather than reckless. First, the fetch does not move with the entry — it moves further away from the rider. Today the cover fetches the moment it appears (two .task calls, the observations POST and the roster GET); here nothing leaves the phone until a bordered button reading "Look Up on the Observer Network" is pressed under a sentence naming the actual host. The opt-in stays in Settings and no screen in this feature writes it. Second, the risky code does not get rewritten — Phase 1 moves PacketScopeDetailView's hard-won behaviour into an observable model with the pixels unchanged and the existing tests as the oracle, before any new UI exists. Third, the load-bearing sheet mechanics are untouched by construction: the surviving cover stays on ActionsDetailsSection's own VStack with its onDismiss deferral verbatim, so Reply with Route's wire string, the iPad presenting context, and performAction's dispatch-then-dismiss order are exactly what ships.

The one thing this spec asks Rafael to give up: after a Send Again, the earlier attempt can no longer be looked up. Today the app keeps that lookup and quietly shows a superseded packet's coverage next to a bubble that says the message was sent twice, under a caption blaming observers for a choice this phone made. Clearing the hash on resend makes both halves always describe the same attempt. That is a real capability removal and it needs his yes, not a reviewer's inference.

What this does not fix, and he should hear it plainly: a rider who never long-presses a bubble still learns none of this exists. The sheet is now obvious once opened; nothing yet makes opening it obvious.

## 1. The shape, in one paragraph

The message actions sheet gains a caption, "What happened to this message", and exactly one row under it, placed as the FIRST child of the sheet's ScrollView — above Reply/Copy/Translate/Send Again, separated by a Divider. It replaces View Path, Network View and the Repeat Details disclosure. Its title is the rider's question ("Where did this go?" / "How did this arrive?"); its second line is the local-only answer, computed from data already on the phone, never a fetch. Tapping it opens one fork-only fullScreenCover, MessageJourneyView, whose map is the local geometry (echo loops outgoing, header path incoming) and whose floating panel opens with the message's identity, then a section headed "What your radio saw" holding the answer line, the figures and the rows. Below that, always present, is "What the observer network saw", whose first state is a bordered button reading "Look Up on the Observer Network" under the sentence "Sends this packet's identifier — never its text — to scope.digitaino.com over your internet connection." Tapping that button, and only that, starts the CoreScope lookup. When it returns, observer pins and the weighted link substrate appear on the same map beneath the local route, and the observer rows, ladder, breadcrumb, sort and focus model appear inside that second section. The local layer is never removed by an observer focus — it is the constant the observer evidence is compared against.

ARITHMETIC FOR THE PLACEMENT (F029). Today the first evidence row sits behind an ~82 pt header, an ~52 pt emoji strip and up to four ~54 pt action rows — roughly 350 pt, at or past the medium-detent fold on a phone. After the move: 82 + 52 + ~64 = ~198 pt, and Reply lands at ~262. Verify on the smallest supported phone, and separately at accessibility Dynamic Type where ActionsEmojiSection moves inside the ScrollView (MessageActionsSheet.swift:56-63) and the detents become [.large].

## 2. The vocabulary spine — normative, check this table into the repo

Check this table in beside MessageJourneyState.swift. RULE: no user-visible string may be added to this feature that does not fit a cell of it. Forty-odd new keys across eleven locales with no CI parity check is exactly the condition under which vocabulary drifts back apart — which is how the app got here.

| Source | Vantage | Cost | Answers | Section | Provenance line |
|---|---|---|---|---|---|
| A. Heard repeats | your own radio demodulated the echo | free, offline, outgoing channel only | did it get out of here at all | What your radio saw | Measured here · no internet |
| B. Header path | the packet's own header, written by the repeaters that carried it | free, offline, incoming only | how did this reach me, from where | What your radio saw | Recorded here from the packet's own header · no internet |
| C. CoreScope | third-party stations on one internet server | opt-in, internet, user-initiated | who else, far away, heard it | What the observer network saw | Reported over the internet |

A and B share one section header because they are mutually exclusive by direction — the rider must never have to learn two local vantages — but carry different provenance lines because they are different evidence.

FIVE RULES that fall out of the table and govern every string:

1. HEARD. Retired as a shared prefix. Nothing on either surface says "Heard: N" or "Heard by N" again. Local says "echoed it back to you"; observers say "reported hearing it". The sheet's upstream "Heard: %d repeats" info row is DELETED (ActionsDetailsSection.swift:251-256) — see §16 for the merge cost, which is worth paying: leaving it means one sheet showing "3 echoes from 2 repeaters" on the row and "Heard: 3 repeats" four rows below, which is F090's exact confusion reproduced inside the fix.
2. ECHO vs REPEATER (F090). heardRepeats counts RX-log entries, not repeaters. Both figures are always reported and never conflated: the answer line counts DISTINCT repeaters (deduped by resolved public key from the loaded MessageRepeat rows), the figures line counts ECHOES. One repeater echoing three times reads "1 repeater echoed it back to you" over "3 echoes". The same rule applies incoming: the answer line counts distinct repeater identities among pathHops (so A3→7F→A3 is two repeaters), the figures line carries "3 hops".
3. HOP. One formatter behind every hop count on the screen, reusing the three existing keys verbatim — packetScope.direct "Direct, no repeaters" / packetScope.hopOne "1 hop" / packetScope.hopCount "%d hops". Casing collisions ("1 Hop" vs "1 hop" vs "Hop 1") disappear because the two upstream row views that produced them are no longer rendered here. Whose journey a count describes is carried by the ROW's role line, not only by the section header (§7).
4. REPEATER IDENTITY. One component, RepeaterIdentityLabel(hashHex:resolution:) = monospaced uppercase hex + resolved name + the tappable FallbackMatchIndicatorView "?", used by echo rows, incoming hop rows and observer hop pills alike. The bare "~Name" tilde convention is retired (PacketScopeDetailView.swift:983). Unresolved is chats.repeats.unknownRepeater "<unknown repeater>" everywhere; the server's 4-hex resolved key goes in the ID column, never in the name column.
5. SIGNAL. One SignalFigure view — cellularbars at SNRQuality.barLevel, one decimal, the localized "dB" (reuse remoteNodes.status.snrBadgeUnit) — always carrying its measuring subject: "Echo in 6.2 dB", "Last hop in 8.5 dB", "They heard 12.2 dB". Direction is additionally stated once per section by the legend and the provenance strip.

And one label for the rider's own radio: localRadioLabel = appState.connectedDevice?.nodeName ?? L10n.Chats.Chats.Path.Receiver.you ("You"), resolved ONCE by MessageJourneyView and passed to the identity line, the local rows, the receiver row and the .pointB pin, so header, row and pin can never disagree (F009).

## 3. The sheet — the group, the row, and the exact state table

ActionsDetailsSection now renders ONLY the "Details" caption and the read-only info rows, which is what that caption was always meant to label (F007, F032). The journey entry is a separate fork-only view sitting one level up.

ORDER inside MessageActionsSheet's ScrollView VStack:
```
[emoji + Divider  — accessibility Dynamic Type only]
"What happened to this message"   ← caption, .caption/.secondary, .horizontal + .top 12 + .bottom 4
MessageJourneyEntry               ← NEW, ~64 pt
Divider().padding(.vertical, 8)
ActionsButtonsSection             ← Reply/Mention · Send DM · Copy · Translate · Send Again
ActionsDetailsSection             ← "Details" caption + info rows ONLY
ActionsDestructiveSection
```

ROW SHAPE. Two forms, one geometry.
- DESTINATION: `Button { HStack { Image(systemName: glyph); VStack(alignment:.leading, spacing:2){ Text(title).font(.body).foregroundStyle(.primary); Text(subtitle).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true) } }.padding().contentShape(.rect)`
- EXPLAINER: identical geometry, NOT a Button, no chevron, `.accessibilityElement(children:.combine)` + `.accessibilityAddTraits(.isStaticText)`. It is NEVER `.disabled()` — a disabled row announces "dimmed" and reads as broken; a static row reads as an answer.
- Glyph in both directions: `point.topleft.down.to.point.bottomright.curvepath` (F034). The subtitle line is always rendered, so the row never changes height under a moving finger (F074). ≥52 pt by construction.

THE DESTINATION RULE, stated once: EXPLAINER when the message can never produce a repeater trail AND has no packet identity to look up — that is exactly (a) an outgoing DM, and (b) an incoming message with no recorded path (direct-routed, or flood with empty/absent pathNodes) AND packetContentHash == nil. Everything else is a DESTINATION. The row is NEVER absent, so "this app has no such feature" and "this message produced nothing" stop looking identical (F019, F025, F063).

EXACT SUBTITLE PER STATE — this is the complete table. Every value is a pure function of (MessageDTO, [MessageRepeatDTO]?, availability, repeaterSignals.isAttached, now).

OUTGOING CHANNEL — always a destination:
| state | subtitle |
|---|---|
| rows loaded, E echoes from R repeaters | "3 echoes from 2 repeaters" (built from the two reusable fragments) |
| heardRepeats > 0, rows still loading | "Checking your radio's records…" |
| heardRepeats > 0, rows came back empty | "Couldn't read this message's echo records." |
| heardRepeats == 0, message younger than ChatNoRepeatsDetector.defaultWindow (5 s) | "Listening for repeater echoes…" |
| heardRepeats == 0, settled | "No repeater has echoed it back to you" |
| heardRepeats == 0, repeaterSignals.isAttached == false | "Repeat watching is off for this radio" |
| any of the above with sendCount > 1 | subtitle + " · sent 2 times" |

OUTGOING DM — EXPLAINER, never tappable: "Direct messages leave no repeater trail."

INCOMING:
| state | form | subtitle |
|---|---|---|
| flood, pathNodes non-empty, R distinct repeaters | destination | "It reached you through 3 repeaters" (singular: "…through 1 repeater") |
| flood, pathNodes nil/empty | destination if packetContentHash != nil, else EXPLAINER | "Flood-routed — your radio didn't record which repeaters carried it" |
| direct-routed | destination if packetContentHash != nil, else EXPLAINER | "It came by a set route — the packet doesn't record which repeaters carried it" |

The direct-routed wording is load-bearing and deliberately not "no repeater in between": Message.swift:700 documents direct routing as a pre-built path whose hops are CONSUMED in transit. The app cannot know the sender was in earshot, and must not say so.

SCOPE OFF / NO HASH never changes the row's presence or its subtitle. The observer state lives entirely inside the screen's Section B. That is the privacy design, and it is asserted by a unit test (§15).

LIVENESS (F046, F071). MessageJourneyEntry subscribes to HeardRepeatsService.events() filtered to this message id (the stream exists and is public nonisolated, HeardRepeatsService.swift:25) and recomputes its subtitle in place. So at t=3 s after a send — the exact moment the rider long-presses — the row reads "Listening for repeater echoes…" and then changes to "2 echoes from 2 repeaters" while the sheet is open, instead of asserting a settled negative. A count growing because evidence arrived is not the noun-swap defect; the NOUN never changes, because the answer line is only ever derived from the rows.

CAVEAT to state in the code comment: the 5 s window is measured from message.date (createdAt), which for a queued send predates the transmit. A message that sat in the queue can arrive at the sheet with the window already elapsed and show the settled negative — which is also what the retry card behind the bubble shows, so the two never disagree.

ROOM MESSAGES get no row: RoomMessageActionsSheet is a separate parallel surface. It gets one line in its Details block: "Room messages travel through the room server, so there is no repeater trail to show." (F067)

## 4. The screen — chrome, toolbar, and the panel stack

MessageJourneyView, fork-only, presented as the single fullScreenCover — a cover, not a sheet, for the documented reason: a downward drag over a full-bleed map must pan (BETA_CHANGES.md:481 is the fork's own precedent for the sheet-vs-cover bug).

NAVIGATION TITLE, .inline, stable in every state: the same string as the row that opened it — "Where did this go?" / "How did this arrive?". This is deliberately NOT F014's mistake: the row's label is the question the screen answers, not the name of a sibling control, and the row is no longer visible behind it. The .principal PathDistanceBanner is removed entirely, so the title is never replaced and is not visible only on failure (F015); its distance moves into the figures line where it can carry the "≥" qualifier.

TOOLBAR: .topBarTrailing group = Copy (doc.on.doc, disabled until anything is on screen), then Done in .confirmationAction. The Network View's leading Refresh is retired — re-checking becomes "Check again" inside Section B, where the thing it refreshes lives (F050).

LAYOUT. If anything beyond the origin can be plotted by EITHER layer → MessagePathMapCanvas full-bleed with the floating liquidGlass panel as a bottom safeAreaInset (existing constants unchanged: radius 20, 12 pt inset, 45 % height budget, 30 % under a route focus, 132 pt list floor — PacketScopeDetailView.swift:34/41). Otherwise → the IDENTICAL panel content as a plain scroll, no glass, no map. There is no separate List layout with its own error/empty/loading vocabulary; that is what retires F045.

PANEL STACK, fixed shape in every state so nothing appears or disappears under the thumb.

FIXED HEADER (capped at DynamicTypeSize.accessibility2):
1. IDENTITY LINE — .caption/.secondary, one line: "You → #general · Sep 2, 14:07" or "Alice → you · Sep 2, 14:07" (F048)
2. MESSAGE PREVIEW — .caption2/.tertiary, lineLimit 1; hidden at accessibility sizes and under a route focus, where the height is needed
3. RETRY LINE — .caption2/.secondary, only when sendCount > 1: "Sent 2 times — each attempt is a separate packet." It sits with the message's identity because it is a fact about the message, not about observers (today it is printed inside the observer header and misattributes the selection to them — F088)
4. SECTION A HEADER — "What your radio saw" (.caption.weight(.semibold)) with its provenance line beneath (.caption2/.tertiary)
5. ANSWER LINE — .subheadline.weight(.semibold). One sentence stating the conclusion, same slot, same weight, same position in both directions and for every message kind (F041)
6. FIGURES LINE — .caption.monospacedDigit()/.secondary, " · "-joined (F042)

SCROLLING BODY:
7. LOCAL PROVENANCE 2 — .caption2/.tertiary, outgoing only when at least one SNR-coloured leg is drawn: "Signal figures here are what your radio measured receiving the echo — not how well the repeater heard you." (F086)
8. LEGEND LINE — .caption2/.tertiary, map layout only, while focus == .all (§8)
9. LOCAL CAVEAT — .caption2 + mappin.slash, only when something named is not plotted; reuse packetScope.tailUnknownOne/tailUnknown verbatim: "+1 hop not on the map" / "+2 hops not on the map" (F047)
10. PATH CONTROLS — incoming with a non-empty path only: the raw pathString ("A3 → 7F → 42", caption monospace, middle-truncated) and Reply with Route
11. LOCAL ROWS — JourneyEvidenceRow per echo (outgoing) or per hop (incoming), or the section's checking / empty / unreadable state line
12. LOCAL ACTION ROW — outgoing channel with no echoes: the cost line "Sending again starts a new packet and clears this record." then Send Again
13. SECTION B HEADER — "What the observer network saw" (.caption.weight(.semibold)) + "Reported over the internet" (.caption2/.tertiary); trailing, once loaded, the sort menu and the Show/Hide-on-map toggle
14. SECTION B BODY — one of the nine states in §6
15. COVERAGE FOOTER — packetScope.coverageFooter unchanged, always at the bottom of Section B

Every screen now names its vantage in a slot that cannot scroll away and cannot be toggled off. That is the whole of F002 — today the only vantage statement is coverageFooter at the tail of a list the observers toggle deletes wholesale (PacketScopeDetailView.swift:355, 505-510).

## 5. Section A — the local layer, exact strings per direction and state

ANSWER LINE (panel item 5), exactly one of:

OUTGOING CHANNEL
- R ≥ 2 repeaters: "3 repeaters echoed it back to you"
- R == 1: "1 repeater echoed it back to you"
- heardRepeats > 0, rows still loading: "Checking your radio's records…" + spinner
- heardRepeats > 0, rows empty: "Couldn't read this message's echo records." (F017 — the counter/rows contradiction becomes an admission instead of "No repeats yet" printed above "Heard: 3 repeats")
- 0 echoes, inside the listening window: "Listening for repeater echoes…" + a visible listening indicator
- 0 echoes, settled: "No repeater has echoed it back to you", with the footer, normal weight, directly beneath: "A repeater can relay your message onward without you hearing the echo, so this is not proof it went nowhere." (F019, F098)
- 0 echoes, repeat watching detached: "Repeat watching is off for this radio, so no echo would be recorded even if one arrived." (F064 — the state is named rather than the services decoupled. Verified reachable and live: RepeaterSignalModel is @Observable and isAttached is a tracked stored property, so reading appState.repeaterSignals.isAttached from a body invalidates correctly.)

OUTGOING DM (reachable only through the screen's exhaustive switch; the row is an explainer): "Direct messages leave no repeater trail"

INCOMING
- R ≥ 2: "It reached you through 3 repeaters"
- R == 1: "It reached you through 1 repeater"
- flood, no recorded path: "Flood-routed — your radio didn't record which repeaters carried it"
- direct-routed: "It came by a set route — the packet doesn't record which repeaters carried it"

R is derived from the ROWS THE SCREEN ACTUALLY HAS — distinct repeaterHash values for outgoing, distinct hop hexes for incoming — never from message.heardRepeats or message.hopCount. That is what makes the screen incapable of contradicting its own list (F017), and it is why the row subtitle uses the same derivation, so the number cannot change between the tap and the arrival.

FIGURES LINE (panel item 6), " · "-joined:

OUTGOING: `3 echoes · best 6.2 dB · farthest echo ≥ 8.4 km away · still listening`
- echoes fragment (reused by the row and by Copy)
- "best %@" — reuse packetScope.best
- "farthest echo %@ away" — straight-line, ≥-wrapped via the existing packetScope.lowerBound whenever any echoing repeater could not be placed (F042, F047)
- liveness tail: "still listening" while the event subscription is live and the message is young; absent otherwise

INCOMING: `3 hops · ≥ 2.3 mi along the route · last hop in 8.5 dB · measured from where you are now`
- hop fragment — reuse packetScope.hopOne / hopCount / direct
- "%@ along the route" — the summed great-circle length of the drawn polyline, ≥-prefixed whenever any hop is unplotted. Today that honest qualifier is computed thirty lines away (MessagePathDetailView.swift:211-217) and given ONLY to the wire string while the on-screen banner prints a confident figure (F042, F015)
- "last hop in %@" — message.snr, finally attributed to the leg it measures (F092)
- "measured from where you are now" — appended when userFixCoordinate is nil (F062)

LOCAL ROWS: JourneyEvidenceRow (§7), one per echo or per hop. A multi-hop echo renders its full hopHashes chain as numbered pills — the same pill component the observer route rows use — instead of naming only the tail, so the intermediate repeaters that actually relayed the message stop being invisible (F090).

LOCAL STATE VOCABULARY renders INSIDE the panel in all three states (checking / nothing / couldn't read), so it survives the map layout. Where a load genuinely cannot run, the section shows a terminal line and a Retry, never an indefinite ProgressView (F075).

GEOMETRY IS PRESERVED VERBATIM (constraint 7): MessagePathMapView.heardRepeatNodes stays the source of the echo loops, arc fan and all — origin → resolved hops in path order → back to origin, reception legs merged per tail and ranked newest-first, coincident legs fanned into shallow arcs with the badge riding each apex. The only change to it is the pin-id fix in §8.

## 6. Section B — the observer control and its nine states

THE CONTROL (state c) is the only thing in the app that starts a network request. It is a bordered, accent-tinted, full-width button, ≥44 pt, visually unlike every row above it, so the one entry that spends a privacy opt-in never again looks like the rows that read local storage (F022):

```
[globe.badge.chevron.down]  Look Up on the Observer Network
                            Sends this packet's identifier — never its text —
                            to scope.digitaino.com over your internet connection.
```

The host is the host component of the LIVE packetScopeBaseURL, not a literal. The server field is device-local and per-instance by design (AppStorageKey.swift:41: users on another mesh point at their own CoreScope), so a disclosure that omits the host is not true of every install — and naming it makes Copy's provenance survive being pasted into another app.

THE NINE STATES, in evaluation order:

(a) LOOKUPS OFF (packetScopeEnabled == false). No fetching button. Body:
  "Observer-network lookups are off."
  "Turn them on and the app can ask an internet observer network which stations heard this packet. It sends the packet's identifier, never its text."
  "Settings ▸ Chats ▸ Observer Network"  ← an inert path line, NOT a deep link and NOT an in-screen toggle.
RATIONALE: Settings stays the single consent surface. A navigation out of a cover presented from inside a sheet is exactly the class of interaction the two deferral mechanisms exist to protect, and writing the global opt-in from a message screen creates a second surface that can enable outbound network access for a feature whose whole design comment (PacketScopeSettingsSection.swift:4-10) is built around one gated consent point. (F063)

(b) NO WIRE IDENTITY (packetContentHash == nil). No button. One line plus a reason clause, chosen by kind — this is the distinction the app currently renders as blank space:
  outgoing channel: "Nothing to look up yet. The app learns this packet's identifier from the first repeater echo it hears." (F098's coupling stated plainly instead of pretended away)
  outgoing DM: "Direct messages can't be looked up: the app never learns a DM's packet identifier from your own radio." (F025)
  incoming: "This message arrived without a readable packet identifier, so there is nothing to look up." (also covers the deliberately fail-closed sender-prefix-fallback DM)

(c) READY. The button above. Nothing requested.

(d) CHECKING, nothing back yet. The button becomes an inert row: spinner + "Checking the observer network…"

(e) LOADED, N ≥ 1. Headline "9 internet stations reported hearing it" (singular "1 internet station reported hearing it") — its own noun, its own verb, no shared prefix with the local answer (F001). Then the existing summary line verbatim except "farthest %@" → "farthest station %@ away" (F042), then the breadcrumb, then the observer rows and ladder.

(f) LOADED, ZERO, loop RUNNING. "No station has reported it yet. Still checking…" with a visible spinner. The absolute negative is UNREACHABLE while loopOutcome == .running. This is the highest-frequency wrong conclusion in the whole review and it fires on exactly the message a rider opens seconds after sending (F087).

(g) LOADED, ZERO, loop SETTLED or WINDOW CLOSED. "No station on this observer network reported hearing it." then, as a second sentence in NORMAL weight, not small print: "That is not the same as it not being delivered — observers only cover their own region." + [Check again] (F003).
Wording note: deliberately "not the same as it not being delivered", not "not a delivery failure" — the stronger phrasing over-claims in the reassuring direction and the data does not support it.

(h) STOPPED ON FAILURES, with rows on screen. "Couldn't reach the observer network." + "Last checked 14:07." + [Check again]. The liveness word must NOT be "settled" — a failure exit prints nothing rather than the app's word for "this is the final answer" (F061). This state renders in the MAP layout, which today has no failure surface at all (F045).

(i) FAILED BEFORE ANY DATA. Same line, no rows, with the underlying error text one line below. PacketScopeServiceError.invalidResponse stops borrowing "Invalid response from elevation API".

MECHANISM (F061). Replace the single isLive boolean driving the summary line's tail with `enum LoopOutcome { case running, settled, windowClosed, failed }`, set by liveRefreshLoop's exit condition, and record the failure in refresh()'s catch even when receptions != nil. Summary tails: .running → "still arriving"; .settled/.windowClosed → "settled in 1.4 s"/"settled"; .failed → nothing, and the state line above carries "Couldn't reach the observer network." One unit test per exit path.

MAP-VISIBILITY TOGGLE in the section header once loaded: "Show on map" / "Hide on map". Hiding removes the observer pins, links and legs and leaves the local evidence alone on the map — the direct affordance for "what did MY radio see, without the noise", which is half of comparing in place (F036). Hiding first clears any focus to .all, so a focused route can never be hidden out from under its own focus bar.

CHIP: packetScope.new "New" → "Just reported" — it times the app's poll, not the mesh, and sitting beside a real +1.3 s propagation offset it currently reads as a mesh event (F100).

DELETED: packetScope.retriedFooter. The retry line moved to the identity block, and with the hash cleared on resend (§Phase 0) both layers always describe the same attempt, so the misattribution question no longer arises (F088).

EVERYTHING ELSE ABOUT THE FETCH SURVIVES UNTOUCHED: 6 s poll inside the 180 s window, three quiet polls or three failures to stop, 6 s × 2^failures backoff, scene-phase pause, roster fetch, arrival ramps, frozen order, the ‹ › steppers, the breadcrumb, the four sorts with Farthest gated on real distances, the 350 ms settle re-fit against a frozen cameraFocus, the VoiceOver announcements. The ONLY change is the trigger: liveRefreshLoop no longer runs from .task on appear; it runs from startLookup(), called by the button. A message older than the live window still gets exactly one fetch and then reads "settled".

## 7. The shared evidence row

One component, JourneyEvidenceRow, used by echo rows, incoming hop rows and observer rows, so a repeater looks the same everywhere it is named (F012, F016, F043, F047, F052, F079):

```
[ 31 ]  Relay-1  [?]   📍            ▂▄▆  Echo in 6.2 dB
        Echo back to you · 2 hops             -85 dBm    +0.8 s
```

ID COLUMN — monospaced uppercase hex at that source's own width ("31" / "31A7" / "31A79C"). For an observer route hop with no local match, the server's resolved-key first 4 hex goes HERE, never in the name column.

NAME COLUMN — the resolved name, then, for a .fallback match, the SAME tappable `?` FallbackMatchIndicatorView used on the path and repeat rows today, with the same "Possible Match / Multiple nodes share this prefix" popover. The bare `~Name` prefix used only inside observer hop pills is retired. Unresolved is "<unknown repeater>" everywhere (F016).

DRAWABILITY MARK — `mappin.and.ellipse` / `mappin.slash` (map layout only, @ScaledMetric width), ported from the observer route rows onto the LOCAL rows, so a hop named but not pinned says so wherever it is named. Naming is permissive and pinning is not — that asymmetry is deliberate and documented, and until now nothing told the rider (F047).

ROLE LINE — the sentence that says whose journey this hop belongs to, which nothing in the app says today (F012):
- echo row: "Echo back to you · 2 hops"
- incoming hop row: "Hop 2 of 3 to you"
- observer route hop pill (and its a11y label): "Hop 2 of 3 to KTX-Hilltop"
This is why the role line lives on the ROW and not only on the section header: the header works while you are reading the header and fails the moment you are scanning rows, in Copy output, and in VoiceOver.

SIGNAL COLUMN — one SignalFigure, one decimal, spelled localized unit, the measuring subject always stated:
- echo row: "Echo in 6.2 dB", second line "-85 dBm"
- incoming receiver row and the final leg's badge: "Last hop in 8.5 dB"
- observer row: "They heard 12.2 dB"; ladder header "Their best RSSI -96 dBm"

TIME COLUMN — "+0.8 s" relative to the first piece of evidence IN THAT SECTION (reuse packetScope.heardOffset), on local rows as well as observer rows. Each section header states what its list is ordered by (F052).

DYNAMIC TYPE — the row stacks the signal column UNDER the identity at accessibility sizes, via a dynamicTypeSize branch built in from the start. This is the treatment the retry card already has and the current repeat row lacks (F079).

UPSTREAM'S RepeatRowView, RepeatDetailsContent, MessagePathContent and PathHopRowView are left BYTE-IDENTICAL and simply stop being called from this flow — the cheapest possible answer to constraint 3. After Phase 3 both of RepeatDetailsContent's call sites are gone, so those files become retained-but-unrendered. That duplication (~250 lines of name resolution, fallback popover and hop labels) is the deliberate price of zero merge cost, and it MUST be recorded in docs/FORK_FEATURE_INVENTORY.md in the same PR, naming both duplicated files, or the next upstream merge silently misses a fix to either.

## 8. The map — one alphabet, two layers, one origin, one interaction model

ONE MessagePathMapCanvas. locatedNodes = local pins ∪ observer pins, but held in TWO SEPARATE ARRAYS internally (see the Reply-with-Route invariant in §9). linesOverride = local lines + (focused observer legs). overlays = the observer link substrate. cameraCoordinates = the union of the VISIBLE layers' pins.

PIN VOCABULARY, fixed across every state and both directions (F008, F038):
| pin | means | where |
|---|---|---|
| `.pointB` (green "B") | ALWAYS your radio, and nothing else ever | every message map, both directions |
| `.pointA` (blue "A") | ALWAYS the sender of an incoming message | incoming only; an outgoing message has no A |
| `.repeaterHop` | a repeater on a route drawn by either layer | both layers; numbered only inside a focus |
| `.observer` — NEW | a third-party listening station: systemPurple teardrop, ear-family glyph | observer layer only |

This retires both collisions: green "B" meaning "you" on one map and "a stranger's station" on the next, and blue "A" meaning "the sender" on one and "you" on the other. It also fixes F038 outright — for an incoming message the phone is on the map, because the phone is a real, recorded end of the local route. NOTE the consequential change: PacketScopeCoverageMap.swift:195 today gives an OUTGOING message's origin `.pointA`; under this rule it becomes `.pointB`, and PacketScopeCoverageMap.swift:315's `.pointB` for observers becomes `.observer`.

ONE new PinStyle, not two — .pointB is already the deliberate "you" mark on the repeats and path maps (PACKET_SCOPE.md:380-381 records that choice), so redefining it consistently costs nothing and halves the new upstream surface.

SPRITE PLUMBING, verified: MapPoint.swift +1 case (already forked, +16). MC1MapView+Layers.swift +1 case — REQUIRED, its `spriteName(for:)` switch (:501-529) is exhaustive over PinStyle with NO default, so the plan does not compile without it (already forked, +110). PinSpriteRenderer.swift +1 SpriteSpec — this file is BYTE-IDENTICAL to upstream today and is therefore the ONE new conflict site this feature creates. MapSnapshotRenderer.swift needs NO hunk: its switch has `default: "pin-dropped"` (:123-129) and it only ever renders LocationPathMapBuilder styles.

ONE ORIGIN, COMPUTED ONCE. PacketScopeCoverageBuilder.build loses its internal origin block (PacketScopeCoverageMap.swift:178-186) and takes `origin: (coordinate: CLLocationCoordinate2D, name: String?)?` as a parameter. MessageJourneyView computes it once and hands it to BOTH builders: outgoing → message.userFixCoordinate ?? live best location, named localRadioLabel, drawn `.pointB`; incoming → the phone is the receiver end of the local layer (`.pointB`) and MessagePathViewModel.locatedSender is `.pointA` when it resolves. Two origin rules on one map is a latent inconsistency exactly where the F038 fix comes from. Update PacketScopeCoverageBuilderTests for the parameter.

PIN IDENTITY — A PRECONDITION, NOT POLISH. Verified: MessagePathMapView mints `id: UUID()` at :238, :260, :368 and :418 (and for the SNR badges at :526, :535) while PacketScopeCoverageMap.stableID (:625) is content-derived; MapPoint.== includes id and MC1MapView+Layers.swift:92 rebuilds the whole fixed source on `fixedPoints != lastAppliedFixedPoints`. On a fused map rebuilt by a 6 s poll, every local pin re-sources every poll: flicker, dropped name pills, and a camera that fights the 350 ms settle re-fit. Switch both builders (and the badge ids) to content-derived ids on the stableID pattern BEFORE the layers share a canvas. Blast radius beyond this screen: those are fork-authored regions of MessagePathMapView (+976, the fork's most diverged file) that also feed SharedRouteMapSheet and TracePath — verify camera settling and label stability on those callers too.

LINE VOCABULARY:
- LOCAL lines at full weight: the incoming path polyline neutral `.messagePath`; the outgoing echo loops with the reception leg `.forSNR` plus its "1.2 km · 6.2 dB" badge, exactly as today.
- OBSERVER links stay in the weighted MapOverlay layer, which already renders BENEATH pins and lines at 0.3–0.9 opacity, so the local route reads on top of the observer web with no new plumbing and no MapLine.opacity dimming (which the fork removed for good reasons).
- ONE RULE CHANGE, and it is what makes two SNR colour languages coexist: OBSERVER SNR LEGS ARE DRAWN ONLY INSIDE AN OBSERVER OR ROUTE FOCUS. In the default state the observer layer contributes pins and the link substrate only. Nothing is lost — per-observer signal still reads in the row's bars and dB and in "best 12.2 dB" — but the default map carries exactly ONE SNR-coloured line class, and it is always the local one. ~6 lines in the new model (stop passing everything(in:)'s legs through when focus == .all); PacketScopeCoverageBuilder itself is untouched. This is a real change to a shipped beta behaviour — see open question 3.

LEGEND LINE (.caption2/.tertiary), in the scrolling panel while focus == .all, map layout only, and reused as the PREFIX of the map's accessibilitySummary so a VoiceOver user gets the same key (F051):
- outgoing: "Green B is your radio. Line colour is how strongly your radio heard that echo — not how well the repeater heard you."
- incoming: "Blue A is the sender, green B is your radio. The line is the route this copy took, not a signal measurement."
- appended while the observer layer is showing: "Purple pins are observer stations; the blue web is the links their copies crossed."
The outgoing sentence is F086's actual fix rather than a hedge: SignalMapperCaptureEngine.swift:15-19 states the direction explicitly (the echo's SNR is the repeater's rxSnr) and nothing has ever carried that to the screen, so a rider picking a transmit spot from those colours is reading the downlink.

CAMERA: fits the union of the visible layers; entering a focus fits the focus; an observer poll never re-fits the local layer. The shared map control's label becomes a host-supplied parameter (defaulted, so existing callers are byte-identical) and this screen passes "Fit to everything shown" — MessagePathMapView.swift:772 hardcodes chats.path.centerOnPath today, and on this map there is frequently no path at all (F054).

LABEL PRIORITY under `.collide`: you 0, sender 1, local repeaters 100, observers 200 + rank, observer-only repeaters 1000. The local evidence wins every collision and the you-pin must never drop. Whether basemap labels can suppress the app's pills remains the outstanding on-device acceptance check (PACKET_SCOPE.md:281-290), now over a busier map — run it over a dense area before Phase 4 closes.

INTERACTION, one model (F049):
- A ROW focuses its own evidence: an echo row focuses that loop, a hop row that hop's leg, an observer row that observer, a route row that route. Rows are the primary and fully accessible entry to everything.
- An OBSERVER PIN toggles its observer's focus (unchanged).
- A pin with no row (a repeater) and any unrecognised pin are INERT. Today they fall through to popFocus(), so a tap that looks like it did nothing has actually stepped route → observer → all.
- BARE MAP BACKGROUND DOES NOTHING. Today `onMapTap: { popFocus() }` makes empty map a control that silently destroys a selection made one-handed while framing a pan. Deleted.
- FOCUS IS A FILTER, NOT A DIMMER, and it filters the OBSERVER layer only — local pins keep emphasis 1 and local lines stay drawn under every focus. That is the point of layering: you focus one observer's route in order to see it against your own.

FOCUS TYPE — wrap, do not rewrite:
```swift
enum JourneyFocus: Equatable {
  case all
  case local(LocalFocus)            // .echo(MessageRepeatDTO.ID) | .hop(Int)
  case observers(PacketScopeFocus)  // .observer(id) | .route(observerID:routeID:)
}
```
PacketScopeFocus and PacketScopeFocusLogic (stepping, cameraFocusID, copySummary) and their tests stay UNTOUCHED. The local half needs only a two-case geometry filter. The breadcrumb stays `All › Observer › via …` inside Section B; Section A needs none, being at most two levels deep.

## 9. Reply with Route, Send Again, and Copy

REPLY WITH ROUTE — unchanged in behaviour, position and payload (constraint 6).
- It lives in Section A's path-controls row for an incoming message with a non-empty path.
- Wire string byte-identical: `RX via 80,8F,0C. 3 hops 2.3 mi`, deliberately unlocalized because other clients parse it back into a Shared Route card.
- Deferral verbatim: the button stores pendingRouteInfo and sets showJourney = false; the cover's onDismiss — still attached to ActionsDetailsSection's own VStack — dispatches .replyWithRoute(routeInfo) through onSelectAction → performAction → onAction(action) then dismiss(). NO new MessageAction case, NO new deferral mechanism, NO change to which view is the presenting context.

Two additions:
- ACKNOWLEDGMENT (F083): .sensoryFeedback(.success) plus the label flipping to "Added to Reply" for ~0.4 s before the cover closes. A word is readable across two dismissal animations; a checkmark flash is not.
- HONEST DISTANCE (F062): routeDistanceText WITHHOLDS the distance clause entirely when userFixCoordinate is nil, because that figure was measured from where the rider is standing now, not from where the message landed. The "≥" rule is unchanged and is now ALSO applied to the on-screen figure.

INVARIANT, and it must be enforced structurally rather than by convention: routeDistanceText and routeInfoText are handed the LOCAL polyline array explicitly. Keep the two node sets in SEPARATE arrays. If observer pins ever enter the array those functions read, the wire figure silently changes and cross-client Shared Route cards start disagreeing.

SEND AGAIN — appears in Section A only for an outgoing channel message with no echoes. Directly above it, the cost is stated: "Sending again starts a new packet and clears this record." (F018, F059). Dispatched through the EXISTING .sendAgain case and the SAME cover-onDismiss hand-off as Reply with Route — store a pending action, close the cover, dispatch from onDismiss. NEVER a dismissalDelay sleep: the two deferral mechanisms are not interchangeable, and a plain sleep does not protect the stranded-parent case while the child cover is still presented. The power-escalation button stays on the bubble card, because it changes a persistent radio setting that outlives this message.

COPY — three affordances collapse to one (F050). A single doc.on.doc in the trailing toolbar next to Done, disabled until something is on screen, producing one readable, provenance-tagged account of what is currently shown, in panel order:

```
Sent to #general · 2 Sep 2026, 14:07
Sent 2 times — each attempt is a separate packet.

What your radio saw (measured here, no internet):
2 repeaters echoed it back to you — 3 echoes, best 6.2 dB, farthest echo ≥ 8.4 km away
  31  Relay-1   echo in 6.2 dB / -85 dBm    1 hop    +0.0 s
  7F  Hilltop   echo in 2.1 dB / -102 dBm   2 hops   +4.1 s

What the observer network saw (scope.digitaino.com, over the internet):
9 internet stations reported hearing it — best 12.2 dB, shortest 2 hops, farthest station ≥ 23 mi away
  KTX-Hilltop  they heard 12.2 dB   2 hops via Relay-1 › Hilltop   +1.3 s
  …

Coverage reflects only the configured observer network. A message can be delivered without being observed.
```

RULES, all load-bearing:
- The observer half is STILL built without the MessageDTO in scope, so the 16-hex packet identifier can never reach the clipboard. That is today's deliberate constraint (PacketScopeFocus.swift:173-203) and it is kept.
- The local half is added the SAME way: the builder takes rows and resolved names, not the message.
- The message TEXT is never included.
- The host name IS included, so provenance survives being pasted somewhere else.
- For an incoming message the hex path appears as a `Path: A3,7F,42` line — which is why the separate icon-only "Copy Path" control disappears. The raw pathString stays VISIBLE in the path-controls row; only the duplicate copy affordance goes.

## 10. The state vocabulary and the three kinds of absence

THREE WORDS, one grammar, used identically by both sections and — crucially — rendered INSIDE the panel, so they survive the map layout. Today the observer screen's error, empty and loading rows live only in the List branch, which is why a failing poll over a drawn map is invisible (F045, F061).

| state | Section A | Section B |
|---|---|---|
| CHECKING | "Checking your radio's records…" + spinner, with an a11y label and a completion announcement when the rows land | "Checking the observer network…" + spinner. A manual Check again shows in that control; a silent poll never flickers it (today's behaviour, kept) |
| NOTHING | see the absence taxonomy below | states (f) and (g) — split by whether the loop is still running |
| COULDN'T CHECK | "Couldn't read this message's echo records." + Retry | "Couldn't reach the observer network." + "Last checked 14:07." + Check again |

THE ABSENCE TAXONOMY — a normative wording rule, not just a set of strings. Three kinds of absence are worded differently ON PURPOSE, and the difference IS the information, because the rider's real question in an empty state is "is this broken, is it too early, or is this simply not a thing my radio records" — three different next actions.

1. NOT YET — the evidence could still arrive. Present tense, the word "yet", and a visible checking indicator while a loop or subscription is live.
   "Listening for repeater echoes…" · "No repeater has echoed it back to you" (+ the it-is-not-proof footer) · "No station has reported it yet. Still checking…" · "Nothing to look up yet. The app learns this packet's identifier from the first repeater echo it hears."
2. NEVER FOR THIS KIND — the app does not collect it. Contains "never" or "can't", plus a reason clause.
   "Direct messages leave no repeater trail." · "Direct messages can't be looked up: the app never learns a DM's packet identifier from your own radio." · "Room messages travel through the room server, so there is no repeater trail to show."
3. NOT ON THIS DEVICE — it happened, we cannot show it.
   "Flood-routed — your radio didn't record which repeaters carried it" · "It came by a set route — the packet doesn't record which repeaters carried it" · "Couldn't read this message's echo records." · "This message arrived without a readable packet identifier, so there is nothing to look up."

This rule is what keeps F019, F025, F063, F066 and F098 fixed a year from now, instead of collapsing back into one generic empty state the eleventh time someone adds a string.

HONESTY CEILING, restated as a check on every sentence in this spec: an echo is not delivery (channel broadcasts have no ACK at all); observer silence is not non-delivery (observers cover only their own region); a header path is a claim about ONE copy and says nothing about anyone else's; and a repeat count is a count of echoes this radio demodulated, not of relays that happened.

## 11. Accessibility

- The MAP carries an accessibilitySummary in EVERY state on this screen, built from the legend line plus the answer line plus the figures line, so a VoiceOver user reaches the same conclusion a sighted one does. Today only the observer screen supplies one, so the two local maps read as nothing at all (F051).
- Every focus change announces, branched on drawability, so "Showing the route to X" is never said of a map that did not change. Today's behaviour, extended to the new local focuses.
- Loading rows are labelled and a completion announcement posts when the rows land, so an expanded section can never be silently empty (F080). Empty and failed have distinct spoken text.
- JourneyEvidenceRow stacks the signal column under the identity at accessibility Dynamic Type instead of colliding two fixed columns (F079).
- The EXPLAINER row is `.accessibilityElement(children:.combine)` with `.accessibilityAddTraits(.isStaticText)` and is NEVER `.disabled()`. A disabled row inside a column of tappable rows announces "dimmed" and reads as broken; a static row reads as an answer. VERIFY THIS ON DEVICE with VoiceOver for the outgoing-DM case — it is the state a rider hits most often on DMs and it is the one place this structure diverges from the alternative (making the row tappable onto a screen that is mostly a paragraph explaining absence). Both risks are real; settle it with a device test, not in review.
- The observer lookup button carries its cost line as its accessibility hint, so the privacy statement is not visual-only.
- Section headers and the observer row's ladder expose Expanded/Collapsed values.
- The `?` possible-match popover is the ONLY popover host on the screen. Precedent exists (HeardRepeatsMapView already hosts FallbackMatchIndicatorView via RepeatRowView), so this is not novel — but the fork's iOS 26 rule applies in full and MUST be written into the file's doc comment: no automatic tips and no TCC prompts are ever presented on a popover host, and the popover is never dismissed programmatically during teardown, because every popover dismisses via zoom morph and traps if dismissed mid-teardown.
- The bubble's own VoiceOver default activate action (which opens this sheet) and its named custom actions are untouched.

## 12. Privacy audit — the acceptance checklist for the observer phase

Constraint 1 is currently defended by prose and by code review. This list is the checklist a reviewer runs against the Phase 4 diff, item by item, and §15 turns two of its lines into tests.

Every path that could reach PacketScopeService:

1. RENDERING A BUBBLE → no fetch, no chip, no persisted summary. The always-on "heard by N" coverage chip stays deferred, as PACKET_SCOPE.md:354-358 records.
2. RENDERING THE SHEET → no fetch. MessageJourneyEntry's subtitle is computed from MessageRepeatDTO rows + message.pathNodes + message.sendCount + message.packetContentHash + the injected packetScopeEnabled flag ONLY. Asserted by test. The sheet's .task still fetches repeats and contacts from the LOCAL store, as today.
3. OPENING THE JOURNEY SCREEN → NO FETCH. This is strictly STRONGER than what ships: today PacketScopeDetailView carries two `.task` modifiers that both fire on cover appear — `.task { await liveRefreshLoop() }` (:202, the observations POST) and `.task { await loadObservers() }` (:203, the roster GET). BOTH move behind the button. A reviewer who only moves the POST leaves the hole open.
4. TAPPING "Look Up on the Observer Network" → the ONLY fetch trigger. One POST of `{"hashes":[<16 hex>]}` plus the unparameterised GET /api/observers, both gated INSIDE the actor on AppStorageKey.packetScopeEnabled (PacketScopeService.swift:309, :353) and both refused when it is off. Enforcement stays in the service, not the views, so no future call site can bypass it.
5. "Check again" / the live poll after step 4 → continuation of a lookup the user started.
6. THE OPT-IN IS WRITTEN ONLY IN SETTINGS. No screen in this feature writes AppStorageKey.packetScopeEnabled. State (a) names the Settings path in words and offers no control.

Unchanged and not to be touched: the opt-in default (false), the device-local packetScopeBaseURL and its deliberate exclusion from BackupUserDefaults, HTTPS-only endpoint validation with query/fragment stripping, PacketScopeRedirectGuard's refusal of any host-changing or scheme-downgrading 307/308, the ephemeral 15 s URLSession, the 16-char ASCII lowercase hash validation, and the rule that a request whose every hash was malformed throws .noValidHashes rather than returning empty — so "we never asked" can never render as "No station reported it".

WHAT LEAVES THE PHONE: the 16-hex content hash. WHAT NEVER DOES: message text, sender/recipient, channel, the message's own path, the SNR/RSSI this phone measured, and any location. Copy preserves this by construction (§9).

ONE NEW RISK CREATED BY THE REFACTOR: the fetch/poll/roster state moves out of a View's @State into an @Observable model. A `load-on-init` in that model would silently break the whole contract while looking like ordinary code. The model must own no work until startLookup() is called, and that must be a test, not a comment.

## 13. Presentation-mechanics audit — constraint 2

This is the section that keeps the redesign from breaking the sheet. Every item was verified against the shipping code.

COVERS — the improvement over every submitted design. The three fullScreenCovers collapse to ONE, and it STAYS ATTACHED TO ActionsDetailsSection's OWN VStack, exactly where the three live today (ActionsDetailsSection.swift:69-107). The journey ROW moves up into MessageActionsSheet's ScrollView VStack; the COVER does not move at all.
- MessageActionsSheet gains `@State private var showJourney = false`.
- `MessageJourneyEntry(..., onOpen: { showJourney = true })` is the first child of the ScrollView VStack.
- `ActionsDetailsSection(..., showJourney: $showJourney, ...)` keeps ONE `.fullScreenCover(isPresented: $showJourney, onDismiss: { … pendingRouteInfo dispatch … })` on its own VStack, byte-for-byte the presenting context and onDismiss deferral that ship today, now presenting MessageJourneyView instead of MessagePathDetailView.
- showPathDetail / showRepeatsMap / showPacketScope and two of the three covers are deleted.
WHY THIS MATTERS: moving the cover onto the new child view changes which view is the presenting context, which on iPad decides whether the cover covers the sheet or the whole window — and the fork has documented history of exactly this class of bug (BETA_CHANGES.md:481, "Fixed blank sheet when sharing heard repeats by using fullScreenCover instead of nested sheet"). ActionsDetailsSection is always rendered (it always emits the Details caption and info rows), so the cover host is never conditionally removed. WRITE THE REASON INTO THE FILE'S DOC COMMENT: "moving the cover onto the subview you just created" is the single most natural refactor a future contributor will attempt.

DEFERRAL MECHANISM 1 (child onDismiss) — used verbatim by Reply with Route and, newly, by Send Again. Unchanged.
DEFERRAL MECHANISM 2 (host-side MessageActionsPresentation.dismissalDelay) — untouched. The journey screen adds no MessageAction that presents anything.
The two are NOT interchangeable: a plain sleep does not protect the stranded-parent case while a child cover is up, and an onDismiss hand-off does not protect the iPad sheet-replacement case.

DISPATCH ORDER — performAction still does `onAction(action)` THEN `dismiss()` (MessageActionsSheet.swift:19-25). Unchanged, and load-bearing: handleReply mutates composingText immediately so the text is there when the sheet slides away, and defers only the focus request.

MessageAction gains NO case. The exhaustive switch in ChatConversationView.dispatch is untouched.

INLINE EXPANSION — gone. The disclosure, the `.id("expandedContent")` scroll target and the isDetailExpanded binding all disappear. KEEP the binding in ActionsDetailsSection's signature (never written) OR remove both sides in one hunk; the former keeps MessageActionsSheet's ScrollViewReader/onChange hunk-free, the latter is cleaner. Prefer removing both — the sheet file is already fork-diverged (+17) and dead plumbing rots. Either way the F028 defect stops being reachable, with no change to upstream's detent rules.

DETENTS — `[.medium,.large]` on compact/non-accessibility, `[.large]` otherwise, with `.presentationContentInteraction(.scrolls)` and no selection binding. UNCHANGED. Removing the disclosure removes the tallest thing the sheet could contain, so at rest the block is roughly break-even; verify on a small phone with the emoji row present at both normal and accessibility Dynamic Type.

IPAD — ChatConversationView.swift:313's `.environment(\.horizontalSizeClass, horizontalSizeClass)` re-injection is untouched. Any refactor that recreates the sheet host must carry it, or the chat sheet regresses to the room sheet's behaviour.

CONTEXT MENU — not used, not proposed. The long-press stays SwiftUI's onLongPressGesture with the Mac suppressed-UIContextMenuInteraction path untouched.

AVAILABILITY REACTIVITY — MessageActionAvailability is still a plain computed property reading UserDefaults synchronously; the injectable packetScopeEnabled default argument stays as the test seam. The journey row does not need live availability, because it is unconditional; its liveness comes from the HeardRepeatsService subscription, not from availability.

## 14. Settings, errors, strings, docs

SETTINGS (PacketScopeSettingsSection.swift, fork-only, so no upstream conflict — only the eleven-locale sweep):
- Section header "Packet Scope" → "Observer Network"
- Toggle "Look Up Message Coverage" → "Allow Observer Lookups"; icon `dot.radiowaves.up.forward` → `globe`
- Footer rewritten to name the section as it now appears, keeping the existing privacy sentence verbatim: "Adds an Observer Network section to a message's journey screen, showing which internet-connected stations heard its packet and at what signal level. Looking a message up sends that packet's identifier (never its content) to the server below over your phone's internet connection. Coverage depends on the observer network the server watches."
- The Server field, the packetScopeEnabled / packetScopeBaseURL keys, their defaults and their backup rules are UNTOUCHED.

ERRORS:
- packetScope.error.disabled → "Observer-network lookups are turned off in Settings."
- packetScope.error.invalidBaseUrl → "The observer network's server address is not a valid HTTPS URL."
- NEW fork key for PacketScopeServiceError.invalidResponse → "The observer network sent a response the app couldn't read." It currently borrows common.error.invalidResponse = "Invalid response from elevation API", which on the list layout is the whole screen.

STRINGS BUDGET (constraint 4). About 40 new keys, all in Chats.strings except the ~8 reworded packetScope.* in Localizable.strings and the ~4 renamed in Settings.strings. REUSE where the meaning is exact and add nothing: packetScope.direct / hopOne / hopCount for every hop figure; packetScope.best; packetScope.lowerBound for every "≥"; packetScope.heardOffset "+%@ s" for every propagation offset including the new local ones; packetScope.tailUnknownOne / tailUnknown for the local drawability caveat; remoteNodes.status.snrBadgeUnit for every "dB"; chats.repeats.unknownRepeater; chats.path.hop.possibleMatch* for the "?" indicator; chats.path.receiver.you; common.done; packetScope.coverageFooter.

NO stringsdict — follow the established singular-key precedent (hopOne/routeOne/tailUnknownOne) for every new count. Build the two-variable outgoing subtitle from reusable fragments rather than four plural keys: "1 echo"/"%d echoes" + "from 1 repeater"/"from %d repeaters" joined by "%1$@ from %2$@", giving "3 echoes from 2 repeaters". The fragments are needed on the figures line and in Copy anyway.

RETIRED FROM THE UI but LEFT IN PLACE in all eleven locales (do not sweep — a partial deletion just adds to the existing orphan pile; en already has 5 keys de lacks and pt is 22 chats.* keys short): chats.message.action.viewPath, .repeatDetails, .networkView; chats.repeats.viewOnMap; chats.path.title; chats.path.copyButton|copyAccessibility|copyHint; chats.message.info.heardRepeats; chats.message.info.roundTrip; packetScope.title; packetScope.heardBy; packetScope.observerCount (already dead); packetScope.notObservedFooter; packetScope.retriedFooter.

SWEEP DISCIPLINE — load-bearing. One commit: en + all ten translations + the regenerated L10n.swift, with the key count stated in the commit body (the pattern from a5e76cb4 and 12a839a7). lint.yml verifies ONLY that L10n.swift is regenerated; there is NO locale parity check, so a partial rename fails silently into English fallbacks in eight languages. Before pushing, grep all eleven .lproj directories AND the prose for "Network View", "Packet Scope", "Look Up Message Coverage" and "Heard" — including Settings.strings:1918 and BETA_CHANGES.md, both of which name the row in prose. Run `xcodegen` after any branch switch before building: the SwiftGen pre-build script only exists in a regenerated project.

DOCS:
- docs/PACKET_SCOPE.md — add the merged-entry design, the observer sprite, the origin: parameter, the leg-suppression rule, and the new privacy trigger; move "observer sprite" out of Deferred.
- docs/Glossary.md — it has NO entry for repeater, echo, heard repeat, hop, observer, observer network or packet identifier. Fill the gap.
- docs/FORK_FEATURE_INVENTORY.md — add the Group 7 row that has never existed, covering the sheet's fork deltas AND naming the two duplicated row views so the next upstream merge knows to look.
- BETA_CHANGES.md — the user-facing entry, including the two behaviour changes worth naming: a resend now clears the observer lookup, and "settled" is no longer printed after failed polls.
- docs/User_Guide.md §Message Details — all three of its sentences are already false for this fork, and it is upstream-owned with a ZERO fork diff today. See open question 4.

## 15. Tests

MessageJourneyStateTests (NEW, fork-only, pure) — the state table of §3 as an executable table: one case per row, asserting the exact form (destination vs explainer), title and subtitle, including sendCount > 1, the listening window, the rows-empty-with-positive-counter case, repeat watching detached, and the three incoming route classes. Landing the honesty rules as tested pure functions BEFORE any view exists is what keeps them from drifting during the UI work.

PLUS TWO PRIVACY ASSERTIONS in the same file — this is what turns §12 from prose into CI:
1. The observer section's pre-tap body is a CONSTANT across every message state (it never varies with a cached count, a stored summary, or anything a fetch could have produced).
2. No branch of MessageJourneyState consults a service. Construct the state with only (MessageDTO, [MessageRepeatDTO]?, packetScopeEnabled: Bool, signalsAttached: Bool, now: Date) and assert the type has no service dependency; a later change that makes the row consult a cached count then fails the build rather than a review.

MessageJourneyObserverModelTests (NEW) — startLookup() performs no I/O until called; one case per LoopOutcome exit path (three consecutive failures → .failed; three unchanged polls → .settled; window expiry → .windowClosed) and the summary-line tail each produces. F061 exists precisely because a single isLive boolean cannot distinguish "settled" from "gave up".

JourneyFocusTests (NEW) — the local geometry filter's two cases; the observer half delegates to the untouched PacketScopeFocusLogic.

PacketScopeFocusTests — UNCHANGED, and green throughout Phase 1. This is the oracle for the riskiest refactor in the plan.
PacketScopeCoverageBuilderTests — updated for the `origin:` parameter; otherwise unchanged.
MessageActionAvailabilityTests — existing rules unchanged; extend only if new flags are added.

MANUAL / ON-DEVICE, each an exit gate for its phase:
- Phase 3: the owner's own case — an outgoing channel send with no echo, long-pressed two seconds later — now says something, in the row AND on the screen. Reply with Route still reaches the composer through both deferrals and its wire string is byte-identical. The cover covers the sheet, not the window, on iPad.
- Phase 3: VoiceOver on the outgoing-DM explainer row (§11).
- Phase 4: the privacy audit (§12) run against the diff, line by line.
- Phase 4: `.collide` label priority over a dense area with both layers on one map — the local evidence must win every collision and the you-pin must never drop.
- Phase 4: panel height on the smallest supported phone at accessibility Dynamic Type, with Section B open AND a route focus active. The fixed header now grows to identity + preview + retry + section header + answer + figures over a 132 pt list floor inside a 30 % budget. Verify the specified cuts fire in order: preview hidden first, retry line second.
- Phase 4: watch a real send from second zero to settled and read the empty-state wording sequence in order — Listening → echoes arrive; No station yet, still checking → settled negative.

## 16. Upstream hunk ledger — verified against git diff upstream/dev HEAD

ALREADY FORK-DIVERGED (editing these adds no new conflict surface):
| file | current diff | this change |
|---|---|---|
| ActionsDetailsSection.swift | +187 | ~ −130/+15: delete the three rows, ActionsExpandableDetailRow, networkViewButton, viewPathButton and two covers; the surviving cover is renamed and repointed, keeping its onDismiss deferral verbatim. Diff becomes deletion-heavy. |
| MessageActionsSheet.swift | +17 | ~ +12/−6: add `@State showJourney`, insert the caption + MessageJourneyEntry + Divider as the first children of the ScrollView VStack, pass the binding down, hoist the services guard so pathViewModel.loadContacts always runs from offlineDataStore, remove the isDetailExpanded/scrollTo plumbing. |
| MessageActionAvailability.swift | +13 | ±0 to +6: canViewPacketScope survives as Section B's gate. |
| MapPoint.swift | +16 | +1: `case observer` in PinStyle. |
| MC1MapView+Layers.swift | +110 | +1: `case .observer: "pin-observer"`. REQUIRED — the switch at :501-529 is exhaustive with no default. |
| MessagePathMapView.swift | +976 | ~ +25/−10: content-derived pin and badge ids at :238/:260/:368/:418/:526/:535; a host-supplied fit-control label parameter (defaulted); pass-through for the new pin style. All inside fork-authored regions. |
| MessageService+SendChannel.swift | +32 | +3: clearMessagePacketContentHash in the Catch-2 block (:268-281). |
| PersistenceStore+Messages.swift | +65 | +10: the clear implementation. |
| HeardRepeatPersisting.swift | +6 | +2: the protocol method. |
| MapLine+SNR.swift | +2 | ±0 |

BYTE-IDENTICAL TO UPSTREAM TODAY — each edit here permanently changes that file's merge cost. Take exactly two, knowingly:
1. PinSpriteRenderer.swift, +1 SpriteSpec (~2 lines) for the observer sprite. THE ONE NEW CONFLICT SITE THIS FEATURE CREATES IN A CLEAN FILE. Accepted: the fused map cannot let the phone and a stranger's station share a sprite.
2. RoomMessageActionsSheet.swift, +5 lines for the F067 explainer row. Cheap, and it stops the room sheet's borrowed vocabulary from implying a question that was never asked. DECIDED: take it, rather than leaving it as a footnote that gets dropped in review.

AND ONE REGION-LEVEL CHANGE inside an already-diverged file: ActionsOutgoingDetailsRows (ActionsDetailsSection.swift:239-257) is byte-identical to upstream today — verified, the diff's last hunk ends at +236. Two edits, ~7 lines: delete the `heardRepeats > 0` block ("Heard: %d repeats", the literal anchor of F001 and F090) and swap chats.message.info.roundTrip for the delivery sentence (F057). This converts a clean-merge region into a conflict surface, and any upstream change to the outgoing info rows will now conflict. TAKE IT: leaving "Heard: 3 repeats" four rows below a screen entry reading "3 echoes from 2 repeaters" reproduces F090 inside the fix, and the delivery-sentence hunk creates the conflict site anyway.

NOT TOUCHED, deliberately, and still merging cleanly: MapSnapshotRenderer.swift (its switch has `default: "pin-dropped"` and it only renders LocationPathMapBuilder styles — DROP this hunk from any plan that lists it); ActionsIncomingDetailsRows; ActionInfoRow; ActionButton; ActionsButtonsSection; ActionsDestructiveSection; ActionsPreviewHeader; ActionsEmojiSection; BubbleFooterRow; RepeatDetailsContent; RepeatRowView; PathHopRowView; MessagePathContent; PathDistanceBanner; MapLine.swift.

FORK-ONLY, deleted: MessagePathDetailView.swift (255), HeardRepeatsMapView.swift (186), PacketScopeDetailView.swift (1665) — of which roughly 1,200 lines MOVE nearly verbatim rather than being rewritten.
FORK-ONLY, kept: PacketScopeCoverageMap.swift (872, gains the origin: parameter and the .observer style), PacketScopeFocus.swift (212, untouched and wrapped), PacketScopeService.swift (behaviour untouched), PacketScopeSettingsSection.swift (strings and icon only).

RE-VERIFY EVERY HUNK COUNT AT IMPLEMENTATION TIME: run `git diff --stat upstream/dev HEAD -- <file>` per file before writing each phase. Two of the three submitted plans contained a hunk that was unnecessary or missing.

## 17. What is deliberately NOT changed

Stated plainly so nobody mistakes silence for an oversight.

THE BUBBLE. No new propagation cue, no chip glyph change, no always-on coverage chip. The last is ruled out by the privacy stance (it would need per-message fetches or persisted summaries) and is already recorded as deferred. So a rider who never long-presses still learns none of this exists: the sole pre-tap cue remains an unlabelled loop glyph plus a bare integer, and the incoming path, hop and region chips are off by default. This is half of "it needs to be more obvious" and this spec does not reach it — see open question 5.

THE SHEET'S READ-ONLY DETAILS ROWS, apart from the two lines named in §16. The flattened provenance (wire claims, a rewritten sender clock and this radio's own measurements in one grey list), the duplicate unlabelled "SNR: 8.5 dB (Good)" row, the unconditional "Hops: N" and its reachable 0xFF/63 sentinel all stay exactly as upstream renders them. Regrouping them is an upstream-owned rewrite of ActionsIncomingDetailsRows, a block the fork currently keeps clean.

HOP-COUNT DERIVATION. The screen's figures come from the hops it can actually list (message.pathHops), while upstream's "Hops: N" info row prints the wire byte's declared count (message.hopCount). When the stored pathNodes length disagrees with the declared byte these two differ. The screen states what it can show; the wire's claim stays in the upstream row. Accepted, unresolved.

DATA-LAYER WORK BEYOND THE HASH CLEAR. A resend still wipes the previous attempt's repeats and rows; the heardRepeats counter and the MessageRepeat rows are still two independent writes that can diverge in the database; the 30-second DM sender-prefix fallback still fills pathNodes with a possibly-overheard stranger's route with no uncorroborated marking; the no-repeats detector is still gated on the signal-bars engine; a backlog-drained message still has no recorded receive position. The spec describes these honestly, fixes the display of three of them, and repairs none of the underlying behaviour except the resend hash.

THE ZERO-ECHO COUPLING. An outgoing channel message with no echo still has no packetContentHash and therefore no possible observer lookup — the third-party evidence stays withheld from exactly the message the app says went unheard. Section B state (b) explains why in the rider's words. It cannot remove the coupling.

DEFERRED PACKET-SCOPE WORK, unchanged: repeater focus, line hit-testing on the map, per-route RSSI, the websocket firehose. And no shared floating panel with detents across screens — there is now one screen, so the question is moot, and the height budget stays local to it.

## New and changed user-facing strings

- "What happened to this message" — Sheet: caption above the journey row, first thing inside the ScrollView (replaces: nothing — the three evidence rows have no group header today (F007))
- "Where did this go?" — Sheet journey row title AND MessageJourneyView navigationTitle, outgoing (replaces: chats.message.action.repeatDetails "Repeat Details" and chats.message.action.networkView "Network View")
- "How did this arrive?" — Sheet journey row title AND MessageJourneyView navigationTitle, incoming (replaces: chats.message.action.viewPath "View Path" and chats.path.title "Path")
- "1 echo  /  %d echoes" — Reusable fragment: row subtitle, Section A figures line, Copy (replaces: part of chats.message.info.heardRepeats "Heard: %d %@")
- "from 1 repeater  /  from %d repeaters" — Reusable fragment, same three places (replaces: part of chats.message.info.heardRepeats)
- "%1$@ from %2$@" — Join giving "3 echoes from 2 repeaters" — row subtitle, outgoing channel with rows loaded (replaces: the "Heard: 3 repeats" summary as the row's answer)
- "Checking your radio's records…" — Row subtitle and Section A answer line while the repeat fetch is in flight (replaces: a bare unlabelled ProgressView inside the disclosure)
- "Couldn't read this message's echo records." — Row subtitle and Section A answer line when heardRepeats > 0 but the fetch returned empty (replaces: chats.repeats.emptyState.title "No repeats yet" rendered above "Heard: 3 repeats" (F017))
- "Listening for repeater echoes…" — Row subtitle and Section A answer line, outgoing channel, 0 echoes, inside the 5 s detection window (replaces: an absent row (F019) and a premature settled negative)
- "No repeater has echoed it back to you" — Row subtitle and Section A answer line, outgoing channel, 0 echoes, settled (replaces: an absent row and a details block containing only "Details" and "Sent:")
- "A repeater can relay your message onward without you hearing the echo, so this is not proof it went nowhere." — Footer directly under the zero-echo answer line, outgoing (replaces: nothing — the app never states what a zero does and does not mean (F098))
- "Repeat watching is off for this radio" — Row subtitle when repeaterSignals.isAttached is false (screen answer line uses the long form: "…, so no echo would be recorded even if one arrived.") (replaces: silence — the gate is invisible (F064))
- " · sent 2 times" — Appended to the row subtitle when sendCount > 1 (replaces: nothing — sendCount is never read in the sheet today)
- "Direct messages leave no repeater trail." — Sheet EXPLAINER row subtitle, outgoing DM (never tappable) (replaces: an empty block identical to a channel message that genuinely got nothing (F025))
- "It reached you through 1 repeater  /  It reached you through %d repeaters" — Row subtitle and Section A answer line, incoming with a recorded path; count = DISTINCT repeaters (replaces: the "3 hops • 2.3 mi" toolbar banner as the screen's headline (F041))
- "Flood-routed — your radio didn't record which repeaters carried it" — Row subtitle and Section A answer line, incoming flood with nil/empty pathNodes (replaces: a "Flood" bubble chip and a "Hops: 3" row with no screen behind either (F066))
- "It came by a set route — the packet doesn't record which repeaters carried it" — Row subtitle and Section A answer line, incoming direct-routed (replaces: chats.message.hops.direct "Direct" as the only explanation (and never "no repeater in between", which the data does not support))
- "Delivered — the other radio confirmed it (%d ms)" — Sheet outgoing info row, when roundTripTime is present (replaces: chats.message.info.roundTrip "Round trip: %dms", which files a DM's only delivery proof as a latency statistic (F057))
- "Room messages travel through the room server, so there is no repeater trail to show." — RoomMessageActionsSheet details block (replaces: silently missing rows in a sheet using the identical vocabulary (F067))
- "What your radio saw" — MessageJourneyView, Section A header, both directions (replaces: nothing — no local screen carries any vantage statement today (F002))
- "Measured here · no internet" — Section A provenance line, outgoing (replaces: nothing)
- "Recorded here from the packet's own header · no internet" — Section A provenance line, incoming (replaces: nothing)
- "What the observer network saw" — MessageJourneyView, Section B header (replaces: packetScope.heardBy "Heard by %d" as the panel headline and section header (F001))
- "Reported over the internet" — Section B provenance line, second row of the header, always visible (replaces: packetScope.coverageFooter as the only vantage statement, which the observers toggle deletes wholesale (F002))
- "Sent %d times — each attempt is a separate packet." — Panel identity block, sendCount > 1 (replaces: packetScope.retriedFooter "…This shows the one an observer heard first.", which names the wrong actor (F088))
- "1 repeater echoed it back to you  /  %d repeaters echoed it back to you" — Section A answer line, outgoing, once repeat rows are loaded (replaces: HeardRepeatsMapView's "Heard: %d repeats" panel header)
- "still listening" — Section A figures-line liveness tail while the heard-repeat subscription is live and the message is young (replaces: nothing — the local screens have no liveness word at all (F046))
- "farthest echo %@ away" — Section A figures line, outgoing; ≥-wrapped via packetScope.lowerBound when any echoing repeater is unplotted (replaces: an unqualified straight-line figure with no definition (F042, F047))
- "%@ along the route" — Section A figures line, incoming; ≥-wrapped whenever any hop is unplotted (replaces: the PathDistanceBanner's confident "2.3 mi", whose honest "≥" twin exists only in the wire string (F042, F015))
- "last hop in %@" — Section A figures line, incoming, from message.snr (replaces: the unattributed "SNR: 8.5 dB (Good)" info row and the bare bars on the Receiver row (F092))
- "measured from where you are now" — Section A figures line, incoming, appended when userFixCoordinate is nil (replaces: a confident distance drawn to today's GPS for a backlog-drained message (F062))
- "Echo in %@" — Signal column of an echo row and the reception leg's map badge (RSSI on the second line, unlabelled "-85 dBm") (replaces: the hardcoded English literal "SNR 6.2 dB" on RepeatRowView)
- "Last hop in %@" — Signal column of the incoming receiver row and the final leg's badge (replaces: the hardcoded literal "SNR 8.5 dB" on PathHopRowView)
- "They heard %@" — Signal column of an observer row (replaces: the bare unlabelled dB figure with inconsistent precision)
- "Their best RSSI %@ dBm" — Line above the route ladder in Section B (replaces: packetScope.rssiBest "Best RSSI %@ dBm" — adds the measuring subject)
- "Echo back to you · %@" — Role line of an echo row; %@ is the hop fragment ("2 hops") (replaces: chats.repeats.hop.plural "%d Hops" standing alone with no journey named (F012))
- "Hop %1$d of %2$d to you" — Role line of an incoming hop row (replaces: chats.path.hop.number "Hop %d")
- "Hop %1$d of %2$d to %3$@" — Role line and accessibility label of an observer route hop pill; %3$@ is the observer name (replaces: the bare position number on the hop pill)
- "Look Up on the Observer Network" — Section B: the ONE control in the app that starts a CoreScope request (replaces: tapping the "Network View" row, which opened a screen that fetched on appear (F022))
- "Sends this packet's identifier — never its text — to %@ over your internet connection." — Section B, directly under the lookup button; %@ is the host of the configured packetScopeBaseURL (replaces: Settings.strings packetScope.footer as the only place this is said, on a screen the user is not on)
- "Observer-network lookups are off." — Section B body when packetScopeEnabled is false (replaces: packetScope.error.disabled rendered as a full-screen error, or nothing at all (F063))
- "Turn them on and the app can ask an internet observer network which stations heard this packet. It sends the packet's identifier, never its text." — Section B, under the off-state line (replaces: nothing)
- "Settings ▸ Chats ▸ Observer Network" — Section B, inert path line under the off state — deliberately not a deep link and not an in-screen toggle (replaces: a dead end requiring the user to guess that "Packet Scope" is the same feature)
- "Nothing to look up yet. The app learns this packet's identifier from the first repeater echo it hears." — Section B when packetContentHash is nil, outgoing channel (replaces: an absent row indistinguishable from the feature being off (F019, F063, F098))
- "Direct messages can't be looked up: the app never learns a DM's packet identifier from your own radio." — Section B when packetContentHash is nil, outgoing DM (replaces: an absent row (F025))
- "This message arrived without a readable packet identifier, so there is nothing to look up." — Section B when packetContentHash is nil, incoming (covers the fail-closed sender-prefix-fallback DM) (replaces: an absent row)
- "Checking the observer network…" — Section B, request in flight (replaces: packetScope.loading "Checking observers…", which existed only in the List layout)
- "1 internet station reported hearing it  /  %d internet stations reported hearing it" — Section B headline once loaded (replaces: packetScope.heardBy "Heard by %d" — retires the shared "Heard" prefix (F001))
- "No station has reported it yet. Still checking…" — Section B, zero receptions while loopOutcome == .running, with a visible spinner (replaces: packetScope.notObserved asserted on the first empty poll while a 6 s loop keeps running for 180 s (F087))
- "No station on this observer network reported hearing it." — Section B, zero receptions once the loop has stopped (replaces: packetScope.notObserved "No observer heard this packet" — scopes the negative to one server (F003))
- "That is not the same as it not being delivered — observers only cover their own region." — Section B, normal weight directly under the settled-zero line — not small print (replaces: packetScope.notObservedFooter, which carries the rescuing clause as a footer nobody reads)
- "Couldn't reach the observer network." — Section B when the loop stopped on failures, with or without rows, in the MAP layout too (replaces: silence plus "settled in 1.4 s" produced by the failure path (F061, F045))
- "Last checked %@." — Section B, under the failure line (replaces: nothing — no last-updated state exists today)
- "Check again" — Section B button after a settled-zero or a failure (replaces: the toolbar packetScope.refresh, moved to where the thing it refreshes lives (F050))
- "Show on map  /  Hide on map" — Section B header once loaded (replaces: packetScope.showObservers / hideObservers, which toggled only the row list; now it toggles the observer geometry — the compare-in-place control (F036))
- "Just reported" — Observer row chip, 20 s after that station first reports in this lookup (replaces: packetScope.new "New", which reads as a mesh event beside the real +1.3 s propagation offset (F100))
- "farthest station %@ away" — Section B summary line (replaces: packetScope.farthest "farthest %@", which reads as reach but is a straight line to whichever observers publish coordinates (F042))
- "Signal figures here are what your radio measured receiving the echo — not how well the repeater heard you." — Section A provenance line 2, outgoing, whenever at least one SNR-coloured leg is drawn (replaces: the unlabelled SNR colour on the repeats map's return leg, which an operator reads as uplink quality (F086))
- "Green B is your radio. Line colour is how strongly your radio heard that echo — not how well the repeater heard you." — Legend line, outgoing, map layout, focus == .all; also the map accessibilitySummary prefix (replaces: no legend at all on a map whose only coloured, badged line is the downlink (F008, F051, F086))
- "Blue A is the sender, green B is your radio. The line is the route this copy took, not a signal measurement." — Legend line, incoming, map layout, focus == .all (replaces: no legend, and an A/B alphabet that flips meaning between two adjacent rows (F008))
- "Purple pins are observer stations; the blue web is the links their copies crossed." — Appended to the legend line while the observer layer is showing on the map (replaces: observers wearing the green "B" that means "you" one row away (F008, F038))
- "Fit to everything shown" — The shared map control on this screen; its label becomes a host-supplied parameter (defaulted, existing callers unchanged) (replaces: chats.path.centerOnPath "Center on path" on a map that frequently has no path (F054))
- "Sending again starts a new packet and clears this record." — Section A, directly above the Send Again button (replaces: nothing — the cost of a resend is stated nowhere today (F018, F059))
- "Added to Reply" — Reply with Route's momentary confirmed label (~0.4 s) alongside a success haptic, before the cover closes (replaces: an unchanged button through two dismissal animations (F083))
- "Observer Network" — Settings ▸ Chats section header (replaces: packetScope.header "Packet Scope" (F005))
- "Allow Observer Lookups" — Settings ▸ Chats master toggle; icon dot.radiowaves.up.forward → globe (replaces: packetScope.toggle "Look Up Message Coverage")
- "Adds an Observer Network section to a message's journey screen, showing which internet-connected stations heard its packet and at what signal level. Looking a message up sends that packet's identifier (never its content) to the server below over your phone's internet connection. Coverage depends on the observer network the server watches." — Settings ▸ Chats section footer (replaces: packetScope.footer, whose first sentence names "a Network View" in prose)
- "Observer-network lookups are turned off in Settings." — PacketScopeServiceError.disabled (replaces: packetScope.error.disabled "Packet Scope is turned off in Settings." — naming a control the user has never seen (F005))
- "The observer network's server address is not a valid HTTPS URL." — PacketScopeServiceError.invalidBaseURL (replaces: packetScope.error.invalidBaseUrl "The Packet Scope server address…")
- "The observer network sent a response the app couldn't read." — PacketScopeServiceError.invalidResponse — a new fork key (replaces: common.error.invalidResponse "Invalid response from elevation API", which on the list layout is the whole screen)

## Implementation phases


### Phase 0 — services and preload correctness

Shippable alone and independently valuable; no UI restructure, ~45 lines. (1) Add clearMessagePacketContentHash(id:) to HeardRepeatPersisting and PersistenceStore+Messages and call it in resendChannelMessage's Catch-2 post-commit block, beside the existing incrementMessageSendCount / updateMessageHeardRepeats(0) / deleteMessageRepeats — so a superseded attempt has nothing to look up and both layers always describe the same packet (F088, F059). (2) Hoist the sheet's `guard let services` so pathViewModel.loadContacts(dataStore: appState.offlineDataStore, radioID:) ALWAYS runs on every branch, with the guard covering only the repeats/contacts/nodes loads (F010, F075). (3) Give PacketScopeServiceError.invalidResponse its own string so a decode failure stops naming the elevation API. Ship with its own BETA_CHANGES line naming the resend trade.

Files: MC1Services/Sources/MC1Services/Protocols/Persistence/HeardRepeatPersisting.swift, MC1Services/Sources/MC1Services/Services/PersistenceStore+Messages.swift, MC1Services/Sources/MC1Services/Services/MessageService+SendChannel.swift, MC1/Views/Chats/Reactions/MessageActionsSheet.swift, MC1/Services/PacketScopeService.swift, MC1/Resources/Localization/en.lproj/Localizable.strings, BETA_CHANGES.md

Risk: LOW technically — all four Swift files already carry fork hunks, the Catch-2 block's failures only log, and the hash has exactly two readers (MessageActionAvailability.swift:36, PacketScopeDetailView.swift:1491), both of which handle nil correctly. The real risk is PRODUCT, not code: a user who resends permanently loses the ability to look up the earlier attempt, with no undo. Do not merge this phase without an explicit owner yes (open question 1). Ship it alone so it can be reverted alone.

### Phase 1 — extract the observer machinery, pixels unchanged

Move PacketScopeDetailView's ~30 @State fields, fetch/poll loop, coverage rebuild, focus/sort/freeze logic, arrival ramps, announcements and summaries into an @Observable MessageJourneyObserverModel, leaving PacketScopeDetailView a thin view over it. Add the LoopOutcome enum here (it is the one behaviour change permitted in this phase and it is covered by new tests). HARD GATE: no string change, no layout change, no new UI in the same commit; PacketScopeFocusTests and PacketScopeCoverageBuilderTests stay green untouched.

Files: MC1/Views/Chats/Components/PacketScopeDetailView.swift, MC1/Views/Chats/Components/Journey/MessageJourneyObserverModel.swift, MC1Tests/Views/Journey/MessageJourneyObserverModelTests.swift, MC1Tests/Views/PacketScopeFocusTests.swift, MC1Tests/Views/PacketScopeCoverageBuilderTests.swift

Risk: HIGHEST IN THE PLAN. PacketScopeDetailView's correctness lives in the INTERACTION of those @State fields — the 350 ms settle re-fit reading a frozen cameraFocus, the 132 pt list floor, frozen order, arrival ramps, scene-phase mirrors, poll backoff, pin hit-testing, and the reconcile-and-announce sequence at the end of rebuildCoverage. Moving them into an @Observable class changes when SwiftUI invalidates. This phase exists precisely so that lands with the pixels unchanged and the existing tests as the oracle. If it slips, Phase 0 still has value. Never merge Phases 1–4 as one PR.

### Phase 2 — pin identity and one origin

Prerequisite for a fused map; shippable alone with no new screen. (1) Content-derived pin ids in MessagePathMapView.heardRepeatNodes and locatedNodes (currently UUID() at :238/:260/:368/:418) and for the SNR badges (:526/:535), on the PacketScopeCoverageMap.stableID pattern. (2) PacketScopeCoverageBuilder.build takes `origin:` instead of computing it internally (:178-186), so one origin serves both layers; update PacketScopeCoverageBuilderTests. (3) Add the .observer PinStyle case, its sprite, and the exhaustive-switch case.

Files: MC1/Views/Chats/Components/MessagePathMapView.swift, MC1/Views/Chats/Components/PacketScopeCoverageMap.swift, MC1/Views/Map/MapPoint.swift, MC1/Views/Map/MC1MapView+Layers.swift, MC1/Views/Map/PinSpriteRenderer.swift, MC1Tests/Views/PacketScopeCoverageBuilderTests.swift

Risk: MEDIUM. The id change touches fork-authored regions of MessagePathMapView (+976, the most-diverged file) that ALSO feed SharedRouteMapSheet and TracePath — verify camera settling and label stability on those callers, not only on the new screen. MapPoint.== includes id and MC1MapView+Layers.swift:92 diffs the whole fixed source, so getting this wrong looks like a broken build rather than a subtle regression. PinSpriteRenderer.swift is byte-identical to upstream and becomes a new conflict site; MC1MapView+Layers.swift's switch is exhaustive with no default, so its hunk is required to compile. MapSnapshotRenderer needs NO hunk — it has a default and only renders LocationPathMapBuilder styles.

### Phase 3 — the state model, the entry, and the local screen

The shippable midpoint that removes the P0 confusion. (1) MessageJourneyState as a pure value type covering the whole §3 table, with MessageJourneyStateTests including the two privacy assertions. (2) MessageJourneyEntry with its HeardRepeatsService.events() subscription. (3) MessageJourneyView shell: identity block, answer line, figures line, legend, Section A with its rows, the local geometry wrapper (MessagePathMapView.heardRepeatNodes unchanged), Reply with Route + its acknowledgment, Send Again + its cost line, the toolbar Copy. (4) Upstream hunks: MessageActionsSheet gains @State showJourney and the entry as the ScrollView's first child; ActionsDetailsSection deletes three rows, ActionsExpandableDetailRow and two covers, keeping the surviving cover ON ITS OWN VStACK with its onDismiss deferral verbatim; ActionsOutgoingDetailsRows loses "Heard: N repeats" and gains the delivery sentence. (5) Delete MessagePathDetailView.swift and HeardRepeatsMapView.swift. (6) Section B renders states (a)/(b)/(c) and, on the lookup button, PUSHES the untouched PacketScopeDetailView into the same NavigationStack — preserving the user-initiated contract without waiting for Phase 4.

Files: MC1/Views/Chats/Components/Journey/MessageJourneyState.swift, MC1/Views/Chats/Components/Journey/MessageJourneyEntry.swift, MC1/Views/Chats/Components/Journey/MessageJourneyView.swift, MC1/Views/Chats/Components/Journey/MessageJourneyLocalSection.swift, MC1/Views/Chats/Reactions/MessageActionsSheet.swift, MC1/Views/Chats/Reactions/Sections/ActionsDetailsSection.swift, MC1/Views/Chats/Components/MessagePathDetailView.swift, MC1/Views/Chats/Components/HeardRepeatsMapView.swift, MC1Tests/Views/Journey/MessageJourneyStateTests.swift

Risk: MEDIUM, and lower than any submitted design because the presenting context does not move: the surviving fullScreenCover stays attached to ActionsDetailsSection's own VStack, so iPad behaviour and both deferral mechanisms are byte-for-byte what ships. Write the reason into that file's doc comment — moving the cover onto the new child view is the single most natural refactor a future contributor will attempt. Exit gates: the owner's zero-echo case on device; Reply with Route's wire string byte-identical and reaching the composer through both deferrals; VoiceOver on the outgoing-DM explainer row; medium-detent height on the smallest phone with the emoji row present at normal AND accessibility Dynamic Type; deleting "Heard: N repeats" converts a byte-identical upstream region into a conflict surface — accepted knowingly.

### Phase 4 — fold in the observer network

Move the observer rows, ladder, hop pills, focus application, coverage rebuild, arrival ramps, sorting, announcements and copy into MessageJourneyObserverSection over the Phase 1 model. Add the nine states, the collapsed pre-tap body (provenance line, cost line naming the live host, Look Up button) and the off / no-hash variants. Move BOTH .task fetches (liveRefreshLoop AND loadObservers) behind startLookup(). Add JourneyFocus wrapping the untouched PacketScopeFocus, the map compositing rules with observer legs suppressed outside a focus, the Show/Hide-on-map toggle, and the both-layers Copy. Delete PacketScopeDetailView.

Files: MC1/Views/Chats/Components/Journey/MessageJourneyObserverSection.swift, MC1/Views/Chats/Components/Journey/JourneyFocus.swift, MC1/Views/Chats/Components/Journey/MessageJourneyCopy.swift, MC1/Views/Chats/Components/PacketScopeDetailView.swift, MC1/Views/Chats/Components/PacketScopeCoverageMap.swift, MC1/Views/Chats/Components/Journey/MessageJourneyView.swift, MC1Tests/Views/Journey/MessageJourneyObserverModelTests.swift

Risk: HIGH-ish, offset by Phase 1 having already de-risked the machinery. The privacy audit (§12) is this phase's acceptance checklist, run line by line against the diff — the ONE thing most likely to be lost is that BOTH .task modifiers move, not just the observations POST, and that the model does no work until startLookup() is called (asserted by test, not by comment). Three on-device gates before it closes: .collide label priority over a dense area with both layers drawn (the local evidence must win every collision, the you-pin must never drop); panel height on the smallest phone at accessibility Dynamic Type with Section B open AND a route focus active; and a screenshot confirming the default map reads correctly with observer legs suppressed (open question 3).

### Phase 5 — one row format, one state vocabulary, accessibility

Introduce JourneyEvidenceRow and use it for echo rows, incoming hop rows and observer rows; port the drawability marks and +N s offsets onto the local rows; replace the ~Name tilde with the shared "?" indicator in the observer hop pills; implement the checking / not-yet / never-for-this-kind / not-on-this-device wording rule inside the panel for both sections including the live-versus-settled split and the Retry paths; add the map accessibilitySummary in every state, the labelled loading rows and the completion announcement, the accessibility-size stacking, and the Expanded/Collapsed values.

Files: MC1/Views/Chats/Components/Journey/JourneyEvidenceRow.swift, MC1/Views/Chats/Components/Journey/MessageJourneyLocalSection.swift, MC1/Views/Chats/Components/Journey/MessageJourneyObserverSection.swift, MC1/Views/Chats/Components/Journey/MessageJourneyView.swift

Risk: LOW-MEDIUM. Mostly presentation, on fork-only files. The one non-obvious item is the popover host: the "?" indicator now appears on a cover-over-MapLibre screen that also runs a poll and camera animations. Precedent exists (HeardRepeatsMapView already hosts it via RepeatRowView), but the fork's iOS 26 zoom-morph rule applies in full — no automatic tips or TCC prompts on that host, no programmatic dismissal during teardown. Write it into the file's doc comment.

### Phase 6 — strings, Settings, docs, cleanup

One commit adding ~40 en keys plus all ten translations plus the regenerated L10n.swift, with the key count stated in the commit body. Rename the Settings section, toggle, icon and footer to Observer Network; update both error strings. Rewrite docs/PACKET_SCOPE.md for the merged entry, the origin: parameter, the observer sprite, the leg-suppression rule and the new fetch trigger; fill docs/Glossary.md (it has no entry for repeater, echo, heard repeat, hop, observer or packet identifier); add the docs/FORK_FEATURE_INVENTORY.md Group 7 row that has never existed, naming both duplicated row views; write the BETA_CHANGES.md entry including the two behaviour changes worth naming (a resend now clears the lookup; "settled" is no longer printed after failed polls). Handle docs/User_Guide.md per open question 4.

Files: MC1/Resources/Localization/en.lproj/Chats.strings, MC1/Resources/Localization/en.lproj/Localizable.strings, MC1/Resources/Localization/en.lproj/Settings.strings, MC1/Resources/Generated/L10n.swift, MC1/Views/Settings/Sections/PacketScopeSettingsSection.swift, MC1/Views/RemoteNodes/Rooms/RoomMessageActionsSheet.swift, docs/PACKET_SCOPE.md, docs/Glossary.md, docs/FORK_FEATURE_INVENTORY.md, BETA_CHANGES.md, docs/User_Guide.md

Risk: LOW per line, HIGH for silent partial failure. lint.yml verifies only that L10n.swift is regenerated; there is NO locale parity check, and the repo already carries an orphan pile (en has 5 keys de lacks; pt is 22 chats.* keys short; chats.path.map survives only in pt). A partial rename fails silently into English fallbacks in eight languages. Do the whole sweep in ONE commit and grep all eleven .lproj dirs AND the prose for "Network View", "Packet Scope", "Look Up Message Coverage" and "Heard" before pushing. Leave retired keys in place rather than sweeping — a partial deletion just grows the orphan pile. Run xcodegen after any branch switch before building.

## Open questions for the owner

1. CLEARING THE PACKET IDENTIFIER ON RESEND (Phase 0). Today a resend wipes the echo record but never clears packetContentHash, so the observer half keeps describing a packet you have already superseded, next to a bubble that says the message was sent twice, under a caption that blames observers for a selection this phone made. Clearing it makes both halves always describe the same attempt — and permanently removes the ability to look up the earlier attempt, with no undo. Recommended yes. This is a data-layer behaviour change and it needs your explicit go, not a reviewer's inference; it ships as its own commit so it can be reverted alone.
2. THE USER-FACING NAME. This spec replaces three names — "Network View" (the row and the screen), "Packet Scope" (the Settings section and both errors) and "Look Up Message Coverage" (the toggle) — with one: Observer Network. That touches Settings, both error strings, the Settings footer prose and BETA_CHANGES, all of which beta testers have already read, across eleven locales with no CI parity check. Confirm the name (or choose a different one) BEFORE the sweep in Phase 6 — a second rename costs the eleven-locale sweep twice.
3. OBSERVER SIGNAL LINES ON THE DEFAULT MAP. To keep exactly one signal colour language on screen, the spec draws observer SNR-coloured legs only once you focus an observer or a route; in the default view the observer layer contributes pins and the blue link web only. Per-observer signal still reads in every row and in "best 12.2 dB", but this removes an at-a-glance signal picture the beta shipped and some riders may use. Decide it from a device screenshot over a dense area before Phase 4 closes. The fallback is to accept two SNR colour languages on one map and lean harder on the legend, which is weaker.
4. docs/User_Guide.md. Its "Message Details" section is upstream-owned with a ZERO fork diff today, and all three of its sentences are already false for this fork (View Path leaves the sheet; nothing grows the sheet; Network View is never mentioned). This redesign makes them false in a new way. Rewrite that section — enlarging the fork's diff against an upstream doc for the first time — or leave the upstream file clean and put the truth in a fork-only doc plus BETA_CHANGES? A maintenance-policy call, not an engineering one.
5. F011 — MAKING THE LONG-PRESS DISCOVERABLE. Nothing in this spec reaches the bubble. A rider who never presses and holds still learns none of this exists: the sole pre-tap cue stays an unlabelled loop glyph plus a bare integer on outgoing messages, and the incoming path, hop and region chips are off by default. The sheet is now obvious once opened; opening it is not. Is a bubble-affordance change the next piece of work after this lands, or does it stay out of scope? (It means editing upstream's BubbleFooterRow and the MessageItem rebuild plumbing the bubble is Equatable on, so it is a real piece of work, not a footnote.)

## Findings matrix (spec status per confirmed finding)

- F001 **fixed** — Each population gets its own noun and vantage: "3 echoes from 2 repeaters" / "2 repeaters echoed it back to you" under "What your radio saw"; "9 internet stations reported hearing it" under "What the observer network saw". packetScope.heardBy is retired and the sheet's "Heard: %d repeats" info row is deleted (§16), so "Heard" leaves both surfaces and the two figures never occupy the same slot.
- F002 **fixed** — Both sections carry a provenance line in the panel's fixed header — "Measured here · no internet" / "Recorded here from the packet's own header · no internet" / "Reported over the internet" — rendered inside the panel so it survives the map layout and cannot be deleted by the observers toggle, which today removes coverageFooter wholesale.
- F003 **fixed** — The negative is scoped to the server and the qualifier is promoted out of the footnote: "No station on this observer network reported hearing it." + "That is not the same as it not being delivered — observers only cover their own region." in normal weight. The incoming-nonsense case disappears because Section A answers the incoming question first, above it.
- F019 **fixed** — The journey row is unconditional. An outgoing channel send with zero echoes reads "Listening for repeater echoes…" then "No repeater has echoed it back to you", and opens a screen stating what that does and does not mean plus the reason no lookup is possible yet. This is the owner's exact case and the sheet is no longer mute.
- F036 **fixed** — The whole design: one entry, one screen, local geometry always drawn, observer geometry overlaid on the same map and stacked in the same panel, comparable in place, with a Show/Hide-on-map toggle to isolate either half. Storage, nouns, colours and counts stay separate; only the question is merged.
- F038 **fixed** — The local layer always contributes the "you" pin, so an incoming message's observer view draws the operator's own radio as the same green .pointB the path screen uses, with observers visibly a different mark (the new .observer sprite). One origin is computed by the screen and handed to both builders.
- F086 **fixed** — Stated three times: the row ("Echo in 6.2 dB"), the Section A provenance line 2 ("…not how well the repeater heard you"), and the map legend. Additionally, observer SNR legs are withheld from the default map so exactly one SNR colour language is on screen at a time, and it is always the local one.
- F087 **fixed** — While loopOutcome == .running an empty result renders "No station has reported it yet. Still checking…" with a visible spinner; the settled negative is structurally unreachable while the loop runs. The state lives in the panel, so it also renders in the map layout, which today has no such state at all.
- F088 **fixed** — Fixed at the source in Phase 0: clearMessagePacketContentHash(id:) added to HeardRepeatPersisting and PersistenceStore+Messages, called in resendChannelMessage's Catch-2 block beside the existing counter reset and row deletion. Both layers then always describe the same attempt. The misattributing retriedFooter is deleted and the retry line moves to the identity block as a fact about the message. Owner decision 1.
- F004 **fixed** — "Repeat Details" is deleted from the UI. The entry is named by the question ("Where did this go?"), and the words repeat/again are reserved for the resend action.
- F005 **fixed** — One user-facing name, Observer Network, on the section header, the Settings section, the toggle, both error strings and the Settings footer prose. "Network View" and "Packet Scope" leave the UI entirely; Packet Scope survives only as the internal/AppStorage/service name and in docs.
- F007 **fixed** — A caption, "What happened to this message", above one evidence row, placed ahead of the composing actions and separated by a Divider. The "Details" caption now labels only the read-only info rows it precedes, which is what it was always meant to do.
- F008 **fixed** — One pin alphabet enforced on every message map: .pointB is ALWAYS your radio, .pointA is ALWAYS the sender of an incoming message, .repeaterHop is a repeater, and one new .observer sprite is a third-party station. A legend line names them and is reused as the map's accessibilitySummary prefix.
- F010 **fixed** — Three fixes: Phase 0 hoists the sheet's services guard so pathViewModel.loadContacts always runs from offlineDataStore on every branch; the journey screen loads contacts itself as a second defence; and for an incoming direct-routed DM the screen now draws the phone, states how the message arrived in words, and labels the observer evidence as somebody else's.
- F011 **deferred** — Not reached by this spec. The bubble's only pre-tap cue is upstream-owned BubbleFooterRow (an unlabelled loop glyph plus a bare integer), the incoming chips are off by default, and an always-on coverage chip is ruled out by the privacy stance. Discoverability improves only in that the entry is now above the medium-detent fold once the sheet is open. Named to the owner as the next piece of work — open question 5.
- F022 **fixed** — The remote entry is a distinct section with its own header, glyph and provenance line, and the lookup is a bordered button unlike every row above it, carrying a cost sentence that names the live configured host and the internet — rendered before any tap. The local section says "no internet".
- F025 **fixed** — An outgoing DM gets a visible non-tappable explainer row ("Direct messages leave no repeater trail.") instead of the same empty block a genuine zero renders, and Section B's state (b) states the structural exclusion of the lookup with its reason. Permanent exclusion is stated, not rendered as absence.
- F028 **fixed** — The inline disclosure is deleted outright, so nothing expands inside a sheet that cannot grow and the scrollTo("expandedContent") compensation is never triggered. Upstream's detent rules are unchanged.
- F029 **fixed** — The entry becomes the first child of the ScrollView's VStack, ahead of ActionsButtonsSection, at roughly 198 pt (82 header + 52 emoji + 64 row) — inside the medium detent on a phone, with Reply landing at ~262. Verify on the smallest phone and at accessibility Dynamic Type, where the emoji strip moves inside the scroll.
- F041 **fixed** — One answer line in one slot, same position and semibold weight in every state and both directions, with the figures line directly beneath it in a fixed order. The .principal distance banner that replaced the title is removed.
- F042 **fixed** — Every distance is labelled by its definition — "%@ along the route", "farthest echo %@ away", "farthest station %@ away" — and the ≥ lower-bound rule is applied to the VISIBLE figure, not only to the wire string as it is today.
- F045 **fixed** — One three-word vocabulary (checking / nothing / couldn't check) shared by both sections and rendered inside the panel, so it survives the map layout. The separate List layout with its own error, empty and loading rows is retired; the no-map branch renders the identical panel content.
- F046 **fixed** — Both the sheet row and the screen subscribe to HeardRepeatsService.events() filtered to this message id, so echoes appear while you watch instead of on the next long-press, and both layers share one liveness vocabulary ("still listening" / "still arriving") and one refresh affordance.
- F047 **fixed** — The observer rows' drawability marks (mappin.and.ellipse / mappin.slash) and the "+N hops not on the map" caveat are ported onto the local rows and the local section, and the ≥ qualifier reaches every on-screen distance.
- F048 **fixed** — A one-line identity block opens the panel in every state and both directions: direction, counterpart and time ("You → #general · Sep 2, 14:07"), plus a one-line text preview beneath it, hidden at accessibility sizes and under a route focus.
- F057 **partial** — The delivery fact is stated in the rider's words — "Delivered — the other radio confirmed it (341 ms)" replaces "Round trip: %dms" — and the DM's structurally impossible evidence is stated in the explainer row and in Section B. NOT done: .sent and .failed still get no info row of their own; the bubble's status chip continues to carry them, and adding rows would widen an upstream hunk for a state already legible behind the sheet.
- F061 **fixed** — A typed LoopOutcome enum (.running/.settled/.windowClosed/.failed) set by liveRefreshLoop's exit condition, with refresh()'s catch recording the failure even when receptions != nil. "Settled" is reserved for a settled loop; a failure prints "Couldn't reach the observer network." with a last-checked time and Check again, and it renders in the map layout. One unit test per exit path.
- F062 **fixed** — The figures line appends "measured from where you are now" when userFixCoordinate is nil, and routeDistanceText withholds the distance clause entirely in that case, so a figure for a journey that was never traversed is not transmitted. The underlying stamping rule is unchanged — the app still cannot know where a backlog-drained message landed, and now says so.
- F064 **partial** — The state is NAMED rather than the services decoupled: "Repeat watching is off for this radio, so no echo would be recorded even if one arrived." Verified reachable and live — RepeaterSignalModel is @Observable and isAttached is a tracked stored property, so a view body reading it invalidates correctly. Decoupling the detector from the signal-bars engine is a ChatViewModel/AppState change with no surface in this redesign.
- F071 **fixed** — The row is unconditional, so it can never fail to appear, and MessageJourneyEntry subscribes to the heard-repeat event stream, so its subtitle recomputes in place while the sheet is open. The noun in the subtitle never changes — only the count — because every figure is derived from the rows.
- F075 **fixed** — Phase 0 hoists the services guard so pathViewModel.loadContacts always runs from offlineDataStore on every branch, and the inline disclosure with its unbounded spinner is gone. Every load in the new screen has a terminal state with a Retry instead of an indefinite ProgressView.
- F089 **deferred** — Path data from the 30 s sender-prefix fallback is still shown, mapped and shareable with no uncorroborated marking. The finding's minimum remedy as specified — suppress Reply with Route for it — is REJECTED as stated: the only available signal (nil contentHash) also fires for legacy RxLog rows, so acting on it would silently break Reply with Route for correct messages. The real fix is a provenance flag through SyncCoordinator+HandlerHelpers into MessageDTO, a services change with its own review.
- F090 **fixed** — Two figures everywhere, never one: distinct repeaters in the answer line, echoes in the figures line, both together in the row subtitle ("3 echoes from 2 repeaters"). Each row's role line states its own hop chain, and a multi-hop echo renders its full hopHashes chain as numbered pills instead of naming only the tail. The same rule is applied incoming: distinct repeaters in the answer, raw hops in the figures.
- F092 **partial** — message.snr is named as what it measures wherever this feature prints it — "Last hop in 8.5 dB" on the figures line, the receiver row and the final leg's badge. NOT done: the duplicate unlabelled "SNR: 8.5 dB (Good)" row in the sheet's Details block stays, because rewriting ActionsIncomingDetailsRows is an upstream-owned block the fork currently keeps byte-identical.
- F098 **partial** — The local state is worded as an observation, not a verdict ("No repeater has echoed it back to you" + the it-is-not-proof footer), and Section B state (b) explains the coupling in the rider's words: the packet identifier comes from the first echo, so a message with no echo has nothing to look up. The structural coupling itself is not broken — the third-party evidence remains unavailable for exactly the message the app says went unheard.
- F006 **fixed** — One destination row with one chevron; there is no in-place disclosure left in the sheet, so the chevron means exactly one thing. The explainer form has no chevron and is not a Button.
- F009 **fixed** — localRadioLabel (connectedDevice?.nodeName ?? "You") is resolved ONCE by MessageJourneyView and passed to the identity line, the local rows, the receiver row and the .pointB pin, so header, row and pin can never disagree. AppState's own unlocalized "Me" literal is outside this feature and untouched.
- F012 **fixed** — One lowercase hop formatter behind every count on the screen (reusing packetScope.direct/hopOne/hopCount), plus a role line on every ROW naming whose journey it belongs to — "Echo back to you · 2 hops", "Hop 2 of 3 to you", "Hop 2 of 3 to KTX-Hilltop". The casing collision disappears because the two upstream rows that produced it are no longer rendered here.
- F013 **fixed** — The heard-repeats map is no longer nested behind a disclosure and no longer waits on a fetch — it is the default content of the one destination for an outgoing message, present from first paint.
- F014 **fixed** — The screen is titled with the question it answers, in both directions, and the row that opened it is gone from the stack behind it — so the shared name is the arrival confirmation rather than the name of a control still sitting open.
- F015 **fixed** — A stable inline navigationTitle in every state; the .principal PathDistanceBanner is removed so the title is never replaced, and the distance moves into the figures line where it carries the ≥ qualifier and a definition.
- F016 **fixed** — One RepeaterIdentityLabel (hex + name + the tappable "?" FallbackMatchIndicatorView with its existing popover) shared by echo rows, incoming hop rows and observer hop pills. The unexplained "~" prefix is retired and the server's 4-hex resolved key moves to the ID column, never the name column.
- F017 **fixed** — The answer line and every count are derived from the rows the screen actually has, so "No repeats yet" over "Heard: 3 repeats" cannot render. The rows-empty-with-positive-counter case becomes an honest admission: "Couldn't read this message's echo records." The two independent database writes can still diverge; only the display is made self-consistent.
- F018 **fixed** — The cost is stated where the resend is offered ("Sending again starts a new packet and clears this record." directly above Send Again), the attempt count is surfaced in the sheet subtitle and the panel identity block for the first time, and Phase 0's hash clear means the two systems no longer describe different packets. The asymmetric data destruction (repeats wiped) is unchanged by design.
- F024 **fixed** — There is one row, so direction cannot flip its order; inside the screen the vantage order is fixed — your radio first, third parties second — in both directions.
- F027 **partial** — The count is stated once, at the head of the evidence it summarises, and the duplicate "Heard: %d repeats" info row is deleted. REJECTED: making the bubble chip's glyph identical to the entry's. It edits upstream's byte-identical BubbleFooterRow for cosmetic gain, and the chip counts echoes while the entry names a question — identical glyphs would assert an equivalence the two figures do not have.
- F031 **fixed** — The row carries a real local answer as its subtitle before any tap, and Section B declares its own state (off / nothing to look up / not looked up yet) on the screen rather than spending a full-screen cover on an unlabelled unknown. A cached or pre-fetched observer count is rejected on privacy grounds.
- F032 **fixed** — "Repeat Details" is gone, so no entry shares a word with the "Details" caption, and the caption's scope is now correct — it labels only the read-only rows beneath it.
- F034 **fixed** — One glyph (point.topleft.down.to.point.bottomright.curvepath) for the journey row in both directions, because it is now one feature; a globe-family glyph on the observer lookup button that says "asks a server" rather than radio waves that read as "my radio"; and each map layer's pin and line style agrees within its own section.
- F043 **partial** — One SignalFigure with fixed label, one decimal, a localized unit and an explicit measuring subject ("Echo in", "Last hop in", "They heard") is used by every row this feature renders, and direction is additionally stated once per section. NOT done: upstream's RepeatRowView and PathHopRowView keep their hardcoded English literals, and the sheet's "SNR: 8.5 dB (Good)" info row stays — all three are simply no longer part of this flow.
- F049 **fixed** — One interaction model: rows focus their own evidence on both layers; observer pins toggle their observer; local pins, repeater pins and unrecognised pins are inert; and bare map background does NOTHING — the onMapTap popFocus() and the repeater-pin fallthrough are both deleted. Focus stays a filter, not a dimmer, and filters the observer layer only.
- F050 **fixed** — One doc.on.doc in one toolbar position producing one readable, provenance-tagged account of both layers, with the observer half still built without the MessageDTO in scope so the packet identifier can never reach the clipboard. The separate Copy Path control and the toolbar Refresh are retired; Done stays a .confirmationAction in one position.
- F051 **fixed** — The map supplies an accessibilitySummary in EVERY state, built from the legend line plus the same answer and figures the panel shows, so a VoiceOver user reaches the same conclusion. Today only the observer screen supplies one and the two local maps read as nothing.
- F052 **fixed** — Local rows gain the "+N s after the first" figure that observer rows already have (reusing packetScope.heardOffset), and each section header states what its list is ordered by.
- F054 **fixed** — The shared map control's label becomes a host-supplied parameter, defaulted so existing callers are byte-identical, and this screen passes "Fit to everything shown" — honest in every layer state on a map that frequently has no path at all.
- F059 **fixed** — Phase 0's hash clear removes the mismatch at the source: after a resend neither layer describes the previous packet, so the screen can no longer hold two halves about two different attempts while the origin pin has been re-stamped to the new send's position. The resend cost line states the consequence before the act.
- F063 **fixed** — With the opt-in off, Section B still renders with its explanation and the Settings path in words (state a); with no packet identity it renders a kind-specific reason (state b). "Turn this on" and "this message has no wire identity to look up" are now two visibly different states instead of the same empty space.
- F066 **fixed** — The row subtitle and the answer line both read "Flood-routed — your radio didn't record which repeaters carried it" instead of printing a hop count that promises a screen. Note: the sheet's own upstream "Hops: N" info row is unchanged and still prints the wire byte's declared count.
- F067 **fixed** — One explainer line in RoomMessageActionsSheet's Details block: "Room messages travel through the room server, so there is no repeater trail to show." Five lines in a file that is byte-identical to upstream — a new conflict site, taken knowingly and decided here rather than left as a footnote.
- F074 **fixed** — The disclosure and its late-inserted "View on Map" row are deleted. The single entry is present from first paint with a reserved subtitle line and the same .padding() as its sibling rows, so nothing is inserted mid-list after a fetch and nothing is under the 44 pt target.
- F079 **fixed** — JourneyEvidenceRow stacks its signal column under the identity at accessibility Dynamic Type, built in from the start. Upstream's RepeatRowView is left byte-identical and, after Phase 3, has no remaining call site in this flow — both of its call sites (the disclosure and HeardRepeatsMapView) are deleted.
- F080 **fixed** — Loading rows are labelled Text with a completion announcement when the rows land, and empty versus failed have distinct spoken text in both sections. The unlabelled spinner inside the disclosure is gone with the disclosure.
- F083 **fixed** — Reply with Route acknowledges itself on the screen where it was tapped: a .success haptic plus the label flipping to "Added to Reply" for ~0.4 s, before the existing two-step deferral chain runs unchanged.
- F091 **deferred** — The sheet's Details block still flattens wire claims, a rewritten sender clock and this radio's own measurements into one grey list, and still prints an undecodable hop count. Regrouping it by provenance is an upstream-owned rewrite of ActionsIncomingDetailsRows, a block the fork keeps clean. The journey screen states the same facts with their vantage attached, which reduces the harm without touching the block.
- F100 **fixed** — The chip becomes "Just reported", so it reads as a property of this lookup rather than a mesh event sitting beside the real +1.3 s propagation offset.

## Appendix — the 65 confirmed findings

Severity is the verifiers' consensus. Evidence cites the code at the time of review.


### F001 [P0] "Heard: 3 repeats" and "Heard by 9" are the same sentence about two unrelated worlds, one tap apart

- where: MC1/Views/Chats/Reactions/Sections/ActionsDetailsSection.swift:255 · cross-screen
- what the user sees: On an outgoing channel message the sheet's read-only rows end with "Heard: 3 repeats". The row directly above them, "Network View", opens a glass panel whose first line is "Heard by 9" in the same semibold subheadline, in the same card, in the same screen position that the heard-repeats map uses for its own "Heard: 3 repeats" header.
- why it fails: A rider reads two counts of "who heard my message" that differ by 6 and concludes the app is inconsistent, or that 9 is the better number. Neither is about recipients: 3 = echoes this radio itself demodulated off the air; 9 = distinct stations on one internet server. The word "Heard" is doing three jobs and never says whose ears.
- evidence: ActionsDetailsSection.swift:255 renders `chats.message.info.heardRepeats` = "Heard: %d %@" (en.lproj/Chats.strings:616) over `message.heardRepeats`. HeardRepeatsMapView.swift:119 renders the SAME string over `repeats.count`. PacketScopeDetailView.swift:373 renders `packetScope.heardBy` = "Heard by %d" (en.lproj/Localizable.strings:854) over `summary.observerCount`. Both panels are the same `liquidGlass` card at the same inset (HeardRepeatsMapView.swift:100-109; PacketScopeDetailView.swift:346-365).
- direction: Give each count its own noun and bake the vantage into the label — "3 repeaters echoed it back to you" vs "9 internet stations reported it" — and retire "Heard" as a shared prefix.

### F002 [P0] Not one of the four surfaces says whose radio produced the number in front of the user

- where: MC1/Views/Chats/Components/PacketScopeDetailView.swift:540 · cross-screen
- what the user sees: Three destination screens full of pins, dB figures, hop chains and repeater names. The only sentence anywhere distinguishing "your radio measured this" from "a station on the internet measured this" is a caption2/tertiary line at the very bottom of a scrolling panel: "Coverage reflects only the configured observer network. A message can be delivered without being observed."
- why it fails: Every screen looks like the same kind of evidence — same map canvas, same SNR-coloured lines, same signal bars, same repeater names — so the rider has no cue that Repeat Details/View Path are free, local, offline facts about their own radio while Network View is a third-party internet report about copies they never received. The one disclaimer is below the fold and disappears entirely when the focus bar's observers toggle is used.
- evidence: PacketScopeDetailView.swift:539-542 puts `packetScope.coverageFooter` (Localizable.strings:830) at the tail of `observerList`, inside a panel capped at 45% of screen height; the toggle at :505-510 hides that list wholesale. RepeatDetailsContent.swift:22-45 has no explanatory copy at all in the populated state. MessagePathDetailView.swift:117-193 (the panel) has none either. `packetScope.notObservedFooter` (Localizable.strings:829) — the fullest explanation of what an observer is — renders only in the empty state (PacketScopeDetailView.swift:581).
- direction: Put one persistent provenance line at the top of every evidence surface naming the vantage and its cost ("Your radio · offline" vs "Observer network · over the internet").

### F003 [P0] "No observer heard this packet" is shown for messages the user is demonstrably holding in their hand

- where: MC1/Views/Chats/Components/PacketScopeDetailView.swift:576 · network-view
- what the user sees: A `waveform.slash` glyph and the headline "No observer heard this packet", with a smaller footer underneath. This is what an incoming DM the user just read shows, and what an outgoing message shows whenever it simply travelled outside the configured server's observer region.
- why it fails: The headline is an absolute negative about a packet, not a scoped statement about one server. For an outgoing message it reads as "it didn't get out" — the exact false belief the rider came to the sheet to resolve — and the qualifier that rescues it ("it may still have been delivered on the mesh") is the small print below. For an incoming message it is nonsense on its face: the message is right there on screen.
- evidence: PacketScopeDetailView.swift:574-583: `Label(L10n.Localizable.PacketScope.notObserved, systemImage: "waveform.slash")` with `packetScope.notObservedFooter` as the section footer. Localizable.strings:828 = "No observer heard this packet"; :829 = "The packet never reached the observer network — it may still have been delivered on the mesh. Observers only cover their own region." The empty result is a real, distinguishable state (PacketScopeService.swift:337-348), so the copy — not the data — is the problem.
- direction: Scope the headline to the server ("No station on this observer network reported it") and promote the "still may have been delivered" clause into the headline's own sentence.

### F019 [P0] An outgoing channel message with no echoes yet shows nothing at all about propagation, while the bubble right behind the sheet shows a "No repeats heard" card

- where: MC1/Views/Chats/Reactions/Sections/ActionsDetailsSection.swift:38 · sheet
- what the user sees: The operator sends to a channel, gets no echo, long-presses to find out what happened. The details block is: the caption "Details", then one row, "Sent: Sep 2, 2026 at 14:07:31". No View Path row, no Repeat Details row, no Network View row. Behind the sheet, under the same bubble, sits a card reading "No repeats heard" with "Send Again" and "Send at 500mW".
- why it fails: This is the exact case the user opens the sheet for — "did it get out?" — and it is the one state where the sheet is completely mute. Absence of rows is indistinguishable from the app not having the feature: nothing says "no repeater echoed this yet", nothing says the observer lookup is unavailable because there is no packet identity to look up. The chat timeline already made the negative claim in words; the sheet, which is the detail surface, refuses to repeat it.
- evidence: canShowRepeatDetails = message.isOutgoing && message.heardRepeats > 0 (MessageActionAvailability.swift:32) and canViewPacketScope = packetScopeEnabled && message.packetContentHash != nil (:36); the content hash for an outgoing message is stamped only by a correlated echo (HeardRepeatsService.swift:113-133), the same event that increments the counter — so zero repeats deterministically means zero of all three rows. The details block then renders only the caption (ActionsDetailsSection.swift:54-59) and "Sent:" (:243-245). The retry card is a sibling of the bubble (UnifiedMessageBubble.swift:121-130) and never appears in the sheet.
- direction: The evidence block must have a stated empty state for an outgoing channel send — one line that says no repeater echo has been heard yet and what that does and does not mean — instead of collapsing to nothing.

### F036 [P0] Local evidence and observer evidence for the same packet can never be seen together or compared

- where: MC1/Views/Chats/Reactions/MessageActionAvailability.swift:36 · cross-screen
- what the user sees: For an outgoing channel message the sheet shows "Network View" and "Repeat Details" together, always — Network View only exists for an outgoing message because a heard echo stamped the content hash. Each opens a separate full-screen cover with its own vocabulary. Neither mentions the other. To compare, the operator taps Done, lands back in the sheet, and taps the other row.
- why it fails: "Did it get out, how far, through what" needs both halves: the echo proves the uplink from here worked (something no listening can establish), the observers prove reach beyond the phone's own earshot. Split across two covers with different headline units, different pin colours and different hop vocabularies, the operator has to hold both in their head and is given no hint they describe one transmission.
- evidence: MessageActionAvailability.swift:32 (canShowRepeatDetails) and :36 (canViewPacketScope) are independent gates. HeardRepeatsService.swift:110-137: the same accepted echo writes the MessageRepeat row, stamps packetContentHash, and increments heardRepeats — the causal chain that makes the lookup possible. PacketScopeDetailView.swift:1388-1399 builds coverage without heardRepeats or MessageRepeatDTO anywhere in its 1665 lines.
- direction: One destination for "what happened to this message", with local evidence and observer evidence as two labelled layers of a single answer rather than two sibling covers reached from two sibling rows.

### F038 [P0] The Network View never draws the user's own radio for an incoming message

- where: MC1/Views/Chats/Components/PacketScopeCoverageMap.swift:178 · network-view
- what the user sees: Opening Network View on a received message gives a map with a blue "A" pin on the sender (only when the sender resolves to exactly one located contact), cyan repeater pins, and green "B" pins for observer stations. There is no pin, no label and no line for the user's own radio anywhere on the screen.
- why it fails: For a received message the operator's question is "how did it reach me, from where". Arriving from View Path — where the same message drew a green "B" pin carrying their node name with the route terminating in it — they read the Network View as the same map minus their own reception, i.e. as evidence their radio was not involved. Nothing on screen says the observer network simply has no opinion about them. The only "you" available is MapLibre's user puck, and only if location is already authorised.
- evidence: PacketScopeCoverageMap.swift:178-186 — origin is the phone only when message.isOutgoing, otherwise MessagePathViewModel.locatedSender; no receiver node is appended anywhere in build(). PacketScopeCoverageMap.swift:310-322 makes .pointB an observer. Contrast MessagePathMapView.swift:258-268, where .pointB is this device. MessagePathMapView.swift:742 gates the user puck on existing authorisation.
- direction: Draw the phone on every message map with a role that never changes, or state explicitly on the incoming case that the operator's own reception is not part of this evidence.

### F086 [P0] The repeats map colours and labels the return leg, so a strong signal reads as "this repeater heard me well"

- where: MC1/Views/Chats/Components/MessagePathMapView.swift:518 · repeats-map
- what the user sees: A loop from a green "B" pin (them) out to a repeater and back, with the closing leg drawn in green/yellow/red and a badge reading "1.2 km · 6.2 dB". No legend, no direction arrows, no VoiceOver description of the map at all.
- why it fails: The SNR that colours that leg is what THIS radio measured receiving the repeater's rebroadcast — the repeater→phone direction. It says nothing about how well the repeater heard the phone. An operator riding around and using these colours to pick a transmit spot or judge an antenna is reading the downlink and acting on the uplink. The codebase itself is explicit about the distinction and files the value as the repeater's rxSnr, reserving txSnr for "they told us how well they heard us"; the map does not carry that distinction to the screen. The outbound half of the loop is drawn in neutral .messagePath style, so the coloured half is the visually dominant one.
- evidence: MessagePathMapView.swift:518 styles the reception leg `leg.snr != nil ? .forSNR(leg.snr) : .messagePath` and :541 attaches `MapLine.snrBadgeText(distance:snr:)`; the outbound body at :469-471 and :486-488 is always `.messagePath`. SignalMapperCaptureEngine.swift:16-19: "The SNR on the echo is what we measured of the repeater's rebroadcast, so it lands as the repeater's rxSnr; txSnr stays reserved for 'they told us how well they heard us'." HeardRepeatsMapView.swift:86-95 builds MessagePathMapCanvas with no accessibilitySummary and no legend.
- direction: Label the measured leg on the map and in the row as a reception of the echo (direction stated), and stop letting a single unlabelled colour stand for link quality in both directions.

### F087 [P0] "The packet never reached the observer network" is asserted while the screen is still polling for it

- where: MC1/Views/Chats/Components/PacketScopeDetailView.swift:573 · network-view
- what the user sees: Open Network View seconds after sending: a `waveform.slash` row reading "No observer heard this packet", footed by "The packet never reached the observer network — it may still have been delivered on the mesh." No spinner, no "still arriving", no indication the app is going to keep asking.
- why it fails: The empty state renders the moment the FIRST fetch returns an empty array, while the live loop keeps re-querying every 6 s for up to 180 s precisely because observers take seconds to ingest. The screen's own liveness word ("still arriving") lives only in `summaryLine`, which is rendered in the map-layout panel header — and an unheard packet is never plottable, so it always lands in the list layout, where that word does not exist. The user is handed a flat, past-tense negative about the one question they opened the screen to answer, at the exact moment it is least likely to be true.
- evidence: PacketScopeDetailView.swift:573-583 renders the notObserved/notObservedFooter branch as soon as `receptions` is non-nil and empty; PacketScopeFold.summary(from: []) returns a valid summary (PacketScopeService.swift:191-198), so the branch is reachable on the first poll. liveRefreshLoop keeps polling at :1533-1554 (6 s interval, 180 s window). summaryLine with `stillArriving` is only rendered in panelHeader at :378-384, and listContent's empty branch shows no liveness at all. Localizable.strings:828-829.
- direction: While the live loop is running, an empty result is "nothing yet" with a visible poll indicator; only when the loop has stopped may the screen state a negative, and it should say what kind of negative (settled vs gave up).

### F088 [P0] A retried message's Network View reports an obsolete attempt forever, and the footer misattributes which one

- where: MC1/Views/Chats/Components/PacketScopeDetailView.swift:393 · network-view
- what the user sees: After tapping "Send Again" (from the sheet or from the "No repeats heard" card) the bubble gains a "2x" chip and the sheet's "Heard: N repeats" row and Repeat Details disappear — but Network View still opens and still shows a full observer list, with a caption reading "Sent 2 times; each attempt is a separate packet. This shows the one an observer heard first."
- why it fails: Two separate lies. (a) The resend wipes heardRepeats and deletes the repeat rows but never clears packetContentHash, and the stamping write is first-writer-wins, so the hash keeps identifying the FIRST attempt that ever produced an echo. The coverage on screen therefore describes a packet the user has already superseded, sitting beside a bubble that says the message was sent twice. (b) The caption blames observers for the selection. Observers had nothing to do with it: the attempt whose hash got stamped is the one whose echo THIS PHONE demodulated first. In the common flow — attempt 1 gets no echo, the card prompts a resend, attempt 2 echoes — the hash is attempt 2's, and the caption's claim is simply wrong.
- evidence: MessageService+SendChannel.swift:268-271 clears heardRepeats and deletes repeats on resend, with no write to packetContentHash. PersistenceStore+Messages.swift:822-833 `setMessagePacketContentHashIfMissing` writes only when the column is nil. HeardRepeatsService.swift:113-133 does the stamping from a heard echo. PacketScopeDetailView.swift:392-396 renders `retriedFooter`, Localizable.strings:848.
- direction: Clear the content hash on resend so a superseded attempt has nothing to look up, and reword the caption to name what actually selected the packet (the first echo this radio heard).

### F004 [P1] "Repeat Details" reads as "details about resending", three rows below "Send Again"

- where: MC1/Views/Chats/Reactions/Sections/ActionsDetailsSection.swift:186 · sheet
- what the user sees: For an outgoing channel message the sheet reads, top to bottom with no divider between them: Copy · Translate · Send Again · [Network View ›] · Repeat Details ›. The bubble behind it carries a ⟳ glyph and a number, and if no echo arrived the card under the bubble says "No repeats heard" with a "Send Again" button.
- why it fails: To a rider, "repeat" means "send it again" — the app itself trains that reading three rows above and on the retry card. Nothing on the row hints it is about repeaters relaying the packet. A user who wants to know "did it get out" scrolls past the one row that answers it, believing it is retry bookkeeping.
- evidence: Row label `chats.message.action.repeatDetails` = "Repeat Details" (Chats.strings:610) at ActionsDetailsSection.swift:186 with icon `arrow.triangle.branch`. "Send Again" (`chats.message.action.sendAgain`) at ActionsButtonsSection.swift:43. MessageActionsSheet.swift:64-68 places ActionsDetailsSection immediately after ActionsButtonsSection with no Divider. Bubble chip uses SF Symbol "repeat" (BubbleFooterRow.swift:227). NoRepeatsRetryCard.swift:22/32 pairs "No repeats heard" with a "Send Again" button.
- direction: Name the row by the question — "Which repeaters relayed this" / "Heard back from 3 repeaters" — and reserve the words "repeat"/"again" for the resend action.

### F005 [P1] "Network View" names nothing, and the same feature carries four different names across the surfaces one user touches

- where: MC1/Views/Chats/Reactions/Sections/ActionsDetailsSection.swift:120 · sheet
- what the user sees: A row reading "Network View ›" with a radio-waves icon, sitting between two other rows that are also about the network. If the feature is off, tapping the equivalent path yields "Packet Scope is turned off in Settings." In Settings the section is headed "Packet Scope" and the switch is labelled "Look Up Message Coverage".
- why it fails: "Network View" is a noun phrase with no verb and no object: before tapping, the rider cannot tell whether it shows their mesh, their repeaters, their phone's internet, or this message. And a user who wants to enable or disable it must guess that "Network View", "Packet Scope" and "Look Up Message Coverage" are one thing — the error message names a control that does not exist under that name anywhere they have been.
- evidence: `chats.message.action.networkView` = "Network View" (Chats.strings:1341) at ActionsDetailsSection.swift:120; `packetScope.title` = "Network View" (Localizable.strings:824) at PacketScopeDetailView.swift:191; `packetScope.header` = "Packet Scope" and `packetScope.toggle` = "Look Up Message Coverage" (Settings.strings:1914-1915) at PacketScopeSettingsSection.swift:21/40; `packetScope.error.disabled` = "Packet Scope is turned off in Settings." (Localizable.strings:833). The Settings footer (Settings.strings:1917) additionally names the row "Network View" in prose.
- direction: Pick one user-facing name phrased as the question it answers and use it identically on the row, the screen title, the Settings section, the toggle and the error.

### F007 [P1] The three evidence rows have no group header and read as more actions; the "Details" caption that would name them sits underneath

- where: MC1/Views/Chats/Reactions/Sections/ActionsDetailsSection.swift:54 · sheet
- what the user sees: One unbroken column of tappable rows in identical padding and identical primary-tinted Labels: Reply · Send DM · Copy · Translate · Send Again · View Path · Network View · Repeat Details. Only then does a small grey "Details" caption appear, over the non-tappable Sent/Hops/SNR rows.
- why it fails: Nothing groups the three evidence destinations or tells the rider they answer a different kind of question from Copy and Translate. The one label that would have grouped them ("Details") is emitted after them, so it visually claims only the read-only rows and leaves the destinations orphaned in the action list.
- evidence: ActionsDetailsSection.swift:30-52 emits the three rows; `Text(L10n.Chats.Chats.Message.Action.details)` ("Details", Chats.strings:675) is emitted afterwards at :54-59. Row chrome is the same `.padding().contentShape(.rect)` + `.foregroundStyle(.primary)` as ActionButton.swift:9-19. MessageActionsSheet.swift:64-68 renders the two sections back to back with no Divider (contrast ActionsDestructiveSection.swift, which draws its own).
- direction: Put the evidence rows in their own section under a header that states the question ("What happened to this message"), visually separated from the action list.

### F008 [P1] The same green "B" pin means "you" on one map and "a stranger's station" on the map one row away

- where: MC1/Views/Chats/Components/MessagePathMapView.swift:370 · cross-screen
- what the user sees: For one outgoing channel message: Repeat Details → View on Map draws the rider's own transmit position as a green teardrop lettered "B". Backing out and tapping Network View draws that same physical spot as a blue teardrop lettered "A", and puts nine third-party internet stations under green "B" teardrops.
- why it fails: The rider has to relearn the pin alphabet between two screens reachable from adjacent rows of the same sheet, and the letter they were taught means "me" now means "not me". There is no legend on either map. Worse, the letters are borrowed from the line-of-sight tool where A/B are two ends of a link, so "B" reads as destination on the one screen where the user is the source.
- evidence: MessagePathMapView.swift:370 sets `pinStyle: .pointB` for the heard-repeats origin (the phone). PacketScopeCoverageMap.swift:195 sets `pinStyle: .pointA` for the Network View origin (the phone, for an outgoing message) and :315 sets `.pointB` for every observer. Sprites: PinSpriteRenderer.swift:189-192 — `pin-point-a` is systemBlue with text "A", `pin-point-b` is systemGreen with text "B".
- direction: Introduce one dedicated "your radio" pin used identically on all three maps, and stop borrowing the A/B line-of-sight sprites for anything that is not a two-ended link.

### F010 [P1] For a received message the only evidence row is Network View, and its map contains no pin for the user and no repeater names

- where: MC1/Views/Chats/Reactions/MessageActionAvailability.swift:36 · network-view
- what the user sees: On an incoming direct-routed DM with the feature on, the sheet offers exactly one destination: "Network View ›". It opens onto a map whose origin pin is the *sender*, whose other pins are third-party stations, with the rider's own radio nowhere on it — and every hop pill reads "<unknown>" or a bare hex token, permanently.
- why it fails: The rider's question for a received message is "how did this reach *me*, from where". The single row on offer answers "how did it reach nine strangers", with the strangers' repeaters unnamed. Nothing on the row or the screen signals that this is a different journey from the one that delivered the message.
- evidence: MessageActionAvailability.swift:36 `canViewPacketScope = packetScopeEnabled && message.packetContentHash != nil` is direction-agnostic, while :33-35 `canViewPath` requires a non-empty path, so a direct-routed DM gets Network View and nothing else. PacketScopeCoverageMap.swift:182-195 pins the sender as origin for an incoming message; the phone is never a receiver pin. MessageActionsSheet.swift:102/127 preloads `pathViewModel` only on the `canShowRepeatDetails` and `canViewPath` branches — neither fires here — so `pathViewModel.isLoading` stays at its initial `true` (MessagePathViewModel.swift:12) and PacketScopeDetailView's recovery hook `.onChange(of: pathViewModel.isLoading)` (PacketScopeDetailView.swift:215-217) never runs.
- direction: For an incoming message either place the phone's own reception in the same frame as the observers' copies, or title the screen so it plainly describes other stations' copies — and load the resolver on this branch too.

### F011 [P1] The bubble advertises none of this: the sole pre-tap cue is an unlabelled loop glyph and a bare number

- where: MC1/Views/Chats/Components/BubbleFooterRow.swift:67 · bubble-footer
- what the user sees: On an outgoing channel message, a tiny capsule with the ⟳ symbol and "3". On everything else — including every message that has a Network View or a View Path — nothing at all, because the hop, path and region chips are off by default.
- why it fails: There is no affordance telling the rider that a 0.6 s hold reveals propagation evidence, and the one visible cue is the iOS loop/replay glyph with no unit, which reads as "sent 3 times" rather than "3 repeaters relayed it". A rider who never long-presses never discovers either system, which is the ground state the redesign has to fix before the labels matter.
- evidence: BubbleFooterRow.swift:67 appends `BubbleRepeatFooter(count: footer.heardRepeats, …)`; :227 draws `Image(systemName: "repeat")` plus the bare count, outgoing only. Defaults `defaultShowIncomingPath`/`defaultShowIncomingHopCount`/`defaultShowIncomingRegion` are all `false` (AppStorageKey.swift:90-92). An always-on coverage chip was deliberately deferred for privacy (docs/PACKET_SCOPE.md:354-358), so nothing hints at Network View by design.
- direction: Give the bubble one honest, tappable propagation cue that names what it counts and leads into the evidence group, rather than a bare glyph plus an integer.

### F022 [P1] Nothing in the sheet says Network View is an internet lookup while the other two rows are free, local and offline

- where: MC1/Views/Chats/Reactions/Sections/ActionsDetailsSection.swift:114 · sheet
- what the user sees: "Network View" with a radio-waves glyph, styled exactly like "View Path" and "Repeat Details". Nothing on the row mentions a server, the internet, or that the packet's identifier leaves the phone. The one sentence that explains it lives in Settings, on a screen the user is not on.
- why it fails: An operator riding around on a mesh cares intensely about the difference between "my radio measured this" and "a website told me this", and about whether a tap will work with no cell signal. The row's presentation collapses that distinction to zero. It also makes the privacy disclosure structurally unreachable at the moment of the decision: consent was given once in Settings, but the row that spends it looks like the two rows that cost nothing.
- evidence: networkViewButton is a plain Label + chevron with no subtitle (ActionsDetailsSection.swift:114-133); the doc comment at :110-113 states the fetch is deliberately deferred to the presented screen so the row itself makes no request, but no user-visible text carries that. The only prose is the Settings footer, "Adds a Network View to a message's actions … sends that packet's identifier (never its content) to the server below over your phone's internet connection" (en.lproj/Settings.strings:1918).
- direction: The remote entry needs a visible mark of its own kind — a short subtitle or a distinct grouping that says this one asks a server — so local and remote evidence are never mistaken for each other.

### F025 [P1] An outgoing DM can never show any propagation evidence, and the sheet gives no way to tell that from "nothing happened"

- where: MC1/Views/Chats/Reactions/MessageActionAvailability.swift:32 · sheet
- what the user sees: Long-press a DM you sent: "Details", "Sent: …", sometimes "Round trip: 812ms". No evidence rows, ever, on any DM, with Packet Scope on or off.
- why it fails: A DM is structurally excluded — echoes are only correlated for channel frames, and no content hash is ever stamped for an outgoing DM — but the sheet renders that permanent exclusion with the identical empty block it renders for a channel message that genuinely got nothing. The user learns the wrong rule: they will conclude the feature is broken, or (worse) that their DM had no reach, when the app simply never collects that evidence for DMs. The demo data actively teaches the wrong thing by seeding heardRepeats on DMs.
- evidence: canShowRepeatDetails requires isOutgoing && heardRepeats > 0 and HeardRepeatsService only correlates .groupText frames (HeardRepeatsService.swift:64), so a DM's counter is permanently 0; canViewPacketScope requires packetContentHash != nil (MessageActionAvailability.swift:36) which for outgoing messages arrives only via an echo (HeardRepeatsService.swift:113-133). Simulator data contradicts this with heardRepeats: 1 and 3 on DMs (MockDataProvider+DMMessages.swift:54, :264-276).
- direction: Distinguish "no evidence yet" from "this message kind never produces evidence" — a one-line explanation on the excluded kinds, not an empty block.

### F028 [P1] The disclosure expands inside a sheet that cannot grow, and the scroll it triggers lands below the row it just revealed

- where: MC1/Views/Chats/Reactions/MessageActionsSheet.swift:93 · sheet
- what the user sees: At the half-height detent, tapping "Repeat Details" does not enlarge the sheet. The content scrolls instead, landing on the first repeat row — so the "View on Map" row that was just inserted above it has already scrolled out of sight. The repeat rows, the "Details" caption, the info rows and the red "Delete" row now compete for the same half screen.
- why it fails: An inline disclosure only works if the container can make room. Here the container is fixed and the compensating scroll actively hides the newly-revealed destination, so the interaction reads as "the app jumped somewhere" rather than "this opened". The shipped user guide even promises the opposite behaviour.
- evidence: presentationDetents([.medium, .large]) with no selection: binding and presentationContentInteraction(.scrolls) (MessageActionsSheet.swift:93-97); the expansion handler only calls proxy.scrollTo("expandedContent", anchor: .top) (:84-90); that id is attached to RepeatDetailsContent (ActionsDetailsSection.swift:233), which is emitted after the View on Map row (:209-224). docs/User_Guide.md:82 claims "Expanding a detail section automatically grows the sheet for readability."
- direction: Either let the sheet promote its detent when evidence expands, or stop expanding in place and make the entry a destination like its siblings.

### F029 [P1] At the medium detent the entire evidence block starts below the fold, behind Copy and Translate, with no signal that it exists

- where: MC1/Views/Chats/Reactions/MessageActionsSheet.swift:64 · sheet
- what the user sees: Long-press an incoming channel message on a phone: the sheet opens at half height showing the message preview, the emoji row, then "Reply", "Send DM", "Copy", "Translate". "View Path" is at the very bottom edge or past it; "Network View", the "Details" caption and every info row are off-screen. Nothing indicates there is more than clipboard actions below.
- why it fails: The sheet's first screenful is entirely composing actions, and every answer to "what did this message do" is below them. A user who does not habitually drag the sheet up will never learn the evidence exists — which is a plausible reading of why the owner experiences the two systems as hidden and confusing rather than merely duplicated.
- evidence: Section order in the scroll: ActionsButtonsSection then ActionsDetailsSection then ActionsDestructiveSection (MessageActionsSheet.swift:64-81); ActionsButtonsSection emits up to four full-padding rows before any evidence row (ActionsButtonsSection.swift:11-47). Detents are [.medium, .large] on compact width with no programmatic promotion (MessageActionsSheet.swift:93-96).
- direction: The evidence a user long-pressed to find should be above the fold at the default detent — either ahead of the composing actions or summarised in the header.

### F041 [P1] Three headlines in three shapes, and none of them answers the operator's question

- where: MC1/Views/Chats/Components/MessagePathDetailView.swift:50 · cross-screen
- what the user sees: Path: a toolbar capsule "3 hops • 2.3 mi" that replaces the navigation title entirely whenever anything plots. Repeats map: "Heard: 3 repeats". Network View: "Heard by 9" plus a monospaced dot-joined line "best 12.2 dB · shortest 2 hops · farthest ≥ 23 mi · 4 heard directly · settled in 1.4 s".
- why it fails: One headline is a geometry measurement, one is a raw count, one is five simultaneous extremes. None states the plain-language conclusion the operator opened the screen for — did it get out, how far, or how did it reach me. Their three different shapes make three answers to one question read as three unrelated tools.
- evidence: MessagePathDetailView.swift:48-55 with PathDistanceBanner.swift:13-21 (a .principal item, so it replaces the title). HeardRepeatsMapView.swift:114-125. PacketScopeDetailView.swift:370-403 and :884-916.
- direction: Give all three the same one-sentence conclusion slot in the same position, with the supporting figures beneath it in the same order.

### F042 [P1] "Distance" means three different measurements rendered in identical typography

- where: MC1/Views/Chats/Components/MessagePathDetailView.swift:52 · cross-screen
- what the user sees: Path banner "2.3 mi" = the summed length of the drawn polyline sender → hops → you. Repeats map badges "1.2 km · 6.2 dB" = the straight-line length of one echo's reception leg. Network View "farthest ≥ 23 mi" = the straight-line radius from the origin to the most distant observer, and in a route focus "1.2 mi drawn" = the summed length of that route's drawn segments. All are abbreviated road-usage Measurements in the same weight.
- why it fails: "How far did it get" is the operator's real question, and the app answers it with four incompatible quantities that look identical, on three screens one tap apart. The path banner additionally reports a partial route as if complete, while the Reply-with-Route text derived from the very same nodes marks that number "≥".
- evidence: MessagePathDetailView.swift:52 (banner, plain) against :211-217 (same figure, "≥ "-prefixed when locatedHops < message.hopCount). MapLine+SNR.swift:22-27. PacketScopeCoverageMap.swift:248-251 (straight-line origin→observer). PacketScopeDetailView.swift:895-901 and :1251-1258.
- direction: Pick one distance definition per claim, label it inside the figure ("2.3 mi along the route", "23 mi from you"), and apply the lower-bound rule everywhere it is true rather than only on the wire.

### F045 [P1] Loading, empty and error use three different shapes, and the Network View's map layout has none of them

- where: MC1/Views/Chats/Components/PacketScopeDetailView.swift:329 · cross-screen
- what the user sees: Path and Repeats: a bare full-screen ProgressView with no text while contacts load, then — when nothing plots — a headerless list with no explanation of why there is no map. Network View: a List row with a spinner and "Checking observers…", a waveform.slash "No observer heard this packet" with an explanatory footer, and an error Label — but all three live only in the list layout. Once a map is on screen, three consecutive failed polls end the loop silently and the header keeps saying "still arriving" until the loop's defer clears it.
- why it fails: The one screen whose data can genuinely fail — a network lookup over the phone's internet connection — is the one that hides failure the moment it has something to draw. The two screens that cannot fail present their normal loading case as an unlabelled spinner, and present "nothing could be placed" as a layout change with no words at all.
- evidence: MessagePathDetailView.swift:92-103; HeardRepeatsMapView.swift:72-84 (no placard in either fallback). PacketScopeDetailView.swift:329-336 (listContent only in the non-plottable branch), :564-616, :1507-1512 (errorText assigned only when receptions == nil), :906-907 ("still arriving" driven by isLive).
- direction: One state vocabulary for all three (checking / nothing to show / could not check), rendered inside the panel so it survives the map layout.

### F046 [P1] Only the remote screen is live; the two local screens are frozen snapshots with no refresh anywhere

- where: MC1/Views/Chats/Reactions/Sections/ActionsDetailsSection.swift:89 · cross-screen
- what the user sees: Network View has a persistent Refresh control in the top-left, polls every 6 s for three minutes, animates arriving links and legs, and chips each new observer "New" for 20 s. Repeat Details and its map show whatever the sheet's one-shot fetch returned at open; there is no refresh control on either, and the list never grows while the repeat chip on the bubble behind the sheet keeps climbing.
- why it fails: Echoes arrive over several seconds — precisely the window in which an operator opens Repeat Details right after sending. They watch a static list and a static map while the very number that sent them there is still moving, with no control that would reconcile it.
- evidence: ActionsDetailsSection.swift:86-92 hands HeardRepeatsMapView `repeats ?? []` as a value snapshot; MessageActionsSheet.swift:101-130 fetches once with no subscription to HeardRepeatsService.events(); HeardRepeatsService.swift:153-172 (refreshRepeats only re-reads stored rows despite its doc comment). PacketScopeDetailView.swift:194-196, :202, :1534-1555.
- direction: Subscribe the repeats list and map to HeardRepeatEvent the way the bubble chip already is, and give all three screens the same liveness affordance and the same "still arriving / settled" wording.

### F047 [P1] Two of the three maps drop unplottable hops silently; the third explains every gap before you tap

- where: MC1/Views/Chats/Components/MessagePathContent.swift:41 · cross-screen
- what the user sees: Network View marks every route "can be drawn" or "cannot" with mappin.and.ellipse / mappin.slash before the tap, dashes the capsule border of an unplaced hop pill, adds a "+2 hops not on the map" chip, and states "This route can't be drawn on the map". Path and Repeats render every hop row identically whether or not it pinned; the polyline simply jumps over the missing ones, and the path banner then reports the shortened distance with no qualifier.
- why it fails: A four-row hop list over a three-pin map with a confident "2.3 mi" reads as a complete route. The operator has no way to know which row was dropped, or why, or that the distance understates the journey — and the app already knows how to say it, because the "≥" rule for exactly this case lives thirty lines away in the same file, used only for the text sent over the air.
- evidence: MessagePathContent.swift:41-53 (identical rendering regardless of plottability); MessagePathMapView.swift:229-234 (hops skipped silently). MessagePathDetailView.swift:52 (plain distance) vs :211-217 ("≥" for the wire text). PacketScopeDetailView.swift:767-773, :797-799, :840-853, :1269-1271.
- direction: Port the Network View's drawability marks and lower-bound rule onto the path and repeats lists — a hop named but not on the map should say so wherever it is named.

### F048 [P1] None of the three destinations says which message it is about, or whether it was sent or received

- where: MC1/Views/Chats/Components/PacketScopeDetailView.swift:370 · cross-screen
- what the user sees: The actions sheet header shows the sender, the time and a line of the message text; all three full-screen covers drop it. The Network View's panel header is "Heard by N" plus figures and a breadcrumb — the same screen and the same words mean "these stations heard what you sent" for an outgoing message and "these stations also heard what someone sent you" for an incoming one.
- why it fails: A full-screen cover with no message context, opened from a sheet the operator can no longer see, forces them to remember which bubble they long-pressed. On the Network View they must additionally infer the direction of the message from whether the blue A pin happens to be on their own position — an inference the incoming case denies them entirely, since no "you" pin exists.
- evidence: PacketScopeDetailView.swift:370-403 (header carries no direction and no message reference; message.isOutgoing is read only for the origin pin and the GPS request at :208 and inside PacketScopeCoverageMap.swift:179). MessagePathDetailView.swift:137-171 (panel header is raw hex + copy + Reply with Route). HeardRepeatsMapView.swift:114-125.
- direction: Carry a one-line message identity — direction, counterpart, time, text snippet — into all three destination headers, in the same slot.

### F057 [P1] An outgoing DM's sheet says nothing about where it went, and its one delivery fact is printed as a latency figure

- where: MC1/Views/Chats/Reactions/Sections/ActionsDetailsSection.swift:247 · sheet
- what the user sees: Long-press a DM you sent. The whole details block is: the caption "Details", then "Sent: 2 Sep 2026 at 14:22:07", and — if the recipient ACKed — "Round trip: 341ms". No path row, no repeats row, no Network View row, whether Packet Scope is on or off.
- why it fails: The user's question for a sent message is "did it get out". The sheet's answer is a send timestamp, which is true even for a message that failed. The app actually holds the proof — `roundTripTime` is written only when the ACK lands and the status flips to `.delivered` — and prints it under an engineering label that reads as a performance statistic, never as "the other radio confirmed it". Meanwhile the three structurally impossible rows leave no trace, so the user cannot tell "this message type has no propagation evidence" from "this message had none".
- evidence: ActionsOutgoingDetailsRows renders exactly three optional rows and no status (ActionsDetailsSection.swift:239-257). `roundTripTime` is set only alongside `.delivered` (MessageService.swift:200-214; PersistenceStore+Messages.swift:511-523). Repeats are impossible for a DM: `processForRepeats` requires `payloadType == .groupText` (HeardRepeatsService.swift:64) and a non-nil channelIndex (:67). `canViewPath` requires `!isOutgoing` (MessageActionAvailability.swift:33). `packetContentHash` for an outgoing message is stamped only from a correlated echo (HeardRepeatsService.swift:113-133), so `canViewPacketScope` is false too (:36). Note the room sheet, by contrast, does print `message.localizedStatusText` (RoomMessageActionsSheet.swift:129, :137).
- direction: Put the send outcome in the details block as its own row in the user's words (delivered / sent, no confirmation possible / failed), and state the impossible-evidence cases rather than omitting them.

### F061 [P1] Losing internet mid-poll makes Network View announce that coverage has "settled"

- where: MC1/Views/Chats/Components/PacketScopeDetailView.swift:906 · network-view
- what the user sees: The panel header reads "Heard by 4 · best 8.2 dB · shortest 2 hops · still arriving". The phone drops off the network. After three backed-off failures the line changes to "… · settled in 1.4 s" and stays there. The map, the pins and the Refresh glyph are unchanged; nothing anywhere says a request failed.
- why it fails: "Settled" is the screen's word for "coverage is final — this is everything that heard it". It is being produced by the failure path. A rider who steps out of cell coverage while watching a message propagate is told, in the app's own confident vocabulary, that four observers is the final answer.
- evidence: `liveRefreshLoop` exits when `consecutiveFailures >= failuresBeforeStopping` and its `defer { isLive = false }` fires (PacketScopeDetailView.swift:1534-1554); `summaryLine` then falls to `settledIn`/`settled` purely on `isLive` (:906-914). `refresh`'s catch sets `errorText` only when `receptions == nil` (:1507-1513), and the error/empty/loading rows live in `listContent`, which renders only in the non-plottable branch (:329-336) — so once a map is drawn there is no failure surface at all.
- direction: Separate "stopped because coverage settled" from "stopped because the lookups failed", and give the map layout a visible degraded/last-updated state.

### F062 [P1] A message received while the app was closed pins "you" on the path map wherever you are standing now

- where: MC1Services/Sources/MC1Services/Sync/SyncCoordinator+MessageHandlers.swift:184 · path-screen
- what the user sees: View Path on a message that drained from the radio's backlog: the map draws sender → repeaters → a B pin at the user's current position, with a coloured last leg and a toolbar banner reading e.g. "3 hops • 12.4 mi". Reply with Route then shares that same distance over the air.
- why it fails: The screen presents itself as a record of a reception ("how this message reached me, and from where") but the receiver end is today's GPS, not the reception's. A rider who has driven 30 km since the message arrived reads a route and a distance that were never traversed — and transmits the fabricated figure to the sender. Nothing distinguishes a recorded fix from a live one on screen.
- evidence: `userFix` is stamped only for `.live` deliveries with an uncorrected clock, bounded transit, and a fresh valid fix (SyncCoordinator+MessageHandlers.swift:170-189) — a backlog drain gets nil (:174-176). `MessagePathMapView.receiverReference` then falls back to `appState.bestAvailableLocation`, and MessagePathDetailView.swift:61-71 actively requests a fresh phone fix in exactly that case and rebuilds when it lands (:83-86). The banner distance is `locatedNodes.map(\.coordinate).totalDistance()` over those nodes (:50-53), and `routeDistanceText` reuses the same polyline for the wire string (:211-217).
- direction: Mark the receiver pin and the distance as live-position-derived whenever `userFixCoordinate` is nil, and withhold the distance from the shared route text in that case.

### F064 [P1] The no-repeats card — the only place the app admits an outgoing message may have gone nowhere — is switched off by an unrelated setting

- where: MC1/Views/Chats/ViewModel/ChatViewModel+NoRepeatsRetry.swift:27 · bubble-footer
- what the user sees: With signal bars disabled for the device, a channel message that no repeater relayed produces a bubble with a checkmark and a timestamp, and a long-press sheet reading "Details / Sent: …". A message that propagated to five repeaters produces the same bubble plus a small "5" chip and one extra row. Nothing anywhere says the app stopped watching for repeats.
- why it fails: The user's mental model becomes "no news is good news" on the exact surface where no news is the failure case. And the gate is on a setting about signal-strength display, which has no visible relationship to whether the app tells you your broadcast went unheard.
- evidence: `noteNoRepeatsInput` drops every arming observation unless `signalDataAvailableProvider()` (ChatViewModel+NoRepeatsRetry.swift:26-29), wired to `repeaterSignals.isAttached` (AppState+ChatPrefetch.swift:42). With no arming, no detector window is created and no card can ever appear (:17-21). Repeat *collection* itself is not gated — `processForRepeats` runs from RxLogService regardless (RxLogService.swift:487-491) — so the counter still climbs; only the absence is unreported.
- direction: Decouple the "nothing relayed this" signal from the signal-bars engine, or say plainly on the message surface that repeat watching is off.

### F071 [P1] The sheet's evidence rows are frozen at long-press time, so neither system can appear while you are watching for it

- where: MC1/Views/Chats/Reactions/MessageActionsSheet.swift:15 · sheet
- what the user sees: You send a channel message and long-press it two seconds later to check whether it got out. The sheet has no Repeat Details row and no Network View row — just Copy / Translate / Send Again and a "Sent:" line. Three seconds later two repeaters echo you: the repeat chip on the bubble *behind* the sheet ticks to 2, but the sheet you are staring at never gains either row. You have to dismiss and long-press again to see that anything happened.
- why it fails: The exact moment the operator asks "did it get out" is the moment both evidence systems are still empty, and the sheet is a dead snapshot of that moment. It teaches the user that a fresh message has no propagation data at all, which is the opposite of true — and it is why the two systems feel arbitrary: whether you get one, both or neither depends on how fast you pressed.
- evidence: `availability` is a plain computed property over the captured `MessageDTO` value (MessageActionsSheet.swift:15-17), and the sheet is bound to that captured value (ChatConversationView.swift:311-314). `canShowRepeatDetails = isOutgoing && heardRepeats > 0` and `canViewPacketScope = packetScopeEnabled && packetContentHash != nil` (MessageActionAvailability.swift:32,36) — and the content hash is stamped by the *same* echo that increments the counter (HeardRepeatsService.swift:113-133 immediately precedes :136-141), so before the first echo both rows are absent by construction. Nothing in MessageActionsSheet subscribes to `HeardRepeatsService.events()`; the live path stops at the bubble (MessageEventDispatcher.swift:79-87 → ChatViewModel+EventStream.swift:63-66).
- direction: Drive the sheet from a live observation of the message row (or re-evaluate availability on `heardRepeatRecorded`) so the evidence rows appear when the evidence does, instead of only on the next long-press.

### F075 [P1] With no connected radio the entire outgoing-evidence branch dies silently: permanent spinner, no map row, and an unresolvable Network View

- where: MC1/Views/Chats/Reactions/MessageActionsSheet.swift:103 · sheet
- what the user sees: Browsing your chats with the radio off or mid-reconnect, you long-press an outgoing channel message that shows a "3" repeat chip and expand Repeat Details. You get a spinner that never resolves — no rows, no error, no retry — "View on Map" never appears, and if you tap Network View instead, every repeater in every route reads as four hex characters instead of a name.
- why it fails: Offline browsing is a supported state in this app, and it is exactly when an operator reviews what happened on the ride. All three surfaces degrade differently and none of them says why, so the user concludes the repeat data was lost rather than that the app simply refused to read it.
- evidence: `guard let services = appState.services else { return }` sits *inside* the `canShowRepeatDetails` branch (MessageActionsSheet.swift:102-103); `appState.services` is `connectionManager.services` (AppState.swift:135-137), nil when disconnected, while `offlineDataStore` exists precisely for offline browsing (AppState.swift:182-186). The early return leaves `repeats == nil` → the indefinite `ProgressView()` at RepeatDetailsContent.swift:40-44, leaves the "View on Map" gate false (ActionsDetailsSection.swift:209), and skips `pathViewModel.loadContacts` (:112-115) so `isLoading` keeps its initial `true` (MessagePathViewModel.swift:12) and PacketScopeDetailView's recovery hook never fires (PacketScopeDetailView.swift:215-217).
- direction: Move the services guard so the path preload always runs from `offlineDataStore`, and give the disclosure a real terminal state instead of an unbounded spinner.

### F089 [P1] A DM whose path came from the 30-second prefix fallback shows, maps and transmits a stranger's route

- where: MC1Services/Sources/MC1Services/Sync/SyncCoordinator+HandlerHelpers.swift:63 · path-screen
- what the user sees: An incoming flood-routed DM offers "View Path"; the screen draws a named repeater chain and a distance banner, and "Reply with Route" composes "RX via 80,8F,0C. 3 hops 2.3 mi" into the reply, which the other party's client renders as a Shared Route card.
- why it fails: When the exact-timestamp RxLog correlation misses, the app falls back to matching a SINGLE sender-prefix byte inside a 30-second window with no recipient check — the code's own comment says it can land on "a DM between two other people that this radio merely overheard" or a 1-in-256 collision. That branch deliberately withholds contentHash because the hash leaves the device, calling every other field "cosmetic". pathNodes is not cosmetic once View Path exists: it is presented as the route this message took, drawn on a map with a confident distance, and then put on the air over someone else's DM. The privacy reasoning that fails closed for Network View does not reach the path screen.
- evidence: SyncCoordinator+HandlerHelpers.swift:57-89 (fallback lookup at :63-67, comment and `contentHash: nil` at :71-85, `routeType`/`pathNodes`/`pathLength` returned unguarded). MessageActionAvailability.swift:33-35 offers View Path for any incoming flood-routed message with non-empty pathNodes. MessagePathDetailView.swift:198-217 builds the wire text from those same bytes.
- direction: Mark path data that arrived via the prefix fallback as uncorroborated — at minimum suppress Reply with Route for it, the same fail-closed rule the content hash already gets.

### F090 [P1] "Heard: N repeats" counts echoes, and can mean one repeater, or three, or a chain of three that counts as one

- where: MC1/Views/Chats/Reactions/Sections/ActionsDetailsSection.swift:255 · sheet
- what the user sees: A grey row under "Details" reading "Heard: 3 repeats", and the same figure as a bare `repeat`-glyph chip on the bubble. Expanding Repeat Details shows three rows, each naming one repeater with "1 Hop" / "3 Hops".
- why it fails: N is the number of RX-log entries this radio matched to the message, deduped only by RX-log entry id. One repeater rebroadcasting twice counts 2. Three different repeaters count 3. One echo that reached the phone through a chain of three repeaters counts 1 — and the two intermediate repeaters that actually relayed the message are named nowhere in the list, because the row prints only the tail (the node the radio demodulated). So the headline number is neither a repeater count, nor a hop count, nor a relay count, and the same word "repeats" is used for all three readings. An operator reading "Heard: 3" as "three repeaters picked me up" is drawing exactly the coverage conclusion the number cannot support.
- evidence: ActionsDetailsSection.swift:251-255 prints message.heardRepeats. HeardRepeatsService.swift:83 dedupes on rxLogEntryID alone; :137 increments once per accepted entry. MessageRepeat.swift:133-139 `repeaterHash` is `pathNodes.suffix(hashSize)` — the tail only; :141-145 `hopCount = pathNodes.count / hashSize`. RepeatRowView.swift:17-28 prints only the tail hex, its name and the hop count.
- direction: Report the two facts the data actually supports as separate figures — how many distinct repeaters were heard, and how many echoes arrived — and surface the intermediate hops of a multi-hop echo instead of hiding them behind a hop count.

### F092 [P1] The route's only signal figure describes the last hop, and shows up twice with no hop attribution

- where: MC1/Views/Chats/Components/MessagePathContent.swift:60 · cross-screen
- what the user sees: On the Path screen, a four-row list — Sender / Hop 1 / Hop 2 / Receiver — where only the last row carries signal bars and "SNR 8.5 dB". One tap back, the sheet shows a standalone row "SNR: 8.5 dB (Good)" with no row label at all.
- why it fails: message.snr is a single measurement of the final leg (last repeater → this radio). Presented as the terminal row of a route list with green bars, and again as an unqualified "SNR:" line in a block called Details, it reads as the quality of the route. It is not: the earlier hops carry no measurement anywhere in the app, and a route whose first two legs were marginal shows exactly the same green bar as one that was strong end to end. The same number appearing in two places with two different framings (once attributed to "Receiver", once to nothing) makes it harder, not easier, to work out what it covers.
- evidence: MessagePathContent.swift:47-51 passes `snr: nil` for every intermediate hop; :57-60 passes `snr: message.snr` to the Receiver row. PathHopRowView.swift:60-69 renders bars plus "SNR x.x dB" only for `.receiver`. ActionsDetailsSection.swift:307-314 prints the same value as `SNR: 8.5 dB (Good)` with no icon and no label.
- direction: Name the leg the number measures wherever it appears ("last hop to you"), and stop printing it a second time unlabelled in the Details block.

### F098 [P1] "No repeats heard" delivers a verdict five seconds in, and the one tool that could check is unavailable exactly then

- where: MC1/Views/Chats/Components/NoRepeatsRetryCard.swift:22 · bubble-footer
- what the user sees: Five seconds after a channel send resolves, a card appears under the bubble: "No repeats heard", with "Send Again" and sometimes "Send at 500mW". Long-pressing that same message offers no Network View row.
- why it fails: The card reads as "it didn't get out". It means only that no repeater rebroadcast reached this radio within 5 seconds — a channel broadcast has no ACK, so the app cannot know whether anyone received it, and a repeater that relayed the message away from the user leaves no echo by construction. Worse, the two systems are coupled in the wrong direction: an outgoing message only gains a packetContentHash from a heard echo, so a message with zero repeats has no hash and `canViewPacketScope` is false — the third-party evidence that could actually answer "did it get out" is withheld from the only message where the user is being told it did not. Tapping Send Again then wipes any later-arriving evidence for the original attempt, because the resend rewrites the wire timestamp and deletes the repeat rows.
- evidence: NoRepeatsRetryCard.swift:22 title; ChatNoRepeatsDetector.defaultWindow = .seconds(5); ChatNoRepeatsPolicy.swift:76-79 ".sent is the terminal success state for a channel broadcast (there is no recipient ACK)". MessageActionAvailability.swift:36 `canViewPacketScope = packetScopeEnabled && message.packetContentHash != nil`; HeardRepeatsService.swift:113-133 is the only stamping site for an outgoing message. MessageService+SendChannel.swift:243-249, 268-271.
- direction: Word the card as what it observed ("no repeater echo reached you") rather than a verdict, and break the accidental coupling that makes the observer lookup unavailable on exactly the messages that most need it.

### F006 [P2] Four identical chevrons: three leave the sheet, one expands six lines in place

- where: MC1/Views/Chats/Reactions/Sections/ActionsDetailsSection.swift:190 · sheet
- what the user sees: "View Path ›", "Network View ›" and "Repeat Details ›" render as three rows of identical geometry with an identical trailing `chevron.right`. Two of them take over the entire screen with a full-bleed map; the third rotates its chevron 90° and reveals text rows inside the half-height sheet.
- why it fails: The chevron is the only pre-tap signal about consequence, and it lies for one row in three. On a phone at the medium detent the expansion cannot even grow the sheet, so the rider who expected a screen gets a cramped list competing with the red Delete row, and the rider who expected an expansion loses the sheet.
- evidence: `Image(systemName: "chevron.right")` at ActionsDetailsSection.swift:124 (Network View, fullScreenCover), :147 (View Path, fullScreenCover), :214 (View on Map, fullScreenCover) and :190-191 (Repeat Details, rotated on expand). MessageActionsSheet.swift:93-97 sets `[.medium, .large]` with no selection binding and `.presentationContentInteraction(.scrolls)` at :97, so expanding only scrolls (:84-90).
- direction: Reserve the chevron for destinations; use a disclosure indicator or an inline summary value for anything that expands in place.

### F009 [P2] The user's own radio is called "Me", "You", or nothing at all across one flow

- where: MC1/State/AppState.swift:141 · cross-screen
- what the user sees: With no connected device name, the sheet header names the sender of an outgoing message "Me"; the hop list on the path screen labels the last row "Receiver / You"; the pin for that same radio on the path map carries no label at all; the repeats map origin pin says "You".
- why it fails: Three renderings of one identity inside two taps means the rider cannot confirm that the row, the pin and the header are the same radio — precisely the confirmation the maps exist to provide. "Me" is also a hardcoded English literal, so in a translated build it is the one untranslated word in the header.
- evidence: AppState.swift:140-142 `var localNodeName: String { connectedDevice?.nodeName ?? "Me" }` — an unlocalized literal — feeds the outgoing sender resolution at ChatConversationView.swift:735 and renders at ActionsPreviewHeader.swift:22. MessagePathDetailView.swift:183 passes `appState.connectedDevice?.nodeName ?? L10n.Chats.Chats.Path.Receiver.you` ("You", Chats.strings:946) to the hop list, but :247 passes `appState.connectedDevice?.nodeName` with no fallback to pin B. HeardRepeatsMapView.swift:176 uses the "You" fallback.
- direction: Resolve the local radio's display label once and pass that single value to header, hop rows and every map pin.

### F012 [P2] "Hop" counts three different journeys under near-identical labels, in three different casings

- where: MC1/Views/Chats/Components/RepeatRowView.swift:104 · cross-screen
- what the user sees: Inside one sheet and its destinations: "Hops: 3" in the read-only rows; "Hop 1", "Hop 2" in the path hop list; "2 Hops" under a repeat row; "4 hops" on a Network View route chip and a "3 hops • 2.3 mi" banner over the path map.
- why it fails: A rider reasonably assumes one message has one hop count. It does not: the sheet's number is the repeaters that carried this copy to this radio, the repeat row's is the length of an echo's return chain, and Network View's is the length of a stranger's copy — which may share no repeaters with either. The differing capitalisation makes it look like a typo rather than a different quantity.
- evidence: ActionsDetailsSection.swift:265 `chats.message.info.hops` = "Hops: %@" (Chats.strings:646). PathHopRowView.swift:83 `chats.path.hop.number` = "Hop %d" (Chats.strings:931). RepeatRowView.swift:104 `chats.repeats.hop.singular/plural` = "1 Hop"/"%d Hops" (Chats.strings:992/995). PacketScopeDetailView.swift:709/796 → `routeLength` → `packetScope.hopOne`/`hopCount` = "1 hop"/"%d hops" (Localizable.strings:860/840), with position-numbered pills at :757. PathDistanceBanner.swift:15 `contacts.trace.map.hops` = "%d hops" (Contacts.strings:1041, no singular form).
- direction: Qualify every hop count with whose journey it describes and route all of them through one shared, pluralised formatter.

### F013 [P2] "View on Map" is a full-screen destination hidden inside a disclosure and absent until a fetch returns

- where: MC1/Views/Chats/Reactions/Sections/ActionsDetailsSection.swift:209 · repeats-inline
- what the user sees: Tapping "Repeat Details" shows a spinner, then a list of hex-prefixed rows — and a moment later a "View on Map ›" row materialises above them, pushing the list down under the thumb.
- why it fails: The heard-repeats map is the one surface that actually answers "how far did it get", and it sits two levels deep behind a row whose label promises text metadata, appearing only after an async load. Its two siblings, View Path and Network View, are top-level rows. The rider has no reason to expect a map behind "Repeat Details" and no cue that one exists while the fetch is in flight.
- evidence: ActionsDetailsSection.swift:209 gates the row on `if let onViewMap, repeats?.isEmpty == false`; `repeats` is nil until the sheet's `.task` finishes (MessageActionsSheet.swift:111, :125). The row opens `HeardRepeatsMapView` via the third `fullScreenCover` (:86-92) — structurally identical to the two top-level rows at :137-156 and :114-133.
- direction: Promote the repeats map to a sibling of View Path and Network View so all three evidence destinations sit at one level, and render it disabled rather than absent while loading.

### F014 [P2] The heard-repeats map is titled with the name of the row the user left, not the screen they are on

- where: MC1/Views/Chats/Components/HeardRepeatsMapView.swift:36 · repeats-map
- what the user sees: Expand "Repeat Details", tap "View on Map", and arrive at a full-screen map whose navigation title is "Repeat Details".
- why it fails: The title repeats the breadcrumb instead of naming the destination, so the rider cannot tell whether they navigated or the sheet simply re-rendered — and the map, which is the whole point of the screen, is described by a label about text rows.
- evidence: HeardRepeatsMapView.swift:36 `.navigationTitle(L10n.Chats.Chats.Message.Action.repeatDetails)` — the identical string used for the inline disclosure row at ActionsDetailsSection.swift:186 (Chats.strings:610). Contrast PacketScopeDetailView.swift:191, which at least has its own title string.
- direction: Title each destination with what it shows and from whose vantage, never with the label of the control that opened it.

### F015 [P2] The screen reached from "View Path" is titled "Path", and that title is visible only when the screen has failed

- where: MC1/Views/Chats/Components/MessagePathDetailView.swift:45 · path-screen
- what the user sees: Tapping "View Path" lands on a map whose header reads "3 hops • 2.3 mi" and carries no title at all. The word "Path" appears only while loading, or when nothing could be placed on a map.
- why it fails: The two names for the feature never appear together, so the rider has no confirmation they arrived where they aimed; and the one state that does show a title is the state where the screen has nothing to offer. The banner that replaces it also states a partial distance with no qualifier, while the Reply-with-Route text built from the same nodes marks it "≥".
- evidence: MessagePathDetailView.swift:45 sets `navigationTitle(L10n.Chats.Chats.Path.title)` = "Path" (Chats.strings:908); :48-55 installs `PathDistanceBanner` at `ToolbarItem(placement: .principal)` whenever `locatedNodes` is non-empty, and a principal item replaces the inline title. The banner formats the distance plainly (PathDistanceBanner.swift:16-20) while `routeDistanceText` prefixes "≥ " over the same nodes (MessagePathDetailView.swift:211-217).
- direction: Keep a stable title naming the question the screen answers, move the distance figure into the panel, and carry the "≥" qualifier onto the visible figure too.

### F016 [P2] The same repeater's identity is rendered four ways and its uncertainty marked three ways across two taps

- where: MC1/Views/Chats/Components/PacketScopeDetailView.swift:983 · cross-screen
- what the user sees: One physical repeater appears as "31  Relay-1 ?" on a repeat row, "A37F0C  Relay-1 ?" on a path hop row, and "1 ~Relay-1" inside a truncating capsule on a Network View route pill. When it cannot be resolved it is "<unknown repeater>", "<unknown>", or a four-hex token like "A3F1" depending on the screen.
- why it fails: The rider cannot tell that these are the same node, and the tilde is explained nowhere in the UI — inside a middle-truncating pill it reads as part of the name. The "?" popover that does explain the identical condition is one screen away and never appears on the screen where the marker is most cryptic.
- evidence: PacketScopeDetailView.swift:983 returns `"~\(resolution.displayName)"` for `matchKind == .fallback`; RepeatRowView.swift:24 and PathHopRowView.swift:48-49 render `FallbackMatchIndicatorView` for the same case, carrying "Possible Match — Multiple nodes share this prefix. The displayed name may not be correct." All three call the same `MessagePathViewModel.repeaterResolution` with the same reference location (ActionsDetailsSection.swift:44-49, :100-105). Unresolved fallbacks: `chats.repeats.unknownRepeater`, `chats.path.hop.unknown`, and the server pubkey prefix at PacketScopeDetailView.swift:986-990.
- direction: One uncertainty marker with one explanation, and one repeater-identity component (hash + name + certainty) shared by all three lists.

### F018 [P2] Resending has opposite consequences in the two systems, and the sheet says so in neither place

- where: MC1Services/Sources/MC1Services/Services/MessageService+SendChannel.swift:271 · cross-screen
- what the user sees: Tapping "Send Again" — from the sheet, or from the "No repeats heard" card under the bubble — makes the "Repeat Details" row vanish from the sheet and empties the repeats map. Network View, meanwhile, keeps showing the old attempt's coverage and adds a line: "Sent 3 times; each attempt is a separate packet. This shows the one an observer heard first."
- why it fails: A rider comparing coverage before and after a retry (the whole point of the retry card, especially its power-escalation button) loses the local baseline silently while the remote one persists with a footnote. Nothing on either row warns that the resend destroys evidence on one side and not the other, so the two systems appear to disagree about what just happened.
- evidence: MessageService+SendChannel.swift:269-271 — `incrementMessageSendCount`, `updateMessageHeardRepeats(id:, heardRepeats: 0)`, `deleteMessageRepeats(messageID:)` — plus a fresh wire timestamp at :243-249, after which echoes of the old packet no longer correlate. The Network View side prints `packetScope.retriedFooter` at PacketScopeDetailView.swift:393 and :600. `sendCount` is never surfaced in the sheet at all (ActionsDetailsSection.swift:239-257).
- direction: State the cost of a resend where it is offered (a new packet; the local echo record restarts), and surface the attempt count in the sheet so the two systems tell one story.

### F027 [P2] The repeat count is printed twice inside one scroll view from two independently-written sources, under two different glyphs

- where: MC1/Views/Chats/Reactions/Sections/ActionsDetailsSection.swift:251 · repeats-inline
- what the user sees: With Repeat Details expanded, the sheet shows a list of three repeat rows and then, a few rows below, the line "Heard: 3 repeats". Behind the sheet the bubble carries a "repeat"-glyph chip reading 3. The list is headed by an "arrow.triangle.branch" icon; the bubble chip uses the "repeat" icon.
- why it fails: The same number is stated three times in three visual languages within two taps, and the user has no way to know it is one number rather than three related facts (repeats heard, repeaters reached, times relayed). The two in the sheet come from different writes and can disagree — the counter row can say 3 while the list shows 0. And the icon change between the bubble chip and the sheet row severs the one link that would let the user connect "that little 3 on my message" to "this list".
- evidence: "Heard: %d %@" reads message.heardRepeats (ActionsDetailsSection.swift:251-256); the list length comes from a separate fetch rendered at RepeatDetailsContent.swift:31-38, whose source returns [] on any fetch error (HeardRepeatsService.swift:167-170) while the counter is a separate increment (PersistenceStore+Messages.swift:803-816). Glyphs: "arrow.triangle.branch" at ActionsDetailsSection.swift:187 versus Image(systemName: "repeat") at BubbleFooterRow.swift:225.
- direction: State the count once, at the head of the evidence it summarises, and keep the bubble chip's glyph and the sheet entry's glyph identical so they read as the same fact.

### F031 [P2] The Network View row looks the same whether the answer is nine observers or nothing at all

- where: MC1/Views/Chats/Reactions/MessageActionAvailability.swift:36 · sheet
- what the user sees: A row reading "Network View >". Tapping it replaces the entire screen with a full-screen cover that may say "Checking observers…" and then "No observer heard this packet" — after which the user taps Done to get back to where they were.
- why it fails: The row's presence is decided purely by "the feature is on and this message has a packet identity", never by whether anything was heard. The full-screen cover is therefore spent as often on an empty answer as on a real one, and because it is the same row on a message with rich local evidence and on one with none, it gives no hint of which. The one entry that could tell an operator whether their message travelled beyond earshot is also the one entry that never previews its own answer.
- evidence: canViewPacketScope = packetScopeEnabled && message.packetContentHash != nil (MessageActionAvailability.swift:36) — no observation data participates. The row itself performs no fetch by design (ActionsDetailsSection.swift:110-113), and the empty state lives on the presented screen (packetScope.notObserved, "No observer heard this packet").
- direction: Let the entry carry a value, not just a label — either a cached/pre-fetched count or an explicit "not looked up yet" state — so the cover is only spent when there is something to see.

### F043 [P2] Signal is three different strings for the same physical quantity, with different labels and precision

- where: MC1/Views/Chats/Components/RepeatRowView.swift:39 · cross-screen
- what the user sees: Repeat row trailing column: bars, "SNR 6.2 dB", "RSSI -85 dBm". Path hop list: bars and "SNR 6.2 dB" on the Receiver row only, nothing on any hop. Network View observer row: bars, then a bare "12 dB" with no label; RSSI appears only as "Best RSSI -96 dBm" above an expanded route ladder.
- why it fails: Two screens spell out "SNR" (as hardcoded English literals) and always show one decimal; the third drops the label and shows nought-to-one decimals, so "12 dB" and "6.2 dB" read as different kinds of number. And no screen states which end measured it: on the repeat row it is our radio hearing the repeater's rebroadcast, on the path row it is our radio hearing the last leg, on the Network View it is a stranger's radio hearing a stranger's copy.
- evidence: RepeatRowView.swift:36-45 (literal "SNR "/"RSSI ", MessageRepeat.swift:183-186 fixes one decimal). PathHopRowView.swift:61-69 (literal, receiver row only). PacketScopeDetailView.swift:703-707 with PacketScopeCoverageMap.swift:636-638 (decibels(), fractionLength 0...1, no label) and :729-733.
- direction: One signal component with a fixed label, fixed precision and an explicit measuring subject, shared by all three lists and the map badges.

### F049 [P2] Interactivity is inverted between the screens, and on the Network View bare map background is a control

- where: MC1/Views/Chats/Components/PacketScopeDetailView.swift:305 · cross-screen
- what the user sees: On the path and repeats maps nothing in the panel or on the map responds to a tap except the "?" popover — rows are inert, pins are inert. On the Network View, observer rows, route rows, hop pills, observer pins, SNR badges, breadcrumb crumbs, ‹ › steppers, an ✕, an observers toggle, repeater pins and empty map space all do something; a tap on a repeater pin or on empty map silently removes one level of focus.
- why it fails: Coming from two inert screens, a tap looks free. On the Network View a stray tap while framing a one-handed pan drops the selection the operator just made, and a repeater pin looks like it did nothing while in fact stepping route → observer. Going the other way, a user who learned "tap the row to see it on the map" finds repeat rows and path rows do nothing at all.
- evidence: PacketScopeDetailView.swift:305-322 (onPointTap falls through to popFocus for any non-observer pin; onMapTap: popFocus at :314), :684, :811, :502-511. MessagePathDetailView.swift:106-109 and HeardRepeatsMapView.swift:87-91 construct MessagePathMapCanvas with no onPointTap and no onMapTap.
- direction: Settle one interaction model for message maps — either all three are explorable with the same gestures, or exploration lives in one place — and never let bare map background destroy a selection.

### F050 [P2] Three copy affordances in three positions copying three unrelated artefacts; one screen has none

- where: MC1/Views/Chats/Components/MessagePathDetailView.swift:140 · cross-screen
- what the user sees: Path: an unlabelled doc.on.doc glyph inside the panel header that puts "A3,7F,42" on the clipboard while "A3 → 7F → 42" is displayed 8 pt to its right. Network View: a doc.on.doc glyph in the toolbar that copies a multi-line prose account ("Heard by 9 · best 12.2 dB…" then one line per observer). Repeats map: no copy at all. Done is a bold .confirmationAction on Path and Repeats and a plain button sitting beside Copy on the Network View.
- why it fails: The same glyph in two different places yields two different kinds of artefact, one of which does not match the text printed immediately beside it. And the evidence an operator is most likely to want to hand another operator — which repeaters echoed them and how strongly — is the one thing that cannot be copied or shared at all, while the path (which can) has a bespoke Reply with Route the other two lack.
- evidence: MessagePathDetailView.swift:140-153 (pathStringForClipboard vs the displayed pathString) and :56-58 (.confirmationAction Done). PacketScopeDetailView.swift:197-200 (Done in a plain ToolbarItemGroup beside Copy), :277-291 with PacketScopeFocus.swift:173-203. HeardRepeatsMapView.swift:38-42 (Done only).
- direction: One share/copy control in one toolbar position on all three, producing the same kind of artefact: a readable account of the evidence currently shown.

### F051 [P2] The map's spatial content is unreadable to VoiceOver on two of the three screens

- where: MC1/Views/Chats/Components/HeardRepeatsMapView.swift:87 · cross-screen
- what the user sees: The Network View's map carries a spoken sentence ("Heard by 9. best 12.2 dB · …") and announces every focus change. The path and repeats maps pass no accessibilitySummary, so the canvas reads as nothing and the floating panel list is the entire content.
- why it fails: On the repeats map the panel rows never state distance or bearing — that lives only in the map's per-leg "1.2 km · 6.2 dB" badges — so a VoiceOver user gets strictly less than a sighted one on the two screens that are otherwise the simplest, while the most complex screen is the only fully described one.
- evidence: MessagePathMapView.swift:844-854 labels the map only when a host supplies a summary; HeardRepeatsMapView.swift:87-91 and MessagePathDetailView.swift:106-109 supply none; PacketScopeDetailView.swift:323 with :919-923.
- direction: Give every message map the same one-sentence spoken summary, built from the same figures its panel headline shows.

### F052 [P2] Propagation time is a first-class figure on one screen and invisible on the other two

- where: MC1/Views/Chats/Components/RepeatRowView.swift:28 · cross-screen
- what the user sees: The Network View prints "+1.3 s" on every observer row and "settled in 1.4 s" (or "still arriving") in its headline. Repeat rows show "1 Hop"/"N Hops" and a signal column and no time at all, though the list is ordered by arrival. The path screen shows no time anywhere.
- why it fails: Propagation is a temporal story on both sides — how fast the mesh carried it, whether echoes are still coming in. The local screens hold the data and never surface it, so the repeat list's order is unexplained, and an operator cannot tell a burst of echoes in one second from three trickling in over a minute.
- evidence: RepeatRowView.swift:12-53 never renders repeatEntry.receivedAt; PersistenceStore+Messages.swift:765-778 sorts by receivedAt ascending. PacketScopeDetailView.swift:928-933 (heardOffset) and :906-914 (still arriving / settled in N s).
- direction: Show the same "+N s after the first" figure on repeat rows that observer rows use, and state what each list is ordered by.

### F059 [P2] Send Again in the sheet deletes the repeat evidence two rows below it and leaves Network View describing the previous packet

- where: MC1Services/Sources/MC1Services/Services/MessageService+SendChannel.swift:270 · sheet
- what the user sees: The sheet shows "Heard: 3 repeats" and an expandable list of three named repeaters with SNR/RSSI. The user taps Send Again (an ordinary, unconfirmed button higher up in the same sheet). Reopening the message: the Repeat Details row is gone, the bubble's repeat chip is gone, a "2x" chip has appeared — and the Network View row is still there.
- why it fails: The only record of what the first transmission achieved is destroyed by a button that reads as "try again", with no warning and no way back. Worse, the surviving Network View is keyed to the FIRST attempt's content hash while the map's origin pin has been re-stamped to where the SECOND attempt was transmitted — so the screen draws attempt 1's observer coverage radiating from attempt 2's location. Nothing says the two halves describe different packets.
- evidence: `resendChannelMessage` post-commit: `incrementMessageSendCount`, `updateMessageHeardRepeats(id:, 0)`, `deleteMessageRepeats`, then `updateMessageUserFix` with a fresh `currentSendFix()` (MessageService+SendChannel.swift:268-284). `packetContentHash` is never cleared, and `setMessagePacketContentHashIfMissing` refuses to overwrite an existing value (PersistenceStore+Messages.swift:822-835), so it stays attempt 1's forever. The Network View origin reads `message.userFixCoordinate` for an outgoing message (PacketScopeCoverageMap.swift:178-184). The sheet's Send Again routes to the same resend as the card (ChatViewModel+MessageActions.swift:61-80).
- direction: Either keep per-attempt evidence (repeats and hash scoped to a send attempt) or make a resend an explicit "this replaces what you're looking at" step; the two must not silently describe different packets in one sheet.

### F066 [P2] A flood message with an empty path advertises a route in the bubble and prints a hop count in the sheet, with no screen behind either

- where: MC1/Views/Chats/Reactions/MessageActionAvailability.swift:33 · sheet
- what the user sees: An incoming channel message the app could not correlate to an RxLog row: the bubble footer chip reads "Flood" (when incoming-path display is on), and the sheet's details print "Hops: 3". There is no View Path row and no Network View row.
- why it fails: Two surfaces assert routing information and neither can be opened. The user reads "Hops: 3" as three known repeaters and looks for the list; there is none, and nothing distinguishes this from a message whose path is simply not worth showing. "Hops: 63" is reachable the same way when the path byte is the 0xFF sentinel.
- evidence: `canViewPath` requires `!(pathNodes?.isEmpty ?? true)` (MessageActionAvailability.swift:33-35) while the incoming rows unconditionally print `Hops: \(message.hopCount)` (ActionsDetailsSection.swift:264-267, :317-322), and `hopCount = decodePathLen(pathLength)?.hopCount ?? Int(pathLength & 63)` (Message.swift:687-689) — derived from the firmware-reported byte, not from stored hops. An uncorrelated lookup returns `pathNodes: nil` with `pathLength: defaultPathLength` intact (SyncCoordinator+HandlerHelpers.swift:105-113). The chip says "Flood" via MessagePathFormatter.swift:31-33. The same failure also drops the Region row, since `routeType` comes back nil and the gate is `== .tcFlood` (ActionsDetailsSection.swift:273).
- direction: When hop details are unavailable, say so in the row ("3 hops, repeaters not recorded") instead of printing a number that promises a screen.

### F067 [P2] Room-server messages reuse the same sheet vocabulary with none of the evidence and no explanation

- where: MC1/Views/RemoteNodes/Rooms/RoomMessageActionsSheet.swift:104 · sheet
- what the user sees: Long-press a room message: the same header, the same "Details" caption, the same "Sent:" / "Received:" rows in the same typography — and no View Path, no Network View, no Repeat Details, and no "No repeats heard" card ever appears under a room bubble.
- why it fails: The identical presentation implies the identical question was asked and answered. A user who has learned that Repeat Details means "it propagated" reads its absence here as "this one didn't", rather than "this message class carries no propagation evidence at all". Room messages are also the case where an operator most wants to know whether their post got out.
- evidence: RoomMessageActionsSheet.swift:104-141 reuses `L10n.Chats.Chats.Message.Action.details`, `Info.sent`, `Info.received` and `ActionInfoRow` with no details destinations; `RoomMessageActionAvailability` has only canReply/canSendDM/canSendAgain. RoomConversationView.swift:136 passes `signalDataAvailable: { false }`, so the no-repeats detector never arms for rooms. It does print `message.localizedStatusText` (:129, :137), which the chat sheet does not.
- direction: Either state in the room sheet that propagation evidence does not exist for server-relayed messages, or stop borrowing the vocabulary that implies it might.

### F074 [P2] "View on Map" is inserted into the middle of the expanded list after the fetch returns, shifting rows under a moving finger — and it is the one row under the 44 pt target

- where: MC1/Views/Chats/Reactions/Sections/ActionsDetailsSection.swift:209 · repeats-inline
- what the user sees: You long-press and immediately tap "Repeat Details". You get a spinner. ~200 ms later the spinner is replaced by N repeat rows *and* a "View on Map" button is inserted above them with no animation — everything below jumps down by roughly a row. A finger already travelling toward the red "Delete" row at the bottom lands somewhere else. The button that appeared is also visibly shorter than every other row in the sheet and is the easiest to miss.
- why it fails: The one control that connects "repeats" to a picture of what happened materialises late, unannounced, in the middle of a list the user is already reaching into. Discoverability and hit reliability both fail on the same row.
- evidence: The row is gated on `repeats?.isEmpty == false` (ActionsDetailsSection.swift:209) and `repeats` is nil until the sheet's `.task` completes (MessageActionsSheet.swift:30, :125); the insertion is not wrapped in `withAnimation` (contrast the disclosure toggle at ActionsDetailsSection.swift:180-182). Its padding is `.padding(.horizontal).padding(.vertical, 10)` (:219-220) ≈ 42 pt tall, against `.padding()` ≈ 52 pt on the View Path, Network View and Repeat Details rows (:129, :152, :196).
- direction: Render the row from the moment the disclosure opens (disabled while loading) and give it the same padding as its sibling rows.

### F079 [P2] Repeat rows have no accessibility-size layout, so at large Dynamic Type the per-echo evidence is unreadable on both surfaces that show it

- where: MC1/Views/Chats/Components/RepeatRowView.swift:14 · repeats-inline
- what the user sees: At accessibility text sizes each repeat row is a fixed two-column layout — hex + repeater name on the left, signal bars + "SNR 6.2 dB" + "RSSI -85 dBm" on the right — and the two columns collide: the repeater name truncates to a few characters while "RSSI -85 dBm" wraps or clips. The same rows are reused inside the heard-repeats map's floating panel, capped at 45 % of the screen, where barely one row fits.
- why it fails: This is the only place in the app that lists which repeater carried each echo and how strongly it came back. At the text sizes where a rider actually reads a phone in daylight, the identity half of every row is the half that gets truncated.
- evidence: `RepeatRowView.body` is a bare `HStack(alignment: .top)` with two fixed VStacks and no `ViewThatFits`, no `dynamicTypeSize` branch (RepeatRowView.swift:14-47). Compare the deliberate handling elsewhere in the same feature: NoRepeatsRetryCard stacks its buttons vertically at accessibility sizes (NoRepeatsRetryCard.swift:39-50) and EmojiPickerRow caps itself at `DynamicTypeSize.accessibility1` (EmojiPickerRow.swift:21). Reused verbatim at HeardRepeatsMapView.swift:127-142 inside a panel capped at `proxy.size.height * 0.45` (:93).
- direction: Give the row the same accessibility-size treatment the retry card already has — stack the signal figures under the identity rather than beside it.

### F083 [P2] "Reply with Route" gives no acknowledgment on the screen where it was tapped; the result arrives three transitions later

- where: MC1/Views/Chats/Components/MessagePathDetailView.swift:158 · path-screen
- what the user sees: On the Path screen you tap "Reply with Route". The button does not change, there is no haptic, no toast. The map screen closes. Then the actions sheet closes. Then, about 300 ms after that, the keyboard rises with the composer already containing your reply plus an "RX via 80,8F,0C. 3 hops 2.3 mi" line. Users tap it twice.
- why it fails: The Copy Path button sitting a few points to its left fires a success haptic on tap; Reply with Route, which does far more, fires nothing. The user cannot tell whether the tap registered until two dismissal animations have finished, and the deferral chain that makes the flow safe is exactly what makes it feel unresponsive.
- evidence: The button just calls `onReplyWithRoute(routeInfo)` with no feedback (MessagePathDetailView.swift:158-167); Copy Path beside it bumps `copyHapticTrigger` feeding `.sensoryFeedback(.success, …)` (:60, :141). The presenter stashes `pendingRouteInfo` and closes the cover (ActionsDetailsSection.swift:78-81), dispatches from the cover's `onDismiss` (:69-73) → `performAction` dispatches then dismisses the sheet (MessageActionsSheet.swift:19-25) → `handleReplyWithRoute` sets the composer text and `handleReply` raises focus only after `MessageActionsPresentation.dismissalDelay` = 300 ms (ChatConversationView.swift:784-818, MessageBubbleLongPress.swift:26).
- direction: Acknowledge the tap on the screen where it happened (haptic plus a momentary state change) before the deferral chain runs.

### F091 [P2] The "Details" block prints wire claims and this radio's own measurements as one undifferentiated grey list

- where: MC1/Views/Chats/Reactions/Sections/ActionsDetailsSection.swift:260 · sheet
- what the user sees: For an incoming message: "Hops: 3" · "Path hash: 2-byte" · "Region: Texas" · "Sent: 14 Aug 2026 at 09:12:31 (adjusted)" · "Received: 14 Aug 2026 at 09:12:34" · "SNR: 8.5 dB (Good)" — all identical subheadline/secondary rows, only two of which carry an icon, under a caption that says nothing but "Details".
- why it fails: Three different kinds of fact are flattened into one list. "Hops", "Path hash" and "Region" are decoded from bytes some other node wrote into the header. "Sent" is the sender's clock, silently rewritten by the app when it disagreed ("(adjusted)"), with the real wire value demoted to a separate row. "Received" and "SNR" are this phone's own measurements. A user cannot tell which figures the app measured, which it inferred, and which it is merely relaying — and one of them can be nonsense: when the path byte is the 0xFF flood sentinel, `hopCount` falls back to `pathLength & 63` and the row prints "Hops: 63" for a message that carries no path information at all, with no View Path row to contradict it.
- evidence: ActionsDetailsSection.swift:260-310 renders every row through the same ActionInfoRow; icons only at :265-266 and :288. Message.swift:687-689 `hopCount = decodePathLen(pathLength)?.hopCount ?? Int(pathLength & 63)`; PathEncoding.swift:50-52 returns nil for mode 3, and PacketBuilder's flood sentinel is 0xFF. Message.swift:693-695: a channel message is always isFloodRouted, so the "Direct" branch never rescues it (derived from code, not observed on device).
- direction: Group the rows by whose measurement they are, and suppress a hop count the app knows it could not decode rather than printing the fallback.

### F100 [P2] The "New" chip times the app's polling, not the mesh, and sits beside a figure that does time the mesh

- where: MC1/Views/Chats/Components/PacketScopeDetailView.swift:1003 · network-view
- what the user sees: An observer row reading "KTX-Hilltop  [New]     +1.3 s", the chip fading out after 20 seconds. On a message sent minutes ago, rows still appear wearing "New".
- why it fails: "+1.3 s" is real propagation — how long after the first observer this one heard the packet. "New" means only that this observer's report showed up in a poll issued after the screen opened; it is a property of CoreScope ingest lag and the app's 6-second poll cadence, not of the radio event. Rendered as a peer of the propagation offset, on a screen whose whole job is to time and place a packet, the chip reads as "just heard it" and inflates the sense that coverage is still spreading long after the packet has gone quiet.
- evidence: PacketScopeDetailView.swift:1003-1007 `isNew` compares now against `observerArrivals[id]`, which is stamped in rebuildCoverage at :1419-1424 for any observer a poll returns that was not previously seen; :928-933 `heardOffset` computes the true offset from `summary.firstHeard`. Localizable.strings for `packetScope.new` = "New".
- direction: Word or style the chip as "just arrived in this lookup" so it cannot be read as a mesh event alongside the propagation offset.

### F017 [P3] "No repeats yet" can render directly above "Heard: 3 repeats" in the same scroll view

- where: MC1/Views/Chats/Components/RepeatDetailsContent.swift:25 · repeats-inline
- what the user sees: Expanding "Repeat Details" shows an empty-state panel — "No repeats yet / Repeats will appear here as your message propagates through the mesh" — while two rows below, in the same scroll view, the details rows read "Heard: 3 repeats".
- why it fails: The row only exists because the counter is greater than zero, so this state is reachable only when the counter and the stored rows disagree — and the copy presents it as a normal waiting state, which teaches the rider that the count is aspirational rather than measured. Either way the sheet contradicts itself about the one fact the rider came for.
- evidence: MessageActionAvailability.swift:32 gates the row on `isOutgoing && heardRepeats > 0`; RepeatDetailsContent.swift:24-29 renders `ContentUnavailableView` with `chats.repeats.emptyState.title` ("No repeats yet", Chats.strings:974) and `.description` (Chats.strings:977) whenever the array is empty; `refreshRepeats` returns `[]` on any fetch error (HeardRepeatsService.swift:167-171); the counter and the rows are two independent writes (HeardRepeatsService.swift:100-149).
- direction: Derive the displayed count from the rows the screen actually has, so one fact has one source and this contradiction cannot render.

### F024 [P3] For outgoing messages the internet lookup is listed above the free local evidence; for incoming messages it is listed below — the order flips with direction

- where: MC1/Views/Chats/Reactions/Sections/ActionsDetailsSection.swift:30 · sheet
- what the user sees: Incoming flood message: "View Path" then "Network View". Outgoing channel message: "Network View" then "Repeat Details".
- why it fails: The order encodes nothing the user can learn from — it is the order the features were built in. Because View Path is incoming-only and Repeat Details is outgoing-only, the fixed sequence produces two different priority claims: for a received message the local evidence is offered first, for a sent one the remote lookup is. The user cannot build the habit "the first row is the one my radio knows".
- evidence: Fixed emission order at ActionsDetailsSection.swift:30 (canViewPath), :34 (canViewPacketScope), :38 (canShowRepeatDetails). canViewPath requires !isOutgoing and canShowRepeatDetails requires isOutgoing (MessageActionAvailability.swift:32-35), so the two local rows are mutually exclusive and the remote row lands between them.
- direction: Order the evidence by vantage — this radio first, third parties second — so the sequence means the same thing in both directions.

### F032 [P3] "Repeat Details" is a row named Details sitting above a caption named Details that it is not part of

- where: MC1/Views/Chats/Reactions/Sections/ActionsDetailsSection.swift:186 · sheet
- what the user sees: The block reads, top to bottom: "Repeat Details v", then the grey heading "Details", then "Sent: …", "Heard: 3 repeats".
- why it fails: One word does two jobs three rows apart: the name of a specific evidence entry and the name of the group of read-only metadata that excludes it. A user scanning the sheet reasonably reads "Repeat Details" as a member of "Details", which is exactly backwards — and "Heard: 3 repeats", the summary of what Repeat Details contains, really is under "Details".
- evidence: chats.message.action.repeatDetails = "Repeat Details" (Chats.strings:610) rendered at ActionsDetailsSection.swift:186; chats.message.action.details = "Details" (Chats.strings:675) rendered at :54.
- direction: Rename so the group heading and the entry do not share a word, and put the entry's own summary inside whichever group it belongs to.

### F034 [P3] Five different glyphs across the evidence rows, with no family and no local-versus-remote distinction

- where: MC1/Views/Chats/Reactions/Sections/ActionsDetailsSection.swift:121 · sheet
- what the user sees: "View Path" with a curving-path glyph, "Network View" with broadcasting radio waves, "Repeat Details" with a branching arrow, "View on Map" with a map pin sheet, and — below the Details caption — "Hops: 3" with a bouncing arrow. The bubble's own repeat chip uses a sixth glyph.
- why it fails: Icons are the fastest grouping cue in a dense list, and here they group nothing. Two rows that are both "this radio's own evidence" look maximally different from each other; the remote lookup's radio-waves glyph is the one most likely to be read as "my radio". The "Hops" bouncing-arrow row, which is the numeric summary of the path, shares no glyph with the View Path row that opens it.
- evidence: "dot.radiowaves.up.forward" (ActionsDetailsSection.swift:121), "point.topleft.down.to.point.bottomright.curvepath" (:144), "arrow.triangle.branch" (:187), "map" (:212), "arrowshape.bounce.right" (:266); the bubble chip uses "repeat" (BubbleFooterRow.swift:225). Only Hops and the region row pass an icon at all to ActionInfoRow — Sent, Received, SNR, Path hash, Round trip and Heard pass none (:243-256, :291-309).
- direction: Use the glyph to encode vantage — one mark for what this radio heard, one for what others reported — and keep an entry's glyph identical to the glyph on its summary row and bubble chip.

### F054 [P3] The shared map control is labelled "Center on path" on a screen that has no path

- where: MC1/Views/Chats/Components/MessagePathMapView.swift:772 · network-view
- what the user sees: All three maps get the same floating controls stack, including a "Center on path" button. On the Network View that button frames the observer constellation — a set of third-party stations and their repeaters, which is not the message's path and is never called a path anywhere else on the screen.
- why it fails: It is the one control label the three maps literally share, and it asserts the exact conflation the redesign is meant to remove: it tells the operator that what they are looking at on the Network View is "the path", the same word the sibling screen uses for the message's own recorded route.
- evidence: MessagePathMapView.swift:770-777 renders L10n…Path.centerOnPath gated only on !locatedNodes.isEmpty; PacketScopeDetailView.swift:299-324 and HeardRepeatsMapView.swift:87-91 both host the same MessagePathMapCanvas.
- direction: Make the shared control's label a parameter of the host screen ("Fit to route" / "Fit to echoes" / "Fit to coverage").

### F063 [P3] Packet Scope off and "this message has nothing to look up" are the same empty space, and turning it on never reaches old messages

- where: MC1/Views/Chats/Reactions/MessageActionAvailability.swift:36 · sheet
- what the user sees: With Packet Scope off, no message in the app mentions that a network view exists. After turning it on in Settings → Chats, long-pressing yesterday's messages still shows no Network View row — only messages received or echoed since the toggle get one, with no indication why.
- why it fails: The feature is invisible from the surface it belongs to, so a user never discovers it; and the user who does discover it concludes it is broken, because the obvious verification step (check it on a message I remember) silently fails. The Settings footer promises "Adds a Network View to a message's actions", which is only true prospectively.
- evidence: `canViewPacketScope = packetScopeEnabled && message.packetContentHash != nil` (MessageActionAvailability.swift:36); the row is rendered only `if availability.canViewPacketScope` with no disabled/explanatory variant (ActionsDetailsSection.swift:34-36). The hash is copied at ingest "now or never" because the RxLog row is pruned within hours (SyncCoordinator+MessageHandlers.swift:270-272; docs/PACKET_SCOPE.md:50), and `setMessagePacketContentHashIfMissing` is the only writer (PersistenceStore+Messages.swift:822-835) — there is no backfill path. Settings copy: Settings.strings:1918.
- direction: Show the row (or a single explanatory line) in the states where it is unavailable, distinguishing "turn this on" from "this message has no wire identity to look up".

### F080 [P3] The loading and failure states of Repeat Details are invisible to VoiceOver

- where: MC1/Views/Chats/Components/RepeatDetailsContent.swift:41 · repeats-inline
- what the user sees: A VoiceOver user activates "Repeat Details". The value changes to "Expanded". Swiping right goes straight from that button to the "Details" static text — nothing is spoken about content loading, nothing announces the rows when they arrive, and in the disconnected-radio case (see that finding) nothing ever will. The user concludes the message has no repeats.
- why it fails: Sighted users at least get a spinner. A VoiceOver user gets a disclosure that claims to be expanded and contains nothing, which is indistinguishable from an empty result — on a feature whose entire point is proving something happened.
- evidence: The loading branch is a bare `ProgressView()` with no accessibility label (RepeatDetailsContent.swift:40-44). The disclosure carries only `.accessibilityValue("Expanded"/"Collapsed")` (ActionsDetailsSection.swift:200-204) with no hint and no announcement, and the sheet posts no `AccessibilityNotification` on completion — contrast PacketScopeDetailView, which announces every focus transition (PacketScopeDetailView.swift:1147, 1189-1191).
- direction: Label the spinner and post a completion announcement when the rows land, and give the empty/failed states distinct spoken text.
