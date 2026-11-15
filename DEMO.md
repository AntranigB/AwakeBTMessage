# Demo script — 90 seconds

**Live only — no recording.** That means the fallbacks below have to carry the
claim on their own; they use the dashboard's receipt and the phone's own
transcript, both of which exist whether or not anyone is watching.

Rehearse it twice, live, exactly as written. The second run should be boring.

## Before you walk up

- [ ] `./demo.sh` run — it resets the log, keeps the Mac awake, opens both windows
- [ ] **`./dryrun.sh` says READY** — this is the only check that proves a message will actually arrive. If it fails, read the causes it prints; do not walk up.
- [ ] Dashboard open on the projector at `localhost:8787`
- [ ] Anchor header reads **PHONE LINKED** in green
- [ ] iPhone connected: header shows `LINKED · AWAKE-ANCHOR`
- [ ] Notifications allowed, phone **not** on silent, volume up
- [ ] Airplane mode already on, Bluetooth on, Wi-Fi off
- [ ] Phone screen locked, face down on the table — **keep it locked for the
text beat.** While Awake is frontmost it speaks every incoming message aloud,
so an unlocked phone narrates your demo in a synthetic voice. That's the voice
feature working; it's only wanted at the 1:00 beat.
- [ ] The phone has been within a metre of the Mac for the last few minutes —
  not in a bag, not in a pocket across the room

## The script

**0:00 — the problem, in one sentence**

> "Every offline messenger works great — until you put your phone in your
> pocket. Lock the screen and delivery stops. That's the exact moment you need
> it."

**0:10 — show the phone**

Hold it up. Lock screen visible. Airplane icon, no bars, Wi-Fi off.
Put it face down on the table. Leave it there for the rest of the demo.

**0:20 — show the anchor**

> "This is the anchor. In production it's an eight-dollar BLE board on a
> keyring. Right now it's my laptop, running the same code."

**0:30 — send**

Type `where are you` in the anchor. Press return.

**Wait. Do not talk over the silence.** Two beats.

**The phone buzzes.** Pick it up, show the notification on the lock screen,
still locked. Then unlock and show `1 DELIVERED WHILE LOCKED`.

> "That was about fifty milliseconds. Phone locked, no Wi-Fi, no cell."

If the phone had been out of range, the anchor would have held the message and
handed it over on reconnect — the log shows that working too, 84 seconds late.
That's the difference between a chat app and a messaging service.

**0:50 — the receipt**

Dashboard: the `LAST ACK` figure, node count, message count.

> "Round-trip receipt. Not a guess — the phone acked it."

**1:00 — voice (the local-AI beat)**

Tap the mic on the phone and say `meet me at the north gate`. Tap stop. The
transcript appears and goes out over BLE — the anchor receives it.

**Then type a reply in the anchor** (`on my way`) and the phone speaks it aloud.
The phone only speaks messages it *receives*; it will not read back what it
sent.

> "Whisper, running on this phone, no network. The only thing that crossed the
> air was a text frame."

Watch for `VOICE·READY` before you start — the first run downloads the model.

**1:10 — location**

Tap the location button on the phone. Pin and coordinates land on the
dashboard.

> "Same link, so search-and-rescue gets a position without a network."

**1:25 — the honest close**

> "What you saw is real: BLE only, no Wi-Fi, no cell, phone locked.
> Message bodies are sealed with ChaChaPoly — but the key is shared and
> published, so it stops casual interception, not a determined attacker.
> What's genuinely missing is multi-hop between anchors and forward-secret
> keys."

**Stop talking.** Let them ask.

## If it fails

1. **No connection** — the Mac went to sleep. `caffeinate` should prevent it;
   wake the Mac, wait, reconnect.
2. **Notification doesn't appear** — check Focus mode and the notification
   permission. Fall back to showing the in-app `DELIVERED WHILE LOCKED` counter
   after unlocking, and the `ack` line on the dashboard, which is independent
   of notifications entirely.
3. **Everything fails** — the claim survives without the buzz. Say *"the receipt
   is the evidence, not the notification"*, then show the dashboard's last `ack`
   and p50, and the message in the phone's transcript. If there is no message
   either, stop demonstrating and explain the design — do not debug on stage.

## Questions you will get

**"Why not just use iMessage?"**
iMessage has no offline transport; it's a cloud service. And Apple gives no API
to add one. We're not replacing iMessage — we're the layer that works when
there is no server at all.

**"Isn't this Bridgefy / Meshtastic / Totem?"**
Those need both phones awake, or bespoke hardware, or Android. Totem does
friend-finding with a wearable at festivals — great product, different shape.
We're phone-native and the anchor is generic infrastructure.

**"What about encryption?"**
Not yet. Next commit is X3DH + Double Ratchet. The frame is opaque bytes, so
nothing below it changes.

**"Why will Apple allow this?"**
Nothing here needs a private API. Background BLE + notifications + state
restoration are all documented, supported behaviour.
