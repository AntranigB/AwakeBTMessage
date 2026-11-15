# AWAKE

**Offline messaging that actually reaches a locked phone.**

*The delivery layer for the ninety seconds after the network dies.*

Every Bluetooth messenger has the same hole: the moment you lock your phone or
put it in your pocket, delivery stops. Awake's whole design is aimed at that
one second — the one where you need the message and the app is suspended.

---

## The insight

iOS will not let a suspended app scan, advertise, or run. But it *will* wake an
app for a notification from a **connected** BLE peripheral. So Awake inverts the
usual design: instead of phones discovering each other, a cheap always-on
**anchor** holds the link and pulls the phone awake.

That anchor is a $8 BLE board in production. In this build it's a Mac, running
the identical code path.

```
   iPhone (locked, airplane mode)
        │  BLE GATT — phone writes RX, anchor notifies TX
        ▼
   AWAKE-ANCHOR  (macOS app, stands in for the $8 board)
        │  local HTTP
        ▼
   dashboard :8787   ← judges watch the packet land
```

## What is genuinely working

| Claim | Status |
|---|---|
| Phone ↔ anchor over BLE, no Wi-Fi, no cellular | **real** |
| Message delivered with the app backgrounded | **real, logged** |
| Local notification fires on a locked phone | **observed once, not instrumented** |
| Delivery with the app backgrounded | **2 verified: 56 ms live, 84 s replayed** |
| Fragmented messages (~690 B over 5 BLE writes) | **verified, 70 ms** |
| Delivery receipt with round-trip latency | **real** (ack frames) |
| GPS position relayed over BLE to the dashboard | **real** |
| On-device speech→text (Argmax WhisperKit) | **real, no network** |
| On-device text→speech playback | **real** |
| ChaChaPoly body encryption | **real, 6 tests** |
| Store-and-forward while out of range | **real, 11 tests** |
| Protocol + queue + crypto unit tests | **35 passing** |
| iOS state restoration + pending reconnect | **verified: 84 s replay · link held 3.9 h** |
| Mesh multi-hop between phones | **not in this build** |

Be precise about the last three in the pitch. Judges forgive a missing feature;
they do not forgive a claim that collapses under one question.

## Requirements

- macOS 14 or newer, with **Xcode 16+** (built against Xcode 27 / Swift 6.4)
- **XcodeGen** — the `.xcodeproj` is generated, never committed:
  `brew install xcodegen`
- An iPhone for the BLE half. The Mac alone can build and run the anchor;
  Bluetooth does not exist in the iOS simulator.

A fresh clone has no Xcode project until you generate one:

```
brew install xcodegen
xcodegen generate
./verify.sh          # 35 tests, both targets, dashboard check
```

Verified against a clean checkout: 35 tests pass and both targets build.

## Verify it

```
./status.sh        # is the demo still standing? one screen
./dryrun.sh        # will a message actually arrive right now? (~15s)
./verify.sh        # 35 unit tests + both builds + dashboard health
./demo.sh          # clean start, Mac kept awake, phone relinks
./install.sh       # rebuild + reinstall on the phone (unlock it first)
```

Latest run and the live BLE evidence are in [RESULTS.md](RESULTS.md).
Written summary for judges: [SUBMISSION.md](SUBMISSION.md).

## Run it

One command brings the whole thing up in a known-good state: it archives the
previous event log, starts the dashboard, keeps the Mac awake, launches the
anchor, and opens the dashboard.

```
./demo.sh
```

The dashboard binds to **127.0.0.1 only** — it renders live GPS coordinates and
accepts unauthenticated POSTs, so it must not be reachable from venue Wi-Fi.
If you're projecting from another machine on a trusted LAN, opt in explicitly:

```
AWAKE_BIND=0.0.0.0 python3 dashboard/server.py
```

Or by hand, in three terminals:

**1 — dashboard**

```
python3 dashboard/server.py
# → http://localhost:8787
```

