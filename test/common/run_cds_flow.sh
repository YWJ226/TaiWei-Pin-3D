#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: test/common/run_cds_flow.sh <case_dir> [options]

Arguments:
  case_dir                     Test case directory, e.g. test/nangate45_3D/swerv_wrapper/cds

Options:
  --variant <name>             Flow variant name (default: cadence)
  --start-from <stage>         Resume from a later stage, e.g. cds-place-init / cds-cts
  --skip-2d-part               Skip clean_all and cds-3d-flow-2dpart
  --reuse-2dpart <variant>     Reuse 2D-part artifacts from another variant
  --outer-iterations <n>       Override staged preCTS outer-loop iterations
  --num-cores <n>              Export NUM_CORES before launching
  --allow-net-flow <on|off>    Export PIN3D_ALLOW_NET_FLOW
  --split-net-flow <on|off>    Export PIN3D_SPLIT_NET_FLOW
  --use-flow <cadence>         Flow selector (default: cadence)

Examples:
  test/common/run_cds_flow.sh test/nangate45_3D/swerv_wrapper/cds
  test/common/run_cds_flow.sh test/nangate45_3D/swerv_wrapper/cds --start-from cds-place-init
  test/common/run_cds_flow.sh test/nangate45_3D/swerv_wrapper/cds --reuse-2dpart cadence --start-from cds-pre
EOF
  exit 1
}

if [[ $# -lt 1 ]]; then
  usage
fi

CASE_DIR="$(cd "$1" && pwd)"
shift

FLOW_VARIANT="${FLOW_VARIANT:-cadence}"
USE_FLOW="${USE_FLOW:-cadence}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant)
      [[ $# -ge 2 ]] || usage
      FLOW_VARIANT="$2"
      shift 2
      ;;
    --start-from)
      [[ $# -ge 2 ]] || usage
      export START_FROM="$2"
      shift 2
      ;;
    --skip-2d-part)
      export SKIP_2D_PART=1
      shift
      ;;
    --reuse-2dpart)
      [[ $# -ge 2 ]] || usage
      export REUSE_2DPART_FROM_VARIANT="$2"
      shift 2
      ;;
    --outer-iterations)
      [[ $# -ge 2 ]] || usage
      export OUTER_ITERATIONS="$2"
      shift 2
      ;;
    --num-cores)
      [[ $# -ge 2 ]] || usage
      export NUM_CORES="$2"
      shift 2
      ;;
    --allow-net-flow)
      [[ $# -ge 2 ]] || usage
      export PIN3D_ALLOW_NET_FLOW="$2"
      shift 2
      ;;
    --split-net-flow)
      [[ $# -ge 2 ]] || usage
      export PIN3D_SPLIT_NET_FLOW="$2"
      shift 2
      ;;
    --use-flow)
      [[ $# -ge 2 ]] || usage
      USE_FLOW="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "ERROR: unknown option '$1'" >&2
      usage
      ;;
  esac
done

DESIGN_DIR="$(dirname "${CASE_DIR}")"
PLATFORM_DIR="$(dirname "${DESIGN_DIR}")"
TEST_DIR="$(dirname "${PLATFORM_DIR}")"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

DESIGN_NICKNAME="$(basename "${DESIGN_DIR}")"
ENABLEMENT="$(basename "${PLATFORM_DIR}")"
LAUNCHER="${REPO_ROOT}/test/commercial/CDS_3D_NEW_FLOW.sh"

case "${USE_FLOW}" in
  cadence|Cadence) USE_FLOW="cadence" ;;
  *)
    echo "ERROR: USE_FLOW='${USE_FLOW}' is invalid for cds wrapper." >&2
    exit 1
    ;;
esac

if [[ ! -f "${LAUNCHER}" ]]; then
  echo "ERROR: launcher not found: ${LAUNCHER}" >&2
  exit 1
fi

echo "[run] case_dir=${CASE_DIR}"
echo "[run] enablement=${ENABLEMENT} design=${DESIGN_NICKNAME}"
echo "[run] flow_variant=${FLOW_VARIANT} use_flow=${USE_FLOW}"
echo "[run] START_FROM=${START_FROM:-}"
echo "[run] SKIP_2D_PART=${SKIP_2D_PART:-0}"
echo "[run] REUSE_2DPART_FROM_VARIANT=${REUSE_2DPART_FROM_VARIANT:-}"

exec bash "${LAUNCHER}" "${ENABLEMENT}" "${FLOW_VARIANT}" "${USE_FLOW}" "${DESIGN_NICKNAME}"
