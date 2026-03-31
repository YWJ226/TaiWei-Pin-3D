#!/usr/bin/env python3
import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import time
from concurrent.futures import FIRST_COMPLETED, ProcessPoolExecutor, ThreadPoolExecutor, wait
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

import run_experiments_remote as remote


# ==============================================================================
# Experiment definitions
# ==============================================================================


@dataclass(frozen=True)
class RunConfig:
    flow: str  # "ord" or "cds"
    tech: str
    case: str
    repo_root: Path  # local repo root (where test/ exists)
    do_run: bool
    do_eval: bool
    host: Optional[str] = None
    host_slot: int = 0

def _log_paths(flow: str, tech: str, case: str) -> Tuple[Path, Path]:
    base = Path(f"run_logs/{tech}/{flow}")
    run_log = base / "run" / f"{case}_run.log"
    eval_log = base / "eval" / f"{case}_eval.log"
    return run_log, eval_log


def _status_dir(repo_root: Path) -> Path:
    return repo_root / "run_logs" / "status"


def _status_path(cfg: RunConfig) -> Path:
    return _status_dir(cfg.repo_root) / f"{cfg.flow}__{cfg.tech}__{cfg.case}.json"


def _dispatch_dir(cfg: RunConfig) -> Path:
    return cfg.repo_root / "run_logs" / "dispatch" / cfg.flow / cfg.tech / cfg.case


def _script_paths(repo_root: Path, flow: str, tech: str,
                  case: str) -> Tuple[Path, Path]:
    run_script = repo_root / "test" / tech / case / flow / "run.sh"
    eval_script = repo_root / "test" / tech / case / flow / "eval.sh"
    return run_script, eval_script


def discover_available_tasks(repo_root: Path) -> List[Tuple[str, str, str]]:
    test_root = repo_root / "test"
    if not test_root.exists():
        return []

    found = set()
    for run_script in sorted(test_root.glob("*/*/*/run.sh")):
        rel = run_script.relative_to(test_root)
        if len(rel.parts) != 4:
            continue
        tech, case, flow, _ = rel.parts
        if flow not in ("ord", "cds"):
            continue
        found.add((flow, tech, case))

    return sorted(found, key=lambda item: (item[0], item[1], item[2]))


def _load_env_from_script(env_script: Path) -> None:
    if not env_script.exists():
        return
    cmd = [
        "bash",
        "-lc",
        f'export FLOW_ENV_QUIET=1; source "{env_script}"; env -0',
    ]
    proc = subprocess.run(cmd,
                          stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE,
                          check=True)
    for entry in proc.stdout.split(b"\0"):
        if not entry:
            continue
        key, _, value = entry.partition(b"=")
        os.environ[key.decode(errors="ignore")] = value.decode(errors="ignore")


def parse_host_list(values: Sequence[str]) -> List[str]:
    if not values:
        return []

    text = " ".join(values).strip()
    if text.startswith("{") and text.endswith("}"):
        text = text[1:-1]
    text = text.replace(",", " ")
    return _dedup_keep_order([item.strip() for item in text.split() if item.strip()])


def _target_label(cfg: RunConfig, local_host: Optional[str] = None) -> str:
    if cfg.host:
        if cfg.host_slot > 0:
            return f"{cfg.host}[{cfg.host_slot}]"
        return cfg.host
    return local_host if local_host else "localhost"