**2 — anchor**

```
open ~/Library/Developer/Xcode/DerivedData/Awake-*/Build/Products/Debug/AwakeNode.app
```

Grant Bluetooth when macOS asks. The header should read
`AWAKE-ANCHOR · ADVERTISING`.

**3 — phone**

Awake is already installed. Open it, allow **Notifications**, **Bluetooth**, and
**Location While Using**.

Wait for `LINKED · AWAKE-ANCHOR` in the header, then lock the phone.

Type in the anchor's composer and press return.

## The 20-second proof

1. iPhone: Control Center → **Airplane mode on**, then **Bluetooth back on**.
   Wi-Fi is off. There are no bars.
2. Lock the phone. Put it face down.
3. Anchor: type `where are you` → return.
4. **The phone buzzes on the table.** Screen stays off.
5. Unlock: the message is there, and the header reads
   `1 DELIVERED WHILE LOCKED`.
6. Dashboard: node count, latency, and the phone's GPS position.

## Voice, fully on device (Argmax)

[argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift) supplies
**WhisperKit** for speech-to-text. Tap the mic, speak, tap stop: the transcript
is produced on the Neural Engine and sent as a normal text frame. Incoming
messages are spoken back with `AVSpeechSynthesizer`.

Nothing leaves the device except the BLE frame.

- Model: `base.en`, ~140 MB, **downloaded once on first launch while online**,
then cached and fully offline. Watch for `VOICE·READY` in the header.
- Argmax also ships **TTSKit** (Qwen-TTS) if you want the full stack; this build
uses the system synthesiser because it is instant and never waits on a model.
- Model load happens at launch, in parallel with the BLE link coming up.

## Before you publish this repo

The event logs (`dashboard/events*.jsonl`) contain the phone's live GPS
coordinates. They are gitignored and must stay that way — an earlier revision
tracked them, so **`master` history still contains coordinates from the
build session.**

Push the **`public`** branch instead. It is a single clean commit with no logs
and no positions:

```
git push origin public:main
```

A pre-push hook blocks the mistake: `tools/pre-push` refuses any push of a
branch containing coordinates. Install it after cloning:

```
cp tools/pre-push .git/hooks/pre-push && chmod +x .git/hooks/pre-push
```

If you ever need to re-create it:

```
git branch -D public && git checkout --orphan public && git add -A \
  && git commit -m "Awake" && git checkout master
```

## Architecture

```
shared/Wire.swift       length-prefixed JSON framing (both platforms)
ios/Sources/Voice.swift  WhisperKit STT + AVSpeechSynthesizer TTS
ios/Sources/Mesh.swift  CoreBluetooth central, restore identifier,
                        pending reconnect, local notifications, wake log
ios/Sources/Views.swift chat + diagnostics (the proof UI)
mac/Sources/…           CBPeripheralManager anchor + dashboard POST
dashboard/              zero-dependency Python server + single-page viz
```

Wire format is in [PROTOCOL.md](PROTOCOL.md).

## Known limits (say these before a judge finds them)

- One anchor, one phone. Multi-hop relay is the next commit, not this one.
- No encryption yet. The demo is a **transport** proof.
- If you force-quit the app from the app switcher, iOS will not wake it.
  AccessorySetupKit is the fix; it needs a real accessory to pair.
- The Mac must stay awake (`caffeinate`) or it stops advertising.
- Delivery while the app is not frontmost works when the GATT link is up.
  Recovering the link after a long suspension is the part that needs the
  overnight test.

## Roadmap

1. Multi-hop relay between anchors (store-and-forward, TTL dedupe).
2. ESP32 anchor on a coin cell — replaces the Mac, costs ~$8.
3. AccessorySetupKit pairing so the app survives force-quit.
4. X3DH + Double Ratchet; the envelope is already opaque bytes.
5. Venue mode: fixed anchors + staff dashboard.
