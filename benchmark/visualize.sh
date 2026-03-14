#!/bin/bash
#
# Visualize benchmark results as ASCII charts.
# Reads the JSON result files and produces a comparison chart.
#
# Usage:
#   ./visualize.sh                    # visualize all results
#   ./visualize.sh results/baseline.json results/server_2x2.json
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="${1:-$SCRIPT_DIR/results}"

# If arguments are files, use them directly
if [[ -f "$RESULTS_DIR" ]]; then
    FILES=("$@")
else
    FILES=("$RESULTS_DIR"/*.json)
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "No result files found in $RESULTS_DIR"
    echo "Run the benchmark first, then fetch results with:"
    echo "  ./deploy-and-run.sh --results"
    exit 1
fi

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║          PIPER TTS BENCHMARK — VISUAL COMPARISON               ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Extract key metrics from each JSON file
declare -A RT_FACTORS
declare -A COLD_STARTS
declare -A AVG_GAPS
declare -A MAX_GAPS
declare -A THROUGHPUTS

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || continue
    NAME=$(basename "$f" .json)

    RT=$(grep -o '"realtime_factor"[[:space:]]*:[[:space:]]*[0-9.]*' "$f" | head -1 | grep -o '[0-9.]*$')
    COLD=$(grep -o '"cold_start_ms"[[:space:]]*:[[:space:]]*[0-9.]*' "$f" | head -1 | grep -o '[0-9.]*$')
    AVGG=$(grep -o '"avg_gap_ms"[[:space:]]*:[[:space:]]*[0-9.]*' "$f" | head -1 | grep -o '[0-9.]*$')
    MAXG=$(grep -o '"max_gap_ms"[[:space:]]*:[[:space:]]*[0-9.]*' "$f" | head -1 | grep -o '[0-9.]*$')
    THRU=$(grep -o '"throughput_chars_per_sec"[[:space:]]*:[[:space:]]*[0-9.]*' "$f" | head -1 | grep -o '[0-9.]*$')

    RT_FACTORS[$NAME]="${RT:-0}"
    COLD_STARTS[$NAME]="${COLD:-0}"
    AVG_GAPS[$NAME]="${AVGG:-0}"
    MAX_GAPS[$NAME]="${MAXG:-0}"
    THROUGHPUTS[$NAME]="${THRU:-0}"
done

# ── Bar chart function ────────────────────────────────────────────────

bar_chart() {
    local TITLE="$1"
    local -n VALUES=$2
    local UNIT="$3"
    local MAX_BAR=40
    local HIGHER_IS_BETTER="${4:-true}"

    echo "┌─ $TITLE ──────────────────────────────────────────────"

    # Find max value for scaling
    local MAX_VAL=0
    for NAME in "${!VALUES[@]}"; do
        local VAL="${VALUES[$NAME]}"
        VAL=$(echo "$VAL" | awk '{printf "%.0f", $1}')
        if [[ $VAL -gt $MAX_VAL ]]; then MAX_VAL=$VAL; fi
    done

    if [[ $MAX_VAL -eq 0 ]]; then MAX_VAL=1; fi

    # Sort by value
    for NAME in $(for k in "${!VALUES[@]}"; do echo "$k ${VALUES[$k]}"; done | sort -k2 -n -r | awk '{print $1}'); do
        local VAL="${VALUES[$NAME]}"
        local IVAL=$(echo "$VAL" | awk '{printf "%.0f", $1}')
        local BAR_LEN=$((IVAL * MAX_BAR / MAX_VAL))
        if [[ $BAR_LEN -lt 1 ]] && [[ $IVAL -gt 0 ]]; then BAR_LEN=1; fi

        local BAR=""
        for ((j=0; j<BAR_LEN; j++)); do BAR="${BAR}█"; done

        printf "│ %-22s %s %s %s\n" "$NAME" "$BAR" "$VAL" "$UNIT"
    done
    echo "└──────────────────────────────────────────────────────────"
    echo ""
}

# ── Display charts ────────────────────────────────────────────────────

echo "═══ Realtime Factor (higher = better, >1.0 means faster than playback) ═══"
echo ""
bar_chart "Realtime Factor (×)" RT_FACTORS "×" true

echo "═══ Cold Start Time (lower = better) ═══"
echo ""
bar_chart "Cold Start (ms)" COLD_STARTS "ms" false

echo "═══ Average Gap Between Sentences (lower = better) ═══"
echo ""
bar_chart "Avg Gap (ms)" AVG_GAPS "ms" false

echo "═══ Maximum Gap (lower = better, worst-case pause) ═══"
echo ""
bar_chart "Max Gap (ms)" MAX_GAPS "ms" false

echo "═══ Throughput (higher = better) ═══"
echo ""
bar_chart "Throughput (chars/s)" THROUGHPUTS "chars/s" true

echo ""
echo "Note: Run './deploy-and-run.sh --results' to fetch latest results from Kobo."
