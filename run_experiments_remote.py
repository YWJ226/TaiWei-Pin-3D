#!/usr/bin/env python3
import os
import re
import shlex
import signal
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

_ACTIVE_PROCS: Dict[int, subprocess.Popen] = {}
_ACTIVE_PROCS_LOCK = threading.Lock()
_ACTIVE_REMOTE_JOBS: Dict[str, Tuple[str, Path]] = {}
_ACTIVE_REMOTE_JOBS_LOCK = threading.Lock()


def _register_active_proc(proc: subprocess.Popen) -> None:
    with _ACTIVE_PROCS_LOCK:
        _ACTIVE_PROCS[proc.pid] = proc


def _unregister_active_proc(proc: subprocess.Popen) -> None:
    with _ACTIVE_PROCS_LOCK:
        _ACTIVE_PROCS.pop(proc.pid, None)


def _register_active_remote_job(job_id: str, host: str, pid_path: Path) -> None:
    with _ACTIVE_REMOTE_JOBS_LOCK:
        _ACTIVE_REMOTE_JOBS[job_id] = (host, pid_path)


def _unregister_active_remote_job(job_id: str) -> None:
    with _ACTIVE_REMOTE_JOBS_LOCK:
        _ACTIVE_REMOTE_JOBS.pop(job_id, None)


def install_signal_handlers() -> None:
    """Install signal handlers so SIGINT/SIGTERM interrupt the launcher."""

    def _handler(signum, frame):
        raise KeyboardInterrupt()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(sig, _handler)
        except Exception:
            pass


def terminate_active_procs(sig: int = signal.SIGTERM) -> None:
    with _ACTIVE_PROCS_LOCK:
        procs = list(_ACTIVE_PROCS.values())
    for proc in procs:
        try:
            if getattr(os, "killpg", None):
                os.killpg(proc.pid, sig)
            else:
                proc.terminate()
        except ProcessLookupError:
            pass
        except Exception:
            try:
                proc.terminate()
            except Exception:
                pass
    if sig == signal.SIGTERM and procs:
        time.sleep(1)
        with _ACTIVE_PROCS_LOCK:
            survivors = list(_ACTIVE_PROCS.values())
        for proc in survivors:
            try:
                if proc.poll() is not None:
                    continue
                if getattr(os, "killpg", None):
                    os.killpg(proc.pid, signal.SIGKILL)
                else:
                    proc.kill()
            except ProcessLookupError:
                pass
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
    _terminate_active_remote_jobs()


def run_command_with_log(
    cmd: Sequence[str],
    log_path: Path,
    cwd: Optional[Path] = None,
    env: Optional[dict] = None,
) -> None:
    """Run a command with stdout/stderr redirected to a log file."""

    log_path.parent.mkdir(parents=True, exist_ok=True)
    preexec = getattr(os, "setsid", None)

    with open(log_path, "w") as log_file:
        proc = subprocess.Popen(
            list(cmd),
            stdout=log_file,
            stderr=subprocess.STDOUT,
            cwd=str(cwd) if cwd else None,
            preexec_fn=preexec,
            env=env,
        )
        _register_active_proc(proc)
        try:
            ret = proc.wait()
            if ret != 0:
                raise subprocess.CalledProcessError(ret, list(cmd))
        except KeyboardInterrupt:
            try:
                if preexec and hasattr(os, "killpg"):
                    os.killpg(proc.pid, signal.SIGTERM)
                else:
                    proc.terminate()
            except Exception:
                pass
            raise
        except Exception:
            try:
                if preexec and hasattr(os, "killpg"):
                    os.killpg(proc.pid, signal.SIGTERM)
                else:
                    proc.terminate()
            except Exception:
                pass
            raise
        finally:
            _unregister_active_proc(proc)


