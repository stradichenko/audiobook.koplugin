# Piper TTS Benchmark Results — Kobo ARM

**Date:** March 14, 2026  
**Hardware:** Kobo Clara (ARMv7 Cortex-A8, single-core ~1GHz, 942MB RAM)  
**OS:** Linux 4.9.77  
**Runtime:** LuaJIT 2.1  
**Model:** `en_US-lessac-low.onnx` (16kHz) unless noted  
**Test corpus:** 25 sentences, 513 chars, 89 words (~33s of audio)

---

## Executive Summary

> **The optimal strategy is `server_1x1_batch3` — a single persistent Piper server with
> 3-sentence batching — achieving 0.329× RT and 2.7s average gaps.**
>
> The current production configuration (2 servers, pipeline depth 2) is **catastrophically
> bad** on single-core ARM, running **4× slower** than a single server.

---

## Complete Results (13 strategies tested)

```
Rank  Strategy              RT×      Avg Gap   Max Gap   Cold Start  Chars/s
─────────────────────────────────────────────────────────────────────────────
 1.   server_1x1_batch3    0.329×    2697ms    5150ms      2666ms     5.2  ★ BEST
 2.   server_1x1           0.322×    2791ms    8944ms      4000ms     5.1
 3.   adaptive             0.319×    2717ms    3746ms      3916ms     5.1  ★ BEST max gap
 4.   batch_10             0.316×    2793ms    4053ms      3300ms     5.1
 5.   batch_5              0.304×    3053ms    4476ms      3200ms     4.8
 ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
 6.   model_compare        0.223×    6170ms   10072ms      5000ms     4.2
 7.   baseline             0.203×    5215ms    9704ms      5000ms     3.2
 8.   quiet_flag           0.198×    5249ms   10976ms      5000ms     3.2
 9.   output_raw           0.198×    5247ms   10880ms      5000ms     3.2
10.   noise_zero           0.190×    5199ms   10960ms      5000ms     3.2
11.   length_scale_08      0.185×    5165ms    9832ms      5000ms     3.3
12.   server_1x2           0.166×    6538ms   11848ms      5000ms     2.7
13.   server_2x2           0.085×   14438ms   30864ms      7000ms     1.3  ✗ WORST
```

### Visual: Realtime Factor (higher = faster)

```
server_1x1_batch3  ████████████████████████████████▉  0.329×  ★ BEST
server_1x1         ████████████████████████████████▏  0.322×
adaptive           ███████████████████████████████▉   0.319×
batch_10           ███████████████████████████████▌   0.316×
batch_5            ██████████████████████████████▍    0.304×
model_compare      ██████████████████████▎            0.223×
baseline           ████████████████████▎              0.203×
quiet_flag         ███████████████████▊               0.198×
output_raw         ███████████████████▊               0.198×
noise_zero         ███████████████████                0.190×
length_scale_08    ██████████████████▌                0.185×
server_1x2         ████████████████▌                  0.166×
server_2x2         ████████▌                          0.085×  ✗ WORST
```

---

## Tier 1: Winners (amortize model load overhead)

### 🥇 server_1x1_batch3 — 0.329× RT

- **1 persistent server + 3-sentence batching** (the hybrid approach)
- **Avg gap: 2697ms** · Max gap: 5150ms · Cold start: **2666ms** (fastest!)
- Eliminates model reload (server mode) AND amortizes per-request JSON overhead (batching)
- 9 server calls for 25 sentences instead of 25
- **This is the recommended production config**

### 🥈 server_1x1 — 0.322× RT

- **1 persistent server, pipeline depth 1** (sentence-by-sentence via FIFO)
- **Avg gap: 2791ms** · Max gap: 8944ms · Cold start: 4000ms
- Best raw throughput per-sentence. Max gap is high because long sentences (62 chars) take
  11s and nothing can overlap on single-core
- Good for fine-grained playback tracking (1 WAV per sentence)

### 🥉 adaptive — 0.319× RT

- **Per-process batching up to 500 chars** (variable batch sizes)
- **Avg gap: 2717ms** · Max gap: **3746ms** (★ lowest!) · Cold start: 3916ms
- Only 2 Piper invocations (1 × 493 chars + 1 × 20 chars)
- **Best max gap** because large batches mean fewer process transitions
- Trade-off: very large first batch means long initial delay (94s for 493 chars)

### batch_10 — 0.316× RT

- **10 sentences per piper invocation**
- Avg gap: 2793ms · Max gap: 4053ms · Cold start: 3300ms
- Very consistent gap times. Simple to implement.

### batch_5 — 0.304× RT

- **5 sentences per piper invocation**
- Avg gap: 3053ms · Max gap: 4476ms · Cold start: 3200ms
- Good balance of responsiveness and throughput

---

## Tier 2: Piper Flag Variations (per-process, no batching)

These all tested individual Piper CLI flags against the baseline. **None improved throughput.**
The ~4.5s model-load overhead completely dominates per-process execution.

| Strategy | RT× | vs Baseline | Finding |
|---|---|---|---|
| **baseline** | 0.203× | — | Reference: 1 process per sentence |
| **quiet_flag** | 0.198× | −2% | `--quiet` saves negligible I/O |
| **output_raw** | 0.198× | −2% | `--output_raw` doesn't accelerate ONNX inference |
| **noise_zero** | 0.190× | −6% | `--noise_scale 0 --noise_w 0` — deterministic, slightly slower (no early termination in sampling) |
| **length_scale_08** | 0.185× | −9% | `--length_scale 0.8` produces less audio for same compute → worse ratio |

