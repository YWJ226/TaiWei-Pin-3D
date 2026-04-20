#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Iterable

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from run_experiments import discover_available_tasks


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Compare generated eval JSONs against CI baselines under "
            "designs/<tech>/<case>/. Supported contracts are compared by "
            "default; research paths must be enabled explicitly."
        )
    )
    parser.add_argument(
        "mode",
        nargs="?",
        choices=("smoke", "full"),
        default="smoke",
        help="smoke runs gcd only by default; full runs all matching cases.",
    )
    parser.add_argument(
        "--flow",
        choices=("ord", "cds", "all"),
        default="all",
        help="Which flow-origin baselines to compare (default: all supported flows).",
    )
    parser.add_argument(
        "--variant-base",
        default="ORD_CI",
        help="Base CI variant. Derived defaults are <base>__ord and <base>__cds.",
    )
    parser.add_argument(
        "--ord-flow-variant",
        help="Explicit report variant for ord-flow outputs.",
    )
    parser.add_argument(
        "--cds-flow-variant",
        help="Explicit report variant for cds-flow outputs.",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=REPO_ROOT,
        help="Repository root (default: script parent).",
    )
    parser.add_argument(
        "--tech",
        action="append",
        default=[],
        help="Tech filter. Repeatable. Default: all matched techs.",
    )
    parser.add_argument(
        "--case",
        action="append",
        default=[],
        help="Case filter. Repeatable. Default: all matched cases.",
    )
    parser.add_argument(
        "--abs-tol",
        type=float,
        default=1e-9,
        help="Absolute tolerance for numeric comparisons (default: 1e-9).",
    )
    parser.add_argument(
        "--research-cds-openroad-eval",
        action="store_true",
        help=(
            "Also compare the research-only cds-origin -> OpenROAD eval path "
            "against designs/<tech>/<case>/ci/research/cds/openroad_eval.json. "
            "Research mismatches are reported but do not fail the command."
        ),
    )
    parser.add_argument(
        "--no-sync-missing",
        dest="sync_missing",
        action="store_false",
        help="Fail instead of seeding missing baseline JSONs.",
    )
    parser.set_defaults(sync_missing=True)
    return parser.parse_args()


def _selected_cases(
    repo_root: Path,
    flows: list[str],
    mode: str,
    tech_filters: list[str],
    case_filters: list[str],
) -> list[tuple[str, str]]:
    seen: set[tuple[str, str]] = set()
    selected: list[tuple[str, str]] = []
    tech_set = set(tech_filters)
    if case_filters:
        case_set = set(case_filters)
    elif mode == "smoke":
        case_set = {"gcd"}
    else:
        case_set = set()

    for flow, tech, case in discover_available_tasks(repo_root):
        if flow not in flows:
            continue
        if tech_set and tech not in tech_set:
            continue
        if case_set and case not in case_set:
            continue
        key = (tech, case)
        if key in seen:
            continue
        seen.add(key)
        selected.append(key)
    return selected


def _flow_variant(args: argparse.Namespace, flow: str) -> str:
    if flow == "ord":
        return args.ord_flow_variant or f"{args.variant_base}__ord"
    if flow == "cds":
        return args.cds_flow_variant or f"{args.variant_base}__cds"
    raise ValueError(f"unsupported flow {flow}")


def _load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def _metric_items(payload: dict) -> Iterable[tuple[str, dict]]:
    for key, value in payload.items():
        if key.startswith("_"):
            continue
        if isinstance(value, dict) and "value" in value and "compare" in value:
            yield key, value


def _sanitized_baseline(payload: dict) -> dict:
    return {
        key: {"value": value["value"], "compare": value["compare"]}
        for key, value in _metric_items(payload)
    }


