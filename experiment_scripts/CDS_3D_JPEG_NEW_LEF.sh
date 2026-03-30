#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT="${SCRIPT_DIR}/CDS_3D_NEW_FLOW.sh"
FLOW_VARIANT="NEW_LEF"
USE_FLOW="cadence"
RUN_LOG_DIR="./run_logs/new"
# export CREATE_OBS_STAGE="FLOORPLAN"
if [[ ! -x "${RUN_SCRIPT}" ]]; then
  echo "ERROR: missing executable ${RUN_SCRIPT}" >&2
  exit 1
fi

mkdir -p "${RUN_LOG_DIR}"

PLATFORMS=(
  "nangate45_3D"
  "asap7_3D"
  "asap7_nangate45_3D"
)

DESIGNS=(
  "jpeg"
  "swerv_wrapper"
)

launch_case() {
  local platform="$1"
  local design="$2"
  local case_name="cds_3d_${platform}_${design}_${FLOW_VARIANT}"
  local unified_log="${RUN_LOG_DIR}/${case_name}.log"

  (
    set -o pipefail
    {
      echo "[run] case=${case_name} start=$(date '+%F %T')"
      bash "${RUN_SCRIPT}" "${platform}" "${FLOW_VARIANT}" "${USE_FLOW}" "${design}"
      status=$?
      echo "[run] case=${case_name} status=${status} end=$(date '+%F %T')"
      exit "${status}"
    } 2>&1 | tee "${unified_log}" | sed -u "s/^/[${platform}:${design}] /"
  ) &

  CASE_PID["${case_name}"]="$!"
}

declare -A CASE_PID=()

for platform in "${PLATFORMS[@]}"; do
  for design in "${DESIGNS[@]}"; do
    launch_case "${platform}" "${design}"
  done
done

status=0
for platform in "${PLATFORMS[@]}"; do
  for design in "${DESIGNS[@]}"; do
    case_name="cds_3d_${platform}_${design}_${FLOW_VARIANT}"
    if ! wait "${CASE_PID[${case_name}]}"; then
      echo "[run] ${case_name} failed" >&2
      status=1
    fi
  done
done

exit "${status}"
