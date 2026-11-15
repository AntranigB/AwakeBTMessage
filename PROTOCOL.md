# Awake wire protocol v1

Deliberately boring: one BLE GATT service, length-prefixed JSON, no dependencies.

## GATT

| Role | UUID |
|---|---|
| Service | `D3ADBEEF-0001-4A5B-9C8D-0123456789AB` |
| RX (central writes here) | `D3ADBEEF-0002-4A5B-9C8D-0123456789AB` |
| TX (peripheral notifies here) | `D3ADBEEF-0003-4A5B-9C8D-0123456789AB` |

The **anchor** (macOS app, or later a $8 BLE board) is the peripheral. The
**phone** is the central. One connection carries both directions: the phone
writes to RX, the anchor notifies on TX.

This matters: a subscribed notify characteristic on a *connected* peripheral is
the one thing iOS will wake a suspended app for. That's the whole trick.

## Framing

Every logical message becomes one frame:

```
[uint16 big-endian length][JSON payload]
```

The frame is then written in chunks of at most **150 bytes**. The receiver
appends every incoming chunk to a buffer and drains complete frames:

```
while buf.count >= 2:
    n = (buf[0] << 8) | buf[1]
    if buf.count < 2 + n: break
    payload = buf[2 ..< 2+n]
    buf.removeFirst(2+n)
    handle(payload)
```

Chunk boundaries are meaningless — a single BLE write may contain half a frame
or three frames.

## Message

```json
{
  "id":   "8F3A",          // 4 hex chars, unique per message
  "from": "IPH1",          // node id
  "to":   "*",             // "*" = broadcast, else node id
  "type": "msg",           // msg | ack | loc | hello | heartbeat | selftest
  "ts":   1763251200.123,  // unix seconds, sender clock
  "body": "e1:Q2hhQ2hh...",  // sealed body, or the acked id for type=ack
  "hops": ["IPH1"],        // path history; app state on receipts
  "lat":  40.7128,         // type=loc
  "lon": -74.0060,
  "batt": 75,              // type=heartbeat
  "rssi": -64              // type=heartbeat
}
```

### Types

- `msg` — a chat message. Receiver replies with `ack` whose `body` is the
  original `id`.
- `ack` — delivery receipt. Sender computes `latency = now - sentAt[id]`.
- `loc` — position update. Dashboard plots it.
- `hello` — node introduction, carries the display name in `body`.
- `heartbeat` — every 30 s while connected; carries `batt` and `rssi`. The
  anchor uses it for liveness (a link is stale after 90 s of silence) and keeps
  it out of the dashboard feed.
- `selftest` — a ~500-byte upload probe, sent only when the app launches with
  `--selftest`; exercises multi-chunk framing in the phone→anchor direction.
- `log` — anchor-forwarded diagnostic string.

## Rules

1. Frames are capped at 4096 bytes; writes are chunked at 150 bytes and
   reassembled by length. A ~690-byte message spans five writes and is
   acknowledged in the same time as a short one.
2. `id` is unique per message and is the ack key. Not a security boundary.
3. **`msg` bodies are sealed with ChaChaPoly**, prefixed `e1:` and base64
   encoded. The key is SHA-256 of a passphrase; the demo build uses the
   constant `awake-demo-channel`, which is published here and therefore offers
   no secrecy against anyone who reads this file. It defeats casual over-the-air
   interception, nothing more. **Production is X3DH + Double Ratchet per
   pair**, and this layer is the seam that replaces. Routing metadata is left
   in the clear so the anchor can route without holding conversation keys.
4. Deduplicate on `id`. A duplicate is **re-acked but not re-logged** — a lost
   receipt must not strand the sender.
5. A message for an absent node is queued and replayed on reconnect; the `ack`
   clears the queue entry. TTL 24 h.
