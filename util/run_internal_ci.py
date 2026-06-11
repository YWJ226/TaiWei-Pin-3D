#!/usr/bin/env python3

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import run_experiments_remote as remote
from run_experiments import discover_available_tasks


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Internal CI wrapper for supported 3D flow contracts. By default it "
            "runs the supported paths only: ord-origin with native OpenROAD plus "
            "Cadence eval, and cds-origin with native Cadence plus cds-restore "
            "eval. Research-only cross-eval paths must be enabled explicitly."
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
        help="Which supported flow-origin contract(s) to run (default: all).",
    )
    parser.add_argument(
        "--variant-base",
        default="ORD_CI",
        help="Base CI variant. Derived defaults are <base>__ord and <base>__cds.",
    )
    parser.add_argument(
        "--ord-flow-variant",
        help="Explicit variant for ord-flow outputs.",
    )
    parser.add_argument(
        "--cds-flow-variant",
        help="Explicit variant for cds-flow outputs.",
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
        "--jobs",
        type=int,
        default=None,
        help="Local parallelism forwarded to run_experiments.py.",
    )
    parser.add_argument(
        "--host-list",
        nargs="+",
        default=None,
        help="Optional SSH host list forwarded to run_experiments.py.",
    )
    parser.add_argument(
        "--max-jobs-per-host",
        type=int,
        default=1,
        help="Forwarded to run_experiments.py when --host-list is used.",
    )
    parser.add_argument(
        "--status-interval",
        type=int,
        default=30,
        help="Status interval for run_experiments.py monitor mode.",
    )
    parser.add_argument(
        "--num-shards",
        type=int,
        default=1,
        help="Deterministic sharding forwarded to run_experiments.py.",
    )
    parser.add_argument(
        "--shard-index",
        type=int,
        default=0,
        help="Shard index forwarded to run_experiments.py.",
    )
    parser.add_argument(
        "--compare-only",
        action="store_true",
        help="Skip running experiments and compare existing outputs only.",
    )
    parser.add_argument(
        "--detach",
        action="store_true",
        help=(
            "Launch this internal CI invocation via the same detached local "
            "wrapper backend used for per-task jobs, then exit immediately."
        ),
    )
    parser.add_argument(
        "--research-cds-openroad-eval",
        action="store_true",
        help=(
            "Also run the research-only cds-origin -> OpenROAD ord-final eval "
            "path. This path is reported but does not block CI."
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


def _common_runner_args(args: argparse.Namespace) -> list[str]:
    repo_root = args.repo_root.resolve()
    runner_args = [
        "--repo-root",
        str(repo_root),
        "--num-shards",
        str(args.num_shards),
        "--shard-index",
        str(args.shard_index),
        "--status-interval",
        str(args.status_interval),
    ]
    if args.jobs is not None:
        runner_args.extend(["--jobs", str(args.jobs)])
    for tech in args.tech:
        runner_args.extend(["--tech", tech])
    if args.case:
        for case in args.case:
            runner_args.extend(["--case", case])
    elif args.mode == "smoke":
        runner_args.extend(["--case", "gcd"])
    return runner_args


def _strip_flag(argv: list[str], flag: str) -> list[str]:
    out: list[str] = []
    for arg in argv:
        if arg == flag:
            continue
        out.append(arg)
    return out


def _launcher_tag(args: argparse.Namespace) -> str:
    jobs = args.jobs if args.jobs is not None else "default"
    stamp = time.strftime("%Y%m%d_%H%M%S")
    return f"internal_ci_{args.mode}_{args.flow}_jobs{jobs}_{stamp}"


def _wait_for_launch_snapshot(launch: remote.RemoteLaunch,
                              *,
                              timeout_s: float = 3.0
                              ) -> remote.RemoteLaunchSnapshot:
    deadline = time.time() + timeout_s
    snapshot = remote.snapshot_local_launch(launch)
    while time.time() < deadline and snapshot.pid is None:
        time.sleep(0.2)
        snapshot = remote.snapshot_local_launch(launch)
    return snapshot


def _detach_self(args: argparse.Namespace) -> int:
    repo_root = args.repo_root.resolve()
    tag = _launcher_tag(args)
    log_path = repo_root / "run_logs" / f"{tag}.log"
    pid_path = repo_root / "run_logs" / f"{tag}.pid"
    job_path = repo_root / "run_logs" / f"{tag}.job"
    dispatch_dir = repo_root / "run_logs" / "dispatch" / "internal_ci" / tag
    child_argv = [
        sys.executable,
        str(repo_root / "util" / "run_internal_ci.py"),
        *_strip_flag(sys.argv[1:], "--detach"),
    ]
    launch = remote.submit_local_command(
        repo_root=repo_root,
        dispatch_dir=dispatch_dir,
        command=child_argv,
        log_path=log_path,
        stage="launcher",
        phase_name="ci",
        env=os.environ.copy(),
    )
    snapshot = _wait_for_launch_snapshot(launch)
    job_path.write_text(f"{launch.job_id}\n", encoding="utf-8")
    if snapshot.pid is not None:
        pid_path.write_text(f"{snapshot.pid}\n", encoding="utf-8")
    print(f"[ci] detached launcher submitted: {launch.job_id}")
    print(f"[ci] log: {log_path}")
    if snapshot.pid is not None:
        print(f"[ci] pid: {snapshot.pid}")
    print(f"[ci] dispatch dir: {dispatch_dir}")
    return 0


def _run_subprocess(cmd: list[str], env: dict[str, str], cwd: Path) -> None:
    print(f"[ci] exec: {' '.join(cmd)}")
    subprocess.run(cmd, cwd=cwd, env=env, check=True)


def _status_path(repo_root: Path, flow: str, tech: str, case: str) -> Path:
    return repo_root / "run_logs" / "status" / f"{flow}__{tech}__{case}.json"


def _check_statuses(repo_root: Path, tasks: list[tuple[str, str]], flow: str) -> int:
    failures = 0
    for tech, case in tasks:
        status_path = _status_path(repo_root, flow, tech, case)
        if not status_path.exists():
            print(f"[ci] missing status file: {status_path}")
            failures += 1
            continue
        payload = json.loads(status_path.read_text(encoding="utf-8"))
        status = str(payload.get("status", "unknown"))
        phase = str(payload.get("phase", "unknown"))
        if status != "ok":
            print(
                f"[ci] task failed: {tech}/{case} status={status} phase={phase} "
                f"message={payload.get('message', '')}"
            )
            failures += 1
    return failures


def _sanitize_cadence_def_text(text: str) -> tuple[str, int]:
    pattern = re.compile(r"(?<=\s)VIRTUAL(?=\s+\()")
    sanitized, count = pattern.subn("", text)
    return sanitized, count


def _run_openroad_eval_on_cds_case(
    repo_root: Path, tech: str, case: str, flow_variant: str
) -> None:
    def_path = repo_root / "results" / tech / case / flow_variant / "5_route.def"
    summary_path = repo_root / "logs" / tech / case / flow_variant / "final_summary.txt"
    if not def_path.exists():
        raise FileNotFoundError(f"missing Cadence route DEF for OpenROAD eval: {def_path}")

    original_def = def_path.read_text(encoding="utf-8")
    sanitized_def, virtual_count = _sanitize_cadence_def_text(original_def)
    original_summary = summary_path.read_text(encoding="utf-8") if summary_path.exists() else None

    try:
        if virtual_count:
            def_path.write_text(sanitized_def, encoding="utf-8")
            print(f"[ci] sanitized {virtual_count} VIRTUAL token(s) in {def_path}")
        cmd = [
            "bash",
            "test/common/run_stage.sh",
            tech,
            flow_variant,
            "openroad",
            case,
            "ord-final",
        ]
        _run_subprocess(cmd, env=os.environ.copy(), cwd=repo_root)
    finally:
        if virtual_count:
            def_path.write_text(original_def, encoding="utf-8")
        if original_summary is not None:
            summary_path.write_text(original_summary, encoding="utf-8")


def _run_openroad_eval_on_cds(
    repo_root: Path, tasks: list[tuple[str, str]], flow_variant: str, jobs: int
) -> int:
    failures = 0
    workers = max(1, min(len(tasks), jobs))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        future_map = {
            executor.submit(_run_openroad_eval_on_cds_case, repo_root, tech, case, flow_variant): (tech, case)
            for tech, case in tasks
        }
        for future in concurrent.futures.as_completed(future_map):
            tech, case = future_map[future]
            try:
                future.result()
                print(f"[research] cds-flow OpenROAD eval OK: {tech}/{case}")
            except Exception as exc:
                print(f"[research] cds-flow OpenROAD eval failed: {tech}/{case}: {exc}")
                failures += 1
    return failures


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    if args.detach:
        return _detach_self(args)
    flows = ["ord", "cds"] if args.flow == "all" else [args.flow]
    tasks = _selected_cases(repo_root, flows, args.mode, args.tech, args.case)
    if not tasks:
        print("[ci] No tasks matched the requested filters.")
        return 2

    base_env = os.environ.copy()
    runner = [sys.executable, str(repo_root / "run_experiments.py")]
    compare = [sys.executable, str(repo_root / "util" / "compare_eval_baselines.py")]
    common_args = _common_runner_args(args)

    if not args.compare_only:
        for flow in flows:
            env = base_env.copy()
            env["FLOW_VARIANT"] = _flow_variant(args, flow)
            run_cmd = runner + ["--flow", flow] + common_args
            if args.host_list:
                run_cmd.extend(["--host-list", *args.host_list])
                run_cmd.extend(["--max-jobs-per-host", str(args.max_jobs_per_host)])
            _run_subprocess(run_cmd, env=env, cwd=repo_root)

            status_failures = _check_statuses(repo_root, tasks, flow)
            if status_failures:
                print(f"[ci] {flow} runner completed with {status_failures} failed task(s).")
                return 1

        if args.research_cds_openroad_eval:
            if "cds" not in flows:
                print("[research] --research-cds-openroad-eval ignored because cds flow is not selected.")
            else:
                research_failures = _run_openroad_eval_on_cds(
                    repo_root=repo_root,
                    tasks=tasks,
                    flow_variant=_flow_variant(args, "cds"),
                    jobs=args.jobs or 1,
                )
                if research_failures:
                    print(
                        "[research] cds-flow OpenROAD eval failed for "
                        f"{research_failures} task(s). This does not block CI."
                    )

    compare_cmd = compare + [
        args.mode,
        "--flow",
        args.flow,
        "--variant-base",
        args.variant_base,
        "--repo-root",
        str(repo_root),
    ]
    if args.ord_flow_variant:
        compare_cmd.extend(["--ord-flow-variant", args.ord_flow_variant])
    if args.cds_flow_variant:
        compare_cmd.extend(["--cds-flow-variant", args.cds_flow_variant])
    if args.research_cds_openroad_eval:
        compare_cmd.append("--research-cds-openroad-eval")
    for tech in args.tech:
        compare_cmd.extend(["--tech", tech])
    for case in args.case:
        compare_cmd.extend(["--case", case])
    if not args.sync_missing:
        compare_cmd.append("--no-sync-missing")

    _run_subprocess(compare_cmd, env=base_env, cwd=repo_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
