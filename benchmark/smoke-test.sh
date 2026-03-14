#!/bin/bash
#
# Quick smoke test: synthesize a single sentence to verify Piper works.
# Useful for debugging connectivity and Piper setup before running
# the full benchmark.
#
# Usage:
#   ./smoke-test.sh
#   ./smoke-test.sh "Custom text to synthesize"
#

set -euo pipefail

KOBO_IP="${KOBO_IP:-192.168.1.28}"
KOBO_PORT="${KOBO_PORT:-2222}"
KOBO_PASS="${KOBO_PASS:-}"
KOBO_USER="root"
PLUGIN_DIR="/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin"

TEXT="${1:-Hello, this is a test of the neural text to speech system running on the Kobo e-reader.}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

ssh_cmd() {
    nix-shell -p sshpass openssh --run \
        "sshpass -p '$KOBO_PASS' ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p $KOBO_PORT ${KOBO_USER}@${KOBO_IP} \"$*\"" 2>&1
}

log "Testing Kobo connectivity..."
if ! ssh_cmd "echo ok" | grep -q "ok"; then
    echo "ERROR: Cannot connect to Kobo"
    exit 1
fi
log "Connected ✓"

log "Checking Piper binary..."
ssh_cmd "ls -la $PLUGIN_DIR/piper/piper" || { echo "Piper not found!"; exit 1; }
log "Piper found ✓"

log "Listing models..."
ssh_cmd "ls -la $PLUGIN_DIR/piper/*.onnx 2>/dev/null || echo 'No models found'"

log "Running smoke test synthesis..."
SMOKE_CMD="cd $PLUGIN_DIR && echo '$TEXT' | timeout 120 nice -n 19"

# Build the actual piper command
PIPER_CMD=$(cat <<'EOCMD'
PIPER_DIR="/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin/piper"
ESPEAK_DIR="/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin/espeak-ng"
MODEL=$(ls "$PIPER_DIR"/*-low.onnx 2>/dev/null | head -1)
if [ -z "$MODEL" ]; then
    MODEL=$(ls "$PIPER_DIR"/*.onnx 2>/dev/null | head -1)
fi
echo "Using model: $MODEL"
ESPEAK_DATA=""
if [ -d "$PIPER_DIR/espeak-ng-data" ]; then
    ESPEAK_DATA="--espeak_data $PIPER_DIR/espeak-ng-data"
fi
LD_PREFIX=""
if [ -f "$ESPEAK_DIR/lib/ld-linux-armhf.so.3" ]; then
    LD_PREFIX="$ESPEAK_DIR/lib/ld-linux-armhf.so.3 --library-path $PIPER_DIR/lib:$ESPEAK_DIR/lib"
fi
echo "Test sentence" > /tmp/smoke_test_in.txt
T0=$(date +%s%3N)
nice -n 19 $LD_PREFIX $PIPER_DIR/piper --model "$MODEL" $ESPEAK_DATA --output_file /tmp/smoke_test.wav < /tmp/smoke_test_in.txt 2>&1
T1=$(date +%s%3N)
ELAPSED=$((T1 - T0))
echo "Synthesis time: ${ELAPSED}ms"
ls -la /tmp/smoke_test.wav 2>/dev/null || echo "OUTPUT FILE MISSING!"
rm -f /tmp/smoke_test_in.txt /tmp/smoke_test.wav
EOCMD
)

ssh_cmd "$PIPER_CMD"

log "Smoke test complete ✓"
