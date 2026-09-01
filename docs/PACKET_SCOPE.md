# Packet Scope — per-message observer coverage

Branch: `feature/packet-scope` (off `v2`). Status: v1 data layer + on-demand UI, 2026-08-31.

The chat can ask a [CoreScope](https://github.com/Kpa-clawbot/CoreScope) observer
network (default: the AUS instance at `scope.digitaino.com`) what the mesh saw of a
message's packet: which observers heard it, at what SNR/RSSI, via which repeaters.
That is ground truth no phone or radio can see alone — the "did it actually get
out, and how far" answer.

## The join key, and why it is not `packetHash`

CoreScope groups observations under the **firmware content hash**:

```
SHA256( payloadTypeNibble ‖ [rawPathLenByte, 0x00 if TRACE] ‖ payload-after-path )[:8] → 16 lowercase hex
```

Route bits, version bits, transport code and path are all excluded, so every node
and observer that hears one transmission — through any path — derives the same
value (CoreScope `cmd/server/decoder.go ComputeContentHash`, which follows the
firmware; their issue #786 is why the full header byte is *not* hashed).

**Exception: TRACE.** Its raw path-length byte *is* folded in (as LE16, matching
firmware), and that byte changes at every hop — so TRACE packets are deliberately
**not** hop-invariant. Harmless here, since a TRACE never becomes a chat message,
but the "same value everywhere" rule above does not cover it.

The app's pre-existing `ParsedRxLogData.packetHash` is `SHA256(payload)[:8]` — no
type nibble — so it **never matches** observer-side hashes. It stays as the local
heard-repeats correlation key. The mesh-wide key is the new
`ParsedRxLogData.contentHash` / `RxLogEntryDTO.contentHash`.

Verified against live captures: `MeshCoreTests/ContentHashTests.swift` pins eight
real packets to the hashes the AUS observers computed for them — covering all four
route types (both transport-code routes, whose 4-byte code must be skipped), one
packet heard via two different paths, and a TRACE with a **non-zero** path-length
byte. The non-zero TRACE matters: with a zero byte, the implemented `[plb, 0x00]`
is indistinguishable from `[0x00, plb]`, a constant `[0x00, 0x00]`, or folding the
*decoded* hop count, so the original zero-byte fixture pinned nothing.

Beyond the fixtures, the formula was replayed against **3000 consecutive live
packets** spanning every route and payload type on the mesh: 3000 matches, 0
mismatches (2026-09-01).

## Where the hash lives

`Message.packetContentHash` (+ DTO, backup wire format — additive, legacy
envelopes decode to nil). It is copied out of the RxLog correlation **at ingest**
because RxLog entries are pruned (keepCount 1000) — within hours on a busy mesh.

- **Incoming (DM + channel):** `SyncCoordinator.lookupRxLogEntry` already
  correlated the message to its RxLog entry and threw the hash away; it now rides
  `RxLogLookupResult.contentHash` onto the row — **from the exact-timestamp match
  only.**
- **Not from the DM sender-prefix fallback.** That branch matches on a one-byte
  sender prefix inside a 30-second window and never checks the recipient, so it can
  land on a DM between two other people this radio merely overheard, or on an
  unrelated sender colliding 1-in-256. Every other field it fills is cosmetic and
  stays local if wrong; the content hash is the one value that *leaves the device*,
  and stamping a stranger's packet identity would both misreport coverage and POST
  a third party's packet to the observer network. It returns nil instead: a DM
  whose exact correlation missed simply gets no Network View.
- **Never from an ambiguous legacy row.** `payloadTypeBits` postdates the RxLog
  table and lightweight migration defaults old rows to 0, which is
  indistinguishable from a real REQUEST. `RxLogEntryDTO.contentHash` returns nil
  rather than minting a confidently wrong hash into a column that lives for years
  with no repair path.
- **Outgoing channel:** the phone never sees its own on-air bytes (the radio
  encrypts and assembles), so there is nothing to hash at send. But a repeater
  echo is byte-identical after path stripping — `HeardRepeatsService` stamps the
  echo's hash onto the sent message, first writer wins
  (`setMessagePacketContentHashIfMissing`).
- **Outgoing DM:** no echo correlation exists today → no hash, no Network View
  row. Candidate v2: hash the *expected ACK packet*
  (`SHA256(ackNibble ‖ expectedAck CRC)[:8]`) to watch the delivery confirmation
  propagate — needs a fixture test against a real ACK before promising it.

**Retries stamp one attempt, not all of them.** A retried message puts N distinct
packets on the air with N hashes, and `findSentChannelMessage` matches every
attempt's echo to the same row. First-writer-wins therefore records whichever
attempt's echo *arrived* first, which need not be attempt 1. Rather than pretend
otherwise, the view says so: when `sendCount > 1` the footer notes that each
attempt is a separate packet and this is the one an observer heard first.

## The API (verified live, 2026-09-01)

Public read, no auth, passes Cloudflare from URLSession. The client uses one
endpoint: `POST /api/packets/observations` with `{"hashes":[...]}` →
`{"results": {hash: [observation…]}}`. Observation rows carry `observer_id`,
`observer_name`, `observer_iata`, `snr`, `rssi`, `path_json`, `resolved_path`,
`timestamp` (ISO 8601 with *and* without fractional seconds — parse both),
`raw_hex`. A hash absent from `results` means no observer heard it.

Sharp edges, all confirmed against the live instance:

- **`resolved_path` elements can be `null`** — ~30% of hop slots, and ~14% of
  observations omit the field entirely. It is positionally aligned with
  `path_json` (0 length mismatches measured). The element type **must** stay
  optional: decoding a null into `[String]` throws, and that failure takes down
  the whole batch response, not one row.
- **`rssi: 0` means "not reported"**, not a 0 dBm reading.
- **One observer appears many times** — it hears the same transmission by
  different routes. Measured: 25 observations from 9 observers for one packet, up
  to 4.4× per observer; across 400 packets, max 40 observations / 10 observers.
- **Server cap is 200 hashes** per batch (401 → HTTP 400). This client caps at 100
  as a runaway guard; nothing caps the *response*, so it truncates at 500 rows.
- **No rate limiting server-side, anywhere.** Pacing is entirely the client's job.
- **`Cache-Control: no-store` on every route**, no ETag — every poll is a full
  transfer. Server-side TTLs still mean a fresh response ≠ fresh data.
- **`X-CoreScope-Load-Status: loading`** means the store is still warming and the
  data is incomplete.
- **No API version exists.** Empirically additive across releases, but there is no
  contract header to pin.

## Privacy stance

A content hash is exactly the "cross-mesh join key" the M3.5 mapper review banned
from the ride log (`docs/ACTIVE_SURVEY_M3_5.md`, enforced by
`MapperRawLogPrivacyInvariantTests`). Chat is a different bargain — the user asks
about *their own* messages — but the rules here are:

- **Opt-in, default off** (`packetScopeEnabled`), link-previews pattern; the
  settings footer says exactly what is sent.
- **The server URL is device-local** — deliberately *not* in `BackupUserDefaults`.
  Restore writes keys the device does not already have, without prompting, so a
  backed-up destination would let a crafted backup silently aim packet hashes at a
  host of its choosing. The toggle round-trips (it is a preference); the
  destination does not, so a restore always lands on the default instance.
- **No cross-host redirects.** A 307/308 preserves method *and body*, so without
  `PacketScopeRedirectGuard` the configured server could bounce the hash payload
  to any other host. Same-host redirects still follow; downgrades to http do not.
- **Enforced in `PacketScopeService`, not the views** — a disabled service throws
  before any request; no future call site can bypass the gate.
- **User-initiated fetches only**: opening the Network View sheet (which then
  live-polls briefly for a fresh message). Rendering a conversation never fires a
  request.
- **Only validated 16-hex hashes** ever reach the wire; HTTPS only; the base URL
  is user-configurable (`packetScopeBaseURL`) since coverage is per-instance.
- The mapper's raw-log ban is untouched and must stay: `MapperRawLog` rows carry
  no packetHash *and* no contentHash, ever.

## UI

`MessageActionAvailability.canViewPacketScope` (opt-in AND hash present) gates a
"Network View" row in the message actions sheet → `PacketScopeDetailView`:
observer list sorted by SNR, path hops, empty state that says *unobserved ≠
undelivered* (observers only cover their region), 6-second live polling while the
message is under 3 minutes old.

Deferred, deliberately: an always-on footer chip ("heard by N") on bubbles would
require persisted observation summaries plus `MessageItem` rebuild plumbing (the
bubble is `Equatable` on its item) — and auto-fetching per rendered message is
exactly what the privacy stance rules out. Revisit only with a design that keeps
fetches user-initiated.
