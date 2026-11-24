"""mihomo submodule lifecycle and gomobile/xcframework builds."""

from __future__ import annotations

import contextlib
import os
import shlex
import tempfile
from pathlib import Path
from typing import Iterator, Mapping

from .config import (
    DEFAULT_GOGARBLE,
    DEFAULT_GOMOBILE,
    FRAMEWORKS_DIR,
    LIBMIHOMO_DIR,
    MIHOMO_DIR,
    ROOT,
    XCFRAMEWORK_PATH,
    BuildError,
)
from .process import capture, require, run
from .versions import mihomo_build_info

_TARGETS = {
    "all": "ios,iossimulator",
    "device": "ios",
    "sim": "iossimulator",
}

_GARBLE_SHIM = """#!/usr/bin/env python3
# Installed by build.py when LIBMIHOMO_OBFUSCATE=1. Only build/install
# are routed through garble; `go env`, `go list`, `go mod`, etc. stay on
# the real toolchain. Garble's own `go` lookups must NOT see this shim,
# so PATH is replaced with LIBMIHOMO_REAL_PATH before exec.
import os
import shlex
import sys

args = sys.argv[1:]
if args and args[0] in ("build", "install"):
    env = os.environ.copy()
    env["PATH"] = env["LIBMIHOMO_REAL_PATH"]
    flags = shlex.split(env.get("LIBMIHOMO_GARBLE_FLAGS", ""))
    garble = env["LIBMIHOMO_GARBLE_BIN"]
    os.execvpe(garble, [garble, *flags, *args], env)

real_go = os.environ["LIBMIHOMO_REAL_GO"]
os.execvpe(real_go, [real_go, *args], os.environ)
"""


def parse_garble_flags(value: str | None) -> list[str]:
    return shlex.split(value or "")


def _git(directory: Path, *args: str, check: bool = True) -> str | None:
    return capture(["git", "-C", str(directory), *args])


def _git_succeeds(directory: Path, *args: str) -> bool:
    result = run(
        ["git", "-C", str(directory), *args],
        capture=True,
        check=False,
        quiet=True,
    )
    return result.returncode == 0


def is_initialized() -> bool:
    return (MIHOMO_DIR / "go.mod").is_file()


def initialize() -> None:
    if not is_initialized():
        print("==> Initializing mihomo submodule", flush=True)
        run(["git", "submodule", "update", "--init", "--recursive", "mihomo"], cwd=ROOT)
        return

    short = _git(MIHOMO_DIR, "rev-parse", "--short=12", "HEAD") or "unknown"
    print(f"==> mihomo submodule already initialized ({short})", flush=True)


def _require_initialized() -> None:
    if is_initialized():
        return
    raise BuildError(
        "mihomo submodule is not initialized\n"
        "  run: python3 build.py mihomo-init",
        exit_code=2,
    )


def _head_short() -> str:
    return _git(MIHOMO_DIR, "rev-parse", "--short=12", "HEAD") or "unknown"


def _head_subject() -> str:
    return _git(MIHOMO_DIR, "log", "-1", "--format=%s") or ""


def upgrade() -> None:
    initialize()
    print("==> Fetching latest mihomo Meta", flush=True)
    run(["git", "-C", str(MIHOMO_DIR), "fetch", "--tags", "--force", "origin"])
    run(["git", "-C", str(MIHOMO_DIR), "checkout", "--detach", "origin/Meta"])
    print(f"    now at {_head_short()} ({_head_subject()})", flush=True)
    build(target="all")
    print(
        "\nMihomo upgraded to origin/Meta. Commit the new pointer with:\n"
        f'  git add mihomo && git commit -m "Bump mihomo to {_head_short()}"',
        flush=True,
    )


def checkout(ref: str) -> None:
    ref = ref.strip()
    if not ref:
        raise BuildError("REF is required", exit_code=2)

    initialize()
    print("==> Fetching mihomo refs from origin", flush=True)
    run(["git", "-C", str(MIHOMO_DIR), "fetch", "--tags", "--force", "origin"])

    print(f"==> Checking out {ref}", flush=True)
    local_commit = _git(MIHOMO_DIR, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}")
    remote_commit = _git(
        MIHOMO_DIR, "rev-parse", "--verify", "--quiet", f"origin/{ref}^{{commit}}"
    )
    if not local_commit and not remote_commit:
        raise BuildError(f"'{ref}' does not resolve to a commit in mihomo/")

    is_remote_branch = _git_succeeds(
        MIHOMO_DIR, "rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{ref}"
    )
    is_tag = _git_succeeds(
        MIHOMO_DIR, "rev-parse", "--verify", "--quiet", f"refs/tags/{ref}"
    )
    target = f"origin/{ref}" if is_remote_branch and not is_tag else ref
    run(["git", "-C", str(MIHOMO_DIR), "checkout", "--detach", target])
    print(f"    now at {_head_short()} ({_head_subject()})", flush=True)

    build(target="all")
    print(
        f"\nMihomo pinned to {ref}. Commit the new pointer with:\n"
        f'  git add mihomo && git commit -m "Pin mihomo to {_head_short()} ({ref})"',
        flush=True,
    )


