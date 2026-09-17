# sanoTTS voice: heart-nano

| | |
|---|---|
| lineage | `en_us_e13b` |
| parameters | 294,279 |
| runtime | `snt_nano` (mcu/src/snt_nano.c) |
| weights | int8 |
| sample rate | 24000 Hz |
| front end | front_q8.bin (109,296 B) |
| decoder | model_q8.bin (235,936 B) |
| mel channels | 100 |
| hop / n_fft | 256 / 1024 |
| vocab | 62 symbols |

## Running it

This voice runs on the **nano** runtime (`mcu/src/snt_nano.c`), not the
piperlite runtime the `voices-v1` packages use. That matters:

* The C runtime plays it directly. Point `snt_nano_config.front_blob` and
  `.dec_blob` at these two files. See `arduino/examples/BoardBenchmark` for a
  complete working caller.
* The browser demo plays it: <https://ampixa.github.io/sanoTTS/>
* **`pip install sanotts` does NOT play it yet.** That package implements the
  `duration_conv` / `token_context` / `piperlite` graph and raises
  `NotImplementedError` on anything else. The nano graph (mel-100 ->
  ConvNeXt1D -> iSTFT, noise-fed decoder) is not in the numpy runtime.

## Input

The runtime takes phoneme ids, not text. This voice's front end is
misaki-normalized espeak-ng IPA, character-level 62-symbol vocabulary (web/trellis_frontend.js).

## Integrity

`meta.json` carries `front_sha256` and `dec_sha256`; verify against
`SHA256SUMS` in this package.
