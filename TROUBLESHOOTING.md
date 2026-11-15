# Troubleshooting

Every entry here is a failure that actually happened during this build, in the
order you're likely to meet it again.

---

## 60-second recovery

If something is wrong and you're about to walk on stage:

```bash
./demo.sh          # archive log, fresh dashboard, keep Mac awake, launch anchor
```

Then on the phone: **unlock it, open Awake, look for `LINKED · AWAKE-ANCHOR`.**

That fixes: dead dashboard, sleeping Mac, anchor not running, stale state,
wrong event log. It does not fix permissions or a crashed app — see below.

---

## Symptom → cause → fix

### The anchor window says `NO PHONE · QUEUEING` but the phone is right there

The anchor calls a link stale after 90 s of silence. Causes, in order:

1. **The phone app isn't open.** Unlock, open Awake.
2. **The phone moved out of range.** BLE is ~10 m indoors, ~100 m open air.
3. **The app was force-quit** (swiped away in the app switcher). iOS will not
   relaunch it. Reopen the app — this is the documented limit.
4. **Bluetooth is off on the phone**, or was toggled in Settings (toggling in
   Settings kills the restore path; the Control Center toggle is fine).

### `RADIO NOT READY · state 2`, and the phone can't see the anchor

State 2 is *unsupported* — on a Mac that usually means the **app bundle's code
signature is broken**, not that Bluetooth is missing. Repeated incremental
builds can leave the bundle inconsistent:

```
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/Awake-*/Build/Products/Debug/AwakeNode.app | head -1)
$ codesign -v --deep "$APP"
…: code has no resources but signature indicates they must be present
$ codesign -dvv "$APP" | grep TeamIdentifier
TeamIdentifier=not set
```

Fix it with a clean build, then relaunch:

```
xcodebuild -project Awake.xcodeproj -scheme AwakeNode \
  -destination 'platform=macOS' clean build
```

The anchor log should show `advertising as AWAKE-ANCHOR` within a second.

This happened repeatedly during the build session and cost fifteen minutes the
first time, because it looks exactly like a Bluetooth problem — the menu bar
said Bluetooth was On the whole time. **Check the signature before you touch
Bluetooth.**

It had a cause worth knowing: `./verify.sh` builds with
`CODE_SIGNING_ALLOWED=NO` into the same DerivedData directory that `demo.sh`
launches from, so **verifying the app replaced it with an unsigned copy** and
the next launch reported "unsupported". `verify.sh` now builds into
`/tmp/awake-verify`, leaving the app you actually run untouched. If this
recurs, ask what last rebuilt the bundle.

### The anchor says `RADIO NOT READY` with any other number

macOS denied Bluetooth to the anchor.

**System Settings → Privacy & Security → Bluetooth → enable "Awake Anchor".**
Then quit and reopen the anchor. It must read `AWAKE-ANCHOR · ADVERTISING`.

### The app flashes and closes on launch

Historically: `allowsBackgroundLocationUpdates` set before authorization raised
an exception. That is fixed and guarded — but if it recurs, the phone log will
show how far it got:

```bash
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer \
  --domain-identifier com.antranigbaghdassarian.awake \
  --source Documents/awake.log --destination /tmp/dev.log
cat /tmp/dev.log
```

### The phone is connected but nothing ever gets through

Look at the phone log for these, in order:

| Log line | Meaning |
|---|---|
| `state CBManagerState 5` | Bluetooth authorised and on |
| `restored peripheral already connected` | iOS handed back a live link |
| `restored link — re-discovering services` | the fix for the mute-link bug |
| `ready subscribed — wakes on lock` | **this** is the line that means it works |
| `ack delivered in N ms` | a round trip completed |

If it stops after `CBManagerState 5`, service discovery failed — force-quit and
reopen the app.

### Nothing arrives on a locked phone, but it works unlocked

- **Force-quit** defeats delivery. Reopen the app.
- **Low Power Mode** throttles background radio work. Turn it off.
- If it persists, run `./demo.sh --probe` (one probe every 5 minutes) and watch
  `python3 tools/report.py` — you'll get a delivery rate instead of a guess.
  Quit and re-run `./demo.sh` without the flag to stop probing.

### The dashboard is blank or won't load

```bash
lsof -nP -iTCP:8787 -sTCP:LISTEN      # is anything on the port?
python3 dashboard/server.py            # run it in the foreground to see errors
```

Port 8080 is taken by a local model server on this machine — the dashboard uses
**8787** deliberately.

### Events disappeared

They didn't; the server restarted with an empty in-memory list and replays from
disk on boot. `dashboard/events.jsonl` is the source of truth. If it's missing,
`demo.sh` archived it as `events-HHMM.jsonl`.

### `./install.sh` fails with a device error

The iPhone is locked or unreachable.

```
xcrun devicectl list devices        # needs "available (paired)" / "connected"
```

Unlock the phone, keep it near the Mac, and re-run.

### Build fails: bundle identifier not available, or "no profiles for …"

`project.yml` carries the author's `DEVELOPMENT_TEAM` and two bundle IDs, so a
device build on any other machine fails — with an error that names neither.
Change all three and regenerate:

```
DEVELOPMENT_TEAM: <your team id>
PRODUCT_BUNDLE_IDENTIFIER: <your.bundle.id>     # both targets
```

`xcodegen generate`, then `./install.sh`.

Simulator builds need none of this: `./verify.sh` passes
`CODE_SIGNING_ALLOWED=NO`. Find your team ID with
`security find-identity -v -p codesigning` and read the value in parentheses.

### Build fails: Time Sensitive Notifications capability

A personal development team does not support it. The entitlement was removed
deliberately; the app falls back to a normal alert. Do not add it back unless
you're on a paid team.

### `swift test` complains about `iOS(.v18)`

The package manifest targets `.v17` on purpose — swift-tools 5.9 doesn't know
about v18. Changing it breaks `swift test`.

---

## After you restart the anchor, the phone takes ~30 seconds

A killed anchor doesn't announce itself. The phone's BLE stack can hold a
stale connection for up to half a minute before it notices and relinks. If you
restart the anchor and immediately send, the message is **queued, not lost** —
it replays the moment the link returns.

`./dryrun.sh` knows this and waits for `hello from` in the anchor log before it
measures anything.

## The anchor has a log file too

```
~/Library/Application Support/AwakeAnchor/anchor.log
```

Radio state, subscriptions, every send and ack. If the window says
`RADIO NOT READY`, the numeric state here is the diagnosis:
`0` unknown · `1` resetting · `2` unsupported · `3` unauthorized · `4` off.

## Reading the two logs

**Phone** (`Documents/awake.log`) — what the app experienced, including things
that never reach the dashboard because the app was suspended at the time.

**Dashboard** (`http://localhost:8787`) — what the anchor observed: receipts,
latency, queue depth, positions.

When they disagree, the phone log is usually right: the anchor only knows what
arrived.

## The last resort

```bash
./verify.sh                     # tests + both builds + dashboard
./install.sh                    # rebuild and reinstall on the phone
./demo.sh                       # clean restart of everything
```

If `verify.sh` is green and the phone still won't link, it's a permission —
Bluetooth, Location, Notifications, or Microphone. Check
**Settings → Awake** on the phone.
