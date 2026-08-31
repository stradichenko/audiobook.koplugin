# AirPods Pro 3 on Kindle Paperwhite (11th gen)

Field report for **audiobook.koplugin** Bluetooth playback with Apple AirPods Pro 3
on a jailbroken **Kindle Paperwhite 11th generation** (PW11), running KOReader.

Validated in August 2026 against plugin builds **v0.1.17.15–v0.1.17.17**
(branch work that became PR [#52](https://github.com/stradichenko/audiobook.koplugin/pull/52)).

Companion Storyteller EPUB3 Media Overlay work (separate PR) was tested on the
same device with Bose QuietComfort Ultra Gen1 and later with AirPods Pro 3.

---

## Current status (what works)

| Scenario | Result |
|----------|--------|
| First play after pairing / reconnect from plugin BT UI | Works (audio reaches AirPods) |
| Continuous Storyteller / audiobook playback | Works |
| Pause → wait → Play via Kindle UI / plugin controls | Works (v0.1.17.17 keepalive + resume path) |
| Seek / skip while playing | Works (v0.1.17.18 bridges A2DP across seek-restart) |
| Auto-advance to next SMIL/playlist chunk (~4–5 min) | Works (v0.1.17.21: A2DP keepalive + soft stop; optional BT reconnect via menu) |
| Manual ⏭/⏮ chapter (Storyteller SMIL chapter) | Works (same bridge; BT cycle only if setting enabled) |
| Manual Disconnect → Connect from plugin BT menu | Restores audio if the A2DP route went stale |
| Overlay **BT** button | Removed (v0.1.17.22); use menu “Reconnect BT on track change” / BT settings |
| Volume up/down via AirPods stem | Works (system / `audiomgrd` volume path) |
| ANC on/off via stem long-press / gestures | Works on the headset (Apple BLE); no plugin involvement |
| **Stem single-press Play/Pause** | **Does not work** (see Limitations) |

Pipeline used on Kindle:

```text
ffmpeg → gst-launch-0.10 fdsrc → mixersink stream-type=Music
       → audiomgrd → btfd / Bluedroid A2DP → AirPods Pro 3
```

On firmware that ships GStreamer 1.0 only (no `gst-launch-0.10`), the same
pipeline runs under `gst-launch-1.0` with `audio/x-raw` caps and
`fdsrc do-timestamp=true`.

---

## Hardware / software under test

- **E-reader:** Kindle Paperwhite 11th generation (jailbroken, KOReader)
- **Headset:** AirPods Pro 3 (`bd_name` example: `AirPods Pro 3 de Juan - Find My`)
- **Plugin:** audiobook.koplugin (Kindle backend `kindle-gst-play`)
- **Sample content:** Storyteller EPUB3 Media Overlay (*Le Roi de fer*, and other night-generated readaloud EPUBs)
- **Also validated earlier on same Kindle:** Bose QuietComfort Ultra Gen1 (Storyteller sync / highlight path)

Bug reports used during diagnosis (device root, after repro):

- `audiobook-bug-report-20260809-071033.txt` — initial “blip then silence”
- `audiobook-bug-report-20260809-073727.txt` — pause/resume silence + stem
- `audiobook-bug-report-20260809-080541.txt` — resume-restart with dead A2DP route
- `audiobook-bug-report-20260809-083008.txt` — stem volume/ANC vs play/pause

---

## Problems we hit (and how they were fixed)

### 1. Audio starts for ~1 s then permanent silence

**Symptoms:** A2DP “connected”, sockets present, ffmpeg/gst still running or killed;
listener hears a short blip then nothing.

**Causes found in `crash.log` / bug reports:**

- Redundant `seek-by-restart` immediately after play (killed a healthy pipeline)
- Orphan-kill on PID-capture miss (`spawn-fallback`) murdering the just-started stream
- Premature pipeline exit treated as EOS

**Mitigations:** skip no-op seeks; recover PID via `pgrep`; longer AirPods `adelay`/`apad`;
treat early exit as fail + one retry; Music-focus reclaim; A2DP watchdog.

### 2. Pause then Play → silence (until manual BT reconnect)

**Symptoms:** UI shows playing, position advances, no sound on AirPods.
Manual Disconnect/Connect from the plugin BT menu restores audio.

**Root cause:** Kindle `audiomgrd` suspends the A2DP datapath when the mixer goes
idle. `SIGSTOP`/`SIGCONT` and even “resume-restart” of the content pipeline were
not enough once the route was dead. Reconnect works because `BTManager:connect`
does a **Disconnect/Connect cycle** that re-arms A2DP.

**Mitigations (v0.1.17.17):**

- On pause: halt content, start a **silence keepalive** on `mixersink` (same idea as TTS)
- On resume: keep keepalive across the content restart gap; if
  `audioOutputConnected` is still 0, **cycle BT** (Disconnect → Connect) then play
- Watchdog: same cycle + restart when the route drops mid-play

### 3. Stem Play/Pause does nothing

**Symptoms:** Stem volume and ANC work; single-press does not pause/resume KOReader.

**Finding:** `/proc/bus/input/devices` only exposes power key + touch (`bd71828-pwrkey`,
`pt_mt`). No `(AVRCP)` / Consumer Control node. `btui` is absent on this firmware.
`playermgr InPlayback` never toggles on stem press. `bt_media_control` can be on;
there is simply **no event to receive**.

See [Limitations](#limitations-airpods-stem-playpause) below.

---

## Limitations (AirPods stem Play/Pause)

**AVRCP** (*Audio/Video Remote Control Profile*) is the Bluetooth profile that
carries remote commands (Play, Pause, Next, …) from a headset to a player.

On many Linux/BlueZ stacks, those commands appear as a virtual keyboard:

```text
/dev/input/eventN   name contains "(AVRCP)" or media keys
```

The plugin’s `btmediacontrol.lua` listens for that (and Kobo D-Bus MediaPlayer1).

On **Kindle PW11 + Lab126 `btfd`/Bluedroid**:

- There is **no AVRCP input device** for third-party players using `mixersink`
- Volume still works via Absolute Volume / `audiomgrd` (`speakerVolume`)
- ANC is handled inside Apple’s BLE stack on the buds
- Stem **Play/Pause** requires the host to register as an AVRCP *target*; Amazon’s
  Audible/TTS path may do that, but our `ffmpeg|gst|mixersink` path does not get
  a Linux media-key device

**Conclusion for this platform:** stem Play/Pause is a **platform gap**, not a
missing checkbox in the plugin UI. Use on-screen controls or Kindle buttons.

---

## Pistes to push stem Play/Pause further

These are research directions, not implemented:

1. **`ace_bt` / `btmanagerd` / KindleBT** — register as an AVRCP target via Amazon’s
   proprietary IPC (`/dev/aipc/…`), similar to [Sighery/kindlebt](https://github.com/Sighery/kindlebt).
   Heavy native work; firmware-dependent.
2. **`btui UpdatePlayBackState` / `UpdateMetaData`** — present on some Kindles as an
   interactive test UI; **not found** on the PW11 under test (`kindle_btui: not found`).
3. **LIPC event subscriptions** — watch for undocumented `btfd`/`playermgr` events
   when the stem is pressed (none observed in our captures).
4. **HCI / Bluedroid snoop** — confirm whether AVRCP pass-through frames are dropped
   before userspace (Wireshark/Apple BT tooling on a PC is useful for protocol study only).

**Kobo Libra Colour (Kaleido 3):** much more promising. That device uses `mtkbtd`
(BlueZ-compatible). The plugin already has AVRCP evdev + D-Bus paths used with
other headsets (e.g. Shokz). AirPods Pro 3 stem Play/Pause should be re-tested there;
the infrastructure exists, unlike on Kindle `btfd`.

---

## Manual test checklist (PW11 + AirPods Pro 3)

Performed and passing unless noted:

- [x] Pair AirPods; connect from plugin Bluetooth UI; start Storyteller read-aloud
- [x] Audio continues past the first 1–2 seconds (no permanent silence after blip)
- [x] Pause (Kindle / UI) for several seconds → Play → audio returns on AirPods
- [x] Longer pause (~2+ minutes) → Play → audio returns (keepalive held A2DP)
- [x] Seek / chapter jump while playing
- [x] Disconnect + Connect from plugin BT menu restores audio when route was stale
- [x] Bug report fields: `kindle_apple_headset`, `kindle_btfd_list_connected`, gst PIDs
- [x] Stem volume up/down works
- [x] Stem ANC toggle works (headset-local)
- [ ] Stem Play/Pause controls KOReader — **blocked** (no AVRCP device on this firmware)
- [x] Regression context: Bose QC Ultra Gen1 previously OK for Storyteller sync on same Kindle

---

## Code touchpoints

| Area | Files |
|------|--------|
| Kindle gst play / pause keepalive / BT cycle | `mediaengine.lua` |
| Headset media buttons (evdev / Kindle stubs) | `btmediacontrol.lua`, `main.lua` |
| Hard stop clears keepalive | `mediasync.lua` |
| Diagnostics | `bugreport.lua` (`kindle_apple_headset`, input devices, `btui`) |

Related platform overview: [PLATFORM_AUDIO.md](./PLATFORM_AUDIO.md) (Kindle `btfd` / `audiomgrd` section).

---

## Deploy note

Copy the plugin tree to `koreader/plugins/audiobook.koplugin/` and **fully restart
KOReader** after updates. Partial Lua reloads are not enough for MediaEngine changes.
