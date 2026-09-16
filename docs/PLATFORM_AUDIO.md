# Platform Audio & Bluetooth Architecture

Comprehensive reference of how the plugin routes TTS audio to the user on each
supported platform. Covers the Bluetooth stack, audio pipeline, pairing
mechanism, failure detection, and known limitations per device generation.

---

## Quick Comparison

| Component | Kobo (MTK) | Kobo (BlueZ) | Kindle | Android |
|-----------|-----------|--------------|--------|---------|
| BT daemon | `mtkbtd` | `bluetoothd` (BlueZ) | `btfd` (Lab126) | OS-managed |
| IPC bus | D-Bus (`com.kobo.mtk.bluedroid`) | D-Bus (`org.bluez`) | LIPC (Lab126 IPC) | JNI / Binder |
| A2DP negotiation | BlueZ profiles via MTK wrapper | BlueZ profiles | `btfd` internal | OS-managed |
| Audio sink | `mtkbtmwrpcaudiosink` (GStreamer) | `aplay -D bluealsa` | `aplay` (if ALSA exposed) | Android `MediaPlayer` |
| Speaker | No | No | No (PW2 and later); Yes on K2/K3/DXG/K4/Touch/PW1 | Yes (usually) |
| BT pairing | Plugin UI (D-Bus) | Plugin UI (`bluetoothctl`) | Kindle Settings only | OS Settings only |
| Failure detection | Socket early-death (<500ms) | Rapid-exit (<200ms) | Rapid-exit (<200ms) | JNI error code |
| Plugin manages BT power | Yes (D-Bus) | Yes (`bluetoothctl`) | Yes (`lipc-set-prop`) | No |

---

## 1. Kobo -- MTK Bluetooth Stack

**Devices:** Clara 2E, Sage, Libra Colour (dual-core ARM Cortex-A7/A9)

### Bluetooth

| Property | Value |
|----------|-------|
| Daemon | `mtkbtd` (MediaTek proprietary, BlueZ-compatible D-Bus interface) |
| D-Bus destination | `com.kobo.mtk.bluedroid` |
| D-Bus adapter path | `/org/bluez/hci0` |
| D-Bus device interface | `org.bluez.Device1` |
| Detection method | `gst-inspect-1.0 mtkbtmwrpcaudiosink` (primary), D-Bus name check (secondary) |
| Abstract socket | `@kobo:mtkbtmwrpc` (exclusive -- one pipeline at a time) |

### Audio Pipeline

GStreamer persistent pipeline over FIFO:

```
┌──────────┐    ┌──────────────┐    ┌──────────────┐    ┌───────────────┐    ┌─────────────────────┐
│ filesrc   │───>│ rawaudioparse │───>│ audioconvert  │───>│ audioresample  │───>│ mtkbtmwrpcaudiosink │
│ (FIFO)   │    │ S16LE mono   │    │              │    │  → 48kHz 2ch  │    │                     │
└──────────┘    └──────────────┘    └──────────────┘    └───────────────┘    └─────────────────────┘
```

| Property | Value |
|----------|-------|
| Input format | S16LE mono (Piper output, typically 22050 Hz) |
| Output format | S16LE stereo 48 kHz (A2DP standard) |
| FIFO path | `/tmp/audiobook_fifo` |
| Control dir | `/tmp/audiobook_ctrl/` |
| GStreamer PID file | `/tmp/audiobook_ctrl/gst_pid` |
| Pipe buffer | 16 KB (370ms latency) or 64 KB (1500ms latency) |
| `sync` property | `false` (uses socket backpressure, not GStreamer clock) |

**One-shot pipeline** (first sentence or retry):

```
gst-launch-1.0 filesrc location="{WAV}" \
  ! wavparse ! audioconvert ! audioresample \
  ! "audio/x-raw,format=S16LE,rate=48000,channels=2" \
  ! mtkbtmwrpcaudiosink
```