def write_task_status(
    cfg: RunConfig,
    status: str,
    phase: str,
    message: str = "",
    pid: Optional[int] = None,
    local_host: Optional[str] = None,
    extra: Optional[Dict[str, object]] = None,
    target_host: Optional[str] = None,
) -> None:
    status_path = _status_path(cfg)
    status_path.parent.mkdir(parents=True, exist_ok=True)
    run_log, eval_log = _log_paths(cfg.flow, cfg.tech, cfg.case)
    payload = {
        "flow": cfg.flow,
        "tech": cfg.tech,
        "case": cfg.case,
        "target_host": target_host if target_host else _target_label(
            cfg, local_host),
        "pwd": str(cfg.repo_root),
        "launcher_pwd": os.getcwd(),
        "status": status,
        "phase": phase,
        "message": message,
        "pid": pid,
        "updated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "run_log": str(run_log),
        "eval_log": str(eval_log),
    }
    if extra:
        payload.update(extra)
    tmp_path = status_path.with_suffix(".json.tmp")
    with open(tmp_path, "w") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
    os.replace(tmp_path, status_path)


def read_task_status(cfg: RunConfig) -> Dict[str, object]:
    status_path = _status_path(cfg)
    if not status_path.exists():
        return {
            "flow": cfg.flow,
            "tech": cfg.tech,
            "case": cfg.case,
            "target_host": _target_label(cfg),
            "status": "unknown",
            "phase": "unknown",
            "message": "",
        }
    with open(status_path, "r") as fh:
        return json.load(fh)


def init_task_statuses(tasks: Sequence[RunConfig]) -> None:
    for task in tasks:
        write_task_status(task, "queued", "queued")


def mark_interrupted_tasks(tasks: Sequence[RunConfig]) -> None:
    for task in tasks:
        payload = read_task_status(task)
        status = str(payload.get("status", "unknown"))
        if status in ("ok", "failed"):
            continue
        phase = str(payload.get("phase", "unknown"))
        write_task_status(
            task,
            status="failed",
            phase=phase,
            message="[MAIN] interrupted and terminated by launcher",
        )


def print_status_summary(tasks: Sequence[RunConfig]) -> None:
    payloads = [read_task_status(task) for task in tasks]
    print_status_summary_from_payloads(payloads)


def print_status_summary_from_payloads(payloads: Sequence[Dict[str, object]]
                                       ) -> None:
    counts: Dict[str, int] = {}
    active = []
    for payload in payloads:
        status = str(payload.get("status", "unknown"))
        counts[status] = counts.get(status, 0) + 1
        if status == "running":
            active.append(payload)

    ordered = []
    for key in ("queued", "running", "ok", "failed", "unknown"):
        if counts.get(key):
            ordered.append(f"{key}={counts[key]}")
    print(f"[STATUS] {' '.join(ordered)}")
    for payload in active[:12]:
        print(
            "[STATUS] "
            f"{payload.get('target_host')} "
            f"{payload.get('flow')}/{payload.get('tech')}/{payload.get('case')} "
            f"phase={payload.get('phase')} "
            f"updated_at={payload.get('updated_at')}"
        )


def print_status_details(payloads: Sequence[Dict[str, object]]) -> None:
    for payload in payloads:
        parts = [
            f"{payload.get('target_host', 'localhost')}",
            f"{payload.get('flow')}/{payload.get('tech')}/{payload.get('case')}",
            f"status={payload.get('status')}",
            f"phase={payload.get('phase')}",
        ]
        if payload.get("dispatch_job_id"):
            parts.append(
                f"dispatch={payload.get('dispatch_stage')}:{payload.get('dispatch_state')}"
            )
        if payload.get("dispatch_pid") is not None:
            parts.append(f"dispatch_pid={payload.get('dispatch_pid')}")
        if payload.get("dispatch_pid_alive") is not None:
            parts.append(
                f"dispatch_pid_alive={payload.get('dispatch_pid_alive')}")
        print("[TASK] " + " ".join(parts))


def _status_host_from_payload(payload: Dict[str, object]) -> Optional[str]:
    raw = str(payload.get("target_host", "")).strip()
    if not raw:
        return None
    return raw.split("[", 1)[0]


def _status_has_terminal_state(payload: Dict[str, object]) -> bool:
    return str(payload.get("status", "unknown")) in ("ok", "failed")


def _local_pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except Exception:
        return False


