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

Reactions are sent as regular mesh messages with a specific text format. There are three formats: **v3 (piggyback)** is what current clients emit; **v2 (human-readable)** and **v1 (legacy)** are still accepted on receive for back-compat with older clients.

### v3 — piggyback (canonical, emit this)

**Channel** (includes target sender to disambiguate identical messages from different users):
```
{emoji} reacted to "{snippet}" @[{targetSenderName}]\n{hash}
```
Example: `👍 reacted to "see you at the meetup" @[AlphaNode]` + newline + `b45pc4ek`

**DM** (two-party, sender is unambiguous):
```
{emoji} reacted to "{snippet}"\n{hash}
```
Example: `👍 reacted to "see you at the meetup"` + newline + `b45pc4ek`

**Why this shape:** v3 is structurally a **v1 reaction whose emoji field carries a readable phrase**. Stock upstream MC1 (v1.3.0, which parses only the v1 grammar) accepts it: the hash sits after the last newline, the first `@[` starts the sender field, and its emoji check only requires the field to *start* with an emoji. Upstream therefore attaches the reaction to the correct message and hides the carrier — rendering the whole phrase in its badge — while clients with no reaction support display a readable sentence. Upstream's badge-tap "react back" echoes the stored phrase, which reproduces the v3 string byte-for-byte, so echoes parse as clean tapbacks here too.

The `{snippet}` is a human-readable echo of the target message text. It is **cosmetic only** — receivers MUST NOT parse it or compare it to anything. Only the `{hash}` carries identity. Snippets may be truncated with a trailing `...`.

**Snippet sanitization (mandatory for emitters):** the phrase (everything before `@[` on channels / before the newline in DMs) lands verbatim in upstream MC1's persisted `{emoji}:{count}` summary cache, whose delimiters are `:` and `,`. Emitters MUST therefore replace `:`, `,`, and line breaks in the snippet with spaces (collapsing runs), and MUST split an echoed `@[` with a no-break space (`@ [`, U+00A0) so the structural `@[` stays the first occurrence.

#### Length limits

All limits are in **UTF-8 bytes** (the firmware enforces a byte budget, not characters). When the full text would exceed the budget, shorten the **snippet** and append `...`. The hash line must always be preserved; a target sender long enough to crowd out the hash is truncated inside the brackets too, before the snippet is dropped entirely.

- **Channel reactions** must fit so that the firmware-prepended `"{NodeName}: "` plus the reaction stays within a total of **147 bytes** (`ProtocolLimits.maxChannelMessageTotalLength`). Unlike v2, the budget is computed against the protocol's **worst-case 31-byte node name** (budget = `147 - 31 - 2` = 114 bytes), *not* the actual local name: upstream MC1 groups badge counts by the full phrase string, so two reactors sending the same emoji to the same message must emit byte-identical text regardless of their own name lengths.
- **DM reactions** are capped at **150 UTF-8 bytes total**. No firmware prefix is prepended.

### v2 — human-readable (accept on receive, do not emit; emitted by fork Builds 19–40)

**Channel:**
```
{emoji} reacted to [{targetSenderName}]: "{snippet}" ({hash})
```
Example: `👍 reacted to [AlphaNode]: "see you at the meetup" (b45pc4ek)`

**DM:**
```
{emoji} reacted to: "{snippet}" ({hash})
```
Example: `👍 reacted to: "see you at the meetup" (b45pc4ek)`

v2 reads best on clients with no reaction support, but stock upstream MC1 does not parse it — there it degrades to a plain-text message instead of a tapback, which is why v3 replaced it. Where the echoed text itself contains ` reacted to [` or ` reacted to: `, v2 senders replace that leading space with a no-break space (U+00A0); the v2 budget is computed against the **actual** local node name (`147 - nodeNameBytes - 2` for channels, 150 for DMs).

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
