# Piper TTS Benchmark for Kobo ARM

## Problem Statement

Neural TTS (Piper) on Kobo ARM hardware (iMX6/iMX7, ~1GHz single-core Cortex-A9)
synthesizes at **~0.3-0.5× real-time**: a 5-second sentence takes 10-30 seconds
to generate. This creates **unwanted pauses** between paragraphs/sentences that
destroy the listening experience.

## Goal

Test and measure different strategies to minimize or eliminate perceptible gaps
between synthesized audio segments when using low-quality Piper models
(e.g. `en_US-danny-low`, `en_US-ryan-low`) on Kobo hardware.

## Strategies Tested

### Strategy 1: Baseline (Current Implementation)
- 2 persistent Piper servers with JSON-input mode
- BATCH_SIZE=1 (one sentence per server call)
- MAX_PIPELINE_DEPTH=2 (2 requests queued per server FIFO)
- 20-sentence lookahead prefetch
- Accumulate-then-play: wait for 3+ consecutive sentences before playing

### Strategy 2: Aggressive Prefetch
- **4 persistent servers** (vs 2) to double throughput
- MAX_PIPELINE_DEPTH=3 for deeper pipelining
- 40-sentence lookahead
- Trade more RAM (~100MB extra) for less waiting

### Strategy 3: Large Batch Concatenation
- Concatenate **5-10 sentences** into a single Piper call
- One synthesis pass produces a long audio segment (~30-60s of audio)
- Split the combined WAV afterward using syllable-proportional estimation
- Fewer synthesis calls = fewer gaps, but higher latency to first audio

### Strategy 4: Optimal Chunk Sizing
- Profile Piper's synthesis time vs. input text length
- Find the **sweet spot** where chars/second throughput is maximized
- Dynamic chunking: merge short sentences, split long ones to hit optimal size
- Target: maximize synthesis throughput per CPU second

### Strategy 5: Sentence-Length Adaptive Batching
- Short sentences (<50 chars): batch 5+ together in one Piper call
- Medium sentences (50-150 chars): batch 2-3 together
- Long sentences (>150 chars): synthesize individually
- Adapts to content structure automatically

### Strategy 6: Overlap Streaming with Pre-Silence
- Start playing audio AS SOON as first sentence is ready
- Append estimated silence duration to each WAV to cover synthesis gap
- Replace silence with real audio when next sentence completes
- User hears brief silence instead of choppy play-pause-play

## Metrics Collected

| Metric | Description |
|--------|-------------|
| `cold_start_ms` | Time from first synthesis request to first audio ready |
| `total_synthesis_ms` | Total wall-clock time to synthesize all sentences |
| `total_audio_duration_ms` | Sum of all produced audio durations |
| `realtime_factor` | `total_audio_duration_ms / total_synthesis_ms` (>1 = faster than realtime) |
| `avg_gap_ms` | Average gap between consecutive sentence completions |
| `max_gap_ms` | Worst-case gap (longest user-perceptible pause) |
| `p95_gap_ms` | 95th percentile gap |
| `throughput_chars_per_sec` | Characters synthesized per second |
| `throughput_words_per_sec` | Words synthesized per second |
| `peak_memory_kb` | Peak RSS of all Piper processes combined |
| `sentences_total` | Number of sentences tested |
| `wav_total_bytes` | Total WAV file output size |

## Running the Benchmark

### From the development machine:

```bash
# Deploy and run all strategies:
cd benchmark/
./deploy-and-run.sh

# Deploy and run a specific strategy:
./deploy-and-run.sh --strategy baseline

# Just deploy (don't run):
./deploy-and-run.sh --deploy-only
```

### On the Kobo directly:

```bash
cd /tmp/piper-benchmark/
lua benchmark.lua                    # Run all strategies
lua benchmark.lua baseline           # Run one strategy
lua benchmark.lua --list             # List available strategies
```

## Interpreting Results

Results are written to `/tmp/piper-benchmark/results/` as JSON and
human-readable text. Key things to look for:

1. **realtime_factor > 1.0**: Synthesis is faster than playback — no gaps possible
2. **max_gap_ms < 500**: Worst-case pause is under 0.5s — acceptable
3. **cold_start_ms < 5000**: First audio within 5s — good UX
4. **Lower peak_memory_kb**: Important for Kobo's limited RAM (256-512MB)

## Test Document

The benchmark uses a generated test document with:
- 10 "pages" of content
- Mix of short (1-2 sentences), medium (3-5 sentences), and long (6-10 sentences) paragraphs
- Varied sentence lengths (5-50 words)
- Common punctuation patterns (commas, semicolons, dashes, ellipsis)
- Dialogue and quotations
- Technical/numerical content
