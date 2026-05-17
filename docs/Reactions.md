# Reactions Interoperability Guide

How to implement emoji reactions compatible with MeshCore One.

## Message Hashing

Reactions target messages by a hash of their content. Every node that received the original message can compute the same hash independently.

1. Concatenate the message's UTF-8 text bytes with the sender's original timestamp as a little-endian `UInt32`
2. SHA-256 the result
3. Take the first 5 bytes (40 bits)
4. Encode as 8 characters of [Crockford Base32](https://www.crockford.com/base32.html)

```
SHA-256( UTF-8(text) + LE(UInt32(senderTimestamp)) )
  → first 5 bytes → Crockford Base32 → "b45pc4ek"
```

Use the **sender's original timestamp**, not your local receive time, so all nodes agree on the hash.

### Why Crockford Base32?

Crockford Base32 maps 5 bytes to exactly 8 characters using only alphanumerics — no special characters that could conflict with the wire format delimiters (`(`, `)`, `[`, `]`, `"`, `@`, `\n`). Hex would need 10 characters for the same data. Base64 fits in 8 but uses `+`, `/`, `=`. The parser is case-insensitive and normalizes common substitutions (O → 0, I/L → 1). Canonical output is lowercase.

## Wire Format

Reactions are sent as regular mesh messages with a specific text format. There are two formats: **v2 (human-readable)** is what current clients emit; **v1 (legacy)** is still accepted on receive for back-compat with older clients.

### v2 — human-readable (canonical, emit this)

**Channel** (includes target sender to disambiguate identical messages from different users):
```
{emoji} reacted to [{targetSenderName}]: "{snippet}" ({hash})
```
Example: `👍 reacted to [AlphaNode]: "see you at the meetup" (b45pc4ek)`

**DM** (two-party, sender is unambiguous):
```
{emoji} reacted to: "{snippet}" ({hash})
```
Example: `👍 reacted to: "see you at the meetup" (b45pc4ek)`

The `{snippet}` is a human-readable echo of the target message text. It is **cosmetic only** — receivers MUST NOT parse it or compare it to anything. Only the `{hash}` carries identity. Snippets may be truncated with a trailing `...`.

#### Length limits

- **Channel reactions** are capped at **136 characters total**. This accounts for the firmware-prepended `NodeName: ` prefix that consumes part of the 160-character on-air message budget. When the full text would exceed 136 chars, shorten the **snippet only** (append `...`). The emoji, sender, and hash suffix must be preserved.
- **DM reactions** are capped at **150 UTF-8 bytes total**. Same rule: shorten the snippet only.

### v1 — legacy (accept on receive, do not emit)

**Channel:**
```
{emoji}@[{targetSenderName}]\n{hash}
```
Example: `👍@[AlphaNode]\nb45pc4ek`

**DM:**
```
{emoji}\n{hash}
```
Example: `👍\nb45pc4ek`

Implementations should parse v1 to remain compatible with pre-v2 clients but should always emit v2.

## Receiving Reactions

When you receive a message, check if it matches a reaction format (v2 or v1) before treating it as a regular message.

**If it's a reaction:** look up the target message by hash. If the target hasn't arrived yet (out-of-order delivery is common on mesh), queue the reaction and match it when the target appears.

**If it's a regular message:** compute its hash and index it so future reactions can find it. Also check your pending queue for reactions already waiting on this hash.

### Parsing order

Try v2 first, then fall back to v1. The reference implementation distinguishes them as follows:

- **v2 channel:** ends with `)`, contains ` reacted to [`, and the trailing 8 chars before `)` are valid Crockford Base32 preceded by ` (`.
- **v2 DM:** same as channel but with ` reacted to: ` (no `[`).
- **v1 channel:** contains `@[` and a final `\n` before an 8-char Crockford Base32 hash.
- **v1 DM:** no `@[`, final `\n` before an 8-char Crockford Base32 hash.

### Deduplication

Deduplicate by `(targetHash, senderName, emoji)` — a node may relay the same reaction more than once.

### Pending-reaction queue

For reactions whose target hasn't arrived yet, keep a per-session queue keyed by `(channelIndex, targetSender, messageHash)` for channels and `(deviceID, messageHash)` for DMs. The reference implementation:

- Holds reactions for the session lifetime (no TTL).
- Caps the queue at **100 entries** with FIFO eviction when full.
- Flushes the matching entries whenever a regular message is indexed.

Implementations are free to choose different cap/eviction policies, but should expect out-of-order delivery to occasionally exceed seconds.
