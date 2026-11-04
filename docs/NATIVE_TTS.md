# Platform-native TTS backend

The **platform-native TTS backend** lets you use a text-to-speech engine that is already licensed and present on your device, without the plugin shipping any proprietary voices, libraries, or credentials. It is intentionally generic: the plugin handles the `text → WAV → playback` pipeline and a small set of conventions, and you provide a helper program that talks to your device's own engine.

This was motivated by PocketBook Era owners who want to reuse the built-in ReadSpeaker voice from KOReader, but the backend works with any device-native engine that can be driven by a small helper script.

## What the plugin does NOT ship

- No voice files.
- No engine binaries or libraries.
- No device-specific credentials, license files, or extraction tools.

Everything engine-specific must come from your own device or from software you are authorized to use.

## Enabling the backend

1. Open **Audiobook → Voice Settings → TTS engine**.
2. Select **Platform-native helper** (it appears once a helper path is configured or the backend was previously selected).
3. Open **Platform-native helper settings** and set the path to your helper.

## Helper interface

### One-shot mode

For simple engines, the plugin runs the helper once per sentence:

```bash
<helper> --input <text_file> --output <wav_file> --speed <rate>
```

- `<text_file>`: path to a file containing the sentence. The file is UTF-8 by default, or CP1252 if you select that encoding in settings.
- `<wav_file>`: path where the helper must write a valid RIFF/WAV file.
- `<rate>`: the current speech rate, as a float where `1.000` is normal speed. Your helper can scale this to whatever units the engine expects.

The helper must exit with status `0` and produce a non-empty WAV file.

### Daemon/FIFO mode

For engines with a large voice database that is expensive to load per sentence, the helper can run as a persistent daemon:

```bash
<helper> --daemon --fifo <fifo_path>
```

The plugin starts the helper once (using `flock` for single-instancing when available) and keeps it running. For each sentence it writes one line to the FIFO:

```text
SYNTH|<input_text_file>|<output_wav>|<speed>
```

Pipe characters inside paths are escaped as `\|`. The helper must:

1. Read one request line from the FIFO.
2. Synthesize speech from `<input_text_file>`.
3. Write a valid RIFF/WAV file to `<output_wav>`.
4. Create a completion marker file at `<output_wav>.done` containing either:
   - `OK` on success, or
   - `ERR|<message>` on failure.

The plugin polls for the marker file, so the helper never needs to write back to a FIFO.

## WAV output format

Write a plain canonical 44-byte PCM header (16-bit mono/stereo, `data` chunk last). The plugin patches WAV sizes in place when it appends sentence gaps, and it locates the `data` chunk by walking the RIFF chunk list, but the simplest way to stay out of trouble is a header with no extra chunks: produce it with `ffmpeg -map_metadata -1 -fflags +bitexact -flags:a +bitexact`, or write the 44 bytes yourself. Files with extra `LIST`/`INFO` chunks still play, but gap-appends into them are refused rather than risk a corrupted clip.

## Encoding

Some device-native engines (including PocketBook ReadSpeaker) expect CP1252 input rather than UTF-8. If you select **Input encoding: CP1252** in settings, the plugin converts the text before writing the helper input file. Characters that cannot be represented in CP1252 become `?`.

## Pre-synthesis command

The optional **Pre-synthesis command** runs before each synthesis request. This is useful for device-specific setup, for example checking or restarting the `alsaloop` bridge that carries audio to the PocketBook speaker:

```bash
/path/to/check_alsaloop.sh
```

Keep this command fast and non-blocking; it runs on the UI thread.

## Example wrapper for PocketBook ReadSpeaker (illustrative)

The snippet below is only a template. You must adapt paths, library names, and invocation details to your own device and licensed voice.

```bash
#!/bin/sh
# /mnt/ext1/system/config/audiobook_tts.sh
# ADAPT THIS TO YOUR OWN DEVICE AND LICENSED VOICE.

INPUT_UTF8="$1"
OUTPUT_WAV="$2"
SPEED="$3"   # plugin rate, e.g. 1.000

TMP="/tmp/audiobook_readspeaker"
mkdir -p "$TMP"

# Convert UTF-8 to CP1252 for the engine.
INPUT_CP1252="$TMP/input_cp1252.txt"
iconv -f UTF-8 -t CP1252 "$INPUT_UTF8" > "$INPUT_CP1252"

# Set the engine library path for your device and voice.
# export LD_LIBRARY_PATH="/mnt/ext1/system/tts/<voice>/.../P22/bin:$LD_LIBRARY_PATH"

# Invoke your own licensed helper here.
# /path/to/your/helper "$INPUT_CP1252" "$OUTPUT_WAV" "$SPEED"
```

Save it as an executable shell script and point the plugin's **Native helper** setting at it.

## Speed mapping

The plugin passes its internal speech rate (typically `0.250` to `2.000`, with `1.000` as normal) directly to the helper. If your engine uses a different scale, convert inside the helper. For example, a native engine that takes `100` as normal speed can use:

```bash
NATIVE_SPEED=$(awk "BEGIN { printf \"%d\", $SPEED * 100 }")
```

## Timing and word highlighting

Most native engines do not provide word-level timing. The plugin falls back to its usual estimated timing and scales it to the real WAV duration, so sentence highlighting and auto-advance work normally.

## Troubleshooting

- **No audio**: check the log files `/tmp/.native_tts_last.log` (one-shot) and `/tmp/audiobook_native_daemon.log` (daemon).
- **Daemon not starting**: make sure `flock` is available on the device, or ensure your helper refuses duplicate instances on its own.
- **Garbled punctuation**: switch input encoding to CP1252 if your engine expects it.
- **Stuck after suspend/wake**: use the pre-synthesis command to restart any audio bridge (`alsaloop`) that your firmware stops during sleep.
