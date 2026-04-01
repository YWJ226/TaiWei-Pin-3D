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
  SKIP_2D_PART=1          Skip clean_all and cds-3d-flow-2dpart
  REUSE_2DPART_FROM_VARIANT=<variant>
                          Copy 1_synth.sdc, 2_2_floorplan_io.def/.v, and
                          partition artifacts from an existing result variant,
                          then continue from cds-pre
  START_FROM=<stage>      Resume from a later stage without rerunning earlier
                          bootstrap stages. Common value: cds-cts
  OUTER_ITERATIONS=N      Number of staged preCTS outer-loop iterations (default: 2)
  NUM_CORES=N             Exported before sourcing the flow environment
  PIN3D_ALLOW_NET_FLOW    on/off, default on
  PIN3D_SPLIT_NET_FLOW    on/off, default on
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

cd "${FLOW_ROOT}"

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
START_FROM="${START_FROM:-}"

stage_order_index() {
  case "$1" in
    cds-pre) echo 10 ;;
    cds-3d-floorplan) echo 20 ;;
    cds-3d-io) echo 30 ;;
    cds-3d-split-net) echo 40 ;;
    cds-place-macro-upper) echo 50 ;;
    cds-place-macro-bottom) echo 60 ;;
    cds-3d-pdn-only) echo 70 ;;
    cds-place-init) echo 80 ;;
    cds-place-init-upper) echo 90 ;;
    cds-place-init-bottom) echo 100 ;;
    staged-prects) echo 110 ;;
    cds-gp2lg) echo 120 ;;
    cds-legalize-upper) echo 130 ;;
    cds-legalize-bottom) echo 140 ;;
    cds-cts) echo 150 ;;
    cds-route) echo 160 ;;
    cds-restore) echo 170 ;;
    *)
      echo "ERROR: unsupported START_FROM stage '$1'" >&2
      exit 1
      ;;
  esac
}

if [[ -n "${START_FROM}" ]]; then
  START_FROM_INDEX="$(stage_order_index "${START_FROM}")"
else
  START_FROM_INDEX=0
fi

should_run_stage() {
  local stage="$1"
  local stage_index
  stage_index="$(stage_order_index "${stage}")"
  [[ "${stage_index}" -ge "${START_FROM_INDEX}" ]]
}

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

seed_reused_2dpart_artifacts() {
  local source_variant="$1"
  local source_results="./results/${ENABLEMENT}/${DESIGN_NICKNAME}/${source_variant}"
  local required_files=(
    "1_synth.sdc"
    "2_2_floorplan_io.def"
    "2_2_floorplan_io.v"
    "partition.txt"
  )
  local optional_files=(
    "1_synth.v"
    "partition.result.tcl"
    "partition.simple_plan.txt"
  )

  if [[ ! -d "${source_results}" ]]; then
    echo "ERROR: missing reuse source directory ${source_results}" >&2
    exit 1
  fi

  for file_name in "${required_files[@]}"; do
    if [[ ! -f "${source_results}/${file_name}" ]]; then
      echo "ERROR: missing required reuse artifact ${source_results}/${file_name}" >&2
      exit 1
    fi
  done

  mkdir -p "${RESULTS_DIR}" "${LOG_DIR}" "${OBJECTS_DIR}" "${REPORTS_DIR}"

  echo "[run] reuse 2D-part artifacts from ${source_results}"
  for file_name in "${required_files[@]}" "${optional_files[@]}"; do
    if [[ -f "${source_results}/${file_name}" ]]; then
      cp -f "${source_results}/${file_name}" "${RESULTS_DIR}/${file_name}"
      echo "[run] copied ${file_name}"
    fi
  done
}

echo "[run] enablement=${ENABLEMENT} design=${DESIGN_NICKNAME} use_flow=${USE_FLOW} flow_variant=${FLOW_VARIANT}"
echo "[run] design_config_3d=${DESIGN_CONFIG_3D}"
echo "[run] design_config_2d=${DESIGN_CONFIG_2D}"
echo "[run] outer_iterations=${OUTER_ITERATIONS}"
echo "[run] PIN3D_ALLOW_NET_FLOW=${PIN3D_ALLOW_NET_FLOW:-on}"
echo "[run] PIN3D_SPLIT_NET_FLOW=${PIN3D_SPLIT_NET_FLOW:-on}"
echo "[run] REUSE_2DPART_FROM_VARIANT=${REUSE_2DPART_FROM_VARIANT:-}"
echo "[run] START_FROM=${START_FROM:-}"

if [[ -n "${START_FROM}" ]]; then
  echo "[run] resume mode enabled, skip clean_all/reuse/cds-3d-flow-2dpart bootstrap"
elif [[ -n "${REUSE_2DPART_FROM_VARIANT:-}" ]]; then
  rm -rf "${LOG_DIR}" "${OBJECTS_DIR}" "${REPORTS_DIR}" "${RESULTS_DIR}"
  seed_reused_2dpart_artifacts "${REUSE_2DPART_FROM_VARIANT}"
  echo "[run] reuse mode enabled, skip clean_all and cds-3d-flow-2dpart"
elif [[ "${SKIP_2D_PART:-0}" != "1" ]]; then
  run_make clean_all "${DESIGN_CONFIG_3D}"
  run_make cds-3d-flow-2dpart "${DESIGN_CONFIG_2D}"
else
  echo "[run] SKIP_2D_PART=1, skip clean_all and cds-3d-flow-2dpart"
fi

if should_run_stage cds-pre; then
  run_make cds-pre
fi
if should_run_stage cds-3d-floorplan; then
  run_make cds-3d-floorplan
fi
if should_run_stage cds-3d-io; then
  run_make cds-3d-io
fi
if should_run_stage cds-3d-split-net; then
  run_make cds-3d-split-net
fi
if should_run_stage cds-place-macro-upper; then
  run_make cds-place-macro-upper
fi
if should_run_stage cds-place-macro-bottom; then
  run_make cds-place-macro-bottom
fi
if should_run_stage cds-3d-pdn-only; then
  run_make cds-3d-pdn-only
fi
if should_run_stage cds-place-init; then
  run_make cds-place-init
fi
if should_run_stage cds-place-init-upper; then
  run_make cds-place-init-upper
fi
if should_run_stage cds-place-init-bottom; then
  run_make cds-place-init-bottom
fi
if should_run_stage staged-prects; then
  for ((i = 1; i <= OUTER_ITERATIONS; i++)); do
    echo "[run] staged preCTS iteration ${i}/${OUTER_ITERATIONS}"
    run_make_with_allow_net "upper-only" cds-place-upper
    run_make_with_allow_net "bottom-only" cds-place-bottom
  done
fi
if should_run_stage cds-gp2lg; then
  run_make cds-gp2lg
fi
if should_run_stage cds-legalize-upper; then
  run_make cds-legalize-upper
fi
if should_run_stage cds-legalize-bottom; then
  run_make cds-legalize-bottom
fi
if should_run_stage cds-cts; then
  run_make cds-cts
fi
if should_run_stage cds-route; then
  run_make cds-route
fi
if should_run_stage cds-restore; then
  run_make cds-restore
fi

echo "[run] flow completed for ${ENABLEMENT}/${DESIGN_NICKNAME} (${FLOW_VARIANT})"
