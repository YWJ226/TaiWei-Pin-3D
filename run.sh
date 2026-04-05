#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_ROOT="${SCRIPT_DIR}"
while [[ "${FLOW_ROOT}" != "/" && ! -f "${FLOW_ROOT}/env.sh" ]]; do
  FLOW_ROOT="$(dirname "${FLOW_ROOT}")"
done

if [[ ! -f "${FLOW_ROOT}/env.sh" ]]; then
  echo "ERROR: env.sh not found for ${SCRIPT_DIR}" >&2
  exit 1
fi

export NUM_CORES="${NUM_CORES:-8}"
source "${FLOW_ROOT}/env.sh"

export DESIGN_DIMENSION="3D"
export DESIGN_NICKNAME="swerv_wrapper"
export USE_FLOW="cadence"
export FLOW_VARIANT="${FLOW_VARIANT:-cadence}"

ENABLEMENT="nangate45_3D"
DESIGN_CONFIG_3D="designs/${ENABLEMENT}/${DESIGN_NICKNAME}/config.mk"
DESIGN_CONFIG_2D="designs/${ENABLEMENT}/${DESIGN_NICKNAME}/config2d.mk"

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

echo "[run] direct commercial flow for ${ENABLEMENT}/${DESIGN_NICKNAME}"
echo "[run] flow_variant=${FLOW_VARIANT}"
echo "[run] outer_iterations=${OUTER_ITERATIONS}"
echo "[run] PIN3D_ALLOW_NET_FLOW=${PIN3D_ALLOW_NET_FLOW:-on}"
echo "[run] PIN3D_SPLIT_NET_FLOW=${PIN3D_SPLIT_NET_FLOW:-on}"

if [[ "${SKIP_2D_PART:-0}" != "1" ]]; then
  # input: RTL + SDC in designs/asap7_nangate45_3D/gcd/
  # output: 2_2_floorplan_io.def/.v, partition.txt
  run_make clean_all "${DESIGN_CONFIG_3D}"
  run_make cds-3d-flow-2dpart "${DESIGN_CONFIG_2D}"
else
  echo "[run] SKIP_2D_PART=1, skip clean_all and cds-3d-flow-2dpart"
fi

# input: 2_2_floorplan_io.def/.v + partition.txt + map.json
# output: ${DESIGN_NAME}_3D.fp.def/.v
run_make cds-pre

# input: ${DESIGN_NAME}_3D.fp.def/.v + 1_synth.sdc
# output: 2_3_floorplan_3d.def/.v/.sdc
run_make cds-3d-floorplan

# input: 2_3_floorplan_3d.def/.v/.sdc
# output: 2_4_floorplan_io.def/.v/.sdc
run_make cds-3d-io

# input: 2_4_floorplan_io.def/.v/.sdc
# output: updated 2_4_floorplan_io.def/.v/.sdc in place
# note: PIN3D_SPLIT_NET_FLOW=off keeps this stage as pass-through
run_make cds-3d-split-net

# input: 2_4_floorplan_io.def/.v/.sdc
# output: 2_5_place_macro_upper.def/.v
run_make cds-place-macro-upper

# input: 2_5_place_macro_upper.def/.v
# output: 2_5_place_macro_bottom.def/.v
run_make cds-place-macro-bottom

# input: macro-placed floorplan + 1_synth.sdc
# output: 2_floorplan.def/.v/.sdc
run_make cds-3d-pdn-only

# input: 2_floorplan.def/.v/.sdc
# output: ${DESIGN_NAME}_3D.tmp.def/.v
run_make cds-place-init

# input: ${DESIGN_NAME}_3D.tmp.def/.v + 2_floorplan.sdc
# output: updated ${DESIGN_NAME}_3D.tmp.def/.v
run_make cds-place-init-upper

# input: ${DESIGN_NAME}_3D.tmp.def/.v + 2_floorplan.sdc
# output: updated ${DESIGN_NAME}_3D.tmp.def/.v
run_make cds-place-init-bottom

for ((i = 1; i <= OUTER_ITERATIONS; i++)); do
  echo "[run] staged preCTS iteration ${i}/${OUTER_ITERATIONS}"
  # input: ${DESIGN_NAME}_3D.tmp.def/.v + 2_floorplan.sdc
  # output: updated ${DESIGN_NAME}_3D.tmp.def/.v, upper_only + mixed refined
  run_make_with_allow_net "upper-only" cds-place-upper

  # input: ${DESIGN_NAME}_3D.tmp.def/.v + 2_floorplan.sdc
  # output: updated ${DESIGN_NAME}_3D.tmp.def/.v, bottom_only + mixed refined
  run_make_with_allow_net "bottom-only" cds-place-bottom
done

# input: ${DESIGN_NAME}_3D.tmp.def/.v
# output: ${DESIGN_NAME}_3D.lg.def/.v
run_make cds-gp2lg

# input: ${DESIGN_NAME}_3D.lg.def/.v
# output: updated ${DESIGN_NAME}_3D.lg.def/.v and 3_place.def/.v/.sdc
run_make cds-legalize-upper

# input: ${DESIGN_NAME}_3D.lg.def/.v
# output: updated ${DESIGN_NAME}_3D.lg.def/.v and 3_place.def/.v/.sdc
run_make cds-legalize-bottom

# input: 3_place.def/.v/.sdc
# output: 4_cts.def/.v/.sdc
run_make cds-cts

# input: 4_cts.def/.v/.sdc
# output: 5_route.def/.v/.sdc
run_make cds-route-new

# input: routed database
# output: final_summary.txt, final_metrics.csv, restored final views
run_make cds-restore

echo "[run] completed ${ENABLEMENT}/${DESIGN_NICKNAME} (${FLOW_VARIANT})"

cat <<'EOF'

Examples:
  PIN3D_ALLOW_NET_FLOW=on PIN3D_SPLIT_NET_FLOW=on \
    bash test/commercial/CDS_3D_NEW_FLOW.sh asap7_3D cadence_cmp_allownet cadence ibex

  PIN3D_ALLOW_NET_FLOW=off PIN3D_SPLIT_NET_FLOW=off \
    bash test/commercial/CDS_3D_NEW_FLOW.sh asap7_3D cadence_cmp_noallownet cadence ibex

  bash test/commercial/CDS_3D_ALLOW_NET_MATRIX.sh
EOF
