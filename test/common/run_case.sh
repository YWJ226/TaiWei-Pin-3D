#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <ord|cds> <case_dir>" >&2
  exit 1
fi

FLOW_KIND="$1"
CASE_DIR="$(cd "$2" && pwd)"

DESIGN_DIR="$(dirname "${CASE_DIR}")"
PLATFORM_DIR="$(dirname "${DESIGN_DIR}")"
TEST_DIR="$(dirname "${PLATFORM_DIR}")"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

DESIGN_NICKNAME="$(basename "${DESIGN_DIR}")"
ENABLEMENT="$(basename "${PLATFORM_DIR}")"

FLOW_ROOT="${REPO_ROOT}"
if [[ ! -f "${FLOW_ROOT}/env.sh" ]]; then
  echo "ERROR: env.sh not found under ${FLOW_ROOT}" >&2
  exit 1
fi

case "${FLOW_KIND}" in
  ord)
    LAUNCHER="${FLOW_ROOT}/test/openroad/ORD_3D_NEW_FLOW.sh"
    FLOW_VARIANT="${FLOW_VARIANT:-openroad}"
    USE_FLOW="${USE_FLOW:-openroad}"
    case "${USE_FLOW}" in
      openroad|OpenROAD) USE_FLOW="openroad" ;;
      *)
        echo "ERROR: USE_FLOW='${USE_FLOW}' is invalid for ord wrapper." >&2
        exit 1
        ;;
    esac
    ;;
  cds)
    LAUNCHER="${FLOW_ROOT}/test/commercial/CDS_3D_NEW_FLOW.sh"
    FLOW_VARIANT="${FLOW_VARIANT:-cadence}"
    USE_FLOW="${USE_FLOW:-cadence}"
    case "${USE_FLOW}" in
      cadence|Cadence) USE_FLOW="cadence" ;;
      *)
        echo "ERROR: USE_FLOW='${USE_FLOW}' is invalid for cds wrapper." >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "ERROR: unsupported flow kind '${FLOW_KIND}', expected ord or cds." >&2
    exit 1
    ;;
esac

if [[ ! -f "${LAUNCHER}" ]]; then
  echo "ERROR: launcher not found: ${LAUNCHER}" >&2
  exit 1
fi

exec bash "${LAUNCHER}" "${ENABLEMENT}" "${FLOW_VARIANT}" "${USE_FLOW}" "${DESIGN_NICKNAME}"