**Conclusion:** No Piper CLI flag meaningfully changes inference speed. The model is the bottleneck.

---

## Tier 3: Parallelism Strategies (all worse on single-core)

| Strategy | RT× | vs server_1x1 | Finding |
|---|---|---|---|
| **server_1x2** | 0.166× | −48% | Pipeline depth 2 on 1 server: FIFO writes serialize anyway, adds measurement overhead |
| **server_2x2** | 0.085× | −74% | 2 servers on 1 core: catastrophic CPU contention |

### Why server_1x2 is worse than server_1x1

With pipeline depth 2 on a single server, we write sentence N+1 to the FIFO while sentence N
is still synthesizing. But since Piper processes requests sequentially and the CPU can't
overlap anything, the timing for sentence N+1 includes the wait for sentence N — inflating
measured synth times. The net throughput is identical or slightly worse due to FIFO management
overhead.

**Recommendation:** Pipeline depth should be **1** on single-core hardware.

---

## Model Comparison

All three available models perform identically:

```
Model                    RT×     Chars/s
─────────────────────────────────────────
en_US-danny-low.onnx    0.23×    4.1
en_US-lessac-low.onnx   0.23×    4.2
en_US-ryan-low.onnx     0.21×    4.4
```

All are ~60MB, 16kHz, low-quality VITS models. The small RT× differences are within
measurement noise (±1s per sentence at 1s resolution). **Model choice should be based
on voice preference, not performance.**

---

## Chunk Size Profiling

Throughput vs input text length (separate process per call):

```
Chunk Size    RT×      Chars/s    Overhead %
───────────────────────────────────────────────
  50 chars    0.25×     3.6        ~78%
 100 chars    0.28×     4.3        ~57%
 200 chars    0.32×     5.2        ~32%    ← plateau threshold
 300 chars    0.32×     5.4        ~24%
 500 chars    0.32×     5.4        ~16%
 750 chars    0.33×     5.5        ~11%
```

Every Piper invocation has a **~4.5s fixed cost** (ONNX model load). This means:
- At 50 chars: 78% of time is wasted loading the model
- At 200+ chars: overhead drops below 32% and throughput plateaus at ~5.4 chars/s
- **Minimum efficient batch size: ~200 characters (3-4 sentences)**

---

## Production Recommendations

### Applied Change: Auto-detect CPU Cores

The `piperqueue.lua` now auto-detects CPU cores and scales accordingly:

```lua
local _cpu_cores    = _detect_cpu_cores()    -- reads /sys/devices/system/cpu/possible
local SERVER_COUNT  = math.min(_cpu_cores, 2) -- 1 server per core, max 2
local BATCH_SIZE    = _cpu_cores == 1 and 3 or 1  -- batch more on single-core
```

### Optimal Configuration for Single-Core ARM (Kobo Clara)

| Parameter | Before | After | Impact |
|-----------|--------|-------|--------|
| `SERVER_COUNT` | 2 | **1** | **+280%** throughput (0.085→0.329 RT×) |
| `BATCH_SIZE` | 1 | **3** | **+8%** throughput, **−52%** cold start |
| `MAX_PIPELINE_DEPTH` | 2 | **1** | Avoids FIFO measurement overhead |

### For Multi-Core ARM (newer Kobos with Cortex-A53 quad-core)

The auto-detection will set `SERVER_COUNT=2` on multi-core hardware, which should be
beneficial. Re-run benchmarks on that hardware to validate.

---

## Key Insights

1. **Model load time (~4.5s) is the dominant cost.** Every strategy that amortizes this
   cost (batching or persistent server) is in the top tier.

2. **Single-core means zero parallelism.** Any attempt to overlap CPU-bound work
   (multiple servers, pipeline depth >1) backfires catastrophically.

3. **Piper CLI flags don't matter.** `--quiet`, `--output_raw`, `--noise_scale 0` —
   none change the ONNX inference speed, which is the actual bottleneck.

4. **All 3 low models perform identically.** Choose voice quality, not speed.

5. **The "server + batch" hybrid is optimal:** persistent server eliminates model reload,
   3-sentence batching amortizes per-request JSON overhead, and you get 0.329× RT with
   2.7s average gaps.

6. **~200 chars is the efficiency threshold.** Below this, per-process overhead dominates.
   Above this, throughput plateaus at ~5.4 chars/s.

---

## Reproducing These Results

```bash
cd benchmark/

# Deploy to Kobo
bash deploy-and-run.sh --deploy-only

# Run individual strategies
bash run-single.sh server_1x1_batch3
bash run-single.sh server_1x1
bash run-single.sh adaptive
bash run-single.sh model_compare

# Or run via nohup (survives SSH disconnection)
ssh root@kobo 'nohup luajit benchmark.lua server_1x1_batch3 --pages 4 > out.log 2>&1 &'

# Fetch results
bash deploy-and-run.sh --results
```

---

## Raw Data Files

Results stored in `results/` as JSON + TXT:

| Strategy | JSON | TXT |
|---|---|---|
| server_1x1_batch3 | ✅ | ✅ |
| server_1x1 | ✅ | ✅ |
| adaptive | ✅ | ✅ |
| batch_10 | ✅ | ✅ |
| batch_5 | ✅ | ✅ |
| model_compare | ✅ | ✅ |
| baseline | ✅ | ✅ |
| quiet_flag | ✅ | ✅ |
| output_raw | ✅ | ✅ |
| noise_zero | ✅ | ✅ |
| length_scale_08 | ✅ | ✅ |
| server_1x2 | ✅ | ✅ |
| server_2x2 | ✅ | ✅ |