_REMOTE_ENV_SKIP = {
    "_",
    "BASHPID",
    "BASHOPTS",
    "BASH_ARGC",
    "BASH_ARGV",
    "BASH_CMDS",
    "BASH_COMMAND",
    "BASH_EXECUTION_STRING",
    "BASH_LINENO",
    "BASH_SOURCE",
    "BASH_SUBSHELL",
    "BASH_VERSINFO",
    "COMP_WORDBREAKS",
    "DBUS_SESSION_BUS_ADDRESS",
    "DIRSTACK",
    "DISPLAY",
    "ELECTRON_RUN_AS_NODE",
    "EPOCHREALTIME",
    "EPOCHSECONDS",
    "FUNCNAME",
    "GROUPS",
    "HISTCMD",
    "IFS",
    "LANG",
    "LANGUAGE",
    "LC_ALL",
    "LS_COLORS",
    "OLDPWD",
    "PIPESTATUS",
    "PPID",
    "PROMPT_COMMAND",
    "PS0",
    "PS1",
    "PS2",
    "PS4",
    "PWD",
    "RANDOM",
    "SECONDS",
    "SHELLOPTS",
    "SHLVL",
    "SRANDOM",
    "SSH_AGENT_PID",
    "SSH_AUTH_SOCK",
    "SSH_CLIENT",
    "SSH_CONNECTION",
    "SSH_TTY",
    "WAYLAND_DISPLAY",
    "WINDOWID",
    "XAUTHORITY",
    "XDG_CURRENT_DESKTOP",
    "XDG_RUNTIME_DIR",
    "XDG_SESSION_CLASS",
    "XDG_SESSION_ID",
    "XDG_SESSION_TYPE",
    "XMODIFIERS",
}
_REMOTE_ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_REMOTE_ENV_SKIP_PREFIXES = (
    "BASH_FUNC_",
    "LC_",
    "VSCODE_",
)


def _should_forward_env(name: str, value: str) -> bool:
    if not _REMOTE_ENV_NAME_RE.match(name):
        return False
    if name in _REMOTE_ENV_SKIP:
        return False
    for prefix in _REMOTE_ENV_SKIP_PREFIXES:
        if name.startswith(prefix):
            return False
    if "\0" in value or "\n" in value:
        return False
    return True


def _ssh_client_env() -> dict:
    env = os.environ.copy()
    for name in list(env):
        if name in {
            "DBUS_SESSION_BUS_ADDRESS",
            "DISPLAY",
            "LANG",
            "LANGUAGE",
            "LC_ALL",
            "WAYLAND_DISPLAY",
            "XAUTHORITY",
        }:
            env.pop(name, None)
            continue
        if name.startswith("LC_"):
            env.pop(name, None)
    return env


def _remote_export_lines() -> list[str]:
    lines = []
    for name in sorted(os.environ):
        value = os.environ.get(name, "")
        if not _should_forward_env(name, value):
            continue
        lines.append(f"export {name}={shlex.quote(value)}")
    return lines


@dataclass(frozen=True)
class RemoteLaunch:
    job_id: str
    stage: str
    wrapper_path: Path
    state_path: Path
    rc_path: Path
    pid_path: Path
    phase_path: Path


@dataclass(frozen=True)
class RemoteLaunchSnapshot:
    launch: RemoteLaunch
    state: str
    phase: str
    rc: Optional[int]
    pid: Optional[int]
    pid_alive: Optional[bool]


def _new_remote_launch(dispatch_dir: Path, stage: str) -> RemoteLaunch:
    stamp = int(time.time() * 1000)
    job_id = f"{stage}.{os.getpid()}.{stamp}"
    dispatch_dir.mkdir(parents=True, exist_ok=True)
    return RemoteLaunch(
        job_id=job_id,
        stage=stage,
        wrapper_path=dispatch_dir / f"{job_id}.wrapper.sh",
        state_path=dispatch_dir / f"{job_id}.state",
        rc_path=dispatch_dir / f"{job_id}.rc",
        pid_path=dispatch_dir / f"{job_id}.pid",
        phase_path=dispatch_dir / f"{job_id}.phase",
    )


def _launch_from_job_id(dispatch_dir: Path, job_id: str) -> RemoteLaunch:
    stage = job_id.split(".", 1)[0]
    return RemoteLaunch(
        job_id=job_id,
        stage=stage,
        wrapper_path=dispatch_dir / f"{job_id}.wrapper.sh",
        state_path=dispatch_dir / f"{job_id}.state",
        rc_path=dispatch_dir / f"{job_id}.rc",
        pid_path=dispatch_dir / f"{job_id}.pid",
        phase_path=dispatch_dir / f"{job_id}.phase",
    )


def launch_from_job_id(dispatch_dir: Path, job_id: str) -> RemoteLaunch:
    return _launch_from_job_id(dispatch_dir, job_id)


