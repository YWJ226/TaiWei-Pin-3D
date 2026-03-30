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
from typing import Dict, Optional, Sequence, Tuple

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
    )


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
            pgid = pid_path.read_text().strip()
            if not pgid or not pgid.lstrip("-").isdigit():
                continue
            remote_cmd = (
                f"kill -TERM -- -{pgid} >/dev/null 2>&1 || "
                f"kill -TERM {pgid} >/dev/null 2>&1 || true; "
                "sleep 1; "
                f"kill -KILL -- -{pgid} >/dev/null 2>&1 || "
                f"kill -KILL {pgid} >/dev/null 2>&1 || true"
            )
            subprocess.run(
                [
                    "ssh",
                    "-x",
                    "-o",
                    "BatchMode=yes",
                    host,
                    f"bash --noprofile --norc -c {shlex.quote(remote_cmd)}",
                ],
                env=_ssh_client_env(),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=10,
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
