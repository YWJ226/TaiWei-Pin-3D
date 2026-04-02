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

MATRIX_CASES="${MATRIX_CASES:-asap7_3D:gcd asap7_nangate45_3D:gcd nangate45_3D:gcd}"
MODE_MATRIX="${MODE_MATRIX:-allownet:on:on noallownet:off:off}"
FLOW_VARIANT_BASE="${FLOW_VARIANT_BASE:-openroad_cmp}"
OUTER_ITERATIONS="${OUTER_ITERATIONS:-1}"
REUSE_2DPART_FROM_VARIANT="${REUSE_2DPART_FROM_VARIANT:-openroad}"

declare -a FINAL_SUMMARY_PATHS=()
for case_entry in ${MATRIX_CASES}; do
  enablement="${case_entry%%:*}"
  design="${case_entry##*:}"

  for mode_entry in ${MODE_MATRIX}; do
    IFS=":" read -r mode_label allow_flow split_flow <<< "${mode_entry}"
    flow_variant="${FLOW_VARIANT_BASE}_${enablement}_${design}_${mode_label}"

    echo "[matrix] enablement=${enablement} design=${design} mode=${mode_label} allow=${allow_flow} split=${split_flow}"
    PIN3D_ALLOW_NET_FLOW="${allow_flow}" \
    PIN3D_SPLIT_NET_FLOW="${split_flow}" \
    OUTER_ITERATIONS="${OUTER_ITERATIONS}" \
    REUSE_2DPART_FROM_VARIANT="${REUSE_2DPART_FROM_VARIANT}" \
    SKIP_2D_PART="${SKIP_2D_PART:-0}" \
      bash "${SCRIPT_DIR}/ORD_3D_NEW_FLOW.sh" "${enablement}" "${flow_variant}" openroad "${design}"

    FINAL_SUMMARY_PATHS+=("${FLOW_ROOT}/logs/${enablement}/${design}/${flow_variant}/final_summary.txt")
  done
done

CSV_DIR="${FLOW_ROOT}/reports/compare_allow_net"
mkdir -p "${CSV_DIR}"
CSV_OUTPUT_PATH="${CSV_DIR}/${FLOW_VARIANT_BASE}.csv"
CSV_OUTPUT_PATH="${CSV_OUTPUT_PATH}" \
  bash "${SCRIPT_DIR}/ORD_3D_EXTRACT_VALID_SUMMARIES.sh" "${FINAL_SUMMARY_PATHS[@]}"

echo "[matrix] comparison CSV written to ${CSV_OUTPUT_PATH}"