**Keepalive silence** (holds A2DP socket between sentences):
- 120 seconds of silence streamed through the persistent pipeline
- Prevents BT A2DP idle timeout (~1-2s)
- Cancelled immediately when the next sentence is ready

### Socket Management

The `@kobo:mtkbtmwrpc` abstract socket is exclusive. Only one GStreamer
pipeline can hold it. On startup the plugin kills orphan `gst-launch-1.0`
processes from previous sessions:

```
1. Read /proc/net/unix for @kobo:mtkbtmwrpc
2. If held: killall -9 gst-launch-1.0, wait 200ms
3. Retry up to 5 times
```

`_socket_clean` flag tracks whether the socket was released cleanly:
- `true` after normal completion -- next pipeline launches immediately
- `false` after SIGKILL -- adds 300ms delay before re-launch

### Failure Detection

| Condition | Threshold | Action |
|-----------|-----------|--------|
| Early death | <500ms | Retry once (0.5s delay), then retry with skip-on-fail (2s delay), then stop |
| Premature exit | <40% of expected duration (sentences >2s) | Retry with 2s delay for A2DP re-negotiation |
| Socket still held | 5 retries | `killall -9 gst-launch-1.0` between attempts |

### Pairing

Three strategies in priority order:

1. `bluetoothctl --agent {ADDR}` (BlueZ >= 5.49)
2. `bluetoothctl` with piped agent commands (older BlueZ)
3. Raw D-Bus `Device1.Pair` call (last resort)

Scanning: `bluetoothctl scan on` or D-Bus `StartDiscovery`, 30s default timeout.

---

## 2. Kobo -- BlueZ Bluetooth Stack

**Devices:** Libra 2, Io (dual-core)

### Bluetooth

| Property | Value |
|----------|-------|
| Daemon | `bluetoothd` (standard Linux BlueZ) |
| D-Bus destination | `org.bluez` |
| Adapter path | `/org/bluez/hci0` |
| Adapter interface | `org.bluez.Adapter1` |
| Device interface | `org.bluez.Device1` |
| Properties interface | `org.freedesktop.DBus.Properties` |
| Object manager | `org.freedesktop.DBus.ObjectManager` |
| Binary search order | `/libexec/bluetooth/bluetoothd`, `/usr/libexec/bluetooth/bluetoothd`, `/usr/lib/bluetooth/bluetoothd`, `which bluetoothd` |

### Audio Pipeline (BlueALSA)

```
┌─────────────┐    ┌──────────────┐    ┌─────────────────────────────┐    ┌──────────────┐
│ WAV file    │───>│ aplay -D     │───>│ libasound_module_pcm_       │───>│ bluetoothd   │
│             │    │   bluealsa   │    │   bluealsa.so (ALSA plugin) │    │ → A2DP sink  │
└─────────────┘    └──────────────┘    └─────────────────────────────┘    └──────────────┘
```

Playback command:

```bash
ALSA_PLUGIN_DIR={plugin_dir}/bluealsa/lib/alsa-lib \
LD_LIBRARY_PATH={plugin_dir}/bluealsa/lib \
aplay -q -D bluealsa {WAV_FILE}
```

| Property | Value |
|----------|-------|
| ALSA PCM device | `bluealsa` |
| Audio format | WAV (as generated by Piper/eSpeak) |
| BlueALSA profile | `a2dp-sink` |
| Playback type | `"bluealsa"` |

### BlueALSA Bundle

Cross-compiled via Nix (`cross-build-bluealsa.nix`):

| Property | Value |
|----------|-------|
| Target | `armv7l-hf-multiplatform` (ARM EABI hard-float) |
| AAC support | Disabled (SBC sufficient, avoids fdk-aac patent issues) |
| systemd | Disabled (Kobo has none) |
| hcitop / rfcomm | Disabled (trim dependencies) |

**Directory structure:**

