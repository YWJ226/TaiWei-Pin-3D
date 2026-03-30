#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  cat >&2 <<'EOF'
Usage: test/commercial/CDS_3D_NEW_FLOW.sh <enablement> <flow_variant> <use_flow> <design_nickname>

Arguments:
  enablement      Platform / enablement directory under designs/, such as asap7_3D or nangate45_3D
  flow_variant    Flow variant name used for logs/results/objects/reports
  use_flow        Flow selector. This launcher currently supports cadence only
  design_nickname Design nickname under designs/<enablement>/

Optional environment variables:
  SKIP_2D_PART=1      Skip clean_all and cds-3d-flow-2dpart
  OUTER_ITERATIONS=N  Number of staged preCTS outer-loop iterations (default: 2)
  NUM_CORES=N         Exported before sourcing the flow environment
EOF
  exit 1
fi

ENABLEMENT="$1"
FLOW_VARIANT="$2"
USE_FLOW="$3"
DESIGN_NICKNAME="$4"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_ROOT="${SCRIPT_DIR}"
while [[ "${FLOW_ROOT}" != "/" && ! -f "${FLOW_ROOT}/env.sh" ]]; do
  FLOW_ROOT="$(dirname "${FLOW_ROOT}")"
done

if [[ ! -f "${FLOW_ROOT}/env.sh" ]]; then
  echo "ERROR: env.sh not found for ${SCRIPT_DIR}" >&2
  exit 1
fi

if [[ "${USE_FLOW}" != "cadence" ]]; then
  echo "ERROR: ${BASH_SOURCE[0]} currently supports use_flow=cadence only." >&2
  exit 1
fi

DESIGN_CONFIG_3D="designs/${ENABLEMENT}/${DESIGN_NICKNAME}/config.mk"
DESIGN_CONFIG_2D="designs/${ENABLEMENT}/${DESIGN_NICKNAME}/config2d.mk"

if [[ ! -f "${FLOW_ROOT}/${DESIGN_CONFIG_3D}" ]]; then
  echo "ERROR: missing design config ${DESIGN_CONFIG_3D}" >&2
  exit 1
fi

if [[ ! -f "${FLOW_ROOT}/${DESIGN_CONFIG_2D}" ]]; then
  echo "ERROR: missing design config ${DESIGN_CONFIG_2D}" >&2
  exit 1
fi

export NUM_CORES="${NUM_CORES:-16}"
source "${FLOW_ROOT}/env.sh"

export DESIGN_DIMENSION="3D"
export DESIGN_NICKNAME
export FLOW_VARIANT
export USE_FLOW
export LOG_DIR="./logs/${ENABLEMENT}/${DESIGN_NICKNAME}/${FLOW_VARIANT}"
export OBJECTS_DIR="./objects/${ENABLEMENT}/${DESIGN_NICKNAME}/${FLOW_VARIANT}"
export REPORTS_DIR="./reports/${ENABLEMENT}/${DESIGN_NICKNAME}/${FLOW_VARIANT}"
export RESULTS_DIR="./results/${ENABLEMENT}/${DESIGN_NICKNAME}/${FLOW_VARIANT}"

OUTER_ITERATIONS="${OUTER_ITERATIONS:-1}"

run_make() {
  local target="$1"
  local design_config="${2:-${DESIGN_CONFIG_3D}}"
  echo "[run] make ${target}"
  make DESIGN_CONFIG="${design_config}" "${target}"
}

run_make_with_allow_net() {
  local allow_net="$1"
  local target="$2"
  echo "[run] make ${target} (allow_net=${allow_net})"
  TIER_ALLOW_NET="${allow_net}" make DESIGN_CONFIG="${DESIGN_CONFIG_3D}" "${target}"
}

echo "[run] enablement=${ENABLEMENT} design=${DESIGN_NICKNAME} use_flow=${USE_FLOW} flow_variant=${FLOW_VARIANT}"
echo "[run] design_config_3d=${DESIGN_CONFIG_3D}"
echo "[run] design_config_2d=${DESIGN_CONFIG_2D}"
echo "[run] outer_iterations=${OUTER_ITERATIONS}"

if [[ "${SKIP_2D_PART:-0}" != "1" ]]; then
  run_make clean_all "${DESIGN_CONFIG_3D}"
  run_make cds-3d-flow-2dpart "${DESIGN_CONFIG_2D}"
else
  echo "[run] SKIP_2D_PART=1, skip clean_all and cds-3d-flow-2dpart"
fi

run_make cds-pre
run_make cds-3d-floorplan
run_make cds-3d-io
run_make cds-3d-split-net
run_make cds-place-macro-upper
run_make cds-place-macro-bottom
run_make cds-3d-pdn-only
run_make cds-place-init
run_make cds-place-init-upper
run_make cds-place-init-bottom

for ((i = 1; i <= OUTER_ITERATIONS; i++)); do
  echo "[run] staged preCTS iteration ${i}/${OUTER_ITERATIONS}"
  run_make_with_allow_net "upper-only" cds-place-upper
  run_make_with_allow_net "bottom-only" cds-place-bottom
done

run_make cds-gp2lg
run_make cds-legalize-upper
run_make cds-legalize-bottom
run_make cds-cts
run_make cds-route
run_make cds-restore

echo "[run] flow completed for ${ENABLEMENT}/${DESIGN_NICKNAME} (${FLOW_VARIANT})"
