#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


COMPARE_BY_METRIC = {
    "finish__route__hb_via__count__phys": "<=",
    "finish__timing__setup__ws": ">=",
    "finish__timing__setup__tns": ">=",
    "finish__route__cross_tier_nets__all": "<=",
    "finish__route__drc_errors": "<=",
    "finish__design__instance__area__stdcell": "<=",
    "finish__design__core__area": "<=",
    "finish__design__instance__area__macro": "<=",
    "finish__power__total": "<=",
    "finish__fep__violations": "<=",
    "finish__erc__violations": "<=",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract OpenROAD/Innovus evaluation metrics into rules-base-like JSON files."
    )
    parser.add_argument("--openroad-log-dir", type=Path, help="OpenROAD log directory.")
    parser.add_argument("--openroad-report-dir", type=Path, help="OpenROAD report directory.")
    parser.add_argument("--openroad-result-dir", type=Path, help="OpenROAD result directory.")
    parser.add_argument("--openroad-output", type=Path, help="Output JSON path for OpenROAD.")
    parser.add_argument("--innovus-summary", type=Path, help="Innovus final_summary.txt path.")
    parser.add_argument("--innovus-output", type=Path, help="Output JSON path for Innovus.")
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Repository root for path normalization.",
    )
    return parser.parse_args()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def parse_scalar(raw: str | None) -> int | float | None:
    if raw is None:
        return None
    text = raw.strip()
    if text == "" or text.upper() == "N/A":
        return None
    try:
        if re.fullmatch(r"[+-]?\d+", text):
            return int(text)
        return float(text)
    except ValueError:
        return None


def extract_summary_label(summary_path: Path, label: str) -> int | float | None:
    if not summary_path.exists():
        return None
    for raw in summary_path.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip()
        if line.startswith(label):
            return parse_scalar(line.split()[-1])
    return None


def count_matches(path: Path, pattern: str) -> int | None:
    if not path.exists():
        return None
    return len(re.findall(pattern, path.read_text(encoding="utf-8"), re.M))


def extract_first_match(path: Path, pattern: str) -> str | None:
    if not path.exists():
        return None
    match = re.search(pattern, path.read_text(encoding="utf-8"), re.M)
    return match.group(1) if match else None


def make_metric(value: int | float) -> dict[str, Any]:
    return {"value": value, "compare": COMPARE_BY_METRIC[current_metric_key]}


def add_metric(
    payload: dict[str, Any], missing: list[str], key: str, value: int | float | None
) -> None:
    if value is None:
        missing.append(key)
        return
    payload[key] = {"value": value, "compare": COMPARE_BY_METRIC[key]}


def build_openroad_payload(
    repo_root: Path, log_dir: Path, report_dir: Path, result_dir: Path
) -> dict[str, Any]:
    summary_path = log_dir / "final_summary.txt"
    finish_rpt = report_dir / "6_finish.rpt"
    drc_rpt = report_dir / "5_route_drc.rpt"
    cross_tier_list = log_dir / "cross_tier_nets.list"

    payload: dict[str, Any] = {
        "_meta": {
            "tool": "OpenROAD",
            "metrics_source": "OpenROAD",
            "summary_path": str(summary_path),
            "report_dir": str(report_dir),
            "result_dir": str(result_dir),
            "generated_at": datetime.now(timezone.utc).isoformat(),
        }
    }
    missing: list[str] = []
    notes: list[str] = []

    core_area = extract_summary_label(summary_path, "Core Area")
    stdcell_area = extract_summary_label(summary_path, "StdCell Area")
    macro_area = extract_summary_label(summary_path, "Macro Area")

    wns = extract_summary_label(summary_path, "WNS")
    if wns is None:
        wns = parse_scalar(extract_first_match(finish_rpt, r"^wns max (\S+)"))

    tns = extract_summary_label(summary_path, "TNS")
    if tns is None:
        tns = parse_scalar(extract_first_match(finish_rpt, r"^tns max (\S+)"))

    power = extract_summary_label(summary_path, "Total Power")
    if power is None:
        power = parse_scalar(
            extract_first_match(finish_rpt, r"^Total\s+\S+\s+\S+\s+\S+\s+(\S+)")
        )

    cross_tier = extract_summary_label(summary_path, "Cross-Tier Nets (All)")
    if cross_tier is None:
        cross_tier = parse_scalar(
            extract_first_match(cross_tier_list, r"^Total Cross-Tier Nets:\s+(\d+)")
        )

    drc = extract_summary_label(summary_path, "DRC Violations")
    if drc is None:
        drc = count_matches(drc_rpt, r"^violation type:")

    hb_via = extract_summary_label(summary_path, "HB VIA Count (Phys)")

    erc_total = extract_summary_label(summary_path, "ERC Total (sum)")
    if erc_total is None:
        max_slew = parse_scalar(
            extract_first_match(finish_rpt, r"^max slew violation count (\S+)")
        )
        max_cap = parse_scalar(
            extract_first_match(finish_rpt, r"^max cap violation count (\S+)")
        )
        max_fanout = parse_scalar(
            extract_first_match(finish_rpt, r"^max fanout violation count (\S+)")
        )
        if None not in (max_slew, max_cap, max_fanout):
            erc_total = int(max_slew) + int(max_cap) + int(max_fanout)

    fep = extract_summary_label(summary_path, "FEP Violations")
    if fep is None:
        fep = parse_scalar(extract_first_match(finish_rpt, r"^setup violation count (\S+)"))

    add_metric(payload, missing, "finish__route__hb_via__count__phys", hb_via)
    add_metric(payload, missing, "finish__timing__setup__ws", wns)
    add_metric(payload, missing, "finish__timing__setup__tns", tns)
    add_metric(payload, missing, "finish__route__cross_tier_nets__all", cross_tier)
    add_metric(payload, missing, "finish__route__drc_errors", drc)
    add_metric(payload, missing, "finish__design__instance__area__stdcell", stdcell_area)
    add_metric(payload, missing, "finish__design__core__area", core_area)
    add_metric(payload, missing, "finish__design__instance__area__macro", macro_area)
    add_metric(payload, missing, "finish__power__total", power)
    add_metric(payload, missing, "finish__fep__violations", fep)
    add_metric(payload, missing, "finish__erc__violations", erc_total)
    if missing:
        payload["_missing_metrics"] = missing
    if notes:
        payload["_notes"] = notes
    return payload


