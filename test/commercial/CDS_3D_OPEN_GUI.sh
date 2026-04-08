#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  cat >&2 <<'EOF'
Usage: test/commercial/CDS_3D_OPEN_GUI.sh <enablement> <flow_variant> <design_nickname> <stage-or-manifest>

Arguments:
  enablement       Platform / enablement directory under designs/, such as asap7_3D
  flow_variant     Flow variant name under logs/results/objects/reports
  design_nickname  Design nickname under designs/<enablement>/
  stage-or-manifest
                   Either a handoff stage key such as place-init-upper / final-restore,
                   a Cadence make target such as cds-place-init-upper / cds-restore,
                   or a direct path to a handoff manifest Tcl.

Optional environment variables:
  HANDOFF_VIEW=in|out|auto   Prefer manifest input or output artifacts. Default: auto
EOF
  exit 1
fi

ENABLEMENT="$1"
FLOW_VARIANT="$2"
DESIGN_NICKNAME="$3"
STAGE_OR_MANIFEST="$4"

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

DESIGN_CONFIG_3D="designs/${ENABLEMENT}/${DESIGN_NICKNAME}/config.mk"
if [[ ! -f "${FLOW_ROOT}/${DESIGN_CONFIG_3D}" ]]; then
  echo "ERROR: missing design config ${DESIGN_CONFIG_3D}" >&2
  exit 1
fi

stage_to_handoff_and_lef() {
  case "$1" in
    preplace|cds-preplace)
      echo "preplace LEF_FILES"
      ;;
    floorplan-3d|cds-3d-floorplan)
      echo "floorplan-3d LEF_FILES"
      ;;
    io-place|cds-3d-io)
      echo "io-place LEF_FILES"
      ;;
    split-net|cds-3d-split-net)
      echo "split-net LEF_FILES_SPLIT"
      ;;
    macro-upper|cds-place-macro-upper)
      echo "macro-upper LEF_FILES_BOTTOM_COVER"
      ;;
    macro-bottom|cds-place-macro-bottom)
      echo "macro-bottom LEF_FILES_UPPER_COVER"
      ;;
    pdn-bottom|cds-3d-pdn-only-bottom)
      echo "pdn-bottom LEF_FILES_UPPER_COVER"
      ;;
    pdn-upper|cds-3d-pdn-only-upper)
      echo "pdn-upper LEF_FILES_BOTTOM_COVER"
      ;;
    place-init|cds-place-init)
      echo "place-init LEF_FILES_UPPER_COVER"
      ;;
    place-init-upper|cds-place-init-upper)
      echo "place-init-upper LEF_FILES_BOTTOM_COVER"
      ;;
    place-init-bottom|cds-place-init-bottom)
      echo "place-init-bottom LEF_FILES_UPPER_COVER"
      ;;
    place-upper|cds-place-upper)
      echo "place-upper LEF_FILES_BOTTOM_COVER"
      ;;
    place-bottom|cds-place-bottom)
      echo "place-bottom LEF_FILES_UPPER_COVER"
      ;;
    gp2lg|cds-gp2lg)
      echo "gp2lg LEF_FILES_UPPER_COVER"
      ;;
    legalize-upper|cds-legalize-upper)
      echo "legalize-upper LEF_FILES_BOTTOM_COVER"
      ;;
    legalize-bottom|cds-legalize-bottom)
      echo "legalize-bottom LEF_FILES_UPPER_COVER"
      ;;
    cts-owner-tree|cds-cts-owner-tree)
      echo "cts-owner-tree LEF_FILES_CTS_OWNER"
      ;;
    cts-receive-opt|cds-cts-receive-opt)
      echo "cts-receive-opt LEF_FILES_CTS_RECEIVE"
      ;;
    cts-finalize|cds-cts-finalize)
      echo "cts-finalize LEF_FILES_CTS_FINALIZE"
      ;;
    cts-legacy|cds-cts-legacy)
      echo "cts-legacy LEF_FILES_CTS"
      ;;
    route-only|cds-route-only)
      echo "route-only LEF_FILES_ROUTE_ONLY"
      ;;
    postroute-receive|cds-postroute-receive)
      echo "postroute-receive LEF_FILES_POSTROUTE_RECEIVE"
      ;;
    postroute-owner|cds-postroute-owner)
      echo "postroute-owner LEF_FILES_POSTROUTE_OWNER"
      ;;
    route-legacy|cds-route)
      echo "route-legacy LEF_FILES_ROUTE"
      ;;
    final|cds-final)
      echo "final LEF_FILES_ROUTE"
      ;;
    final-restore|cds-restore)
      echo "final-restore LEF_FILES_ROUTE"
      ;;
    cds-3d-flow-2dpart|cds-pre|cds-3d-pdn-only|cds-cts|cds-route-new)
      echo "ERROR: aggregate/non-GUI Cadence target '$1' is not directly openable; use a concrete handoff stage" >&2
      return 1
      ;;
    *)
      echo "ERROR: unsupported handoff stage or Cadence target '$1'" >&2
      return 1
      ;;
  esac
}

