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

export NUM_CORES="${NUM_CORES:-16}"
source "${FLOW_ROOT}/env.sh"

export DESIGN_DIMENSION="3D"
export DESIGN_NICKNAME="gcd"
export USE_FLOW="openroad"
export FLOW_VARIANT="${FLOW_VARIANT:-example}"

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

echo "[run] direct OpenROAD flow for ${ENABLEMENT}/${DESIGN_NICKNAME}"
echo "[run] flow_variant=${FLOW_VARIANT}"
echo "[run] outer_iterations=${OUTER_ITERATIONS}"
echo "[run] PIN3D_ALLOW_NET_FLOW=${PIN3D_ALLOW_NET_FLOW:-on}"
echo "[run] PIN3D_SPLIT_NET_FLOW=${PIN3D_SPLIT_NET_FLOW:-on}"

if [[ "${SKIP_2D_PART:-0}" != "1" ]]; then
  # input: RTL + SDC in designs/asap7_3D/gcd/
  # output: 2_2_floorplan_io.def/.v, partition.txt
  run_make clean_all "${DESIGN_CONFIG_3D}"
  run_make ord-3d-flow-2dpart "${DESIGN_CONFIG_2D}"
else
  echo "[run] SKIP_2D_PART=1, skip clean_all and ord-3d-flow-2dpart"
fi

# input: 2_2_floorplan_io.def/.v + partition.txt + map.json
# output: ${DESIGN_NAME}_3D.fp.def/.v
run_make ord-pre

# input: ${DESIGN_NAME}_3D.fp.v + 1_synth.sdc
# output: 2_3_floorplan_3d.def/.v + 1_synth.sdc
run_make ord-3d-floorplan

# input: 2_3_floorplan_3d.def/.v + 1_synth.sdc
# output: 2_4_floorplan_io.def/.v + 1_synth.sdc
run_make ord-3d-io

# input: 2_4_floorplan_io.def/.v + 1_synth.sdc
# output: updated 2_4_floorplan_io.def/.v in place
# note: PIN3D_SPLIT_NET_FLOW=off keeps this stage as pass-through
run_make ord-3d-split-net

# input: 2_4_floorplan_io.def/.v + 1_synth.sdc
# output: 2_5_place_macro_upper.def/.v
run_make ord-place-macro-upper

# input: 2_5_place_macro_upper.def/.v
# output: 2_5_place_macro_bottom.def/.v
run_make ord-place-macro-bottom

# input: macro-placed floorplan + 1_synth.sdc
# output: 2_floorplan.def/.v/.sdc
run_make ord-3d-pdn-only

# input: 2_floorplan.def/.v/.sdc
# output: ${DESIGN_NAME}_3D.tmp.def/.v
run_make ord-place-init

# input: ${DESIGN_NAME}_3D.tmp.def/.v + 2_floorplan.sdc
# output: updated ${DESIGN_NAME}_3D.tmp.def/.v
run_make ord-place-init-upper

# input: ${DESIGN_NAME}_3D.tmp.def/.v + 2_floorplan.sdc
# output: updated ${DESIGN_NAME}_3D.tmp.def/.v
run_make ord-place-init-bottom

for ((i = 1; i <= OUTER_ITERATIONS; i++)); do
  echo "[run] staged preCTS iteration ${i}/${OUTER_ITERATIONS}"
  # input: ${DESIGN_NAME}_3D.tmp.def/.v + 2_floorplan.sdc
  # output: updated ${DESIGN_NAME}_3D.tmp.def/.v, upper_only + mixed refined
  run_make_with_allow_net "upper-only" ord-place-upper

  # input: ${DESIGN_NAME}_3D.tmp.def/.v + 2_floorplan.sdc
  # output: updated ${DESIGN_NAME}_3D.tmp.def/.v, bottom_only + mixed refined
  run_make_with_allow_net "bottom-only" ord-place-bottom
done

# input: ${DESIGN_NAME}_3D.tmp.def/.v
# output: ${DESIGN_NAME}_3D.lg.def/.v
run_make ord-gp2lg

# input: ${DESIGN_NAME}_3D.lg.def/.v
# output: updated ${DESIGN_NAME}_3D.lg.def/.v and 3_place.def/.v/.sdc
run_make ord-legalize-upper

# input: ${DESIGN_NAME}_3D.lg.def/.v
# output: updated ${DESIGN_NAME}_3D.lg.def/.v and 3_place.def/.v/.sdc
run_make ord-legalize-bottom

# input: 3_place.def/.v/.sdc
# output: 4_0_cts.def/.v/.sdc
# note: owner-tree CTS stage, receive tier is fixed
run_make ord-cts

# input: 4_0_cts.def/.v/.sdc
# output: 4_cts.def/.v/.sdc
# note: receive-opt CTS stage, owner tier is fixed
run_make ord-cts-post

# input: 4_cts.def/.v/.sdc
# output: 5_route.def/.v/.sdc
run_make ord-route

# input: 5_route.def/.v/.sdc
# output: 6_final.odb/.def/.v/.sdc + final_summary.txt
run_make ord-final

echo "[run] completed ${ENABLEMENT}/${DESIGN_NICKNAME} (${FLOW_VARIANT})"

cat <<'EOF'

Examples:
  PIN3D_ALLOW_NET_FLOW=on PIN3D_SPLIT_NET_FLOW=on \
    bash test/openroad/ORD_3D_NEW_FLOW.sh asap7_3D openroad_cmp_allownet openroad gcd

  PIN3D_ALLOW_NET_FLOW=off PIN3D_SPLIT_NET_FLOW=off \
    bash test/openroad/ORD_3D_NEW_FLOW.sh asap7_3D openroad_cmp_noallownet openroad gcd

  bash test/openroad/ORD_3D_ALLOW_NET_MATRIX.sh
EOF