def build_innovus_payload(summary_path: Path) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "_meta": {
            "tool": "Innovus",
            "metrics_source": "Innovus",
            "summary_path": str(summary_path),
            "generated_at": datetime.now(timezone.utc).isoformat(),
        }
    }
    missing: list[str] = []

    upper_bottom = extract_summary_label(summary_path, "Upper_Bottom")
    upper_io = extract_summary_label(summary_path, "Upper_IO")
    bottom_io = extract_summary_label(summary_path, "Bottom_IO")
    upper_bottom_io = extract_summary_label(summary_path, "Upper_Bottom_IO")
    unknown = extract_summary_label(summary_path, "Unknown_Tier")
    cross_tier = None
    if None not in (upper_bottom, upper_io, bottom_io, upper_bottom_io, unknown):
        cross_tier = int(upper_bottom) + int(upper_io) + int(bottom_io) + int(upper_bottom_io) + int(unknown)
    else:
        cross_tier = extract_summary_label(summary_path, "Cross-Tier Nets (U/B only)")

    add_metric(
        payload,
        missing,
        "finish__route__hb_via__count__phys",
        extract_summary_label(summary_path, "HB VIA Count (Phys)"),
    )
    add_metric(
        payload,
        missing,
        "finish__timing__setup__ws",
        extract_summary_label(summary_path, "WNS (ns)"),
    )
    add_metric(
        payload,
        missing,
        "finish__timing__setup__tns",
        extract_summary_label(summary_path, "TNS (ns)"),
    )
    add_metric(payload, missing, "finish__route__cross_tier_nets__all", cross_tier)
    add_metric(
        payload,
        missing,
        "finish__route__drc_errors",
        extract_summary_label(summary_path, "DRC Violations"),
    )
    add_metric(
        payload,
        missing,
        "finish__design__instance__area__stdcell",
        extract_summary_label(summary_path, "StdCell Area"),
    )
    add_metric(
        payload,
        missing,
        "finish__design__core__area",
        extract_summary_label(summary_path, "Core Area"),
    )
    add_metric(
        payload,
        missing,
        "finish__design__instance__area__macro",
        extract_summary_label(summary_path, "Macro Area"),
    )
    add_metric(
        payload,
        missing,
        "finish__power__total",
        extract_summary_label(summary_path, "Total Power"),
    )
    add_metric(
        payload,
        missing,
        "finish__fep__violations",
        extract_summary_label(summary_path, "FEP Violations"),
    )
    add_metric(
        payload,
        missing,
        "finish__erc__violations",
        extract_summary_label(summary_path, "ERC Total (sum)"),
    )

    if missing:
        payload["_missing_metrics"] = missing
    return payload


def infer_innovus_output(summary_path: Path, explicit_output: Path | None) -> Path:
    if explicit_output is not None:
        return explicit_output
    parts = list(summary_path.parts)
    if "logs" in parts:
        idx = parts.index("logs")
        parts[idx] = "reports"
        return Path(*parts[:-1]) / "innovus_eval.json"
    return summary_path.with_name("innovus_eval.json")


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()

    if args.openroad_log_dir or args.openroad_report_dir or args.openroad_result_dir:
        missing_args = [
            name
            for name, value in (
                ("--openroad-log-dir", args.openroad_log_dir),
                ("--openroad-report-dir", args.openroad_report_dir),
                ("--openroad-result-dir", args.openroad_result_dir),
            )
            if value is None
        ]
        if missing_args:
            raise SystemExit(f"OpenROAD extraction requires: {', '.join(missing_args)}")

        openroad_output = args.openroad_output or (args.openroad_report_dir / "openroad_eval.json")
        openroad_payload = build_openroad_payload(
            repo_root,
            args.openroad_log_dir.resolve(),
            args.openroad_report_dir.resolve(),
            args.openroad_result_dir.resolve(),
        )
        openroad_output.parent.mkdir(parents=True, exist_ok=True)
        openroad_output.write_text(json.dumps(openroad_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"[write] {openroad_output}")

    if args.innovus_summary:
        innovus_summary = args.innovus_summary.resolve()
        innovus_output = infer_innovus_output(innovus_summary, args.innovus_output)
        innovus_payload = build_innovus_payload(innovus_summary)
        innovus_output.parent.mkdir(parents=True, exist_ok=True)
        innovus_output.write_text(json.dumps(innovus_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"[write] {innovus_output}")

    if not args.openroad_log_dir and not args.innovus_summary:
        raise SystemExit("Nothing to do. Provide OpenROAD directories and/or --innovus-summary.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