@contextlib.contextmanager
def _garble_environment(
    base_env: Mapping[str, str],
    *,
    real_go: str,
    garble_bin: str,
    garble_flags: str,
) -> Iterator[dict[str, str]]:
    real_path = base_env.get("PATH", "")
    with tempfile.TemporaryDirectory(prefix="libmihomo-shim-") as shim_dir:
        shim = Path(shim_dir) / "go"
        shim.write_text(_GARBLE_SHIM, encoding="utf-8")
        shim.chmod(0o755)

        env = dict(base_env)
        env["LIBMIHOMO_REAL_GO"] = real_go
        env["LIBMIHOMO_GARBLE_BIN"] = garble_bin
        env["LIBMIHOMO_GARBLE_FLAGS"] = garble_flags
        env["LIBMIHOMO_REAL_PATH"] = real_path
        env["GOGARBLE"] = env.get("GOGARBLE") or DEFAULT_GOGARBLE
        env["PATH"] = os.pathsep.join([shim_dir, real_path]) if real_path else shim_dir
        yield env


def build(
    *,
    target: str = "all",
    obfuscate: bool | None = None,
    garble_flags: str | None = None,
    gomobile: str | None = None,
) -> Path:
    _require_initialized()

    if target not in _TARGETS:
        raise BuildError(
            f"unknown target: {target!r}\n  expected one of: {', '.join(_TARGETS)}",
            exit_code=2,
        )

    go = require("go")
    require("git")
    strip = require("strip")

    if obfuscate is None:
        obfuscate = os.environ.get("LIBMIHOMO_OBFUSCATE", "0") == "1"
    garble_flags = (
        garble_flags
        if garble_flags is not None
        else os.environ.get("LIBMIHOMO_GARBLE_FLAGS", "")
    )
    gomobile_value = gomobile or os.environ.get("GOMOBILE", DEFAULT_GOMOBILE)
    gomobile_bin = require(
        gomobile_value,
        hint="install with: go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init",
    )

    base_env = dict(os.environ)
    run([go, "mod", "tidy"], cwd=LIBMIHOMO_DIR, env=base_env)
    FRAMEWORKS_DIR.mkdir(parents=True, exist_ok=True)

    info = mihomo_build_info(obfuscated=obfuscate)
    target_platforms = _TARGETS[target]

    build_env: Mapping[str, str] = base_env
    garble_bin: str | None = None
    if obfuscate:
        garble_bin = require(
            "garble",
            hint="install with: go install mvdan.cc/garble@master",
        )
        version_line = run(
            [garble_bin, "version"], capture=True, check=False, quiet=True
        )
        first_line = (version_line.stdout or "").splitlines()
        suffix = f" ({first_line[0]})" if first_line else ""
        print(f"==> Obfuscated build via garble{suffix}", flush=True)
        print(f"    GARBLE_FLAGS={garble_flags}", flush=True)
        print(
            f"    GOGARBLE={base_env.get('GOGARBLE') or DEFAULT_GOGARBLE}",
            flush=True,
        )

    print(
        f"==> gomobile bind target={target_platforms} tags={info.build_tags}",
        flush=True,
    )
    print(
        f"    mihomo {info.version} ({info.mihomo_commit}) built {info.build_time}",
        flush=True,
    )

    def bind(env: Mapping[str, str]) -> None:
        run(
            [
                gomobile_bin,
                "bind",
                f"-target={target_platforms}",
                f"-tags={info.build_tags}",
                "-trimpath",
                f"-ldflags={info.ldflags}",
                "-o",
                str(XCFRAMEWORK_PATH),
                "github.com/proxycat/libmihomo",
            ],
            cwd=LIBMIHOMO_DIR,
            env=env,
        )

    if garble_bin is not None:
        with _garble_environment(
            base_env,
            real_go=go,
            garble_bin=garble_bin,
            garble_flags=garble_flags,
        ) as env:
            bind(env)
    else:
        bind(build_env)

    for binary in XCFRAMEWORK_PATH.glob("*/Libmihomo.framework/Libmihomo"):
        run([strip, "-x", str(binary)], check=False, quiet=True)

    size = _tree_size(XCFRAMEWORK_PATH)
    print(f"==> Built {XCFRAMEWORK_PATH}", flush=True)
    print(f"{_human_size(size)}\t{XCFRAMEWORK_PATH}", flush=True)
    return XCFRAMEWORK_PATH


def _tree_size(path: Path) -> int:
    if not path.exists():
        return 0
    return sum(file.stat().st_size for file in path.rglob("*") if file.is_file())


def _human_size(size: int) -> str:
    value = float(size)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if value < 1024 or unit == "TiB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024
    return f"{size} B"