def _dispatch_metadata(cfg: RunConfig,
                       dispatch_stage: str,
                       snapshot: remote.RemoteLaunchSnapshot) -> Dict[str, object]:
    return {
        "dispatch_dir": str(_dispatch_dir(cfg)),
        "dispatch_job_id": snapshot.launch.job_id,
        "dispatch_stage": dispatch_stage,
        "dispatch_state": snapshot.state,
        "dispatch_rc": snapshot.rc,
        "dispatch_pid": snapshot.pid,
        "dispatch_pid_alive": snapshot.pid_alive,
    }


def sync_task_status(cfg: RunConfig) -> Dict[str, object]:
    payload = read_task_status(cfg)
    host = _status_host_from_payload(payload)
    target_host = str(payload.get("target_host", "")).strip() or None
    phase = str(payload.get("phase", "unknown"))
    status = str(payload.get("status", "unknown"))

    if host:
        dispatch_dir = _dispatch_dir(cfg)
        preferred_stage = phase if phase in ("run", "eval") else None
        launch = None
        if preferred_stage:
            launch = remote.latest_remote_launch(dispatch_dir,
                                                stage=preferred_stage)
        if launch is None:
            launch = remote.latest_remote_launch(dispatch_dir, stage="eval")
        if launch is None:
            launch = remote.latest_remote_launch(dispatch_dir, stage="run")

        if launch is not None:
            snapshot = remote.snapshot_remote_launch(host, launch)
            extra = _dispatch_metadata(cfg, launch.stage, snapshot)
            if snapshot.state in ("starting", "running"):
                if snapshot.pid_alive is False:
                    write_task_status(
                        cfg,
                        status="failed",
                        phase=launch.stage,
                        message=
                        "[monitor] dispatch says running, but remote pid is gone",
                        pid=int(payload.get("pid"))
                        if str(payload.get("pid", "")).isdigit() else None,
                        extra=extra,
                        target_host=target_host,
                    )
                else:
                    write_task_status(
                        cfg,
                        status="running",
                        phase=launch.stage,
                        message=str(payload.get("message", "")),
                        pid=int(payload.get("pid"))
                        if str(payload.get("pid", "")).isdigit() else None,
                        extra=extra,
                        target_host=target_host,
                    )
            elif snapshot.state == "failed":
                msg = str(payload.get("message", ""))
                if not msg or "[manual]" not in msg:
                    msg = f"[monitor] remote {launch.stage} failed"
                write_task_status(
                    cfg,
                    status="failed",
                    phase=launch.stage,
                    message=msg,
                    pid=int(payload.get("pid"))
                    if str(payload.get("pid", "")).isdigit() else None,
                    extra=extra,
                    target_host=target_host,
                )
            elif snapshot.state == "ok":
                if launch.stage == "eval" or not cfg.do_eval:
                    write_task_status(
                        cfg,
                        status="ok",
                        phase="done",
                        message=str(payload.get("message", "")),
                        pid=int(payload.get("pid"))
                        if str(payload.get("pid", "")).isdigit() else None,
                        extra=extra,
                        target_host=target_host,
                    )
                else:
                    write_task_status(
                        cfg,
                        status="running",
                        phase="eval" if cfg.do_eval else "done",
                        message=
                        "[monitor] run stage completed, waiting for eval dispatch",
                        pid=int(payload.get("pid"))
                        if str(payload.get("pid", "")).isdigit() else None,
                        extra=extra,
                        target_host=target_host,
                    )
            return read_task_status(cfg)

    pid_text = str(payload.get("pid", "")).strip()
    if status in ("running", "queued") and pid_text.isdigit():
        pid = int(pid_text)
        if not _local_pid_alive(pid):
            write_task_status(
                cfg,
                status="failed",
                phase=phase,
                message="[monitor] local launcher pid is gone",
                pid=pid,
                target_host=target_host,
            )
            return read_task_status(cfg)

    return payload


