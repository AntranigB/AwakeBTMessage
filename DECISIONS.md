# Design decisions

Each entry records what was chosen, why, and what it costs. The costs are the
useful part — they're what a reviewer should push on.

---

## 1 · The anchor holds the link, not the phone

**Decision.** The phone is a BLE *central*; a separate always-on anchor is the
*peripheral*. Messages flow through the anchor.

**Why.** iOS suspends a backgrounded app. It will wake one for a notification
from a **connected** peripheral, but it will not let a suspended app scan or
advertise. Phone-to-phone designs therefore die the moment the screen goes off —
which is the entire problem being solved.

**Cost.** A second device. Without it there is no persistence, and the
architecture collapses back to the category it's trying to beat.

---

## 2 · BLE GATT, not Multipeer or AWDL

**Decision.** One custom GATT service, phone writes to RX, anchor notifies on TX.

**Why.** The wake path is the product, and only Core Bluetooth exposes it. The
alternatives are worse for this problem: Multipeer Connectivity is *deprecated as
of iOS 26* (Apple points to Network.framework), it tears down sessions when the
app backgrounds, and AWDL needs the Wi-Fi radio. BLE's throughput is poor, but
the payload is text.

**Cost.** ~150 bytes per write and low bandwidth. Large media are out of scope.

---

## 3 · Length-prefixed framing, 150-byte chunks

**Decision.** `[uint16 length][JSON]`, written in ≤150-byte pieces, reassembled
by length. Chunk boundaries carry no meaning.

**Why.** BLE's negotiated MTU is unpredictable and writes can split anywhere.
Length prefixing makes the receiver indifferent to how the stack fragments.
150 sits under the smallest common payload after headers.

**Cost.** A 688-byte frame is five writes and a reassembly buffer. Tested with
300 randomised chunkings; a corrupt length prefix clears the buffer rather than
desyncing forever.

---

## 4 · Store and forward, acked, with a 24-hour TTL

**Decision.** Every message to a known node is queued; the ack clears it; an
unclaimed message expires after 24 h. Duplicates are re-acked but not re-logged.

**Why.** "Absence shouldn't be loss." A phone that walks away, sleeps, or gets
suspended should receive what it missed — measured: a message held 83.9 s and
delivered on reconnect.

**Cost.** At-least-once delivery, so the receiver must deduplicate. The queue
lives in the anchor's memory and is lost if it restarts mid-flight.

---

## 5 · 30-second heartbeat, 90-second staleness

**Decision.** The phone sends a heartbeat every 30 s carrying battery and RSSI.
The anchor calls the link stale after 90 s of silence.

**Why.** `CBPeripheralManager` only reports a subscriber leaving when it
unsubscribes cleanly. A phone that sleeps or dies simply stops talking and the
subscriber count stays at 1 — so without this the anchor broadcasts into a dead
link instead of queueing. Three missed heartbeats is a clear signal without
being trigger-happy.

**Cost.** Heartbeats are traffic: ~120 events/hour in the log, hence rotation at
5 MB. A denied Location permission previously *was* the only liveness signal —
the heartbeat removed that dependency.

---

## 6 · ChaChaPoly under a published shared key

**Decision.** `msg` bodies are sealed with ChaChaPoly, keyed by SHA-256 of a
passphrase that ships in the source: `awake-demo-channel`.

**Why.** Real AEAD with no key management UI to get wrong during a demo. It
defeats casual over-the-air interception, which is the threat at a venue.

**Cost.** **It provides no secrecy against anyone who reads the repository**, and
no forward secrecy. Routing metadata (`from`, `to`, `id`) stays in the clear so
the anchor can route without holding conversation keys. Production is X3DH +
Double Ratchet per pair; this layer is the seam that replaces. Said plainly in
PROTOCOL.md because a judge will ask.

---

## 7 · The dashboard binds to localhost only

**Decision.** `127.0.0.1:8787` by default; `AWAKE_BIND=0.0.0.0` opts into LAN.

**Why.** It renders live GPS coordinates and accepts **unauthenticated POSTs**.
On venue Wi-Fi that is a privacy leak and a way to inject fake events into a
demo. The default must be the safe one.

**Cost.** Projecting from a second machine needs one environment variable.

---

## 8 · The phone measures its own signal

**Decision.** The phone calls `readRSSI()` and reports the value on its heartbeat.

**Why.** A BLE peripheral cannot read RSSI from a connected central. The central
can read the peripheral. So the only way to show link quality on the anchor's
dashboard is for the phone to measure and send it.

**Cost.** One more field in the protocol, and the reading is a heartbeat stale.

---

## 9 · One anchor, one hop

**Decision.** Ship a single hop and say so.

**Why.** Multi-hop needs a second radio to test honestly. Relay logic that has
never carried a real message is worse than an admitted gap, and the envelope is
already transport-agnostic — the seam exists.

**Cost.** Range is one BLE hop (~10 m indoors). This is the largest honest gap
between the demo and the venue story.

---

## 10 · One Core package, generated project

**Decision.** Protocol, queues and crypto live in a SwiftPM package compiled into
both apps; the `.xcodeproj` is generated by XcodeGen and never committed.

**Why.** Two apps sharing a wire format will drift. Compiling one package into
both makes drift a build error, and lets the logic be tested on the command line
without a simulator. Generated projects avoid merged `.pbxproj` conflicts.

**Cost.** A clone has no project until `xcodegen generate` runs — documented in
the README, because otherwise it looks broken.
