# sanoTTS engine (int8 neural TTS, low-resource tier)

A tiny neural TTS engine that slots between Piper (quality tier) and
espeak-ng (fallback) in the backend list. Runs real-time on a Kobo Clara
(measured RTF 0.15 on a dual-core Libra Color; 0.33-class on single-core)
with a 0.7-1.5 MB voice and ~5 MB RAM, where Piper needs a ~60 MB voice and
~100 MB RAM.

## Layout

- `snt_server.c` — engine server. Reads Piper-style JSON lines
  (`{"text": "...", "output_file": "..."}`) on stdin, synthesizes, and
  prints the WAV path per line (the same protocol the piper queue expects).
  One binary serves three engines, selected with `--engine`:
  - `int8` (default): the R7 "kristin" voice, 22050 Hz, via `snt_tts.c`.
  - `pq8`: the fully-int8 piperlite stack (`snt_front_q8.c` +
    `snt_piperlite_q8.c`), 22050 Hz. Every dimension comes out of the
    blobs, so any exported piperlite int8 voice runs without a rebuild.
  - `nano`: the heart-nano voice, 24000 Hz, via `snt_nano.c`, phonemized
    by the espeak-free lexicon G2P (`nano_lex_g2p.c`, misaki dictionary
    data, Apache-2.0; ~3 MB of const tables in .rodata).
- `phoneme_id_map.h`: generated Piper phoneme-id map (en_US, espeak en-us),
  used by the int8 and pq8 engines.
- `voice/front_q8.bin`, `voice/model_q8.bin`: the kristin voice (R7 int8,
  680 KB total, 22050 Hz mono output).
- `voice-amy/front_meta_q8.bin`, `front_weights_q8.bin`, `meta_q8.bin`,
  `weights_q8.bin`: the amy voice (en_US-amy-medium distilled, fully int8,
  1.48 MB total, 22050 Hz mono output), exported with upstream's
  `tools/export_piperlite_q8.py` / `export_front_q8.py`.
- `voice-nano/`: heart-nano blobs staged for the nano engine (front_q8.bin,
  model_q8.bin, its `nano_q8_meta.h` offsets header); not yet wired into the
  Lua voice menu.
- `nano_lex_g2p.c`, `nano_lex_g2p.h`, `nano_lex_tables.c`,
  `nano_lex_tables.h`: the espeak-free English G2P for the nano engine,
  ported from upstream `esphome/components/sanotts/`.
- `snt_server` — prebuilt static armv7hf binary (see out/ after builds).

## Provenance and licensing

The inference runtimes (`snt_tts.c`, `snt_nano.c`, `snt_front_q8.c`,
`snt_piperlite_q8.c`, kernels, headers) and the int8 voice blobs come from
the sanoTTS project (https://github.com/ampixa/sanoTTS) and are
MIT-licensed. The phoneme-id map is generated from the same project's
piper-phoneme-config.json (Piper/eSpeak conventions); the nano G2P's
pronunciation data is misaki's us_gold/us_silver tables (Apache-2.0). The
driver (`snt_server.c`) is written for this plugin. Phonemization at runtime
uses the bundled espeak-ng binary already shipped for the espeak-ng backend
(int8 and pq8 engines), so no additional espeak data is bundled here.

## Rebuilding the server

```bash
cd sanotts
nix shell nixpkgs#pkgsCross.armv7l-hf-multiplatform.pkgsStatic.stdenv \
  -c bash -c 'export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -O2 -std=c99 -I$PWD/mcu/include -I$PWD/mcu/src -I$PWD/voice-nano -DFSD_FAST_MATH";
  $CC -static -o snt_server snt_server.c mcu/src/snt_tts.c mcu/src/snt_kernels_ref.c mcu/src/snt_nano.c mcu/src/snt_front_q8.c mcu/src/snt_piperlite_q8.c mcu/ports/host/snt_port_host.c nano_lex_g2p.c nano_lex_tables.c -lm'
```

(with the sanoTTS checkout in `mcu/`; `package-for-kobo.sh` does this
automatically against the pinned upstream snapshot through
`cross-build-snt-server.nix`.)

## Punctuation handling

espeak's IPA output drops punctuation entirely, so the server carries it in
two layers (both on by default for int8/pq8):

1. The text is split at `. , ? ! : ;` and each clause is synthesized
   separately with a silence gap after it, sized by the punctuation
   (`--comma-ms` 150, `--period-ms` 350, colon 220, semicolon 250).
2. The punctuation mark's own phoneme id is appended to the clause's token
   stream before EOS, so the model renders its native terminal contour
   (rising for `?`, falling for `.`). This mirrors what piper's own
   phonemizer does; without it the punctuation would vanish.

`--native-punct` replaces both with piper's exact behavior: the whole line
is one synthesis and the punctuation ids carry all pauses themselves. On
these students the native pauses are subtle (~120 ms), which is why the
layered default exists.

## Runtime tuning

- `--engine int8|pq8|nano` selects the runtime (see Layout).
- `--pause-scale F` (pq8) stretches only the punctuation tokens' frame
  counts; phones keep their native durations, so pacing deepens without
  feeding the decoder stretched phones (which reads as phasing). The plugin
  ships 2.5.
- `--length-scale F` (pq8) warps every duration; useful as a speed control
  but audible as phasing at larger values on these students.
- `--comma-ms N`, `--period-ms N` size the silence inserted after clauses
  ending in `,` and in `. ? !` (colon 220 ms, semicolon 250 ms).
- `--voice en-us`, `--rate 22050|24000` choose the espeak-ng voice for
  phonemization and the output sample rate (nano defaults to 24000).
- `--seed N` (nano) forces one decoder noise seed; default seeds from the
  clause text, so a sentence always sounds the same.
- `--loader <ld-linux>`, `--loader-libdir <dir>` exec the bundled armhf
  espeak-ng through the bundled glibc loader on stock Kobo rootfs (set
  automatically by piperqueue).
