#!/bin/bash
#
# Quick single-strategy benchmark runner.
# Deploys and runs just one strategy for fast iteration.
#
# Usage:
#   ./run-single.sh baseline
#   ./run-single.sh server_2x2 --pages 1,4
#   ./run-single.sh batch_5 --quick
#

set -euo pipefail

STRATEGY="${1:-baseline}"
shift || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Running single strategy: $STRATEGY"
exec "$SCRIPT_DIR/deploy-and-run.sh" --strategy "$STRATEGY" "$@"