```
bluealsa/
  bin/bluealsa                              -- daemon
  lib/
    ld-linux-armhf.so.3                     -- bundled glibc dynamic linker
    libsbc.so                               -- SBC codec (standard BT audio)
    libglib-2.0.so                          -- GLib event loop
    libdbus-1.so                            -- D-Bus client library
    libbluetooth.so                         -- BlueZ library
    alsa-lib/
      libasound_module_pcm_bluealsa.so      -- ALSA PCM plugin
      libasound_module_ctl_bluealsa.so      -- ALSA control plugin
  etc/alsa/conf.d/
    20-bluealsa.conf                        -- ALSA device definition
  share/dbus-1/system.d/
    bluealsa.conf                           -- D-Bus policy (root → org.bluealsa)
```

**Installation on device (first-time):**

1. Copy D-Bus policy to `/etc/dbus-1/system.d/bluealsa.conf`, then `killall -HUP dbus-daemon`
2. Append `20-bluealsa.conf` to `/etc/asound.conf` (if `pcm.bluealsa` not already present)
3. Start daemon:
   ```bash
   LD_LIBRARY_PATH={dir}/lib \
   {dir}/ld-linux-armhf.so.3 \
   {dir}/bluealsa --profile=a2dp-sink 2>/dev/null &
   ```

### Pairing

Same three-strategy approach as MTK (see above). The plugin starts
`bluetoothd` automatically and resets the HCI adapter when the user powers on
Bluetooth from the plugin menu.

### Failure Detection

| Condition | Threshold | Action |
|-----------|-----------|--------|
| Rapid exit | <200ms with `_no_real_audio_output` | Counter ++ ; after 3 → stop + error message |
| No soundcard | `/proc/asound/cards` = "no soundcards" | Set `_no_real_audio_output`, block playback if no BT connected |

---

## 3. Kobo -- Single-Core Devices (No Bluetooth)

**Devices:** Clara (original), Clara HD, Nia, Touch 1-2 (ARM Cortex-A8, ~1 GHz, 256-512 MB RAM)

### Bluetooth

Not available. No BT hardware.

### Audio Pipeline

| Property | Value |
|----------|-------|
| Player | `aplay -q` (if soundcard detected) or fallback chain |
| Fallback chain | `aplay` → `paplay` → `mpv` → `mplayer` → `play` (sox) |
| Playback type | `"aplay"` or `"generic"` |

### TTS Optimization (Single-Core)

| Property | Value |
|----------|-------|
| Piper batch size | 3 (amortize FIFO overhead) |
| Queue depth | 1 (no benefit from multiple queues) |
| Piper servers | 1 (avoids CPU contention) |

These values are auto-detected from `/sys/devices/system/cpu/possible`.

### Failure Detection

Same rapid-exit (<200ms) detection as BlueZ Kobo. The `_no_real_audio_output`
flag blocks playback before it starts if no soundcard and no BT device is
connected, preventing CPU-wasting `aplay` loops that can crash single-core
devices.

---

## 4. Kindle

**Confirmed device:** Kindle Basic 2022 (11th Gen) -- speakerless
**Legacy generation:** Kindle 2/DXG/3/4/Touch/PW1 (2007-2011) -- built-in
speaker, real ALSA, no Bluetooth (see the subsection below)
**Also field-tested:** Kindle Paperwhite 11th gen + Apple AirPods Pro 3 (see
[AIRPODS_PRO3_KINDLE.md](./AIRPODS_PRO3_KINDLE.md) for playback fixes, pause
keepalive, and AVRCP stem limitations).

### Bluetooth

| Property | Value |
|----------|-------|
| Daemon | `btfd` (Lab126 Bluetooth File Daemon, proprietary) |
| IPC | LIPC (Lab126 Inter-Process Communication) -- **not** D-Bus |
| BT control binary | `lipc-set-prop` / `lipc-get-prop` |
| LIPC services probed | `com.lab126.btfd`, `com.lab126.btService`, `com.lab126.cmd`, `com.lab126.acsbt` |
| Read properties | `btEnabled` (0/1), `btPowerState`, `BTstate` (int, Kindle Basic 2022) |
| Write properties | `btEnabled` (0/1 or "true"/"false"), `BTenable` ("true"/"false", Kindle Basic 2022), `btPowerState` |
| Paired devices | `btPairedDevicesList` (LIPC property) |
| Connected devices | `btConnectedDevices`, `BTconnectedDevName` (LIPC properties) |

