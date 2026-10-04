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

Reactions are sent as regular mesh messages with a specific text format. This app **emits v1 emoji-first** and **accepts v1 in either order, v2 and v3** on receive.

Why v1 emoji-first (decided 2026-10-04): it is the one form every stock MeshCore One release shows as a tapback. 1.3.0 to 1.4.0 accept only emoji-first; 1.4.1 and later (upstream 5d63d5fc) accept either order but require the emoji field to be **exactly one emoji**, which turned v3 — the fork's emit until then — into a chat line with a mention ping on every current stock app. v1 has no readable snippet; clients with no reaction support show the bare carrier.

### v1 — emit this

**Channel** (includes target sender to disambiguate identical messages from different users):
```
{emoji}@[{targetSenderName}]\n{hash}
```
Example: `👍@[AlphaNode]` + newline + `b45pc4ek`

Also accepted on receive: mention-first `@[{targetSenderName}]{emoji}\n{hash}`, which stock 1.4.1+ emits.

**DM** (two-party, sender is unambiguous):
```
{emoji}\n{hash}
```
Example: `👍` + newline + `b45pc4ek`

The `{emoji}` field is a single extended grapheme cluster. A remainder that merely starts with an emoji is ordinary chat, not a reaction. Queue unmatched bodies that do match this format; do not persist them as chat.

Even a long ZWJ emoji (a family is 25 bytes) and a 31-byte target sender come to under 70 bytes with the brackets, newline and hash, inside any channel budget, so nothing is truncated.

### v3 — piggyback (accept on receive, do not emit; emitted by fork builds until 2026-10-04)

**Channel:**
```
{emoji} reacted to "{snippet}" @[{targetSenderName}]\n{hash}
```
**DM:**
```
{emoji} reacted to "{snippet}"\n{hash}
```

Structurally a v1 reaction whose emoji field carries a readable phrase. Stock 1.3.0 to 1.4.0 (emoji field only had to *start* with an emoji) showed it as a tapback with the phrase in the badge; stock 1.4.1+ shows it as chat. The `{snippet}` is cosmetic only — receivers never parse or compare it; only `{hash}` carries identity. The phrase never contains `:`, `,`, a line break or a second `@[` (they would corrupt upstream's `{emoji}:{count}` summary cache or the sender field).

### v2 — human-readable (accept on receive, do not emit; emitted by fork Builds 19–40)

**Channel:**
```
{emoji} reacted to [{targetSenderName}]: "{snippet}" ({hash})
```
**DM:**
```
{emoji} reacted to: "{snippet}" ({hash})
```

Stock MeshCore One never parsed v2; there it is a plain-text message.

## Receiving Reactions

When you receive a message, check if it matches a reaction format (v3, v2 or v1) before treating it as a regular message.

**If it's a reaction:** look up the target message by hash. If the target hasn't arrived yet (out-of-order delivery is common on mesh), queue the reaction and match it when the target appears.

**If it's a regular message:** compute its hash and index it so future reactions can find it. Also check your pending queue for reactions already waiting on this hash.

### Parsing order

Try v3, then v2, then v1. The reference implementation distinguishes them as follows:

- **v3 channel:** the phrase before the first `@[` is `{emoji} reacted to "…" ` and the line after the last `\n` is an 8-char Crockford Base32 hash.
- **v3 DM:** no `@[`; the phrase before the last `\n` is `{emoji} reacted to "…"`.
- **v2 channel:** ends with `)`, contains ` reacted to [`, and the trailing 8 chars before `)` are valid Crockford Base32 preceded by ` (`.
- **v2 DM:** same as channel but with ` reacted to: ` (no `[`).
- **v1 channel:** contains `@[` and a final `\n` before an 8-char Crockford Base32 hash; exactly one emoji either before the `@[` or after the `]`.
- **v1 DM:** no `@[`, final `\n` before an 8-char Crockford Base32 hash.

### Deduplication

Deduplicate by `(targetHash, senderName, emoji)` — a node may relay the same reaction more than once.

### Pending-reaction queue

For reactions whose target hasn't arrived yet, keep a per-session queue keyed by `(channelIndex, targetSender, messageHash)` for channels and `(deviceID, messageHash)` for DMs. The reference implementation:

- Holds reactions for the session lifetime (no TTL).
- Caps the queue at **100 entries** with FIFO eviction when full.
- Flushes the matching entries whenever a regular message is indexed.

Implementations are free to choose different cap/eviction policies, but should expect out-of-order delivery to occasionally exceed seconds.