MANIFEST_PATH=""
HANDOFF_STAGE=""
LEF_FILES_VAR=""

if [[ -f "${STAGE_OR_MANIFEST}" ]]; then
  MANIFEST_PATH="${STAGE_OR_MANIFEST}"
  HANDOFF_STAGE="$(basename "${MANIFEST_PATH}" .tcl)"
  read -r _stage_from_file LEF_FILES_VAR < <(stage_to_handoff_and_lef "${HANDOFF_STAGE}")
else
  read -r HANDOFF_STAGE LEF_FILES_VAR < <(stage_to_handoff_and_lef "${STAGE_OR_MANIFEST}")
  MANIFEST_PATH="results/${ENABLEMENT}/${DESIGN_NICKNAME}/${FLOW_VARIANT}/handoffs/${HANDOFF_STAGE}.tcl"
fi

if [[ ! -f "${MANIFEST_PATH}" ]]; then
  echo "ERROR: handoff manifest not found: ${MANIFEST_PATH}" >&2
  exit 1
fi

export NUM_CORES="${NUM_CORES:-16}"
source "${FLOW_ROOT}/env.sh"

GUI_LOG="logs/${ENABLEMENT}/${DESIGN_NICKNAME}/${FLOW_VARIANT}/cadence_open_gui.${HANDOFF_STAGE}.log"
mkdir -p "$(dirname "${GUI_LOG}")"

echo "[gui] enablement=${ENABLEMENT}"
echo "[gui] design=${DESIGN_NICKNAME}"
echo "[gui] flow_variant=${FLOW_VARIANT}"
echo "[gui] handoff_stage=${HANDOFF_STAGE}"
echo "[gui] handoff_tcl=${MANIFEST_PATH}"
echo "[gui] lef_view_var=${LEF_FILES_VAR}"
echo "[gui] gui_log=${GUI_LOG}"

TMP_MAKEFILE="$(mktemp)"
cleanup() {
  rm -f "${TMP_MAKEFILE}"
}
trap cleanup EXIT

cat > "${TMP_MAKEFILE}" <<'EOF'
.PHONY: __pin3d_cds_open_gui
__pin3d_cds_open_gui:
	@HANDOFF_TCL="$(HANDOFF_TCL)" \
	HANDOFF_VIEW="$(HANDOFF_VIEW)" \
	LEF_FILES="$($(GUI_LEF_FILES_VAR))" \
	$(INNOVUS_EXE) -overwrite -log "$(GUI_LOG)" -files $(CADENCE_SCRIPTS_DIR)/open_handoff_gui.tcl
EOF

make --no-print-directory \
  -f Makefile -f "${TMP_MAKEFILE}" \
  DESIGN_CONFIG="${DESIGN_CONFIG_3D}" \
  DESIGN_DIMENSION="3D" \
  DESIGN_NICKNAME="${DESIGN_NICKNAME}" \
  FLOW_VARIANT="${FLOW_VARIANT}" \
  USE_FLOW="cadence" \
  HANDOFF_TCL="${MANIFEST_PATH}" \
  HANDOFF_VIEW="${HANDOFF_VIEW:-auto}" \
  GUI_LEF_FILES_VAR="${LEF_FILES_VAR}" \
  GUI_LOG="${GUI_LOG}" \
  __pin3d_cds_open_gui