def collect_task_statuses(tasks: Sequence[RunConfig],
                          *,
                          sync: bool) -> List[Dict[str, object]]:
    if sync:
        return [sync_task_status(task) for task in tasks]
    return [read_task_status(task) for task in tasks]


def _kill_local_task(payload: Dict[str, object]) -> bool:
    pid_text = str(payload.get("pid", "")).strip()
    if not pid_text.isdigit():
        return False
    pid = int(pid_text)
    if not _local_pid_alive(pid):
        return False
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return False
    except Exception:
        return False
    time.sleep(1)
    if _local_pid_alive(pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except Exception:
            pass
    return True


def kill_task(cfg: RunConfig) -> bool:
    payload = sync_task_status(cfg)
    if _status_has_terminal_state(payload):
        return False

    host = _status_host_from_payload(payload)
    target_host = str(payload.get("target_host", "")).strip() or None
    killed = False
    dispatch_dir = _dispatch_dir(cfg)
    launch = None
    if host:
        stage = str(payload.get("dispatch_stage", "")).strip() or None
        launch = remote.latest_remote_launch(dispatch_dir, stage=stage)
        if launch is None:
            launch = remote.latest_remote_launch(dispatch_dir, stage="eval")
        if launch is None:
            launch = remote.latest_remote_launch(dispatch_dir, stage="run")

    if host and launch is not None:
        killed = remote.kill_remote_launch(host, launch, rc=143)
    else:
        killed = _kill_local_task(payload)

    write_task_status(
        cfg,
        status="failed",
        phase=str(payload.get("phase", "unknown")),
        message="[manual] terminated by run_experiments.py --kill-running",
        pid=int(payload.get("pid"))
        if str(payload.get("pid", "")).isdigit() else None,
        extra={
            "dispatch_dir": str(_dispatch_dir(cfg)),
            "manual_kill": True,
            "manual_kill_ok": killed,
        },
        target_host=target_host,
    )
    return killed


def _run_task_script(
    cfg: RunConfig,
    script_path: Path,
    log_path: Path,
):
    if cfg.host:
        remote.run_remote_task(
            repo_root=cfg.repo_root,
            host=cfg.host,
            dispatch_dir=_dispatch_dir(cfg),
            script_path=script_path,
            log_path=log_path,
        )
        return

    remote.run_command_with_log(
        ["bash", str(script_path)],
        log_path,
        cwd=cfg.repo_root,
        env=os.environ.copy(),
    )


def run_one(cfg: RunConfig) -> str:
    """
    Execute one (flow, tech, case) task.
    - cds: run.sh + eval.sh locally
    - ord: run.sh + eval.sh locally
    """
    remote.install_signal_handlers()
    _load_env_from_script(cfg.repo_root / "env.sh")

    pid = os.getpid()
    local_host = socket.gethostname()
    exec_host = _target_label(cfg, local_host)
    write_task_status(cfg,
                      status="running",
                      phase="starting",
                      pid=pid,
                      local_host=local_host)

    run_log, eval_log = _log_paths(cfg.flow, cfg.tech, cfg.case)
    # 兼容 Python 3.6: unlink(missing_ok=True) 改为 try-except
    if cfg.do_run:
        try:
            run_log.unlink()
        except FileNotFoundError:
            pass
    if cfg.do_eval:
        try:
            eval_log.unlink()
        except FileNotFoundError:
            pass

    run_script, eval_script = _script_paths(cfg.repo_root, cfg.flow, cfg.tech,
                                            cfg.case)

    mode = "run+eval"
    if cfg.do_run and not cfg.do_eval:
        mode = "run-only"
    elif cfg.do_eval and not cfg.do_run:
        mode = "eval-only"
    print(
        f"[{pid}] Start {cfg.flow.upper()} tech={cfg.tech} case={cfg.case} mode={mode} on host={exec_host}"
    )

    # --- run.sh (local) ---
    if cfg.do_run:
        if not run_script.exists():
            msg = f"[{pid}] ERROR: run.sh not found: {run_script}"
            write_task_status(cfg,
                              status="failed",
                              phase="run",
                              message=msg,
                              pid=pid,
                              local_host=local_host)
            print(msg)
            return msg

        try:
            write_task_status(cfg,
                              status="running",
                              phase="run",
                              pid=pid,
                              local_host=local_host)
            _run_task_script(cfg, run_script, run_log)
        except subprocess.CalledProcessError:
            msg = f"[{pid}] ERROR: run.sh failed ({cfg.flow}/{cfg.tech}/{cfg.case}) on host={exec_host}. See {run_log}"
            write_task_status(cfg,
                              status="failed",
                              phase="run",
                              message=msg,
                              pid=pid,
                              local_host=local_host)
            print(msg)
            return msg

    # --- eval.sh ---
    if not cfg.do_eval:
        ok = f"[{pid}] OK: {cfg.flow}/{cfg.tech}/{cfg.case}"
        write_task_status(cfg,
                          status="ok",
                          phase="done",
                          message=ok,
                          pid=pid,
                          local_host=local_host)
        print(ok)
        return ok
    if cfg.flow == "cds":
        if not eval_script.exists():
            msg = f"[{pid}] ERROR: eval.sh not found: {eval_script}"
            write_task_status(cfg,
                              status="failed",
                              phase="eval",
                              message=msg,
                              pid=pid,
                              local_host=local_host)
            print(msg)
            return msg
        try:
            write_task_status(cfg,
                              status="running",
                              phase="eval",
                              pid=pid,
                              local_host=local_host)
            _run_task_script(cfg, eval_script, eval_log)
        except subprocess.CalledProcessError:
            msg = f"[{pid}] ERROR: eval.sh failed ({cfg.flow}/{cfg.tech}/{cfg.case}) on host={exec_host}. See {eval_log}"
            write_task_status(cfg,
                              status="failed",
                              phase="eval",
                              message=msg,
                              pid=pid,
                              local_host=local_host)
            print(msg)
            return msg

    elif cfg.flow == "ord":
        if not eval_script.exists():
            msg = f"[{pid}] ERROR: eval.sh not found: {eval_script}"
            write_task_status(cfg,
                              status="failed",
                              phase="eval",
                              message=msg,
                              pid=pid,
                              local_host=local_host)
            print(msg)
            return msg
        try:
            write_task_status(cfg,
                              status="running",
                              phase="eval",
                              pid=pid,
                              local_host=local_host)
            _run_task_script(cfg, eval_script, eval_log)
        except subprocess.CalledProcessError:
            msg = f"[{pid}] ERROR: eval.sh failed ({cfg.flow}/{cfg.tech}/{cfg.case}) on host={exec_host}. See {eval_log}"
            write_task_status(cfg,
                              status="failed",
                              phase="eval",
                              message=msg,
                              pid=pid,
                              local_host=local_host)
            print(msg)
            return msg
    else:
        msg = f"[{pid}] ERROR: unknown flow={cfg.flow}"
        write_task_status(cfg,
                          status="failed",
                          phase="eval",
                          message=msg,
                          pid=pid,
                          local_host=local_host)
        return msg

    ok = f"[{pid}] OK: {cfg.flow}/{cfg.tech}/{cfg.case} host={exec_host}"
    write_task_status(cfg,
                      status="ok",
                      phase="done",
                      message=ok,
                      pid=pid,
                      local_host=local_host)
    print(ok)
    return ok


# ==============================================================================
# CLI + orchestration
# ==============================================================================


def _dedup_keep_order(xs: Iterable[str]) -> List[str]:
    seen = set()
    out = []
    for x in xs:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


def build_tasks(
    flows: List[str],
    techs: List[str],
    cases: List[str],
    repo_root: Path,
    do_run: bool,
    do_eval: bool,
) -> List[RunConfig]:
    flow_set = set(flows)
    tech_set = set(techs)
    case_set = set(cases)
    tasks: List[RunConfig] = []
    for flow, tech, case in discover_available_tasks(repo_root):
        if flow not in flow_set or tech not in tech_set or case not in case_set:
            continue

        run_script, eval_script = _script_paths(repo_root, flow, tech, case)
        if do_run and not run_script.exists():
            continue
        if do_eval and not eval_script.exists():
            continue

        tasks.append(
            RunConfig(
                flow=flow,
                tech=tech,
                case=case,
                repo_root=repo_root,
                do_run=do_run,
                do_eval=do_eval,
            ))
    return tasks


def shard_tasks(tasks: Sequence[RunConfig], num_shards: int,
                shard_index: int) -> List[RunConfig]:
    if num_shards <= 1:
        return list(tasks)
    return [task for idx, task in enumerate(tasks) if idx % num_shards == shard_index]


def assign_hosts(tasks: Sequence[RunConfig], hosts: Sequence[str],
                 max_jobs_per_host: int) -> List[RunConfig]:
    if not hosts:
        return list(tasks)
    slots = [(host, slot) for host in hosts for slot in range(max_jobs_per_host)]
    out: List[RunConfig] = []
    for idx, task in enumerate(tasks):
        host, host_slot = slots[idx % len(slots)]
        out.append(replace(task, host=host, host_slot=host_slot))
    return out


def build_host_batches(
    tasks: Sequence[RunConfig], ) -> List[Tuple[str, int, List[RunConfig]]]:
    batches = {}
    for task in tasks:
        host = task.host
        if not host:
            continue
        batches.setdefault((host, task.host_slot), []).append(task)
    return [(host, slot, batches[(host, slot)]) for host, slot in batches]


def run_host_batch(host: str, host_slot: int,
                   tasks: Sequence[RunConfig]) -> List[str]:
    results = []
    for task in tasks:
        results.append(run_one(task))
    return results


def parse_args(default_repo_root: Optional[str], ) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=
        "Run ORFS experiments (ORD/CDS) in parallel with per-task logs.")
    p.add_argument(
        "--flow",
        choices=["ord", "cds", "all"],
        default="all",
        help="Which flow to run (default: all).",
    )
    p.add_argument(
        "--tech",
        action="append",
        default=[],
        help="Tech name. Repeatable. Default: run all preset techs.",
    )
    p.add_argument(
        "--case",
        action="append",
        default=[],
        help="Case/design name. Repeatable. Default: run all preset cases.",
    )
    p.add_argument(
        "--jobs",
        type=int,
        default=9,
        help="Parallel workers for local mode.",
    )
    p.add_argument(
        "--host-list",
        "--host_list",
        dest="host_list",
        nargs="+",
        default=None,
        help="Dispatch tasks over SSH using an inline host list only.",
    )
    p.add_argument(
        "--max-jobs-per-host",
        type=int,
        default=1,
        help="Maximum concurrent task queues per host in --host-list mode.",
    )
    p.add_argument(
        "--status-interval",
        type=int,
        default=30,
        help="Seconds between status summary prints.",
    )
    action_group = p.add_mutually_exclusive_group()
    action_group.add_argument(
        "--list",
        action="store_true",
        help="List matched tasks and exit.",
    )
    action_group.add_argument(
        "--show-status",
        action="store_true",
        help="Sync and print current status of matched tasks, then exit.",
    )
    action_group.add_argument(
        "--monitor",
        action="store_true",
        help="Sync and monitor matched tasks until all are terminal.",
    )
    action_group.add_argument(
        "--kill-running",
        action="store_true",
        help="Terminate matched running or queued tasks, then exit.",
    )
    p.add_argument(
        "--num-shards",
        type=int,
        default=1,
        help="Split matched tasks into N deterministic shards.",
    )
    p.add_argument(
        "--shard-index",
        type=int,
        default=0,
        help="0-based shard index to run.",
    )
    stage_group = p.add_mutually_exclusive_group()
    stage_group.add_argument(
        "--eval-only",
        action="store_true",
        help="Only run eval.sh for each task.",
    )
    stage_group.add_argument(
        "--run-only",
        action="store_true",
        help="Only run run.sh for each task.",
    )

    p.add_argument(
        "--repo-root",
        default=default_repo_root,
        help="Local repo root path (default: env FLOW_HOME or script parent).",
    )
    return p.parse_args()


