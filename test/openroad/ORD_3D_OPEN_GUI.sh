#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  cat >&2 <<'EOF'
Usage: test/openroad/ORD_3D_OPEN_GUI.sh <enablement> <flow_variant> <design_nickname> <stage-or-manifest>

Arguments:
  enablement       Platform / enablement directory under designs/, such as asap7_3D
  flow_variant     Flow variant name under logs/results/objects/reports
  design_nickname  Design nickname under designs/<enablement>/
  stage-or-manifest
                   Either a handoff stage key such as place-init-upper / cts-post,
                   an OpenROAD make target such as ord-place-init-upper / ord-cts-post,
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
DESIGN_CONFIG_2D="designs/${ENABLEMENT}/${DESIGN_NICKNAME}/config2d.mk"

if [[ ! -f "${FLOW_ROOT}/${DESIGN_CONFIG_3D}" ]]; then
  echo "ERROR: missing design config ${DESIGN_CONFIG_3D}" >&2
  exit 1
fi

if [[ ! -f "${FLOW_ROOT}/${DESIGN_CONFIG_2D}" ]]; then
  echo "ERROR: missing design config ${DESIGN_CONFIG_2D}" >&2
  exit 1
fi

stage_to_handoff_and_lef() {
  case "$1" in
    floorplan-3d|ord-3d-floorplan)
      echo "floorplan-3d LEF_FILES_SPLIT"
      ;;
    io-place|ord-3d-io)
      echo "io-place LEF_FILES_SPLIT"
      ;;
    split-net|ord-3d-split-net)
      echo "split-net LEF_FILES_SPLIT"
      ;;
    macro-upper|ord-place-macro-upper)
      echo "macro-upper LEF_FILES_BOTTOM_COVER"
      ;;
    macro-bottom|ord-place-macro-bottom)
      echo "macro-bottom LEF_FILES_UPPER_COVER"
      ;;
    pdn-bottom|ord-3d-pdn-only-bottom)
      echo "pdn-bottom LEF_FILES_UPPER_COVER"
      ;;
    pdn-upper|ord-3d-pdn-only-upper)
      echo "pdn-upper LEF_FILES_BOTTOM_COVER"
      ;;
    place-init|ord-place-init)
      echo "place-init LEF_FILES_BOTTOM_COVER"
      ;;
    place-init-upper|ord-place-init-upper)
      echo "place-init-upper LEF_FILES_BOTTOM_COVER"
      ;;
    place-init-bottom|ord-place-init-bottom)
      echo "place-init-bottom LEF_FILES_UPPER_COVER"
      ;;
    place-upper|ord-place-upper)
      echo "place-upper LEF_FILES_BOTTOM_COVER"
      ;;
    place-bottom|ord-place-bottom)
      echo "place-bottom LEF_FILES_UPPER_COVER"
      ;;
    gp2lg|ord-gp2lg)
      echo "gp2lg LEF_FILES_BOTTOM_COVER"
      ;;
    legalize-upper|ord-legalize-upper)
      echo "legalize-upper LEF_FILES_BOTTOM_COVER"
      ;;
    legalize-bottom|ord-legalize-bottom)
      echo "legalize-bottom LEF_FILES_UPPER_COVER"
      ;;
    cts|ord-cts)
      echo "cts LEF_FILES_CTS_OWNER"
      ;;
    cts-post|ord-cts-post)
      echo "cts-post LEF_FILES_CTS_RECEIVE"
      ;;
    route-global|ord-route-global)
      echo "route-global LEF_FILES"
      ;;
    route-detail|ord-route-detail)
      echo "route-detail LEF_FILES"
      ;;
    route|ord-route)
      echo "route LEF_FILES"
      ;;
    final|ord-final)
      echo "final LEF_FILES"
      ;;
    ord-3d-pdn-only)
      echo "ERROR: ord-3d-pdn-only is aggregate; use ord-3d-pdn-only-bottom or ord-3d-pdn-only-upper" >&2
      return 1
      ;;
    *)
      echo "ERROR: unsupported handoff stage or OpenROAD target '$1'" >&2
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

echo "[gui] enablement=${ENABLEMENT}"
echo "[gui] design=${DESIGN_NICKNAME}"
echo "[gui] flow_variant=${FLOW_VARIANT}"
echo "[gui] handoff_stage=${HANDOFF_STAGE}"
echo "[gui] handoff_tcl=${MANIFEST_PATH}"
echo "[gui] lef_view_var=${LEF_FILES_VAR}"

TMP_MAKEFILE="$(mktemp)"
cleanup() {
  rm -f "${TMP_MAKEFILE}"
}
trap cleanup EXIT

cat > "${TMP_MAKEFILE}" <<'EOF'
.PHONY: __pin3d_open_gui
__pin3d_open_gui:
	@HANDOFF_TCL="$(HANDOFF_TCL)" \
	HANDOFF_VIEW="$(HANDOFF_VIEW)" \
	LEF_FILES="$($(GUI_LEF_FILES_VAR))" \
	$(OPENROAD_EXE) $(OPENROAD_SCRIPTS_DIR)/open_handoff_gui.tcl
EOF

make --no-print-directory \
  -f Makefile -f "${TMP_MAKEFILE}" \
  DESIGN_CONFIG="${DESIGN_CONFIG_3D}" \
  DESIGN_DIMENSION="3D" \
  DESIGN_NICKNAME="${DESIGN_NICKNAME}" \
  FLOW_VARIANT="${FLOW_VARIANT}" \
  USE_FLOW="openroad" \
  HANDOFF_TCL="${MANIFEST_PATH}" \
  HANDOFF_VIEW="${HANDOFF_VIEW:-auto}" \
  GUI_LEF_FILES_VAR="${LEF_FILES_VAR}" \
  __pin3d_open_gui
