#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_ROOT="${SCRIPT_DIR}"
while [[ "${FLOW_ROOT}" != "/" && ! -f "${FLOW_ROOT}/env.sh" ]]; do
  FLOW_ROOT="$(dirname "${FLOW_ROOT}")"
done
if [[ ! -f "${FLOW_ROOT}/env.sh" ]]; then
  echo "ERROR: env.sh not found for ${SCRIPT_DIR}" >&2
  exit 1
fi
source "${FLOW_ROOT}/env.sh"

export DESIGN_DIMENSION="3D"
export DESIGN_NICKNAME="ibex"
export USE_FLOW="cadence"
export FLOW_VARIANT="cadence"
# export OPEN_GUI=1
export LOG_DIR=./logs/nangate45_3D/${DESIGN_NICKNAME}/${FLOW_VARIANT}
export OBJECTS_DIR=./objects/nangate45_3D/${DESIGN_NICKNAME}/${FLOW_VARIANT}
export REPORTS_DIR=./reports/nangate45_3D/${DESIGN_NICKNAME}/${FLOW_VARIANT}
export RESULTS_DIR=./results/nangate45_3D/${DESIGN_NICKNAME}/${FLOW_VARIANT}
if [[ "${SKIP_2D_PART:-0}" != "1" ]]; then
  make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config.mk clean_all
  make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config2d.mk cds-3d-flow-2dpart
else
  echo "[INFO] SKIP_2D_PART=1, skip clean_all and cds-3d-flow-2dpart"
fi
make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config.mk cds-pre
make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config.mk cds-3d-floorplan
make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config.mk cds-3d-io
make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config.mk cds-place-macro-upper
make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config.mk cds-place-macro-bottom
make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config.mk cds-3d-pdn-only
make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config.mk cds-place-init
make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config.mk cds-place-init-bottom
make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config.mk cds-place-init-upper
iteration=1
for ((i=1;i<=iteration;i++)); do
  echo "Iteration: $i"
  make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config.mk  cds-place-bottom  
make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config.mk cds-place-upper
done
make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config.mk cds-gp2lg
make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config.mk cds-legalize-bottom
make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config.mk cds-legalize-upper
make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config.mk cds-cts
make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config.mk cds-route
make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config.mk cds-restore
