# PITCH — five slides

Speaking notes. One idea per slide, numbers you can defend.

---

## 1 · The problem

> "Every offline messenger works beautifully — until you put your phone in your
> pocket. Lock the screen and iOS suspends the app, so delivery stops. That is
> precisely the moment you need it."

- Concerts, stadiums, festivals: the network saturates. A 2026 study of Notre
  Dame Stadium measured **5,983 ms** P90 time-to-first-byte and a **46%**
  image-upload failure rate on cellular at full crowd.
- Disasters: towers go down or get congested.
- Backcountry: no bars, no problem — until someone twists an ankle.

**The punchline:** every existing app requires both phones awake, or a wearable
per person, or a radio per person.

---

## 2 · The insight

> "iOS won't let a suspended app scan or advertise. But it *will* wake an app
> for a notification from a **connected** Bluetooth peripheral. So we inverted
> the design."

```
   phone  ──BLE──▶  always-on anchor  ──▶  phone stays reachable
   (locked)          (a $8 board)
```

- Phones discovering phones = dies on lock.
- One always-on anchor holding the link = the phone gets woken, delivers, acks.

We found this by measuring, not by assuming. The first overnight run **failed**
— and that failure pointed at five real bugs, all now fixed and tested.

---

## 3 · The demo

> "Phone in airplane mode. Wi-Fi off. Locked, face down on the table."

- Anchor sends a message.
- **Phone buzzes. Delivered and acknowledged in about fifty milliseconds.**
- Dashboard shows the ack, the p50 latency, the queue depth, and the GPS pin.

> "That one landed on a phone whose app was in the background — about fifty
> milliseconds. Over an eleven-minute run we delivered **23 of 23**, p50 40 ms,
> including 688-byte messages split across five Bluetooth writes. That run had
> the app open. This one didn't."

Then the harder one:

> "Walk out of range and it queues. Walk back and it replays — 84 seconds late,
> still accepted by a locked phone."

That second behaviour is the difference between a chat app and a messaging
service: **absence stops being loss.**

---

## 4 · What's real

| Working now | Not yet |
|---|---|
| Delivery with the app backgrounded — **56 ms**, 2 verified | multi-hop between anchors |
| 688-byte frames fragmented over 5 writes — **70 ms** | venue management console |
| store-and-forward with replay (**84 s**, verified) | forward-secret encryption (X3DH) |
| ChaChaPoly body encryption — 6 tests | LoRa transport |
| on-device Whisper speech→text (**Argmax**) | survives force-quit (needs a real accessory) |
| on-device TTS | venue management console |
| **35 unit tests**, fuzzed framing | |

Say the right column out loud before a judge finds it. That has never lost a
hackathon; being caught does.

---

## 5 · Why us

> "Totem sells a wearable to every attendee. We sell coverage to the venue."

| | phones-only apps | Totem | Meshtastic | **Awake** |
|---|---|---|---|---|
| delivers to a locked phone | no | n/a | partly | **56 ms, verified** |
| hardware per person | none | a Compass | a radio | **none** |
| who deploys | nobody | attendee buys | hobbyist | **the venue** |
| survives leaving range | no | no | yes | **yes** |

**The buyer:** festivals, stadiums, campuses, hospitals, cruise lines. They
already buy DAS, Wi-Fi, and radios for staff. Awake is the layer that keeps
working when all of that is saturated — and it is the only one that needs
nothing from the person in the crowd.

**Close:** *"Every offline messenger dies when your phone locks. We measured
it, fixed it, and it's 56 milliseconds."*

---

## Numbers to have ready

- **23 / 23** — messages delivered over 11 minutes, **app open**, p50 40 ms
- **2** — delivered with the app backgrounded: 56 ms live, 84 s replayed
- **126 ms** — worst case across the run; p95 102 ms
- **56 ms** — the fastest single-message ack measured (live runs vary; say
  "about fifty" unless the screen shows a number)
- **688 B frame / 5 writes / 70 ms** — fragmentation costs nothing measurable
- **84 s** — queued replay after the phone left and came back
- **35** — unit tests, 0 failures
- **8** — dollars, the anchor hardware in production
- **~100 m** — BLE range per hop, open air (vendor figure, not measured here;
  indoors it is closer to 10 m)
- **300** — randomised BLE chunkings tested for reassembly

## If asked "why not iMessage"

iMessage has no offline transport and Apple exposes no API to add one. We are
not replacing iMessage; we are the layer that works when there is no server at
all — including Apple's.
