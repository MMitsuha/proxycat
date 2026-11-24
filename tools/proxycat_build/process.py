"""Subprocess helpers shared by every build command."""

from __future__ import annotations

import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Mapping, Sequence

from .config import BuildError

Command = Sequence[str | os.PathLike[str]]


def resolve_tool(value: str, *, hint: str | None = None) -> str:
    """Resolve a command name or explicit path to an executable path."""
    found = shutil.which(value)
    if found:
        return found

    candidate = Path(value).expanduser()
    if candidate.is_file() and os.access(candidate, os.X_OK):
        return str(candidate)

    message = f"missing tool: {value}"
    if hint:
        message += f"\n  {hint}"
    raise BuildError(message, exit_code=127)


def require(tool: str, *, hint: str | None = None) -> str:
    return resolve_tool(tool, hint=hint)


def run(
    command: Command,
    *,
    cwd: str | os.PathLike[str] | None = None,
    env: Mapping[str, str] | None = None,
    check: bool = True,
    capture: bool = False,
    quiet: bool = False,
) -> subprocess.CompletedProcess[str]:
    argv = [str(part) for part in command]
    if not quiet:
        print("+ " + shlex.join(argv), flush=True)

    try:
        result = subprocess.run(
            argv,
            cwd=str(cwd) if cwd is not None else None,
            env=dict(env) if env is not None else None,
            text=True,
            capture_output=capture,
            check=False,
        )
    except OSError as error:
        raise BuildError(
            f"failed to execute {argv[0]}: {error}", exit_code=127
        ) from error

    if check and result.returncode != 0:
        if capture:
            if result.stdout:
                print(result.stdout, file=sys.stderr, end="")
            if result.stderr:
                print(result.stderr, file=sys.stderr, end="")
        raise BuildError(
            f"command failed with exit code {result.returncode}: {shlex.join(argv)}"
        )

    return result


def capture(
    command: Command,
    *,
    cwd: str | os.PathLike[str] | None = None,
    env: Mapping[str, str] | None = None,
) -> str | None:
    """Run a probe command and return stripped stdout on success."""
    result = run(command, cwd=cwd, env=env, capture=True, check=False, quiet=True)
    if result.returncode != 0:
        return None
    output = result.stdout.strip()
    return output or None