def list_remote_launches(dispatch_dir: Path,
                         stage: Optional[str] = None) -> List[RemoteLaunch]:
    if not dispatch_dir.exists():
        return []

    pattern = "*.state" if stage is None else f"{stage}.*.state"
    launches: List[RemoteLaunch] = []
    for state_path in sorted(
            dispatch_dir.glob(pattern),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
    ):
        job_id = state_path.stem
        launches.append(_launch_from_job_id(dispatch_dir, job_id))
    return launches


def latest_remote_launch(dispatch_dir: Path,
                         stage: Optional[str] = None) -> Optional[RemoteLaunch]:
    launches = list_remote_launches(dispatch_dir, stage=stage)
    return launches[0] if launches else None


def stage_label_from_script(script_path: Path) -> str:
    return "eval" if script_path.name == "eval.sh" else "run"


def _write_text_file(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def _write_remote_wrapper(
    repo_root: Path,
    script_path: Path,
    log_path: Path,
    launch: RemoteLaunch,
) -> None:
    log_abs = repo_root / log_path
    exports = "\n".join(_remote_export_lines())
    unset_line = (
        "unset DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS "
        "LANG LANGUAGE LC_ALL LC_CTYPE LC_MESSAGES "
        "SSH_AGENT_PID SSH_AUTH_SOCK SSH_CLIENT SSH_CONNECTION SSH_TTY "
        "WINDOWID XDG_RUNTIME_DIR XDG_SESSION_ID XDG_SESSION_CLASS "
        "XDG_SESSION_TYPE XDG_CURRENT_DESKTOP XMODIFIERS "
        "VSCODE_AGENT_FOLDER VSCODE_CLI_REQUIRE_TOKEN VSCODE_CWD "
        "VSCODE_ESM_ENTRYPOINT VSCODE_HANDLES_SIGPIPE "
        "VSCODE_HANDLES_UNCAUGHT_ERRORS VSCODE_IPC_HOOK_CLI "
        "VSCODE_NLS_CONFIG ELECTRON_RUN_AS_NODE"
    )
    wrapper = f"""#!/usr/bin/env bash
set -uo pipefail

write_state() {{
  printf '%s\\n' "$1" > {shlex.quote(str(launch.state_path))}
}}

write_rc() {{
  printf '%s\\n' "$1" > {shlex.quote(str(launch.rc_path))}
}}

child_pid=""
on_term() {{
  if [[ -n "$child_pid" ]]; then
    kill "$child_pid" >/dev/null 2>&1 || true
  fi
  write_rc 143
  write_state failed
  exit 143
}}

trap on_term HUP INT TERM

printf '%s\\n' "$$" > {shlex.quote(str(launch.pid_path))}
write_state starting

mkdir -p {shlex.quote(str(log_abs.parent))}
exec >>{shlex.quote(str(log_abs))} 2>&1

{exports}
{unset_line}

cd {shlex.quote(str(repo_root))} || {{
  echo "[launcher] failed to cd into repo root"
  write_rc 1
  write_state failed
  exit 1
}}

echo "[launcher] submit_mode=remote_detached host=$(hostname) stage={launch.stage} pwd=$PWD"
echo "[launcher] env DISPLAY=${{DISPLAY:-}} XAUTHORITY=${{XAUTHORITY:-}} XDG_RUNTIME_DIR=${{XDG_RUNTIME_DIR:-}} LC_ALL=${{LC_ALL:-}} LANG=${{LANG:-}}"

write_state running

bash {shlex.quote(str(script_path))} &
child_pid=$!
wait "$child_pid"
rc=$?
child_pid=""

write_rc "$rc"
if [[ "$rc" -eq 0 ]]; then
  write_state ok
else
  write_state failed
fi
exit "$rc"
"""
    _write_text_file(launch.wrapper_path, wrapper)
    os.chmod(launch.wrapper_path, 0o755)


def _write_remote_task_wrapper(
    repo_root: Path,
    run_script: Path,
    eval_script: Path,
    run_log: Path,
    eval_log: Path,
    launch: RemoteLaunch,
    *,
    do_run: bool,
    do_eval: bool,
) -> None:
    run_log_abs = repo_root / run_log
    eval_log_abs = repo_root / eval_log
    exports = "\n".join(_remote_export_lines())
    unset_line = (
        "unset DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS "
        "LANG LANGUAGE LC_ALL LC_CTYPE LC_MESSAGES "
        "SSH_AGENT_PID SSH_AUTH_SOCK SSH_CLIENT SSH_CONNECTION SSH_TTY "
        "WINDOWID XDG_RUNTIME_DIR XDG_SESSION_ID XDG_SESSION_CLASS "
        "XDG_SESSION_TYPE XDG_CURRENT_DESKTOP XMODIFIERS "
        "VSCODE_AGENT_FOLDER VSCODE_CLI_REQUIRE_TOKEN VSCODE_CWD "
        "VSCODE_ESM_ENTRYPOINT VSCODE_HANDLES_SIGPIPE "
        "VSCODE_HANDLES_UNCAUGHT_ERRORS VSCODE_IPC_HOOK_CLI "
        "VSCODE_NLS_CONFIG ELECTRON_RUN_AS_NODE"
    )
    wrapper = f"""#!/usr/bin/env bash
set -uo pipefail

write_state() {{
  printf '%s\\n' "$1" > {shlex.quote(str(launch.state_path))}
}}

write_rc() {{
  printf '%s\\n' "$1" > {shlex.quote(str(launch.rc_path))}
}}

write_phase() {{
  printf '%s\\n' "$1" > {shlex.quote(str(launch.phase_path))}
}}

on_term() {{
  write_rc 143
  write_state failed
  exit 143
}}

trap on_term HUP INT TERM

printf '%s\\n' "$$" > {shlex.quote(str(launch.pid_path))}
write_phase starting
write_state starting

mkdir -p {shlex.quote(str(run_log_abs.parent))}
mkdir -p {shlex.quote(str(eval_log_abs.parent))}

{exports}
{unset_line}

cd {shlex.quote(str(repo_root))} || {{
  write_rc 1
  write_phase starting
  write_state failed
  exit 1
}}

run_stage() {{
  local phase="$1"
  local script_path="$2"
  local log_path="$3"
  write_phase "$phase"
  write_state running
  bash "$script_path" >"$log_path" 2>&1
  return $?
}}

rc=0
"""
    if do_run:
        wrapper += f"""
run_stage run {shlex.quote(str(run_script))} {shlex.quote(str(run_log_abs))}
rc=$?
if [[ "$rc" -ne 0 ]]; then
  write_rc "$rc"
  write_phase run
  write_state failed
  exit "$rc"
fi
"""
    if do_eval:
        wrapper += f"""
run_stage eval {shlex.quote(str(eval_script))} {shlex.quote(str(eval_log_abs))}
rc=$?
if [[ "$rc" -ne 0 ]]; then
  write_rc "$rc"
  write_phase eval
  write_state failed
  exit "$rc"
fi
"""
    wrapper += """
write_rc 0
write_phase done
write_state ok
exit 0
"""
    _write_text_file(launch.wrapper_path, wrapper)
    os.chmod(launch.wrapper_path, 0o755)


def _submit_remote_launch(
    host: str,
    dispatch_dir: Path,
    launch: RemoteLaunch,
    log_abs: Path,
) -> None:
    remote_cmd = (
        f"mkdir -p {shlex.quote(str(dispatch_dir))} {shlex.quote(str(log_abs.parent))}; "
        f"nohup setsid bash {shlex.quote(str(launch.wrapper_path))} >/dev/null 2>&1 </dev/null &"
    )
    remote_shell = f"bash --noprofile --norc -c {shlex.quote(remote_cmd)}"
    run_command_with_log(
        [
            "ssh",
            "-x",
            "-o",
            "BatchMode=yes",
            host,
            remote_shell,
        ],
        log_abs,
        env=_ssh_client_env(),
    )


def _read_text(path: Path) -> str:
    try:
        return path.read_text().strip()
    except FileNotFoundError:
        return ""


def _ssh_run(host: str,
             remote_cmd: str,
             *,
             timeout: int = 10,
             capture_output: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            "ssh",
            "-x",
            "-o",
            "BatchMode=yes",
            host,
            f"bash --noprofile --norc -c {shlex.quote(remote_cmd)}",
        ],
        env=_ssh_client_env(),
        stdout=subprocess.PIPE if capture_output else subprocess.DEVNULL,
        stderr=subprocess.PIPE if capture_output else subprocess.DEVNULL,
        check=False,
        text=True,
        timeout=timeout,
    )


