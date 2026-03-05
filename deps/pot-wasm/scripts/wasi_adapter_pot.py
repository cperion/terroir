import os
import shlex
import subprocess
from pathlib import Path
from typing import Dict, List, Tuple

POT_TERRA = shlex.split(os.getenv("POT_TERRA", "terra"))
POT_WASI_RUNNER = os.getenv("POT_WASI_RUNNER", "scripts/pot_wasi_runner.t")


def get_name() -> str:
    return "pot-wasm"


def get_version() -> str:
    try:
        result = subprocess.run(
            POT_TERRA + ["-v"],
            encoding="UTF-8",
            capture_output=True,
            check=True,
        )
        first = (result.stdout or result.stderr).splitlines()
        return first[0] if first else "terra"
    except Exception:
        return "unknown"


def get_wasi_versions() -> List[str]:
    return ["wasm32-wasip1"]


def get_wasi_worlds() -> List[str]:
    return ["wasi:cli/command"]


def compute_argv(test_path: str,
                 args_env_dirs: Tuple[List[str], Dict[str, str], List[Tuple[Path, str]]],
                 proposals: List[str],
                 wasi_world: str,
                 wasi_version: str) -> List[str]:
    del proposals
    if wasi_world != "wasi:cli/command":
        raise RuntimeError(f"unsupported world for POT adapter: {wasi_world}")
    if wasi_version != "wasm32-wasip1":
        raise RuntimeError(f"unsupported WASI version for POT adapter: {wasi_version}")

    args, env, dirs = args_env_dirs
    argv: List[str] = []
    argv += POT_TERRA
    argv += [POT_WASI_RUNNER, test_path]

    for k, v in env.items():
        argv += ["--env", f"{k}={v}"]
    for host, guest in dirs:
        argv += ["--dir", f"{host}::{guest}"]

    argv += ["--"]
    argv += args
    return argv
