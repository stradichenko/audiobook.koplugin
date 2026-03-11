<h1 align="center">
  Audiobook Read-Along Plugin for KOReader
</h1>

<h3 align="center">

![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)
![Platform](https://img.shields.io/badge/platform-Kobo%20%7C%20Kindle%20%7C%20Android%20%7C%20Linux-blue)
![TTS](https://img.shields.io/badge/TTS-Piper%20%7C%20espeak--ng-green)

</h3>

<h4 align="center">
  Consider supporting:<br><br>
  <a href="https://www.patreon.com/8153512/join">
    <img src="https://img.shields.io/badge/Patreon-F96854?style=for-the-badge&logo=patreon&logoColor=white" alt="Patreon">
  </a>
  <a href="https://github.com/sponsors/stradichenko">
    <img src="https://img.shields.io/badge/sponsor-30363D?style=for-the-badge&logo=GitHub-Sponsors&logoColor=#EA4AAA" alt="GitHub Sponsors">
  </a>
</h4>

<h4 align="center">

[![Share on X](https://img.shields.io/badge/-Share%20on%20X-gray?style=flat&logo=x)](https://x.com/intent/tweet?text=Audiobook%20Read-Along%20for%20KOReader!%20TTS%20with%20word%20highlighting%20on%20e-readers.&url=https://github.com/stradichenko/audiobook.koplugin&hashtags=KOReader,TTS,eink)

</h4>

A text-to-speech plugin for [KOReader](https://github.com/koreader/koreader)
with synchronized word highlighting. Each word is highlighted as it is spoken,
and the plugin handles page turns automatically so you can listen hands-free.

## About

The plugin sits between KOReader's document renderer and a TTS engine running
on the device. It parses visible page text into words and sentences, synthesizes
audio, and drives a highlight overlay in lockstep with playback. A small control
bar at the bottom of the screen provides transport controls (rewind, play/pause,
forward, close) and a progress indicator.

Supported TTS backends:

| Engine | Quality | Speed | Size |
| -------- | --------- | ------- | ------ |
| espeak-ng | Formant / robotic | Very fast | ~4 MB |
| Piper (low) | Neural / natural | Fast | ~40 MB |
| Piper (medium) | Neural / natural | Moderate | ~85 MB |
| pico2wave | Diphone | Fast | ~5 MB |
| flite | Unit selection | Fast | ~15 MB |
| festival | Unit selection | Moderate | ~30 MB |
| Android TTS | Varies | Varies | System |

## Installation

Copy the `audiobook.koplugin` folder into the KOReader plugins directory for
your device:

| Platform | Path |
| ---------- | ------ |
| Linux | `~/.config/koreader/plugins/` |
| Kindle | `koreader/plugins/` |
| Kobo | `.adds/koreader/plugins/` |
| Android | `/sdcard/koreader/plugins/` |
| PocketBook | `applications/koreader/plugins/` |

After copying, restart KOReader completely (close and reopen, do not just
minimize).

## Requirements

### Kobo

Kobo devices do not ship with a TTS engine. You need to install espeak-ng once
before the plugin will work. The steps below do not require coding experience.

#### Install the plugin via USB

1. Connect your Kobo to your computer with the USB cable.
2. The device appears as a USB drive. Navigate to `.adds/koreader/plugins/`.
   On Windows you may need to enable hidden files in File Explorer. On macOS
   press `Cmd + Shift + .` in Finder. On Linux
   press `Ctrl + H` in your file manager.
3. Copy the entire `audiobook.koplugin` folder into `plugins/`.
4. Eject the device safely and unplug it.

#### Connect to the Kobo shell

You need a shell to install espeak-ng. Pick one of two methods.

**Terminal emulator (no computer needed).** In KOReader, open the menu bar,
then go to More tools > Terminal emulator. A text input will appear where you
can type the commands shown below.

**SSH from your computer.** KOReader includes a built-in SSH server; developer
mode is not required.

1. Open KOReader. Make sure Wi-Fi is connected to your local network.
2. Open the menu bar, then go to Network > SSH server.
3. Enable "Login without password" (you can disable it later) and start the
   server. A popup will display the device IP address.
4. On your computer, connect with port 2222 (not 22):

```bash
ssh root@<kobo-ip> -p 2222
```

The password is `root`.

#### Check existing tools

```bash
which espeak-ng
which aplay
```

If a command prints a path, that tool is already present.

#### Install espeak-ng

Try the package manager first:

```bash
opkg update
opkg install espeak-ng
```

If `opkg` is not available, try `pkm install espeak-ng`. If neither works,
download the `.ipk` from
[nickel-packages](https://github.com/nickel-packages/packages), copy it to the
Kobo via USB, and install manually:

```bash
opkg install /mnt/onboard/espeak-ng*.ipk
```

#### Verify

Plug in headphones, then run:

```bash
espeak-ng "hello" -w /tmp/test.wav
aplay /tmp/test.wav
```

You should hear the word "hello" through your headphones.

#### Quick troubleshooting

| Problem | Solution |
| --------- | ---------- |
| `espeak-ng: command not found` | Repeat the install step above. |
| `aplay: command not found` | `opkg install alsa-utils` |
| No sound through headphones | Plug headphones in before running the command. Run `aplay -l` to list audio devices. |
| `ssh: Connection refused` on port 22 | Use port 2222: `ssh root@<ip> -p 2222` |
| SSH server missing from menu | Make sure you are in KOReader, not the stock Kobo reader. Go to Network > SSH server. |
| `.adds` folder not visible via USB | Enable hidden files on your computer. The folder name starts with a dot. |

Further help:

- [KOReader SSH wiki](https://github.com/koreader/koreader/wiki/SSH)
- [KOReader community forum](https://www.mobileread.com/forums/forumdisplay.php?f=276)

#### Optional: install Piper TTS (neural voice)

Piper is a neural TTS engine that sounds considerably more natural than
espeak-ng. It runs locally on the Kobo ARM processor with no internet
connection required during playback. Total size is roughly 40 MB (24 MB engine
plus 15 MB for the low-quality voice model).

**Method 1: packaging script (recommended)**

```bash
bash package-for-kobo.sh --with-piper
```

This downloads the Piper armv7l binary and the `en_US-danny-low` voice
model and bundles them into the plugin directory. You can choose a different
voice:

```bash
# alternative voice
bash package-for-kobo.sh --piper-voice en_US-ryan-low

# higher quality, larger model (~60 MB, slower synthesis)
bash package-for-kobo.sh --piper-voice en_US-lessac-medium
```

Voice samples are available at
[rhasspy.github.io/piper-samples](https://rhasspy.github.io/piper-samples/).

**Method 2: manual install**

1. Download the armv7l binary from
   [github.com/rhasspy/piper/releases](https://github.com/rhasspy/piper/releases/tag/2023.11.14-2)
   (`piper_linux_armv7l.tar.gz`, ~24 MB).
2. Download a voice model (both the `.onnx` and `.onnx.json` files) from
   [HuggingFace](https://huggingface.co/rhasspy/piper-voices).
3. Extract and copy to the Kobo:

```
.adds/koreader/plugins/audiobook.koplugin/
  piper/
    piper
    lib/
    espeak-ng-data/
    en_US-danny-low.onnx
    en_US-danny-low.onnx.json
```

4. In KOReader, go to Tools > Audiobook Read-Along > Voice settings > TTS
   engine and select Piper (neural).

Both engines can coexist. Switch between them at any time from the same menu.

### Linux / Desktop

Install at least one TTS engine:

```bash
sudo apt install espeak-ng        # recommended
sudo apt install libttspico-utils # pico2wave
sudo apt install flite
sudo apt install festival
```

An audio player is also required. `aplay` (ALSA) is usually present by default.
Alternatives:

```bash
sudo apt install pulseaudio-utils # paplay
sudo apt install mpv
```

### Android

The plugin uses the built-in Android TTS system. Make sure a TTS engine is
configured in your device settings.

## Usage

### Long-press a word (recommended)

1. Open a document in KOReader.
2. Long-press any word to open the dictionary popup.
3. Tap "Read aloud from here" (below the Wikipedia / Search / Close row).
4. Reading begins from that sentence with synchronized word highlighting. The
   playback control bar appears at the bottom of the screen.

### From the tools menu

1. Open a document and tap the top of the screen to show the menu bar.
2. Go to Tools > Audiobook Read-Along.
3. Select "Start reading from current page".

### Playback controls

The control bar at the bottom provides four buttons:

| Button | Action |
| -------- | -------- |
| Rewind | Jump to the previous sentence or paragraph. Hold for 3x skip. |
| Play / Pause | Toggle playback. |
| Forward | Jump to the next sentence or paragraph. Hold for 3x skip. |
| Close | Stop reading and dismiss the bar. |

### Keyboard and gesture shortcuts

Shortcuts can be configured under Settings > Gesture Manager or Settings >
Keyboard shortcuts:

- Toggle Read-Along: play or pause reading
- Stop Read-Along: stop completely

### Settings

**TTS engine.** Choose which backend to use for speech synthesis.

**Speech rate.** Adjust playback speed from 0.5x (half speed) to 2.0x (double
speed). The default is 1.0x.

**Highlight style.** Four options are available: background fill, underline,
box, and invert. Invert tends to work best on e-ink displays.

**Auto-advance pages.** When enabled the plugin turns to the next page
automatically and continues reading.

**Highlight words / sentences.** Word-level and sentence-level highlighting can
be toggled independently.

## Architecture

```
audiobook.koplugin/
  _meta.lua            # plugin metadata
  main.lua             # entry point, menu integration, settings
  textparser.lua       # text tokenization and position tracking
  ttsengine.lua        # TTS synthesis and audio playback
  highlightmanager.lua # on-screen word and sentence highlighting
  playbackbar.lua      # bottom transport control bar widget
  synccontroller.lua   # coordination between audio and highlights
  espeak-ng/           # bundled espeak-ng (formant TTS)
    bin/espeak-ng
    lib/               # cross-compiled glibc and shared libraries
    share/             # phoneme data and English dictionary
  piper/               # bundled Piper (neural TTS, optional)
    piper              # ARM binary
    lib/               # onnxruntime and shared libraries
    espeak-ng-data/    # phonemizer data used internally by Piper
    *.onnx             # voice model files
```

## How It Works

1. **Text parsing.** When read-along starts, the visible page text is split
   into words and sentences. Character positions are recorded so highlights can
   be mapped back to screen coordinates.

2. **Synthesis.** The text is sent to the selected TTS engine, which produces a
   WAV file and, where supported, word-level timing metadata.

3. **Synchronization.** During playback the sync controller tracks elapsed time
   and matches it against the timing data to determine which word is currently
   being spoken.

4. **Highlighting.** The highlight manager draws a visual overlay at the screen
   position of the active word (and optionally the active sentence).

5. **Auto-advance.** When the end of a page is reached the plugin can
   automatically turn the page and continue.

### Timing estimation

When a TTS engine does not provide word-level timing, the plugin estimates it:

- Syllables are counted by vowel patterns.
- Each syllable is assigned a base duration of roughly 200 ms.
- The duration is scaled by the current speech rate multiplier.
- A 50 ms gap is inserted between words.

## Troubleshooting

### Plugin does not appear in the menu

1. The folder must be named exactly `audiobook.koplugin`.
2. It must be inside the correct `plugins/` directory for your device.
3. KOReader must be restarted completely (close and reopen, not just minimize).
4. All files must be readable.
5. A document must be open; the plugin only appears when a document is loaded
   (`is_doc_only = true`).

To verify the installation:

```bash
ls ~/.config/koreader/plugins/audiobook.koplugin/
# expected: main.lua, _meta.lua, textparser.lua, etc.
```

### Nothing happens after "Starting read-along..."

This usually means synthesis failed. Check for error messages, then verify that
the TTS engine and audio player are working:

```bash
which espeak-ng
espeak-ng "hello" -w /tmp/test.wav
ls -la /tmp/test.wav

which aplay
aplay /tmp/test.wav
```

### "No TTS engine found"

Install espeak-ng on the device. See the Requirements section.

### "No audio player found"

The plugin needs `aplay`, `paplay`, or `mpv`. On Kobo, `aplay` is usually
available. Make sure headphones are connected before starting playback.

### "Read aloud" button missing from the dictionary popup

Long-press a word (do not drag-select text). The button appears below the
Wikipedia / Search / Close row. Restart KOReader if you just installed the
plugin.

### No audio with USB-C headphones

Some USB-C audio adapters require extra configuration. Try `aplay /tmp/test.wav`
over SSH first, and check the device list with `aplay -l`.

### Control bar does not appear

If synthesis fails the bar will not be shown. Check the KOReader logs for error
messages.

### Highlights not visible

E-ink screens may need a full refresh to display changes. Try a different
highlight style (invert usually works best). Confirm that "Highlight words" is
enabled in the plugin settings.

### Timing feels off

Estimated timing may not match the exact speech cadence. Adjusting the speech
rate can help. Some TTS engines provide more accurate timing than others.

## Contributing

Contributions are welcome. Areas that could use improvement:

- Real word timing from TTS engines via SSML or callbacks
- Better position mapping for different document types
- Additional TTS engine backends
- Accessibility improvements

## License

Copyright 2025 gespitia

This project is licensed under the GNU Affero General Public License v3.0.
See [LICENSE](LICENSE) for the full text.

Bundled components carry their own licenses:

| Component | License |
| --------- | ------- |
| [KOReader](https://github.com/koreader/koreader) | AGPL-3.0 |
| [espeak-ng](https://github.com/espeak-ng/espeak-ng) | GPL-3.0+ |
| [Piper](https://github.com/rhasspy/piper) | MIT |
| [Piper voice models](https://huggingface.co/rhasspy/piper-voices) | MIT |
| glibc (bundled shared libraries) | LGPL-2.1 |