def remote_pid_is_alive(host: str, pid: int) -> Optional[bool]:
    remote_cmd = (
        f"kill -0 -- -{pid} >/dev/null 2>&1 || "
        f"kill -0 {pid} >/dev/null 2>&1"
    )
    try:
        proc = _ssh_run(host, remote_cmd, capture_output=False)
    except Exception:
        return None
    if proc.returncode == 0:
        return True
    if proc.returncode == 1:
        return False
    return None


def snapshot_remote_launch(host: str,
                           launch: RemoteLaunch) -> RemoteLaunchSnapshot:
    state = _read_text(launch.state_path)
    phase = _read_text(launch.phase_path)
    rc_text = _read_text(launch.rc_path)
    pid_text = _read_text(launch.pid_path)

    rc = int(rc_text) if rc_text.lstrip("-").isdigit() else None
    pid = int(pid_text) if pid_text.lstrip("-").isdigit() else None
    pid_alive = remote_pid_is_alive(host, pid) if pid is not None else None

    return RemoteLaunchSnapshot(
        launch=launch,
        state=state,
        phase=phase,
        rc=rc,
        pid=pid,
        pid_alive=pid_alive,
    )


def kill_remote_launch(host: str,
                       launch: RemoteLaunch,
                       *,
                       rc: int = 143) -> bool:
    pid_text = _read_text(launch.pid_path)
    if not pid_text.lstrip("-").isdigit():
        return False

    pid = int(pid_text)
    remote_cmd = (
        f"kill -TERM -- -{pid} >/dev/null 2>&1 || "
        f"kill -TERM {pid} >/dev/null 2>&1 || true; "
        "sleep 1; "
        f"kill -KILL -- -{pid} >/dev/null 2>&1 || "
        f"kill -KILL {pid} >/dev/null 2>&1 || true"
    )
    try:
        _ssh_run(host, remote_cmd, capture_output=False)
    except Exception:
        return False

    launch.rc_path.write_text(f"{rc}\n")
    launch.state_path.write_text("failed\n")
    return True


