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

MATRIX_CASES="${MATRIX_CASES:-asap7_3D:ibex asap7_nangate45_3D:ibex nangate45_3D:ibex}"
MATRIX_CASES+=" asap7_3D:swerv_wrapper asap7_nangate45_3D:swerv_wrapper nangate45_3D:swerv_wrapper"
MODE_MATRIX="${MODE_MATRIX:-allownet:on:on noallownet:off:off}"
FLOW_VARIANT_BASE="${FLOW_VARIANT_BASE:-cadence_cmp}"
OUTER_ITERATIONS="${OUTER_ITERATIONS:-1}"
REUSE_2DPART_FROM_VARIANT="${REUSE_2DPART_FROM_VARIANT:-}"

CSV_DIR="${FLOW_ROOT}/reports/compare_allow_net"
CSV_PATH="${CSV_DIR}/${FLOW_VARIANT_BASE}.csv"
mkdir -p "${CSV_DIR}"

cat > "${CSV_PATH}" <<'EOF'
enablement,design,mode_label,allow_net_flow,split_net_flow,flow_variant,split_mode,candidate_nets,mixed_tier_nets,split_nets,processed_residual,split_before_upper_bottom,split_before_upper_io,split_before_bottom_io,split_before_upper_bottom_io,split_after_upper_bottom,split_after_upper_io,split_after_bottom_io,split_after_upper_bottom_io,final_hb_via_phys,final_cross_tier_all,final_cross_upper_bottom,final_cross_upper_io,final_cross_bottom_io,final_cross_upper_bottom_io,final_cross_unknown,core_area,wns,tns,drc_violations,fep_violations,total_power,wire_length,final_summary_path
EOF

read_kv_metric() {
  local rpt="$1"
  local key="$2"
  awk -v key="$key" '$1 == key {print $2; found=1; exit} END {if (!found) print ""}' "$rpt" 2>/dev/null || true
}