**NOTE:** Read and write properties may differ by name and type across Kindle
generations (e.g., `BTstate` for reading vs `BTenable` for writing on the
Basic 2022).

**AVRCP / headset buttons:** Kindle `btfd` does **not** expose a Linux
`(AVRCP)` input device for third-party `mixersink` players. AirPods stem
volume/ANC can still work; stem Play/Pause does not reach the plugin.
Kobo `mtkbtd` is different — see `btmediacontrol.lua` and the AirPods doc.

### Audio Pipeline

**Problem:** Amazon does not expose BT headphones as ALSA devices. The
`/proc/asound/cards` file reports "no soundcards" even with BT headphones
paired and connected. `aplay -l`, `aplay -L`, `/dev/snd/`, and PulseAudio are
all empty.

Amazon routes BT audio internally through `btfd` via a proprietary pipe. There
is **no known userspace path** to inject PCM data into this pipe from a
third-party process.

**Current probing strategy** (v0.1.5.25):

```
1. aplay -l          → parse "card N: ... device M:" → hw:N,M
2. aplay -L          → prefer BT names (blue*, a2dp, bt*), skip default/null/surround*
3. /dev/snd/         → check for pcm nodes
4. pactl list sinks  → check PulseAudio (newer firmware)
5. Nothing found     → set _no_real_audio_output = true
```

Steps 1-4 describe post-2012 hardware, where they correctly find nothing:
on PW2 and later, Amazon exposes no ALSA card at all. On the 2007-2011
speaker generation the plugin short-circuits earlier: the legacy model
list plus one cached `aplay -l` probe select the `plughw` aplay route
before any audiomgrd/BT logic runs (see below).

If a device is found in steps 1-4:
- **ALSA device:** `aplay -q -D {device}`
- **PulseAudio sink:** `paplay`

If nothing is found, the rapid-fail detector catches `aplay` exiting in <200ms
(3 consecutive failures → stop + error message asking user to send bug report).

### Pairing

**Not supported by the plugin.** Users must pair via Kindle Settings. The
plugin can only toggle BT power on/off via `lipc-set-prop`.

```lua
-- Pairing attempt returns immediately:
return false, "Pair through Kindle Settings"
```

### Legacy speaker Kindles (2007-2011)

Everything above describes PW2-and-later hardware. The 2007-2011 generation
is a different world: **Kindle 2, DXG, 3, 4, Touch, and PW1** all have a
built-in speaker (WM8962-class codec on the Touch) driven by a real ALSA
card, and they have **no Bluetooth hardware at all**, so every BT route in
this document is unreachable there. KOReader ships them the `kindle-legacy`
(K2/DXG/3) or `kindle` / kindle5-toolchain (K4/Touch/PW1) flavor: soft-float
Cortex-A8, kernel 2.6.x, glibc from that era.

The regular bundled armhf binaries cannot execute on these devices: the
static `bin/ffmpeg` is hard-float with VFPv4 fused-MAC instructions and a
static glibc that refuses kernels below 3.2, and the bundled espeak-ng runs
through the bundled glibc 2.42 loader. The plugin therefore carries two
additional static musl binaries (soft-float-era compatible, no loader, no
glibc floor, VFPv3-D16 FPU pin):

- `bin/ffmpeg-legacy`: decoder subset (aac/mp3/flac/vorbis/opus/ac3/alac/wma,
  mov/mp3/ogg/flac/asf/wav/mkv demuxers) selected first on legacy models and
  used by the `ffmpeg-pipe` backend (`ffmpeg | aplay`). On premature decoder
  death the completion watcher retries once with the next candidate binary.
