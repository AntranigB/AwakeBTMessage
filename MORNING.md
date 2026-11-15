# Morning plan

You have a few hours. This is the order that maximises the chance the demo
lands. Everything here has been run at least once tonight.

---

## 0–10 min · get it running

1. **Plug the Mac in and open the lid.** Closing it suspends the anchor; there
   is no fix for clamshell sleep.
2. Keep the phone on the same desk, unlocked.
3. Run the bootstrap:

   ```
   cd awake
   ./demo.sh
   ```

   Archives the old log, starts the dashboard, arms `caffeinate`, launches the
   anchor, opens http://localhost:8787.
4. Unlock the phone and **open Awake**. Two things must be true:
   - anchor window: **PHONE LINKED** (green)
   - phone header: **LINKED · AWAKE-ANCHOR**
5. Run the dry run:

   ```
   ./dryrun.sh
   ```

   Must end in **READY** with an ack (we have measured 46–76 ms). This is the
   only check that proves a message will actually arrive.

> If the phone does not relink: it takes up to ~30 s after the anchor starts.
> If `RADIO NOT READY · state 2` appears, the app bundle's signature is broken —
> `xcodebuild … clean build`. Do not touch Bluetooth; it is not the problem.

---

## 10–20 min · make it audible and prepared

- **Silent switch off**, volume up, no Focus mode. Delivery is otherwise silent
  and you will think it failed.
- Open Awake and wait for `VOICE·READY` in the header. **The model is already
  on the device** — verified: 39.3 MB audio encoder + 99.3 MB text decoder +
  346 KB mel spectrogram, ~139 MB total, cached at 04:32. It should appear
  within a few seconds, not download. If it says `VOICE·LOADING` for minutes,
  the app needs internet once; without it the voice beat fails and text works.
- Settings → Awake: Notifications, Bluetooth, Location **While Using**,
  Microphone — all allowed.
- Check the battery figure on the dashboard footer. Below 20% it turns orange;
  plug the phone in.

---

## 20–35 min · rehearse it live

No recording — so the live run **is** the rehearsal. Do it twice.

1. Airplane mode on, then Bluetooth back on. Wi-Fi off.
2. Lock the phone, face down on the table, within a metre of the Mac.
3. Type `where are you` in the anchor, press **SEND**.
4. It buzzes. Unlock, look at the transcript and at `1 DELIVERED WHILE LOCKED`.
5. Relaunch Awake so the counter returns to 0 for the real run.

**Before you walk up, relaunch Awake once.** The `DELIVERED WHILE LOCKED`
counter is cumulative since the app last started — after rehearsal it will read
`3`, not `1`. A relaunch resets it. The transcript persists; only the counter
resets.

---

## 35–60 min · rehearse the words

Follow [DEMO.md](DEMO.md). Time yourself. The beats that matter:

- **the problem in one sentence** (10 s)
- **the lock, the send, the buzz** (20 s, mostly silence)
- **the numbers**: 23/23 over 11 minutes with the app **open**, p50 40 ms,
  688-byte frames across five BLE writes — and **56 ms** to a phone whose app
  was in the background. Say the second one; it's the interesting one.
- **the honest limits**: single hop, shared-key crypto, force-quit still
  defeats wake

Say the limits before a judge finds them.

---

## Before you walk up

```
./status.sh     # anchor running · Mac awake · dashboard up · phone reachable
./dryrun.sh     # READY
```

`./verify.sh` is safe at any point — it builds in an isolated directory
(`/tmp/awake-verify`) and starts the dashboard if needed, so it cannot disturb
the anchor you are about to demo. Tested in sequence: demo → dryrun → verify →
dryrun, no relaunch, healthy round trip after.

Then: dashboard on the projector, phone locked, anchor window visible.

**Don't restart anything after this point.** A restart costs ~30 s of relink
and there is no reason to spend it.

---

## If it breaks on stage

| Symptom | Say this | Do this |
|---|---|---|
| Phone doesn't buzz | "the receipt is the evidence" | Show the dashboard `ack`, then unlock and show the transcript |
| `NO PHONE · QUEUEING` | "it's holding the message" | It will replay on reconnect — that's the feature, not a fault |
| Dashboard blank | "the panel is local" | Keep talking; the phone is the demo |
| Nothing works | — | Stop demonstrating; explain the design. Don't debug on stage. |

Nothing on stage is worth improvising for. If the live path fails you show the
receipt, not a workaround.

---

## The one sentence

> Every offline messenger dies when your phone locks. We measured it, fixed it,
> and it's about fifty milliseconds.
