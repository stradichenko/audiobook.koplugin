# sanoTTS engine (int8 neural TTS, low-resource tier)

A tiny neural TTS engine that slots between Piper (quality tier) and
espeak-ng (fallback) in the backend list. Runs real-time on a Kobo Clara
(measured RTF 0.15 on a dual-core Libra Color; 0.33-class on single-core)
with a ~700 KB voice and ~5 MB RAM, where Piper needs a ~60 MB voice and
~100 MB RAM.

## Layout

- `snt_server.c` — engine server. Reads Piper-style JSON lines
  (`{"text": "...", "output_file": "..."}`) on stdin, synthesizes, and
  prints the WAV path per line (the same protocol the piper queue expects).
- `phoneme_id_map.h` — generated Piper phoneme-id map (en_US, espeak en-us).
- `voice/front_q8.bin`, `voice/model_q8.bin` — the int8 voice (en_US,
  "kristin" lineage, 680 KB total, 22050 Hz mono output).
- `snt_server` — prebuilt static armv7hf binary (see out/ after builds).

## Provenance and licensing

The inference runtime (`snt_tts.c`, `snt_kernels_ref.c`, headers) and the
int8 voice blobs come from the sanoTTS project
(https://github.com/ampixa/sanoTTS). The sanoTTS inference runtime and voice
blobs are MIT-licensed; the phoneme-id map is generated from the same
project's piper-phoneme-config.json (Piper/eSpeak conventions). The driver
(`snt_server.c`) is written for this plugin. Phonemization at runtime uses
the bundled espeak-ng binary already shipped for the espeak-ng backend, so
no additional espeak data is bundled here.

## Rebuilding the server

```bash
cd sanotts
nix shell nixpkgs#pkgsCross.armv7l-hf-multiplatform.pkgsStatic.stdenv \
  -c bash -c 'export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -O2 -std=c99 -I$PWD/mcu/include -I$PWD/mcu/src -DFSD_FAST_MATH";
  $CC -static -o snt_server snt_server.c mcu/src/snt_tts.c mcu/src/snt_kernels_ref.c mcu/ports/host/snt_port_host.c -lm'
```

(with the sanoTTS checkout in `mcu/`; `package-for-kobo.sh` does this
automatically against the pinned upstream snapshot.)

## Runtime tuning

- `--comma-ms N`, `--period-ms N` size the silence inserted after clauses
  ending in `,` (default 150) and in `. ? !` (default 350). The input text is
  split at `. , ? ! : ;` and each clause is synthesized separately with a
  gap after it (colon 220 ms, semicolon 250 ms); the plugin adds its own
  gap after the final clause.
- `--voice en-us`, `--rate 22050` choose the espeak-ng voice for
  phonemization and the output sample rate.
- `--loader <ld-linux>`, `--loader-libdir <dir>` exec the bundled armhf
  espeak-ng through the bundled glibc loader on stock Kobo rootfs (set
  automatically by piperqueue).
