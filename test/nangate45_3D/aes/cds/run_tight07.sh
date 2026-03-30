#!/usr/bin/env bash
set -euo pipefail

# Thin wrapper for the tight-clock robustness flow on nangate45_3D/aes.
# This script reuses the local lab harness instead of duplicating flow logic.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

PREPARE_SCRIPT="$REPO_ROOT/work.codex/cts_route_lab/bash/prepare_case_variant.sh"
RUN_SCRIPT="$REPO_ROOT/work.codex/cts_route_lab/bash/run_case_strategy.sh"

PLATFORM="nangate45_3D"
DESIGN_NICKNAME="aes"
DESIGN_NAME="aes_cipher_top"
SEED_VARIANT="openroad"
MODE="${1:-staged}"

run_one() {
  local strategy="$1"
  echo "[aes-tight07] prepare $strategy"
  bash "$PREPARE_SCRIPT" \
    "$PLATFORM" \
    "$DESIGN_NICKNAME" \
    "$DESIGN_NAME" \
    "$SEED_VARIANT" \
    "$strategy"

  echo "[aes-tight07] run $strategy"
  bash "$RUN_SCRIPT" "$PLATFORM" "$DESIGN_NICKNAME" "$strategy"
}

case "$MODE" in
  baseline|staged)
    run_one "$MODE"
    ;;
  all)
    run_one baseline
    run_one staged
    ;;
  *)
    echo "Usage: $0 [baseline|staged|all]" >&2
    exit 1
    ;;
esac
