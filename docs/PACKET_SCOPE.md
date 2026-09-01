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

The app's pre-existing `ParsedRxLogData.packetHash` is `SHA256(payload)[:8]` — no
type nibble — so it **never matches** observer-side hashes. It stays as the local
heard-repeats correlation key. The mesh-wide key is the new
`ParsedRxLogData.contentHash` / `RxLogEntryDTO.contentHash`.

Verified against live captures: `MeshCoreTests/ContentHashTests.swift` pins five
real packets (including one packet heard via two different paths, and a TRACE) to
the hashes the AUS observers computed for them.

## Where the hash lives

`Message.packetContentHash` (+ DTO, backup wire format — additive, legacy
envelopes decode to nil). It is copied out of the RxLog correlation **at ingest**
because RxLog entries are pruned (keepCount 1000) — within hours on a busy mesh.

- **Incoming (DM + channel):** `SyncCoordinator.lookupRxLogEntry` already
  correlated the message to its RxLog entry and threw the hash away; it now rides
  `RxLogLookupResult.contentHash` onto the row. DM correlation remains best-effort
  (timestamp, then sender-prefix fallback).
- **Outgoing channel:** the phone never sees its own on-air bytes (the radio
  encrypts and assembles), so there is nothing to hash at send. But a repeater
  echo is byte-identical after path stripping — `HeardRepeatsService` stamps the
  echo's hash onto the sent message, first writer wins
  (`setMessagePacketContentHashIfMissing`).
- **Outgoing DM:** no echo correlation exists today → no hash, no Network View
  row. Candidate v2: hash the *expected ACK packet*
  (`SHA256(ackNibble ‖ expectedAck CRC)[:8]`) to watch the delivery confirmation
  propagate — needs a fixture test against a real ACK before promising it.

## The API (verified live, 2026-08-31)

Public read, no auth, passes Cloudflare from URLSession. The client uses one
endpoint: `POST /api/packets/observations` with `{"hashes":[...]}` →
`{"results": {hash: [observation…]}}`. Observation rows carry `observer_name`,
`observer_iata`, `snr`, `rssi`, `path_json`, `timestamp` (ISO 8601 with *and*
without fractional seconds — parse both), `raw_hex`. `rssi: 0` means
"not reported". A hash absent from `results` means no observer heard it.

## Privacy stance

A content hash is exactly the "cross-mesh join key" the M3.5 mapper review banned
from the ride log (`docs/ACTIVE_SURVEY_M3_5.md`, enforced by
`MapperRawLogPrivacyInvariantTests`). Chat is a different bargain — the user asks
about *their own* messages — but the rules here are:

- **Opt-in, default off** (`packetScopeEnabled`), link-previews pattern; the
  settings footer says exactly what is sent.
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