append_csv_row() {
  python3 - "$@" <<'PY'
import csv
import pathlib
import re
import sys

(
    enablement,
    design,
    mode_label,
    allow_flow,
    split_flow,
    flow_variant,
    split_summary,
    before_report,
    after_report,
    final_summary,
) = sys.argv[1:]


def parse_split_summary(path_str):
    data = {
        "mode": "",
        "candidate_nets": "",
        "mixed_tier_nets": "",
        "split_nets": "",
        "processed_residual": "",
    }
    path = pathlib.Path(path_str)
    if not path.exists():
        return data
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line == "skip_reasons":
            continue
        parts = line.split()
        if len(parts) >= 2 and parts[0] in data:
            data[parts[0]] = parts[1]
    return data


def parse_cross_report(path_str):
    data = {
        "Upper_Bottom": "0",
        "Upper_IO": "0",
        "Bottom_IO": "0",
        "Upper_Bottom_IO": "0",
        "Unknown_Tier": "0",
        "Total": "0",
    }
    path = pathlib.Path(path_str)
    if not path.exists():
        return data
    category_re = re.compile(r"^(Upper_Bottom|Upper_IO|Bottom_IO|Upper_Bottom_IO|Unknown_Tier)\s+(\d+)$")
    total_re = re.compile(r"^Total Cross-Tier Nets:\s+(\d+)$")
    for raw in path.read_text().splitlines():
        line = raw.strip()
        total_match = total_re.match(line)
        if total_match:
            data["Total"] = total_match.group(1)
            continue
        category_match = category_re.match(line)
        if category_match:
            data[category_match.group(1)] = category_match.group(2)
    return data


def parse_final_summary(path_str):
    labels = {
        "HB VIA Count (Phys)": "final_hb_via_phys",
        "Cross-Tier Nets (All)": "final_cross_tier_all",
        "Upper_Bottom": "final_cross_upper_bottom",
        "Upper_IO": "final_cross_upper_io",
        "Bottom_IO": "final_cross_bottom_io",
        "Upper_Bottom_IO": "final_cross_upper_bottom_io",
        "Unknown_Tier": "final_cross_unknown",
        "Core Area": "core_area",
        "WNS (ns)": "wns",
        "TNS (ns)": "tns",
        "DRC Violations": "drc_violations",
        "FEP Violations": "fep_violations",
        "Total Power": "total_power",
        "Wire Length": "wire_length",
    }
    data = {value: "" for value in labels.values()}
    path = pathlib.Path(path_str)
    if not path.exists():
        return data
    for raw in path.read_text().splitlines():
        line = raw.rstrip()
        for label, key in labels.items():
            if line.startswith(label):
                data[key] = line.split()[-1]
                break
    return data


split_data = parse_split_summary(split_summary)
before_data = parse_cross_report(before_report)
after_data = parse_cross_report(after_report)
final_data = parse_final_summary(final_summary)

row = [
    enablement,
    design,
    mode_label,
    allow_flow,
    split_flow,
    flow_variant,
    split_data["mode"],
    split_data["candidate_nets"],
    split_data["mixed_tier_nets"],
    split_data["split_nets"],
    split_data["processed_residual"],
    before_data["Upper_Bottom"],
    before_data["Upper_IO"],
    before_data["Bottom_IO"],
    before_data["Upper_Bottom_IO"],
    after_data["Upper_Bottom"],
    after_data["Upper_IO"],
    after_data["Bottom_IO"],
    after_data["Upper_Bottom_IO"],
    final_data["final_hb_via_phys"],
    final_data["final_cross_tier_all"],
    final_data["final_cross_upper_bottom"],
    final_data["final_cross_upper_io"],
    final_data["final_cross_bottom_io"],
    final_data["final_cross_upper_bottom_io"],
    final_data["final_cross_unknown"],
    final_data["core_area"],
    final_data["wns"],
    final_data["tns"],
    final_data["drc_violations"],
    final_data["fep_violations"],
    final_data["total_power"],
    final_data["wire_length"],
    final_summary,
]

writer = csv.writer(sys.stdout)
writer.writerow(row)
PY
}

for case_entry in ${MATRIX_CASES}; do
  enablement="${case_entry%%:*}"
  design="${case_entry##*:}"

  for mode_entry in ${MODE_MATRIX}; do
    IFS=":" read -r mode_label allow_flow split_flow <<< "${mode_entry}"
    flow_variant="${FLOW_VARIANT_BASE}_${mode_label}"

    echo "[matrix] enablement=${enablement} design=${design} mode=${mode_label} allow=${allow_flow} split=${split_flow}"
    PIN3D_ALLOW_NET_FLOW="${allow_flow}" \
    PIN3D_SPLIT_NET_FLOW="${split_flow}" \
    OUTER_ITERATIONS="${OUTER_ITERATIONS}" \
    REUSE_2DPART_FROM_VARIANT="${REUSE_2DPART_FROM_VARIANT}" \
    SKIP_2D_PART="${SKIP_2D_PART:-0}" \
      bash "${SCRIPT_DIR}/CDS_3D_NEW_FLOW.sh" "${enablement}" "${flow_variant}" cadence "${design}"

    log_dir="${FLOW_ROOT}/logs/${enablement}/${design}/${flow_variant}"
    split_summary="${log_dir}/split_net.summary.rpt"
    before_report="${log_dir}/split_net.before.nets"
    after_report="${log_dir}/split_net.after.nets"
    final_summary="${log_dir}/final_summary.txt"

    append_csv_row \
      "${enablement}" \
      "${design}" \
      "${mode_label}" \
      "${allow_flow}" \
      "${split_flow}" \
      "${flow_variant}" \
      "${split_summary}" \
      "${before_report}" \
      "${after_report}" \
      "${final_summary}" >> "${CSV_PATH}"
  done
done

echo "[matrix] comparison CSV written to ${CSV_PATH}"
