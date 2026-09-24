# sanoTTS-jp vendored core — provenance

The C sources under `csrc/` are vendored, unmodified except where noted, from
the sanoTTS-jp project (a clean-room Japanese TTS on the sanoTTS recipe):

- Upstream: https://github.com/ayutaz/sanoTTS-jp
- Vendored commit: `96787e7787f99b46e15d49328bca3e73df2bfea7`
- License: MIT (repo `LICENSE`), with the OpenJTalk subset under its own
  modified-BSD terms (`csrc/openjtalk/COPYING`, vendored from
  pyopenjtalk_plus-0.4.1.post9 per upstream's `csrc/openjtalk/PROVENANCE.md`).

## Vendored files

`csrc/`: saanotts.c, saanotts.h, saanotts_stream.c, saanotts_stream.h,
saanotts_internal.h, saanotts_int8.c, saanotts_int8.h, fft.c, fft.h,
saan_prof.h, erf_table.h, g2p.c, g2p.h, g2p_table.h, jdict.c, jdict.h,
accent.c, accent.h, dan_table.h, njd_rules.c, njd_rules.h, label_ids.c,
label_ids.h, token_table.h, golden_test.c — plus `csrc/openjtalk/` (36 files).

Byte-identical to upstream at the pinned commit. The only upstream-local
modification, inherited with the vendored OpenJTalk subset, is
`MAXBUFLEN 4096` → `256` in `openjtalk/jpcommon_label.c` (per-sentence heap
peak; documented in upstream's own PROVENANCE.md).

## What is deliberately NOT vendored

The int8 weights blob (`saanotts-jp-v4-int8.bin`, 654,032 B), the Japanese
pronunciation dictionary (`k1-dict-438750.bin`, 13,702,320 B), the golden
reference blobs, samples, corpus data, and the ESP32 firmware images are
**release assets of the upstream project, never committed here**. The user
downloads the weights and the dictionary in-app (or by hand) from
https://github.com/ayutaz/sanoTTS-jp/releases/tag/v1.0.0 — this plugin ships
only code.

## Runtime data licenses

The weights carry `LicenseRef-sanoTTS-jp-Model-1.0` (attribution, output-use
restrictions, propagation — see upstream `LICENSE-MODEL.md`); the dictionary
is a NAIST-JDIC derivative with its own terms (upstream `NOTICE.md`). Because
this plugin does not redistribute either file, those conditions attach to the
user through their own download. The in-app downloader fetches
`LICENSE-MODEL.md` and `NOTICE.md` next to the voice for the user's records.

## Upstream local-practice notes kept for reference

- The int8 blob must be format v2 (v1 blobs with int8 tensors are rejected in
  `saan_weights_open`).
- The golden gate (`golden_test student_i8.bin golden_i8.bin`) validates the
  core against the released reference; we run it against our vendored copy.