def main() -> int:
    remote.install_signal_handlers()
    script_root = Path(__file__).resolve().parent
    _load_env_from_script(script_root / "env.sh")

    default_repo_root = os.environ.get("FLOW_HOME", str(script_root))
    args = parse_args(default_repo_root=default_repo_root, )

    repo_root = Path(args.repo_root).resolve() if args.repo_root else Path(
        __file__).resolve().parent

    if args.num_shards < 1:
        print("[MAIN] ERROR: --num-shards must be >= 1", file=sys.stderr)
        return 2
    if args.max_jobs_per_host < 1:
        print("[MAIN] ERROR: --max-jobs-per-host must be >= 1", file=sys.stderr)
        return 2
    if args.status_interval < 1:
        print("[MAIN] ERROR: --status-interval must be >= 1", file=sys.stderr)
        return 2
    if args.shard_index < 0 or args.shard_index >= args.num_shards:
        print("[MAIN] ERROR: --shard-index must satisfy 0 <= shard-index < num-shards",
              file=sys.stderr)
        return 2

    available = discover_available_tasks(repo_root)
    if not available:
        print(f"[MAIN] ERROR: no runnable tasks found under {repo_root / 'test'}",
              file=sys.stderr)
        return 2

    default_techs = _dedup_keep_order([tech for _, tech, _ in available])
    default_cases = _dedup_keep_order([case for _, _, case in available])

    techs = _dedup_keep_order(args.tech) if args.tech else default_techs
    cases = _dedup_keep_order(args.case) if args.case else default_cases

    if args.flow == "all":
        flows = ["ord", "cds"]
    else:
        flows = [args.flow]

    do_run = not args.eval_only
    do_eval = not args.run_only

    tasks = build_tasks(
        flows=flows,
        techs=techs,
        cases=cases,
        repo_root=repo_root,
        do_run=do_run,
        do_eval=do_eval,
    )
    tasks = shard_tasks(tasks, args.num_shards, args.shard_index)

    hosts: List[str] = []
    management_mode = args.show_status or args.monitor or args.kill_running

    if args.host_list and not management_mode:
        hosts = parse_host_list(args.host_list)
        if not hosts:
            print("[MAIN] ERROR: no hosts parsed from --host-list",
                  file=sys.stderr)
            return 2
        tasks = assign_hosts(tasks, hosts, args.max_jobs_per_host)
    elif args.host_list and management_mode:
        print(
            "[MAIN] management mode ignores --host-list and uses existing status/dispatch metadata."
        )

    print(f"[MAIN] repo_root={repo_root}")
    print(f"[MAIN] flows={flows} techs={techs} cases={cases} jobs={args.jobs}")
    print(f"[MAIN] stages: run={do_run} eval={do_eval}")
    print(f"[MAIN] shard={args.shard_index}/{args.num_shards}")
    if hosts:
        print(
            f"[MAIN] host_dispatch=ssh host_count={len(hosts)} max_jobs_per_host={args.max_jobs_per_host}"
        )
    print(
        f"[MAIN] total_tasks={len(tasks)} logs under run_logs/<tech>/<flow>/..."
    )

    if args.list:
        for idx, task in enumerate(tasks):
            if task.host:
                print(
                    f"{idx:03d} {_target_label(task)} {task.flow} {task.tech} {task.case}"
                )
            else:
                print(f"{idx:03d} {task.flow} {task.tech} {task.case}")
        return 0

    if not tasks:
        print("[MAIN] No tasks matched the requested filters.")
        return 0

    if args.show_status:
        payloads = collect_task_statuses(tasks, sync=True)
        print_status_summary_from_payloads(payloads)
        print_status_details(payloads)
        return 0

    if args.monitor:
        while True:
            payloads = collect_task_statuses(tasks, sync=True)
            print_status_summary_from_payloads(payloads)
            print_status_details(payloads)
            if all(_status_has_terminal_state(p) for p in payloads):
                print("[MAIN] Monitor completed: all matched tasks are terminal.")
                return 0
            time.sleep(args.status_interval)

    if args.kill_running:
        payloads = collect_task_statuses(tasks, sync=True)
        print_status_summary_from_payloads(payloads)
        killed = 0
        skipped = 0
        for task, payload in zip(tasks, payloads):
            if _status_has_terminal_state(payload):
                skipped += 1
                continue
            if kill_task(task):
                killed += 1
            else:
                skipped += 1
        payloads = collect_task_statuses(tasks, sync=True)
        print_status_summary_from_payloads(payloads)
        print_status_details(payloads)
        print(f"[MAIN] kill_running: killed={killed} skipped={skipped}")
        return 0

    init_task_statuses(tasks)
    print(f"[MAIN] live status files under {_status_dir(repo_root)}")

    # Run
    if hosts:
        executor: Optional[ThreadPoolExecutor] = None
        fast_shutdown = False
        host_batches = build_host_batches(tasks)
        if not host_batches:
            print(
                "[MAIN] ERROR: host dispatch is enabled but no host batches were built.",
                file=sys.stderr,
            )
            return 2
        try:
            executor = ThreadPoolExecutor(max_workers=len(host_batches))
            futures = [
                executor.submit(run_host_batch, host, host_slot, batch)
                for host, host_slot, batch in host_batches
            ]
            pending = set(futures)
            while pending:
                done, pending = wait(pending,
                                     timeout=args.status_interval,
                                     return_when=FIRST_COMPLETED)
                print_status_summary_from_payloads(
                    collect_task_statuses(tasks, sync=True))
                for fut in done:
                    _ = fut.result()
        except KeyboardInterrupt:
            print("[MAIN] KeyboardInterrupt received, shutting down...")
            remote.terminate_active_procs()
            mark_interrupted_tasks(tasks)
            fast_shutdown = True
            if executor is not None:
                try:
                    executor.shutdown(wait=False, cancel_futures=True)
                except Exception:
                    pass
            return 130
        finally:
            if executor is not None:
                try:
                    executor.shutdown(wait=not fast_shutdown,
                                      cancel_futures=fast_shutdown)
                except Exception:
                    pass
    else:
        executor: Optional[ProcessPoolExecutor] = None
        fast_shutdown = False
        try:
            executor = ProcessPoolExecutor(max_workers=args.jobs)
            futures = [executor.submit(run_one, t) for t in tasks]
            pending = set(futures)
            while pending:
                done, pending = wait(pending,
                                     timeout=args.status_interval,
                                     return_when=FIRST_COMPLETED)
                print_status_summary_from_payloads(
                    collect_task_statuses(tasks, sync=True))
                for fut in done:
                    _ = fut.result()
        except KeyboardInterrupt:
            print("[MAIN] KeyboardInterrupt received, shutting down...")
            remote.terminate_active_procs()
            mark_interrupted_tasks(tasks)
            fast_shutdown = True
            if executor is not None:
                try:
                    executor.shutdown(wait=False, cancel_futures=True)
                except Exception:
                    pass
            return 130
        finally:
            if executor is not None:
                try:
                    executor.shutdown(wait=not fast_shutdown,
                                      cancel_futures=fast_shutdown)
                except Exception:
                    pass

    print("[MAIN] All experiments completed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
