# MeshWX: COBS Encoding Fix for Binary Payloads

## The Problem

Binary MeshWX messages (`0x10` radar, `0x20` warnings) are being **silently truncated** by the MeshCore firmware before they reach the iOS app. The firmware's companion radio protocol treats channel message payloads as C-strings (null-terminated), so any `0x00` byte in the binary data causes everything after it to be dropped.

### Where the truncation happens

```
Python server                MeshCore firmware              iOS app
─────────────              ──────────────────            ──────────
pack_warning()  ───LoRa──▶  decrypt channel msg  ───BLE──▶  parse
133 bytes                    strcpy(buf, payload)           2 bytes!
                             ^^^^^^^^^^^^^^^^
                             TRUNCATES AT FIRST 0x00
```

The firmware receives the full encrypted payload over LoRa and decrypts it correctly. But when it constructs the BLE companion protocol response to send to the phone, it uses C-string handling internally — `strlen()`, `strcpy()`, or similar — which stops at the first `0x00` byte.

### Which fields produce 0x00 bytes

**Warning polygons** — the expiry field (big-endian uint16 at offset 2-3):
```
Offset 0: 0x20 (type)         ← always non-zero ✓
Offset 1: type|severity       ← always non-zero ✓
Offset 2: expiry HIGH byte    ← 0x00 for any expiry < 256 minutes! ✗
Offset 3: expiry LOW byte
```
Any warning expiring in less than ~4.3 hours (the common case) has `0x00` at byte 2. **Result: warnings truncated to 2 bytes.** This matches exactly what we saw in the logs.

**Radar grids** — packed 4-bit grid cells:
```
Offset 5-132: grid data, two 4-bit cells per byte
Two clear cells = 0x00
```
Any clear-weather area in the radar grid produces `0x00` bytes. Also, region 0x0 with frame_seq 0 produces `0x00` at byte 1, and the timestamp high byte is `0x00` for times before 04:16 UTC.

## The Solution: COBS Encoding

**COBS (Consistent Overhead Byte Stuffing)** encodes data to eliminate all `0x00` bytes. It's the standard approach for sending binary data through channels that use null-termination.

- **Overhead**: At most 1 byte per 254 input bytes
- **133-byte radar** → ~134 bytes encoded (fits in 136-byte LoRa frame)
- **25-byte warning** → ~26 bytes encoded
- **Deterministic**: No data-dependent size variation beyond the fixed overhead
- **Simple**: ~15 lines of code in any language

### How COBS works (quick version)

COBS replaces every `0x00` with a pointer to the next zero. The encoded output never contains `0x00`.

```
Input:  [0x20, 0x13, 0x00, 0x3C, 0x05]
                      ^^^^
                      null byte

Output: [0x03, 0x20, 0x13, 0x03, 0x3C, 0x05]
         ^^^^                ^^^^
         "3 bytes until       "3 bytes until
          next zero"           end of data"
```

## What to change (Python server)

### Option A: Use the `cobs` library (recommended)

```bash
pip install cobs
```

```python
from cobs import cobs

# In your broadcast code, wrap every binary message:
raw_msg = pack_radar_message(grid, region_id=region.id, ...)
encoded_msg = cobs.encode(raw_msg)
await radio.send_channel(WX_CHANNEL, encoded_msg)

raw_msg = pack_warning_message(warning_type=w.type_code, ...)
encoded_msg = cobs.encode(raw_msg)
await radio.send_channel(WX_CHANNEL, encoded_msg)
```

That's it. Every `pack_*_message()` call gets wrapped with `cobs.encode()` before `send_channel()`.

### Option B: Inline implementation (no dependency)

```python
def cobs_encode(data: bytes) -> bytes:
    """COBS-encode data to eliminate all 0x00 bytes."""
    output = bytearray()
    block_start = len(output)
    output.append(0)  # placeholder for first code byte
    run_length = 1

    for byte in data:
        if byte == 0x00:
            output[block_start] = run_length
            block_start = len(output)
            output.append(0)  # placeholder for next code byte
            run_length = 1
        else:
            output.append(byte)
            run_length += 1
            if run_length == 0xFF:
                output[block_start] = run_length
                block_start = len(output)
                output.append(0)
                run_length = 1

    output[block_start] = run_length
    return bytes(output)
```

Usage is identical:
```python
raw_msg = pack_radar_message(grid, ...)
encoded_msg = cobs_encode(raw_msg)
await radio.send_channel(WX_CHANNEL, encoded_msg)
```

### Verification

You can verify the encoding is correct with this test:

```python
# Test: warning with 0x00 at byte 2 (expiry=60 min → 0x003C)
raw = bytes([0x20, 0x13, 0x00, 0x3C, 0x05, 0x05, 0x57, 0x30, 0xFF, 0x63, 0xDC])
encoded = cobs_encode(raw)

assert 0x00 not in encoded, "Encoded data must not contain 0x00"
print(f"Raw:     {raw.hex(' ')}")
print(f"Encoded: {encoded.hex(' ')}")
print(f"Size:    {len(raw)} → {len(encoded)} bytes (+{len(encoded)-len(raw)} overhead)")

# Verify round-trip (if using cobs library)
from cobs import cobs
assert cobs.decode(encoded) == raw, "Round-trip failed"
```

Expected output:
```
Raw:     20 13 00 3c 05 05 57 30 ff 63 dc
Encoded: 03 20 13 09 3c 05 05 57 30 ff 63 dc
Size:    11 → 12 bytes (+1 overhead)
```

## Changes on the iOS side (already done)

The iOS client (`MeshWXDecoder.swift`) has been updated to:

1. Try COBS-decoding the payload first
2. Fall back to raw binary decoding (for testing / future firmware fixes)

So once you push the server-side COBS encoding, the iOS client will decode it automatically. No coordination needed — just deploy.

## Summary of changes

| Side | File | Change |
|------|------|--------|
| **Python server** | wherever `send_channel()` is called for binary messages | Wrap with `cobs.encode()` / `cobs_encode()` |
| iOS client | `MeshWXDecoder.swift` | Already done — COBS decode + raw fallback |
| Protocol spec | `docs/Weather_Protocol.md` | Already updated |

## FAQ

**Q: Why not fix the firmware instead?**
A: The null-termination is deep in the MeshCore firmware's companion radio protocol. Changing it would require a firmware update across all devices. COBS encoding at the application layer is the standard workaround and costs essentially nothing.

**Q: Why not Base64?**
A: Base64 expands data by 33%. A 133-byte radar message would become 178 bytes — over the 136-byte LoRa frame limit. COBS adds only ~1 byte.

**Q: What about the `text = dbuf.read().strip(b'\0')` in reader.py?**
A: That's the Python SDK stripping trailing nulls from received messages — a separate issue. The truncation we're fixing happens in the firmware *before* the message reaches any SDK. The Python SDK's `strip(b'\0')` would also damage COBS-encoded data by removing trailing bytes that happen to be non-zero but are part of the COBS structure — however since the firmware is the one sending to the iOS app, this Python-side code path isn't involved in the truncation.

**Q: Does this affect the `0x01` refresh request?**
A: Refresh requests are sent via DM, not channel messages, so they go through a different code path. But for consistency, you could COBS-encode those too. The iOS client will handle either way.