- `espeak-ng-legacy/bin/espeak-ng`: static espeak-ng that reuses the bundled
  `espeak-ng/share` voice data via `ESPEAK_DATA_PATH`; the TTS route on these
  models is the ESPEAK backend played through the device `aplay`.

Detection is `Utils.isLegacyKindleModel()` (KOReader `Device.model` against
the six-model list) plus one cached `aplay -l` probe
(`Utils.probeKindleAlsaCard()` → `plughw:N,M`). On legacy models the plugin
skips the BT-only gates (`_audioOutputReady`, the "no built-in speaker"
refusals, the BT pre-flight toast) and the TTS audio player resolves to
`aplay -q -D plughw:N,M`. A one-shot `lipc-set-prop com.lab126.audiomgrd
setFocus 'Music'` covers fw 5.x mixer routing. Piper is refused on legacy
models (armhf binary, and 256 MB cannot hold the model); sanoTTS selection
is untouched.

### btfd Reverse-Engineering Diagnostics (v0.1.5.25)

The bug report collects data to understand how `btfd` routes PCM to BT
headphones:

| Diagnostic | Command | What it reveals |
|-----------|---------|-----------------|
| btfd PID | `pidof btfd` | Whether daemon is running |
| Command line | `cat /proc/{pid}/cmdline` | Startup flags and configuration |
| Open file descriptors | `ls -la /proc/{pid}/fd/` | Sockets, pipes, device files used for audio I/O |
| Unix sockets | `cat /proc/{pid}/net/unix` | IPC endpoints btfd listens on or connects to |
| Memory maps | `cat /proc/{pid}/maps \| grep audio\|alsa\|...` | Shared libraries loaded (audio/SBC/BT codecs) |
| HCI devices | `ls /dev/hci*`, `ls /sys/class/bluetooth/`, `hciconfig -a` | Whether raw HCI access is possible |
| D-Bus | `pidof dbus-daemon`, `dbus-send ... ListNames \| grep blue` | Whether D-Bus/BlueZ exist at all |
| BT unix sockets | `cat /proc/net/unix \| grep bt\|audio\|a2dp` | System-wide BT audio IPC paths |
| Amazon TTS service | `lipc-probe com.lab126.kaf.TTSService` | Properties of Amazon's built-in TTS |
| Amazon audio player | `lipc-probe com.lab126.audioPlayer` | Properties of Amazon's audio player service |

### LIPC Playback via playermgr (v0.1.5.27)

v0.1.5.26 diagnostics revealed the full Kindle audio architecture:

- `audiomgrd` loads `audio.a2dp.default.so` (Android A2DP HAL) and `libmixerAPI.so.1.0`
- `playermgr` is a GStreamer-based media player exposed via LIPC (confirmed by `gstLogLevel` property)
- BT audio uses Android Bluedroid stack with `@/data/misc/bluedroid/.a2dp_ctrl` socket

Audio pipeline:
```
playermgr (GStreamer) → audiomgrd (mixer) → audio.a2dp.default.so → .a2dp_data → BT headphones
```

Plugin implementation (`audio_player_type = "kindle-lipc"`):
```
lipc-set-prop com.lab126.playermgr Stop ''      -- stop previous
lipc-set-prop com.lab126.playermgr Open '<path>' -- load WAV
lipc-set-prop com.lab126.playermgr Play ''       -- start playback
lipc-get-prop com.lab126.playermgr InPlayback    -- poll completion (0 = done)
lipc-set-prop com.lab126.playermgr Pause ''      -- pause
lipc-set-prop com.lab126.playermgr Play ''       -- resume
lipc-set-prop com.lab126.playermgr Stop ''       -- stop
```