def _wait_remote_launch(host: str, launch: RemoteLaunch) -> None:
    _register_active_remote_job(launch.job_id, host, launch.pid_path)
    start = time.time()
    try:
        while True:
            state = _read_text(launch.state_path)
            if state == "ok":
                return
            if state == "failed":
                rc_text = _read_text(launch.rc_path)
                rc = int(rc_text) if rc_text.lstrip("-").isdigit() else 1
                raise subprocess.CalledProcessError(
                    rc,
                    [f"remote:{host}", launch.stage, launch.job_id],
                )
            if not state and (time.time() - start) > 30:
                raise subprocess.CalledProcessError(
                    1,
                    [f"remote:{host}", launch.stage, launch.job_id],
                )
            time.sleep(2)
    finally:
        _unregister_active_remote_job(launch.job_id)


def _terminate_active_remote_jobs() -> None:
    with _ACTIVE_REMOTE_JOBS_LOCK:
        jobs = list(_ACTIVE_REMOTE_JOBS.items())
    for _, (host, pid_path) in jobs:
        try:
            if not pid_path.exists():
                continue
            kill_remote_launch(
                host,
                _launch_from_job_id(pid_path.parent, pid_path.stem),
                rc=143,
            )
        except Exception:
            pass


def run_remote_task(
    repo_root: Path,
    host: str,
    dispatch_dir: Path,
    script_path: Path,
    log_path: Path,
) -> None:
    launch = _new_remote_launch(dispatch_dir, stage_label_from_script(script_path))
    _write_remote_wrapper(repo_root, script_path, log_path, launch)
    _submit_remote_launch(host, dispatch_dir, launch, repo_root / log_path)
    _wait_remote_launch(host, launch)


def submit_remote_task(
    repo_root: Path,
    host: str,
    dispatch_dir: Path,
    run_script: Path,
    eval_script: Path,
    run_log: Path,
    eval_log: Path,
    *,
    do_run: bool,
    do_eval: bool,
) -> RemoteLaunch:
    launch = _new_remote_launch(dispatch_dir, "task")
    _write_remote_task_wrapper(
        repo_root=repo_root,
        run_script=run_script,
        eval_script=eval_script,
        run_log=run_log,
        eval_log=eval_log,
        launch=launch,
        do_run=do_run,
        do_eval=do_eval,
    )
    _submit_remote_launch(host, dispatch_dir, launch, repo_root / run_log)
    return launch
