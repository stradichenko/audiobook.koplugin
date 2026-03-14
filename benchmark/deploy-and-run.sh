#!/bin/bash
#
# Deploy Piper TTS benchmark to Kobo and optionally run it.
#
# Usage:
#   ./deploy-and-run.sh                    # deploy + run all strategies
#   ./deploy-and-run.sh --strategy baseline # deploy + run one strategy
#   ./deploy-and-run.sh --deploy-only      # just copy files
#   ./deploy-and-run.sh --quick            # quick mode (2 pages)
#   ./deploy-and-run.sh --results          # fetch results from Kobo
#   ./deploy-and-run.sh --pages 1,4,6      # test specific pages
#

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────

KOBO_IP="${KOBO_IP:-192.168.1.28}"
KOBO_PORT="${KOBO_PORT:-2222}"
KOBO_PASS="${KOBO_PASS:-}"
KOBO_USER="root"

BENCHMARK_DIR="/tmp/piper-benchmark"
PLUGIN_DIR="/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ── Helpers ───────────────────────────────────────────────────────────

ssh_cmd() {
    nix-shell -p sshpass openssh --run \
        "sshpass -p '$KOBO_PASS' ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p $KOBO_PORT ${KOBO_USER}@${KOBO_IP} $*" 2>&1
}

scp_to() {
    local src="$1"
    local dst="$2"
    nix-shell -p sshpass openssh --run \
        "sshpass -p '$KOBO_PASS' scp -o ConnectTimeout=5 -o StrictHostKeyChecking=no -P $KOBO_PORT '$src' ${KOBO_USER}@${KOBO_IP}:$dst" 2>&1
}

scp_from() {
    local src="$1"
    local dst="$2"
    nix-shell -p sshpass openssh --run \
        "sshpass -p '$KOBO_PASS' scp -o ConnectTimeout=5 -o StrictHostKeyChecking=no -P $KOBO_PORT ${KOBO_USER}@${KOBO_IP}:$src '$dst'" 2>&1
}

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

# ── Parse arguments ───────────────────────────────────────────────────

DEPLOY_ONLY=false
FETCH_RESULTS=false
STRATEGY=""
QUICK=""
PAGES=""
EXTRA_ARGS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --deploy-only)
            DEPLOY_ONLY=true
            shift ;;
        --results)
            FETCH_RESULTS=true
            shift ;;
        --strategy)
            STRATEGY="$2"
            shift 2 ;;
        --quick)
            QUICK="--quick"
            shift ;;
        --pages)
            PAGES="--pages $2"
            shift 2 ;;
        *)
            EXTRA_ARGS="$EXTRA_ARGS $1"
            shift ;;
    esac
done

# ── Fetch results ─────────────────────────────────────────────────────

if $FETCH_RESULTS; then
    log "Fetching results from Kobo..."
    mkdir -p "$SCRIPT_DIR/results"
    scp_from "$BENCHMARK_DIR/results/*" "$SCRIPT_DIR/results/" || true
    log "Results saved to $SCRIPT_DIR/results/"
    if [[ -f "$SCRIPT_DIR/results/COMPARISON.txt" ]]; then
        echo ""
        cat "$SCRIPT_DIR/results/COMPARISON.txt"
    fi
    exit 0
fi

# ── Deploy ────────────────────────────────────────────────────────────

log "Checking Kobo connectivity..."
if ! ssh_cmd "echo ok" | grep -q "ok"; then
    echo "ERROR: Cannot connect to Kobo at $KOBO_IP:$KOBO_PORT"
    echo "  Check that WiFi is on and SSH is enabled."
    echo "  Set KOBO_IP, KOBO_PORT, KOBO_PASS environment variables if needed."
    exit 1
fi

log "Creating benchmark directory on Kobo..."
ssh_cmd "mkdir -p $BENCHMARK_DIR/wav $BENCHMARK_DIR/results"

log "Deploying benchmark files..."
scp_to "$SCRIPT_DIR/benchmark.lua" "$BENCHMARK_DIR/benchmark.lua"
scp_to "$SCRIPT_DIR/testdoc.lua" "$BENCHMARK_DIR/testdoc.lua"

log "Checking Piper availability on Kobo..."
PIPER_CHECK=$(ssh_cmd "ls -la $PLUGIN_DIR/piper/piper 2>/dev/null && echo FOUND || echo MISSING")
if echo "$PIPER_CHECK" | grep -q "MISSING"; then
    log "WARNING: Piper binary not found at $PLUGIN_DIR/piper/piper"
    log "  Make sure the piper bundle is deployed to the Kobo."
fi

MODEL_CHECK=$(ssh_cmd "ls $PLUGIN_DIR/piper/*.onnx 2>/dev/null | head -3 || echo NONE")
log "Models found: $MODEL_CHECK"

if $DEPLOY_ONLY; then
    log "Deploy complete (--deploy-only). Run on Kobo with:"
    log "  cd $BENCHMARK_DIR && lua benchmark.lua"
    exit 0
fi

# ── Run benchmark ─────────────────────────────────────────────────────

log "Starting benchmark on Kobo..."
log "This will take a LONG time on ARM hardware (30min - 2hrs depending on strategies)."
log ""

BENCH_ARGS="$STRATEGY $QUICK $PAGES $EXTRA_ARGS"
BENCH_ARGS=$(echo "$BENCH_ARGS" | sed 's/^ *//')

# Run via SSH with output streaming
log "Running: lua $BENCHMARK_DIR/benchmark.lua $BENCH_ARGS"
echo "═══════════════════════════════════════════════════════════"

# Use a longer timeout for the benchmark (it may run for hours)
nix-shell -p sshpass openssh --run \
    "sshpass -p '$KOBO_PASS' ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=360 -p $KOBO_PORT ${KOBO_USER}@${KOBO_IP} 'cd $BENCHMARK_DIR && lua benchmark.lua $BENCH_ARGS'" 2>&1

echo "═══════════════════════════════════════════════════════════"
log "Benchmark complete."

# Fetch results
log "Fetching results..."
mkdir -p "$SCRIPT_DIR/results"
scp_from "$BENCHMARK_DIR/results/*" "$SCRIPT_DIR/results/" || true
log "Results saved to $SCRIPT_DIR/results/"

if [[ -f "$SCRIPT_DIR/results/COMPARISON.txt" ]]; then
    echo ""
    cat "$SCRIPT_DIR/results/COMPARISON.txt"
fi
