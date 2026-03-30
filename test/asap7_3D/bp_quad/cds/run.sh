#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESIGN_DIR="$(dirname "${SCRIPT_DIR}")"
PLATFORM_DIR="$(dirname "${DESIGN_DIR}")"
DESIGN_NICKNAME="$(basename "${DESIGN_DIR}")"
ENABLEMENT="$(basename "${PLATFORM_DIR}")"
FLOW_VARIANT="${FLOW_VARIANT:-cadence}"
USE_FLOW="cadence"

FLOW_ROOT="${SCRIPT_DIR}"
while [[ "${FLOW_ROOT}" != "/" && ! -f "${FLOW_ROOT}/env.sh" ]]; do
  FLOW_ROOT="$(dirname "${FLOW_ROOT}")"
done

if [[ ! -f "${FLOW_ROOT}/env.sh" ]]; then
  echo "ERROR: env.sh not found for ${SCRIPT_DIR}" >&2
  exit 1
fi

CANONICAL_SCRIPT="${FLOW_ROOT}/test/commercial/CDS_3D_NEW_FLOW.sh"
if [[ ! -x "${CANONICAL_SCRIPT}" ]]; then
  echo "ERROR: commercial launcher not found: ${CANONICAL_SCRIPT}" >&2
  exit 1
fi

exec bash "${CANONICAL_SCRIPT}" "${ENABLEMENT}" "${FLOW_VARIANT}" "${USE_FLOW}" "${DESIGN_NICKNAME}"