Key playermgr properties:
| Property | Type | Use |
|----------|------|-----|
| `Open` | w Str | Load audio file |
| `Play` | w Str | Start/resume playback |
| `Stop` | w Str | Stop playback |
| `Pause` | w Str | Pause playback |
| `Close` | w Str | Release resources |
| `InPlayback` | r Int | 0=stopped, non-zero=playing |
| `TTS_State` | r Int | TTS-specific state |
| `gstLogLevel` | rw Int | GStreamer log verbosity |

### Bundled GStreamer WAV player (`kindle-gst-play`)

Kindle firmware ships GStreamer 0.10 with Amazon's custom `mixersink` element, but
most units strip `wavparse`, so the plugin bundles a tiny helper that reads the
WAV header in C and feeds raw PCM to `mixersink`.

Three variants are shipped and probed in order:

| Binary | Toolchain | ABI | Firmware range |
|--------|-----------|-----|----------------|
| `kindle/gst-play` | `arm-linux-gnueabihf` | hard-float | bundled-ld-linux path; works on kindlehf firmware |
| `kindle/gst-play-native-pw2` | `arm-kindlepw2-linux-gnueabi` | soft-float | PW2/PW3/PW4 on firmware **<= 5.16.2.1.1** |
| `kindle/gst-play-native` | `arm-kindlehf-linux-gnueabihf` | hard-float | PW4+/Colorsoft on firmware **>= 5.16.3** |

The soft-float `kindlepw2` variant was added for issue #28: PW4 devices on
firmware 5.15.x cannot load the hard-float binaries because Amazon only
switched to the hard-float ABI at firmware 5.16.3.

### Potential Future Solutions