def _write_baseline(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(_sanitized_baseline(payload), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _candidate_cadence_json(report_dir: Path) -> Path:
    for name in ("innovus_eval.json", "cadence_eval.json", "innovus_on_openroad_eval.json"):
        candidate = report_dir / name
        if candidate.exists():
            return candidate
    return report_dir / "innovus_eval.json"


def _baseline_candidates(
    repo_root: Path,
    tech: str,
    case: str,
    flow: str,
    evaluator: str,
    *,
    research: bool = False,
) -> list[Path]:
    design_dir = repo_root / "designs" / tech / case
    filename = "openroad_eval.json" if evaluator == "openroad" else "cadence_eval.json"
    if research:
        return [design_dir / "ci" / "research" / flow / filename]

    candidates = [design_dir / "ci" / flow / filename]
    if flow == "ord":
        candidates.append(design_dir / filename)
    return candidates


def _passes(actual_value: float, baseline_value: float, compare: str, abs_tol: float) -> bool:
    if compare == "<=":
        return actual_value <= baseline_value or math.isclose(
            actual_value, baseline_value, abs_tol=abs_tol, rel_tol=0.0
        )
    if compare == ">=":
        return actual_value >= baseline_value or math.isclose(
            actual_value, baseline_value, abs_tol=abs_tol, rel_tol=0.0
        )
    if compare == "==":
        return math.isclose(actual_value, baseline_value, abs_tol=abs_tol, rel_tol=0.0)
    raise ValueError(f"unsupported compare operator: {compare}")


def _compare_metric_payloads(
    baseline_payload: dict, actual_payload: dict, abs_tol: float
) -> list[str]:
    actual_metrics = {key: value for key, value in _metric_items(actual_payload)}
    failures: list[str] = []

    for metric, baseline_entry in _metric_items(baseline_payload):
        actual_entry = actual_metrics.get(metric)
        if actual_entry is None:
            failures.append(f"{metric}: missing in current JSON")
            continue

        compare = str(baseline_entry.get("compare", "")).strip()
        baseline_value = baseline_entry.get("value")
        actual_value = actual_entry.get("value")
        if not isinstance(baseline_value, (int, float)):
            failures.append(f"{metric}: baseline value is not numeric")
            continue
        if not isinstance(actual_value, (int, float)):
            failures.append(f"{metric}: current value is not numeric")
            continue

        if not _passes(float(actual_value), float(baseline_value), compare, abs_tol):
            failures.append(
                f"{metric}: current={actual_value} must satisfy "
                f"{compare} baseline={baseline_value}"
            )

    return failures


def _compare_one(
    label: str,
    actual_path: Path,
    baseline_candidates: list[Path],
    sync_missing: bool,
    abs_tol: float,
) -> tuple[str, list[str]]:
    if not actual_path.exists():
        return ("failed", [f"{label}: missing current JSON {actual_path}"])

    actual_payload = _load_json(actual_path)
    existing_baseline = next((path for path in baseline_candidates if path.exists()), None)
    if existing_baseline is None:
        seed_path = baseline_candidates[0]
        if not sync_missing:
            return ("failed", [f"{label}: missing baseline JSON {seed_path}"])
        _write_baseline(seed_path, actual_payload)
        return ("seeded", [f"{label}: seeded {seed_path}"])

    baseline_payload = _load_json(existing_baseline)
    failures = _compare_metric_payloads(baseline_payload, actual_payload, abs_tol)
    if failures:
        return ("failed", failures)
    return ("ok", [])


def _report_status(
    *,
    kind: str,
    tech: str,
    case: str,
    flow: str,
    label: str,
    baseline_label: Path,
    status: str,
    details: list[str],
) -> tuple[int, int, int]:
    ok = 0
    seeded = 0
    failed = 0
    prefix = f"[{kind}] {tech}/{case} flow={flow} eval={label}"
    if status == "ok":
        ok += 1
        print(f"{prefix} matches {baseline_label}")
    elif status == "seeded":
        seeded += 1
        print(f"{prefix} {details[0]}")
    else:
        failed += 1
        print(f"{prefix}")
        for detail in details:
            print(f"  - {detail}")
    return ok, seeded, failed


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    flows = ["ord", "cds"] if args.flow == "all" else [args.flow]
    tasks = _selected_cases(repo_root, flows, args.mode, args.tech, args.case)

    if not tasks:
        print("[compare] No tasks matched the requested filters.")
        return 2

    ok_count = 0
    seeded_count = 0
    failed_count = 0
    research_ok_count = 0
    research_seeded_count = 0
    research_failed_count = 0

    for tech, case in tasks:
        for flow in flows:
            report_dir = repo_root / "reports" / tech / case / _flow_variant(args, flow)

            supported_pairs: list[tuple[str, Path, list[Path]]] = []
            if flow == "ord":
                supported_pairs.extend(
                    [
                        (
                            "openroad",
                            report_dir / "openroad_eval.json",
                            _baseline_candidates(repo_root, tech, case, flow, "openroad"),
                        ),
                        (
                            "cadence",
                            _candidate_cadence_json(report_dir),
                            _baseline_candidates(repo_root, tech, case, flow, "cadence"),
                        ),
                    ]
                )
            elif flow == "cds":
                supported_pairs.append(
                    (
                        "cadence",
                        _candidate_cadence_json(report_dir),
                        _baseline_candidates(repo_root, tech, case, flow, "cadence"),
                    )
                )

            for label, actual_path, baseline_candidates in supported_pairs:
                status, details = _compare_one(
                    label=label,
                    actual_path=actual_path,
                    baseline_candidates=baseline_candidates,
                    sync_missing=args.sync_missing,
                    abs_tol=args.abs_tol,
                )
                ok, seeded, failed = _report_status(
                    kind="ok" if status == "ok" else "seed" if status == "seeded" else "fail",
                    tech=tech,
                    case=case,
                    flow=flow,
                    label=label,
                    baseline_label=baseline_candidates[0],
                    status=status,
                    details=details,
                )
                ok_count += ok
                seeded_count += seeded
                failed_count += failed

            if args.research_cds_openroad_eval and flow == "cds":
                baseline_candidates = _baseline_candidates(
                    repo_root,
                    tech,
                    case,
                    flow,
                    "openroad",
                    research=True,
                )
                status, details = _compare_one(
                    label="openroad",
                    actual_path=report_dir / "openroad_eval.json",
                    baseline_candidates=baseline_candidates,
                    sync_missing=args.sync_missing,
                    abs_tol=args.abs_tol,
                )
                ok, seeded, failed = _report_status(
                    kind=(
                        "research-ok"
                        if status == "ok"
                        else "research-seed"
                        if status == "seeded"
                        else "research-fail"
                    ),
                    tech=tech,
                    case=case,
                    flow=flow,
                    label="openroad",
                    baseline_label=baseline_candidates[0],
                    status=status,
                    details=details,
                )
                research_ok_count += ok
                research_seeded_count += seeded
                research_failed_count += failed

    print(
        "[summary] "
        f"ok={ok_count} seeded={seeded_count} failed={failed_count} "
        f"research_ok={research_ok_count} research_seeded={research_seeded_count} "
        f"research_failed={research_failed_count}"
    )
    return 1 if failed_count else 0


if __name__ == "__main__":
    raise SystemExit(main())
