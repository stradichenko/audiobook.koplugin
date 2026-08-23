<p align="center">
  <img src="new_audio_logo.svg" alt="Audiobook Read-Along logo" width="200">
</p>

<h1 align="center">
  Audiobook Read-Along Plugin for KOReader
</h1>

<h3 align="center">

![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)
![Platform](https://img.shields.io/badge/platform-Kobo%20%7C%20Kindle%20%7C%20PocketBook%20%7C%20Linux-blue)
![Android](https://img.shields.io/badge/Android-supported-brightgreen)
![TTS](https://img.shields.io/badge/TTS-Piper%20%7C%20espeak--ng%20%7C%20Android-green)

</h3>

<h4 align="center">
  Consider supporting:<br><br>
  <a href="https://www.patreon.com/8153512/join">
    <img src="https://img.shields.io/badge/Patreon-F96854?style=for-the-badge&logo=patreon&logoColor=white" alt="Patreon">
  </a>
  <a href="https://github.com/sponsors/stradichenko">
    <img src="https://img.shields.io/badge/sponsor-30363D?style=for-the-badge&logo=GitHub-Sponsors&logoColor=#EA4AAA" alt="GitHub Sponsors">
  </a>
  <a href="https://buymeacoffee.com/stradichenko">
    <img src="https://raw.githubusercontent.com/pachadotdev/buymeacoffee-badges/main/bmc-donate-white.svg" alt="BuyMeACoffee">
  </a>
</h4>

<h4 align="center">

[![Share on X](https://img.shields.io/badge/-Share%20on%20X-gray?style=flat&logo=x)](https://x.com/intent/tweet?text=Audiobook%20Read-Along%20for%20KOReader!%20TTS%20with%20word%20highlighting%20on%20e-readers.&url=https://github.com/stradichenko/audiobook.koplugin&hashtags=KOReader,TTS,eink)

</h4>

Text-to-speech for [KOReader](https://github.com/koreader/koreader) with synchronized word highlighting, automatic page turns, and Bluetooth audio support. Works offline on Kobo, Kindle, Android, and Linux.

**Also available:**

* [Audio] Play music files (MP3, FLAC, OGG, and more)
* [Books] Play audiobooks with scrubber seek, chapter navigation, and sleep timer
* [Audiobookshelf] Browse, download, and sync playback progress with an [Audiobookshelf](https://www.audiobookshelf.org/) server (see [setup guide](docs/AUDIOBOOKSHELF.md))!
* [Sync] Storyteller compatibility; EPUB 3 Media Overlays support (work in progress)

## Audiobookshelf integration

Connect to an [Audiobookshelf](https://www.audiobookshelf.org/) server to browse your library, download audiobooks for offline playback, and sync progress across devices. All configuration is done through the KOReader menu; no file editing is required.

For setup instructions, see [docs/AUDIOBOOKSHELF.md](docs/AUDIOBOOKSHELF.md).

## Quick start

### 1. Download and copy the plugin

Download the **`.zip` file** from the [latest release](https://github.com/stradichenko/audiobook.koplugin/releases/latest) (look for `audiobook-koplugin-v*.zip` under **Assets**). Do **not** download "Source code (zip)" -- that only contains the Lua sources without the bundled TTS engines.

Unzip it and copy the `audiobook.koplugin` folder into KOReader's plugins directory:

| Platform | Path |
|----------|------|
| Kobo | `.adds/koreader/plugins/` |
| Kindle | `koreader/plugins/` |
| Linux | `~/.config/koreader/plugins/` |
| Android | `/sdcard/koreader/plugins/` |
| PocketBook | `applications/koreader/plugins/` |

Restart KOReader after copying.

### 2. Install a TTS engine (if not using the pre-built release)

The pre-built release from step 1 **already includes espeak-ng and Piper** -- no extra install needed on Kobo or Kindle. Skip to step 3.

If you cloned the repository instead:

**Kobo** -- install espeak-ng via SSH or the terminal emulator (Menu > More tools > Terminal emulator):

```bash
opkg update && opkg install espeak-ng
```

If `opkg` is unavailable, grab the `.ipk` from [nickel-packages](https://github.com/nickel-packages/packages) and run `opkg install /mnt/onboard/espeak-ng*.ipk`.

**Linux** -- `sudo apt install espeak-ng`

**Android (Boox, etc.)** -- the pre-built release includes `tts_helper.dex`, which bridges to the **device's system TTS engine** (Google, Samsung, SherpaTTS, ...). The bundled Piper / espeak-ng binaries and the HuggingFace `.onnx` voices in `piper/` **do not run on Android**. For natural neural voices, install [SherpaTTS](https://f-droid.org/packages/org.woheller69.ttsengine/) and set it as the default engine. Full walkthrough: [High-quality voices on Android](#high-quality-voices-on-android-sherpatts).

If you cloned the repo instead of downloading a release, build the `.dex` manually (requires Android SDK):

```bash
cd audiobook.koplugin/android/
./build-dex.sh
```

The bundled espeak-ng and Piper binaries are for Linux-based e-readers and will not run on Android. See [Android support](#android-support) for details.

### 3. Start reading

- **Long-press a word** to open the dictionary popup, then tap **Read aloud from here**.
- Or **select a paragraph**, then tap **Read aloud from here** in the selection menu.
- Or go to **Tools > Audiobook Read-Along > Start reading from current page**.

## Optional: Piper neural TTS

> **Android:** skip this section. The plugin's Piper binaries and HuggingFace `.onnx` files cannot run on Android. Use a system TTS engine such as SherpaTTS instead: [High-quality voices on Android](#high-quality-voices-on-android-sherpatts).

Piper sounds much more natural than espeak-ng. It runs fully offline on Kobo's ARM processor (~40 MB for engine + voice model). The [pre-built release](https://github.com/stradichenko/audiobook.koplugin/releases/latest) already includes Piper and a default voice (`en_US-danny-low`). For faster load times on Kobo, `low` quality voices like this one are recommended (see [Choosing a voice](#choosing-a-voice)). To build a bundle yourself, see [Building from source](#building-from-source).

Switch between espeak-ng and Piper any time from **Tools > Audiobook Read-Along > Voice settings**.

### Choosing a voice

Listen to samples and pick a voice: [rhasspy.github.io/piper-samples](https://rhasspy.github.io/piper-samples/)

Voices come in four quality levels:

| Quality | Sample rate | Size | Notes |
|---------|-------------|------|-------|
| low | 16 kHz | ~15 MB | **Recommended for Kobo** -- fast load, low RAM |
| medium | 22 kHz | ~60 MB | Better quality, but slower to load on Kobo |
| high | 22 kHz | ~100 MB | Best quality, more RAM/CPU |

> On Kobo (512 MB RAM), `low` voices are recommended. `medium` works but the model takes noticeably longer to load. Not every voice is available at every quality level -- check HuggingFace for what's offered.

### Downloading additional voices

Every voice needs two files: a `.onnx` model and a `.onnx.json` config. Place both in `audiobook.koplugin/piper/`.

Voices are hosted on HuggingFace. The URL pattern is:

```text
https://huggingface.co/rhasspy/piper-voices/resolve/main/<lang>/<lang_REGION>/<speaker>/<quality>/
```

For example, to download **en_US-lessac-medium**:

```bash
cd audiobook.koplugin/piper/
curl -LO https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx
curl -LO https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json
```

Or for **en_US-ryan-low**:

```bash
curl -LO https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/low/en_US-ryan-low.onnx
curl -LO https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/low/en_US-ryan-low.onnx.json
```

Browse all available voices: [huggingface.co/rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices/tree/main)

## PocketBook audio

On PocketBook, the system ALSA configuration routes all audio through a Loopback card. The `tts_sm` PCM device (defined in `/etc/asound.conf`) chains through `softvol -> dmix -> hw:Loopback,0`. A system process (`alsaloop`) reads from `hw:Loopback,1` and plays to the physical codec (`hw:0`). The plugin bundles a small ALSA player (`wav-play`) that opens `tts_sm` directly, avoiding any dependency on `aplay` or GStreamer. Bluetooth output on PocketBook uses the standard BlueZ + `alsaloop` path managed by the firmware.

## Bluetooth audio (Kobo)

The plugin outputs audio through a Bluetooth A2DP connection when a BT device is paired. The connection is managed through the plugin menu:

**Tools > Audiobook Read-Along > Bluetooth settings**

Two Bluetooth stacks are supported, auto-detected at runtime:

| Stack | Devices | Audio path |
|-------|---------|------------|
| **MTK** (mtkbtmwrpc) | Clara 2E, Sage, Libra Colour | GStreamer persistent pipeline |
| **BlueZ** (bluetoothd) | Libra 2 / Io | aplay via ALSA |

On MTK devices the BT audio pipeline uses an exclusive abstract socket. If audio stops working after a crash, restart KOReader -- the plugin kills orphan processes on startup.

> On MTK Kobo devices, the mtkbtmwrpc daemon binds a single abstract socket. Only one GStreamer pipeline can hold it at a time. The plugin keeps one persistent pipeline alive across sentences to avoid reconnection gaps. On BlueZ devices, the plugin starts `bluetoothd` and resets the HCI adapter automatically when you power on Bluetooth.
> **Known issue on MTK devices:** MBROLA voices other than `mb-en1` (UK English Male 1) may produce mid-sentence audio repeats due to a firmware bug in the MTK Bluetooth SBC encoder. This affects all MBROLA voices except `mb-en1`. See [docs/MBROLA_MTK_REPEAT_BUG.md](docs/MBROLA_MTK_REPEAT_BUG.md) for the full diagnostic report.

For the full platform audio and Bluetooth architecture (Kobo generations, Kindle, Android), see [docs/PLATFORM_AUDIO.md](docs/PLATFORM_AUDIO.md). AirPods Pro 3 on Kindle Paperwhite 11 (what works, pause/resume keepalive, stem Play/Pause limitation): [docs/AIRPODS_PRO3_KINDLE.md](docs/AIRPODS_PRO3_KINDLE.md).

## Playback controls

| Button | Action |
|--------|--------|
| Rewind | Previous sentence. Hold for 3x skip. |
| Play/Pause | Toggle playback. |
| Forward | Next sentence. Hold for 3x skip. |
| Close | Stop reading and dismiss the bar. |

Reading pauses automatically when you open a menu and resumes when you close it.

## Settings

All settings are under **Tools > Audiobook Read-Along**:

- **Start reading from current page** - begin read-along from the current page
- **Bluetooth settings**
  - **Bluetooth** - pair, connect, disconnect, scan
  - **Headset media buttons** - use play/pause/next/prev on a Bluetooth headset or speaker to control TTS playback
  - **Disconnect alert** - notify if all BT audio devices disconnect during playback
- **Voice settings** - TTS engine, voice, speech rate, pitch, volume, sentence/paragraph pauses (espeak-ng), sentence/paragraph gaps (Piper), word gap, clause pause. Includes **Quick start with espeak** (Piper-only) which plays the first sentence with espeak-ng while Piper loads, avoiding the ~3s cold start silence. **Android:** language and voice are chosen here (or from the overlay **⚙**); neural quality comes from the system engine (see [SherpaTTS](#high-quality-voices-on-android-sherpatts)).
- **General settings**
  - **Audio output (PocketBook)** - ALSA device selection for PocketBook firmware quirks
  - **Keep playing when lid is closed** - prevents device suspend so audio continues with the case closed
  - **Hide control bar while playing** - experimental; hides the playback bar during TTS so the page is fully visible
  - **Highlight style** - background (default), invert (best for e-ink), underline, box
  - **Auto-advance pages** - turn pages automatically
  - **Highlight sentences** - draw highlight on the active sentence
- **Generate bug report** - save a diagnostic report to share when reporting issues
- **Run device benchmark** - run a TTS performance benchmark on this device
- **Check for updates** - fetch and install a newer release from GitHub

## Tweaking & advanced configuration

### Changing espeak-ng language

The **Voice settings** menu only lists English accents, but espeak-ng supports [dozens of languages](https://github.com/espeak-ng/espeak-ng/blob/master/docs/languages.md). To read in another language, set the voice code manually:

1. Close KOReader completely.
2. Open KOReader's settings file (`settings.reader.lua` in the KOReader directory).
3. Find the `audiobook_settings` table and set `tts_voice` to the desired code:

```lua
["audiobook_settings"] = {
    ["tts_voice"] = "pt-br",
    ["tts_voice_label"] = "Portuguese (Brazil)",
    -- ... other settings ...
},
```

Restart KOReader and start reading. The plugin will use the new voice immediately.

> **Tip:** You can also add a variant (e.g. `pt-br+f2` for female voice 2). See the [espeak-ng voice documentation](https://github.com/espeak-ng/espeak-ng/blob/master/docs/voices.md) for the full list.


## Architecture

```
audiobook.koplugin/
  main.lua             - entry point, menus, event hooks
  synccontroller.lua   - coordinates audio timing with highlights
  ttsengine.lua        - TTS synthesis, audio playback, backend detection
  piperqueue.lua       - persistent Piper server management
  textparser.lua       - sentence/word tokenization with positions
  highlightmanager.lua - screen-coordinate highlight via crengine
  playbackbar.lua      - transport controls widget
  menubuilder.lua      - voice/highlight settings menus
  btmanager.lua        - Bluetooth device scanning and pairing (MTK + BlueZ)
  btui.lua             - BT menu UI and disconnect watcher
  btmediacontrol.lua   - BT headset media buttons (AVRCP play/pause/skip)
  benchmarkrunner.lua  - in-plugin TTS benchmark runner
  wavutils.lua         - WAV file reading, writing, and manipulation
  androidtts.lua       - Android TTS via JNI (DexClassLoader + TtsHelper)
  utils.lua            - shared helpers
  wav-play.c           - minimal ALSA WAV player for PocketBook (compiled to wav-play/wav-play)
```

### Design notes

**Persistent Piper server.** On Kobo's single-core ARM, loading the ONNX model takes ~4.5 seconds. A persistent server process keeps the model in memory and accepts sentences over a FIFO. Combined with 3-sentence batching this brings the realtime factor from 0.085x (old 2-server config) to 0.329x. See [dev/benchmark/RESULTS.md](dev/benchmark/RESULTS.md) for the full analysis.

**Binary-search highlight alignment.** CRe (crengine) snaps text selections to word boundaries, and proportional fonts make character-to-pixel estimates unreliable. The highlight manager uses the proportional estimate as an initial guess, then binary-searches the x coordinate by querying CRe until the selected text matches the target sentence. Converges in 2-4 queries.

**Exclusive BT socket (MTK only).** Kobo's MediaTek BT firmware exposes a single abstract socket (`@kobo:mtkbtmwrpc`). The plugin keeps one GStreamer pipeline alive for the entire reading session and feeds audio through a FIFO. Orphan pipelines from crashes are killed on startup via PID files and `pkill`. On BlueZ devices (Libra 2, etc.) audio goes through standard ALSA and this socket management is not needed.

**Long-sentence splitting.** Piper's attention mechanism scales quadratically with input length. On Kobo's 512 MB of RAM the server OOMs on sentences above ~1000 characters and throughput drops from ~7 ch/s at 300 chars to ~3 ch/s at 1400 chars. The text parser automatically splits any sentence longer than 300 characters at natural clause boundaries (`;` `:` `, and/but/or...` ` - `) then merges fragments shorter than 80 characters with a neighbour (below that, ~90% of synthesis time is wasted on per-request overhead) and re-splits anything still over 300 at word boundaries. See [dev/benchmark/RESULTS_LONG.md](dev/benchmark/RESULTS_LONG.md) for the full data.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Plugin not in menu | Folder must be `audiobook.koplugin` inside `plugins/`. The plugin only appears in the **Tools** menu when a book is open. Restart KOReader after copying. |
| No sound | **Kobo/Linux:** Run `espeak-ng "hello" -w /tmp/t.wav && aplay /tmp/t.wav` over SSH. **PocketBook:** generate a bug report and check `wav_play_smoke_test` -- it runs wav-play against the `tts_sm` device and prints `PLAYING` on success. |
| No audio player found (Kindle) | Pair BT headphones via the Kindle top-swipe menu **before** starting playback. If already paired, restart KOReader so the plugin re-detects the audio output. |
| No TTS engine found | Install espeak-ng (see Quick start). |
| No TTS engine found (Android) | Ensure `android/tts_helper.dex` is present inside the plugin folder. The pre-built release includes it; if you cloned from source, run `./build-dex.sh` in the `android/` directory. The device must also have a TTS engine installed (most do by default). See [Android support](#android-support). |
| Android TTS sounds high / noisy / unlike the engine's own preview | Keep plugin pitch at the default (50). Turn **off** **Android: persistent audio stream**. Fully quit KOReader after changing the system TTS engine or language. See [Android support](#android-support). |
| Android underline does not match the spoken sentence | Android TTS has no word timestamps; the plugin underlines the spoken sentence as a contiguous phrase instead of chasing estimated word positions. Fully quit KOReader after updating the plugin. |
| Android TTS is robotic / not my SherpaTTS voice | SherpaTTS is installed but is **not** Android's preferred TTS engine. The plugin always uses the system default. Follow [High-quality voices on Android](#high-quality-voices-on-android-sherpatts), then fully quit KOReader and reopen it. |
| BT audio silent | Restart KOReader to kill orphan pipelines. Check BT is paired in the plugin menu. |
| SSH refused on port 22 | KOReader uses port 2222: `ssh root@<ip> -p 2222` |
| `.adds` not visible | Enable hidden files on your OS. The folder starts with a dot. |

### Filing a bug report

When reporting a problem, please attach **both** files described below. The bug report captures your device environment (hardware, audio, settings) while the crash log captures KOReader's runtime behavior (errors, warnings, timing). Together they give the full picture needed to diagnose an issue.

1. Reproduce the problem (use the plugin normally until the issue occurs).
2. Generate the plugin bug report (see below).
3. Locate the KOReader crash log (see below).
4. Attach both files to your [GitHub issue](https://github.com/stradichenko/audiobook.koplugin/issues).

> **Tip:** Generate the report and grab the crash log **before** restarting KOReader. The crash log is truncated on every launch, so restarting may discard the relevant entries.

---

#### 1. Plugin bug report

The plugin's diagnostic report captures device info, TTS engine detection, audio configuration, Bluetooth status, and plugin settings. There are two ways to generate it:

**Option A: From the plugin menu**

**Tools > Audiobook Read-Along > Generate bug report**

This saves a `.txt` file to your device's root storage (see locations below).

**Option B: Standalone script (when the plugin menu is not visible)**

If the plugin doesn't appear in the KOReader menu at all, you can run the report generator directly via SSH or KOReader's built-in terminal emulator (Menu > More tools > Terminal emulator):

```bash
sh /mnt/onboard/.adds/koreader/plugins/audiobook.koplugin/generate-report.sh   # Kobo
sh /mnt/us/koreader/plugins/audiobook.koplugin/generate-report.sh              # Kindle
sh /sdcard/koreader/plugins/audiobook.koplugin/generate-report.sh              # Android
```

The report is printed to the terminal and also saved to a file. If using the terminal emulator, you can scroll up to read it on screen.

**Report location:**

| Platform | Report location |
|----------|----------------|
| Kobo | `/mnt/onboard/audiobook-bug-report-*.txt` |
| Kindle | `/mnt/us/audiobook-bug-report-*.txt` |
| Android | `/sdcard/audiobook-bug-report-*.txt` |
| Linux | `~/audiobook-bug-report-*.txt` |

**What the report contains:**

- Device model, platform, screen size, kernel version
- KOReader version
- TTS engine detection results (which backends were found/missing)
- Audio player availability (aplay, GStreamer, etc.)
- Plugin settings (speech rate, highlight style, etc.)
- Full ALSA configuration (`asound.conf` contents, sound card list)
- Audio process list (alsaloop, bluealsa, etc. with PIDs)
- wav-play binary details and smoke test result (opens `tts_sm`, plays silence, checks for `PLAYING`)
- ALSA mixer state
- Bluetooth hardware details (HCI devices, paired/connected devices, adapter info)
- Memory and disk info

**What the report does NOT contain:**

- Book titles, content, or reading positions
- File paths with usernames (sanitized automatically)
- Highlights, bookmarks, or notes
- Network information or credentials

---

#### 2. KOReader crash log

KOReader logs all warnings, errors, and debug output to a file called `crash.log` in its installation directory. This is **not** generated by the plugin -- it is KOReader's own runtime log and captures everything that happens during a session, including TTS process spawning, fallback events, and Lua errors.

**Crash log location:**

| Platform | Path |
|----------|------|
| Kobo | `/mnt/onboard/.adds/koreader/crash.log` |
| Kindle | `/mnt/us/koreader/crash.log` |
| PocketBook | `/mnt/ext1/applications/koreader/crash.log` |
| Linux | Inside the KOReader installation directory |
| Android | No `crash.log` file -- use `adb logcat` to capture KOReader output |

Connect your device via USB and copy the file. On Kobo the `.adds` folder is hidden -- enable hidden files in your file manager to see it.

> KOReader truncates `crash.log` to ~500 KB on every launch. If you restart KOReader before copying the file, earlier entries may be lost. Copy it while KOReader is still running or immediately after the issue occurs.

---

#### Why both files matter

| Diagnostic question | Bug report | Crash log |
|---------------------|:----------:|:---------:|
| Device model, hardware specs, KOReader version, plugin version, TTS engines installed (espeak, Piper, Android), plugin settings (rate, highlight, voice) | yes | no |
| Full ALSA configuration (asound.conf, sound cards, PCM devices), audio process list (alsaloop, bluealsa PIDs), ALSA mixer state, wav-play smoke test result | yes | no |
| Bluetooth pairing and connection state, HCI devices, adapter info | yes | no |
| Lua errors and stack traces, TTS process spawning and fallback events, sentence progression and page turns, timing of operations (delays, freezes), Piper server startup and delivery, device freeze or resource exhaustion | no | yes |

## Device benchmark

The plugin includes a built-in benchmark that measures TTS synthesis speed on your device. It runs a fixed set of test sentences through each available engine (espeak-ng, Piper) and saves a report you can share on GitHub to help document device performance.

### Running the benchmark

**Tools > Audiobook Read-Along > Generate bug report > Run device benchmark**

The benchmark synthesizes five sentences of varying length (short dialogue, narrative prose, technical text, academic text, and short fragments) with each engine and model it finds. espeak-ng tests finish in seconds; Piper tests may take several minutes on slow devices like Kobo.

A progress message is shown between engine runs. The screen may appear unresponsive during individual synthesis calls -- this is expected.

### Output

When complete, a `.txt` report is saved to your device's root storage:

| Platform | Report location |
|----------|----------------|
| Kobo | `/mnt/onboard/audiobook-benchmark-*.txt` |
| Kindle | `/mnt/us/audiobook-benchmark-*.txt` |
| Android | `/sdcard/audiobook-benchmark-*.txt` |
| Linux | `~/audiobook-benchmark-*.txt` |

The report contains:

- Device info (platform, model, CPU cores, RAM, kernel)
- Plugin version
- Per-sentence synthesis time, audio duration, file size, and realtime factor for each engine/model
- Aggregate totals and average realtime factor

No book content, highlights, or personal data is included.

### Example output

```
=== Audiobook TTS Benchmark (v0.1.5.65) ===
Generated: 2026-03-27T12:00:00Z

── Device ──
  platform: kobo
  model: Kobo Clara 2E
  cpu_cores: 1
  memory: 510396 kB
  kernel: 4.1.15

── Test sentences ──
  [1] short_dialogue (57 chars)
  [2] medium_narrative (268 chars)
  [3] medium_technical (254 chars)
  [4] long_academic (362 chars)
  [5] short_fragments (79 chars)

── espeak-ng ──
  short_dialogue          synth=   82ms  audio= 3200ms  size= 102444B  rt=0.03x
  medium_narrative        synth=  310ms  audio=15800ms  size= 505244B  rt=0.02x
  ...

── Piper danny-low  (size=15.8MB, sr=16000Hz) ──
  short_dialogue          synth= 4200ms  audio= 3100ms  size=  99244B  rt=1.35x
  medium_narrative        synth=18200ms  audio=16800ms  size= 537644B  rt=1.08x
  ...

=== End of Benchmark ===
```

A realtime factor below 1.0x means synthesis is faster than playback (good). Above 1.0x means the user will hear pauses between sentences while the engine catches up.

### Sharing your results

Attach the report file to a [GitHub issue](https://github.com/stradichenko/audiobook.koplugin/issues) or include it in a bug report. Benchmark data from different devices helps the project tune batch sizes, choose default voices, and set realistic expectations for each platform.

## Android support

Android TTS is supported via a JNI bridge to the device's **system** `TextToSpeech` engine (Google, Samsung, SherpaTTS, ...). No Termux and no root required. The plugin does **not** run the bundled Piper / espeak-ng binaries on Android.

| Feature | Status |
|---------|--------|
| Plugin loads in KOReader | ![Works](https://img.shields.io/badge/-works-brightgreen) |
| Text parsing & highlighting | ![Works](https://img.shields.io/badge/-works-brightgreen) |
| Android system TTS | ![Works](https://img.shields.io/badge/-works-brightgreen) Via JNI bridge to `TextToSpeech` API |
| Audio playback | ![Works](https://img.shields.io/badge/-works-brightgreen) Via Android `MediaPlayer` |
| Bundled espeak-ng / Piper / HuggingFace `.onnx` | ![No](https://img.shields.io/badge/-not%20supported-red) Linux/glibc binaries, use SherpaTTS instead |
| High-quality neural voices | ![Works](https://img.shields.io/badge/-works-brightgreen) Via a system engine such as [SherpaTTS](https://f-droid.org/packages/org.woheller69.ttsengine/) |

### Setup

The pre-built release from [GitHub Releases](https://github.com/stradichenko/audiobook.koplugin/releases/latest) includes `android/tts_helper.dex`. Just unzip and copy:

1. Download the release zip and extract it.
2. Copy `audiobook.koplugin/` to `/sdcard/koreader/plugins/`.
3. Restart KOReader. The plugin auto-detects Android and initializes the JNI bridge to the device's TTS engine.

If you cloned the repo instead of using a release, build the `.dex` first (requires Android SDK + Java):

```bash
cd audiobook.koplugin/android/
./build-dex.sh
```

### How it works

The plugin loads a small `.dex` file (`tts_helper.dex`, ~4KB) at runtime via Android's `DexClassLoader`. This helper wraps `android.speech.tts.TextToSpeech` with a polling-friendly API (since LuaJIT cannot implement Java callback interfaces). Synthesis produces standard WAV files that feed into the same pipeline used by espeak-ng and Piper.

Audio playback uses Android's `MediaPlayer` instead of `aplay` or GStreamer. Pause, resume, and stop all work through the MediaPlayer API.

For the full technical analysis, see [docs/ANDROID_TTS.md](docs/ANDROID_TTS.md).

### Limitations

- Word timing is estimated (Android TTS does not provide per-word callbacks when synthesizing to file). The plugin underlines the spoken sentence as a contiguous phrase instead of chasing estimated word positions.
- First sentence may have a brief delay while the TTS engine initializes
- The plugin uses whatever engine Android has as **preferred TTS**. Installing SherpaTTS is not enough until you set it as that preferred engine.

### High-quality voices on Android (SherpaTTS)

On Android the plugin never loads the HuggingFace Piper models shipped in `audiobook.koplugin/piper/`. Those `.onnx` files need the Linux Piper binary (glibc). Android uses Bionic, so that binary cannot start.

What *does* work is the system `TextToSpeech` API. Any app that registers as an Android TTS engine (Google, Samsung, or a neural engine such as **SherpaTTS**) can then speak for KOReader.

SherpaTTS runs Piper / VITS models *inside Android*, offline, with quality close to Piper on Kobo. The example below uses **`fr-FR-miro-high`**. The same steps apply to any other language or model (English lessac, German thorsten, ...).

#### 1. Install SherpaTTS

1. On the tablet, install **[SherpaTTS](https://f-droid.org/packages/org.woheller69.ttsengine/)** (`org.woheller69.ttsengine`) from [F-Droid](https://f-droid.org/). That is the recommended source (signed, updates).
2. Open **SherpaTTS** once so Android registers it as a TTS engine.

Skip this step if SherpaTTS is already installed.

#### 2. Install the voice inside SherpaTTS (not in the plugin)

Do **not** copy `fr_FR-miro-high.onnx` into `koreader/plugins/audiobook.koplugin/piper/`. The plugin will ignore it on Android.

1. Open **SherpaTTS**.
2. Open **Manage Languages**.
3. Choose **French** (or the language you need).
4. Download / enable **`fr-FR-miro-high`** (the app may show it as `miro` + quality `high`).
5. If several French models are installed, tap **miro-high** so it is the active model for French.
6. Optional: play the in-app preview.

Internet is only needed for this download. After that, synthesis is offline.

You already have `fr-FR-miro-high` installed? Confirm it is listed and selected in **Manage Languages**, then go to step 3.

#### 3. Make SherpaTTS the *system* default engine (required)

Android allows only **one** preferred TTS engine. KOReader always talks to that engine. If Google TTS is still preferred, you will keep hearing Google even though Miro is installed in SherpaTTS.

**Onyx Boox** ([official path](https://help.boox.com/hc/en-us/articles/360031058312-How-could-I-download-new-TTS-engine-on-BOOX-device-and-use-it-as-the-default-TTS-on-our-device)):

1. Open the Android **Settings** app (not KOReader, not NeoReader).
2. Go to **Language & input → Text-to-speech (TTS) output**.
   On some firmware this is **Language → Voice → Text-to-speech output**.
3. Under **Preferred engine**, select **SherpaTTS**.
4. Set **Language** to **French (France)** if the list offers it.
5. If a gear icon appears next to SherpaTTS, open it and pick the Miro / `fr-FR` voice.
6. Tap **Listen to an example**. You should hear the neural Miro voice, not Google.

**Other Android devices:** **Settings → System → Languages & input → Text-to-speech**. Same: preferred engine = SherpaTTS, then language / voice.

Fully **quit KOReader** (swipe it away from Recents) and reopen it so it reconnects to the new engine. A plugin reload is not enough if TextToSpeech was already created with Google.

> Changing the preferred engine is system-wide: TalkBack, NeoReader, navigation apps, and other readers will also use SherpaTTS.

#### 4. Use it in this plugin

1. Open a book in KOReader.
2. Start TTS: long-press a word → **Read aloud from here**, or **Tools → Audiobook Read-Along → Start reading from current page**.
3. On the playback bar, tap the centre to expand the player (or open **⚙**).
4. **TTS settings → Voice → French**.
   - **Auto (book language)** is enough when the EPUB metadata language is French (`fr` / `fr-FR`).
   - You can also set the voice from **Tools → Audiobook Read-Along → Voice settings → Voice**.

On Android the **Voice** menu lists the voices installed in the system engine and sends the pick to it. It does **not** download HuggingFace models into the plugin. With SherpaTTS as preferred engine and `fr-FR-miro-high` installed, French voices map to Miro.

#### 5. Checks if it is still the wrong voice

| You hear... | Cause | Fix |
|-----------|--------|-----|
| Google / Samsung / robotic voice | SherpaTTS is not the preferred engine | Repeat step 3, then fully quit KOReader |
| English on a French book | Language not set to `fr-FR` | Overlay **⚙ → Voice → French**, or Auto if the book language is French |
| No speech / "No TTS engine found" | `tts_helper.dex` missing, or no TTS engine at all | Use a release zip; confirm SherpaTTS opens |
| Model in `audiobook.koplugin/piper/` but unused | Expected on Android | Install the model in SherpaTTS instead (step 2) |

#### Other engines

SherpaTTS from F-Droid is the usual choice. Alternatives:

| Engine | Distribution | Notes |
|--------|--------------|-------|
| [SherpaTTS](https://f-droid.org/packages/org.woheller69.ttsengine/) | F-Droid | Piper / VITS via Sherpa-ONNX. Built-in model picker. |
| [VoxSherpa TTS](https://github.com/CodeBySonu95/VoxSherpa-TTS) | GitHub APK | Kokoro 82M and custom Sherpa-ONNX `.onnx` import. |
| [Sherpa-ONNX engine APKs](https://k2-fsa.github.io/sherpa/onnx/tts/apk-engine.html) | k2-fsa | One pre-bundled voice per APK. |

Preview Piper-family voices (including Miro) at [piper-samples](https://rhasspy.github.io/piper-samples/) or the [k2-fsa TTS space](https://huggingface.co/spaces/k2-fsa/text-to-speech).

## Building from source

The `package-for-kobo.sh` script cross-compiles espeak-ng and wav-play for ARM and bundles the plugin into a ready-to-deploy directory. It targets ARMv7 and works for both Kobo and PocketBook. It requires [Nix](https://nixos.org/download) for the cross-compilation toolchain.

```bash
# Plugin + espeak-ng only
bash package-for-kobo.sh

# Plugin + espeak-ng + Piper neural TTS
bash package-for-kobo.sh --with-piper

# Use a specific Piper voice (default: en_US-danny-low)
bash package-for-kobo.sh --piper-voice en_US-ryan-low
```

The output is placed in `kobo-tts-bundle/audiobook.koplugin/`. Copy it to your device:

```bash
scp -P 2222 -r kobo-tts-bundle/audiobook.koplugin root@<kobo-ip>:/mnt/onboard/.adds/koreader/plugins/
```

### Installing the Piper binary manually

If you don't want to use the packaging script, you can assemble the Piper runtime yourself:

1. Download the **armv7l** binary from [Piper releases (2023.11.14-2)](https://github.com/rhasspy/piper/releases/tag/2023.11.14-2).
2. Extract `piper`, its `lib/` directory, and `espeak-ng-data/` into `audiobook.koplugin/piper/`.
3. Download a voice model (`.onnx` + `.onnx.json`) as described in [Downloading additional voices](#downloading-additional-voices) and place them in the same `piper/` directory.

> The [rhasspy/piper](https://github.com/rhasspy/piper) repository was archived in October 2025. The binaries on the releases page still work and are what this plugin ships. The project continues under [OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl) but those newer builds have not been tested with this plugin.

## To Do

- Implement real word-level timing from TTS engines (SSML / phoneme callbacks)
- Add PDF/DjVu highlight support (currently EPUB only)
- Integrate more TTS backends
- Improve accessibility
- Support whole audiobook production with hash-based verification
- Evaluate plugin with other TTS models (e.g., KittenTTS)
- Test and optimize for ultralow-quality/size voice models

## License

Copyright 2025-2026 gespitia - AGPL-3.0. See [LICENSE](LICENSE).

| Bundled component | License |
|-------------------|---------|
| [KOReader](https://github.com/koreader/koreader) | AGPL-3.0 |
| [espeak-ng](https://github.com/espeak-ng/espeak-ng) | GPL-3.0+ |
| [Piper](https://github.com/rhasspy/piper) | MIT |
| [Piper voices](https://huggingface.co/rhasspy/piper-voices) | MIT |
| glibc (bundled .so) | LGPL-2.1 |