| Approach | Feasibility | Preserves Piper voice | Dependencies |
|----------|-------------|----------------------|--------------|
| **LIPC playermgr (implemented v0.1.5.27)** | **High -- in use** | **Yes** | **lipc-set-prop (built-in)** |
| Amazon TTS via LIPC (`lipc-set-prop com.lab126.kaf.TTSService ttsSpeak "text"`) | High | No (Amazon's voice) | None (LIPC is built-in) |
| Bundle full BlueZ stack (`bluetoothd` + BlueALSA) | Low | Yes | Conflicts with `btfd` for HCI ownership |
| Inject into `btfd` A2DP socket | Unknown (needs diagnostic data) | Yes | Reverse-engineering required |
| PulseAudio (if present on newer firmware) | Unknown | Yes | `pactl` + running PulseAudio daemon |

### Failure Detection

| Condition | Threshold | Action |
|-----------|-----------|--------|
| Rapid exit | <200ms (always checked on Kindle) | Counter ++ ; after 3 → stop + Kindle-specific error |
| No BT connected | Pre-play check via BT manager | Block playback immediately with instructions |

---

## 5. Android

**Devices:** Boox, other Android e-readers running KOReader

### Bluetooth

Managed entirely by Android OS. The plugin does not interact with BT.

### Audio Pipeline

JNI bridge to Android's `TextToSpeech` / `MediaPlayer` API via a bundled
`.dex` (Dalvik bytecode) helper:

```
┌────────────┐    ┌─────────────┐    ┌──────────────────┐    ┌──────────────┐
│ Piper WAV  │───>│ JNI call    │───>│ TtsHelper.dex    │───>│ Android      │
│ file       │    │ playFile()  │    │ (DexClassLoader)  │    │ MediaPlayer  │
└────────────┘    └─────────────┘    └──────────────────┘    └──────────────┘
```

| Property | Value |
|----------|-------|
| Helper path | `{plugin_dir}/android/tts_helper.dex` |
| Build | `cd android && ./build-dex.sh` |
| Java class | `org.koreader.audiobook.TtsHelper` |
| Loader | `DexClassLoader` |
| Playback type | `"android"` |

**JNI methods:**

| Method | Signature | Purpose |
|--------|-----------|---------|
| `synthesizeSpeech` | `(String, String, I, F, F, Z) → Z` | Synthesize text to WAV |
| `playFile` | `(String) → I` | Play WAV file (0 = success) |
| `isPlaying` | `() → Z` | Check if audio is playing |
| `isPlaybackDone` | `() → Z` | Check if playback finished |
| `stopPlayback` | `() → V` | Stop current playback |
| `pausePlayback` | `() → V` | Pause current playback |
| `resumePlayback` | `() → V` | Resume paused playback |

Android devices typically have built-in speakers, so audio output works
without BT. BT routing is handled transparently by Android's audio HAL.

### Failure Detection

JNI return codes. `playFile()` returns non-zero on failure.

---

## Audio Player Selection Order

The `findAudioPlayer()` function in `ttsengine.lua` builds a priority list:

```
1. [Android]     → JNI MediaPlayer                        (Android only)
2. [Kindle LIPC] → lipc-set-prop com.lab126.playermgr     (Kindle only, v0.1.5.27+)
3. [GStreamer]    → gst-launch-1.0 + mtkbtmwrpcaudiosink  (MTK Kobo only)
4. [BlueALSA]    → aplay -D bluealsa                      (BlueZ Kobo only)
5. [Kindle -D]   → aplay -q -D {probed device}            (Kindle ALSA fallback)
6. [Kindle PA]   → paplay                                 (Kindle with PulseAudio)
7. [ALSA]        → aplay -q -D default                    (any device with soundcard)
8. [ALSA]        → aplay -q -D hw:0,0                     (any device with soundcard)
9. [ALSA]        → aplay -q                               (any device with soundcard)
10. [PulseAudio] → paplay                                 (generic fallback)
11. [mpv]        → mpv --no-video --really-quiet           (generic fallback)
12. [mplayer]    → mplayer -really-quiet                   (generic fallback)
13. [sox]        → play -q                                 (generic fallback)
14. [ALSA]       → aplay -q                               (last resort, no soundcard, non-Kindle)
```

---

## Bug Report Diagnostics per Platform

### All Platforms

- `/proc/asound/cards` content
- Audio player resolved command
- TTS backend detected
- `/tmp` writable check
- Memory and disk info

### Kobo (MTK)

- `gst-inspect-1.0 mtkbtmwrpcaudiosink` output
- `gst-inspect-1.0 --list-elements` (available sinks)
- `/proc/net/unix` (socket status)
- Orphan `gst-launch-1.0` processes

### Kobo (BlueZ)

- `bluetoothctl paired-devices` / `hcitool con` (fallback)
- `/sys/class/bluetooth/` listing
- `hciconfig -a` output
- BlueALSA daemon status (`pidof bluealsa`)
- `/etc/asound.conf` content

### Kindle

- LIPC BT service probing (4 services x 3 properties)
- `aplay -l`, `aplay -L` output
- `/dev/snd/` listing, `/proc/asound/pcm`
- PulseAudio: `pactl info`, `pactl list sinks short`
- Running audio processes (`btfd`, `a2dp`, `bluez`, `pulse`, etc.)
- Available audio binaries scan (9 candidates)
- Kernel sound modules (`lsmod | grep snd`)
- ALSA config (`/etc/asound.conf`)
- `btfd` PID, command line, open fds, unix sockets, memory maps
- `audiomgrd` PID, command line, fds, memory maps (audio/a2dp/mixer libs)
- `playermgr` LIPC properties (Open/Play/Stop/InPlayback/gstLogLevel)
- `audiomgrd` LIPC properties (audioOutputConnected/audioCurrentOutput/speakerVolume)
- HCI devices (`/dev/hci*`, `/sys/class/bluetooth/`, `hciconfig -a`)
- D-Bus daemon presence and BlueZ registration
- System-wide BT/audio unix sockets (including Bluedroid `.a2dp_ctrl`)
- LIPC `com.lab126.kaf.TTSService` properties
- LIPC `com.lab126.audioPlayer` properties

### Android

- `getprop ro.build.version.release` (Android version)
- `getprop ro.build.version.sdk` (SDK level)
- `getprop ro.product.brand` / `ro.product.model`
- `tts_helper.dex` presence
