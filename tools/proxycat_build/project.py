"""xcodegen project generation."""

from __future__ import annotations

import os

from .config import DEFAULT_XCODEGEN, ROOT
from .process import require, run
from .versions import project_env


def generate(*extra_args: str, team: str | None = None) -> None:
    xcodegen_value = os.environ.get("XCODEGEN", DEFAULT_XCODEGEN)
    xcodegen = require(xcodegen_value, hint="install with: brew install xcodegen")

    env = project_env(team=team)
    marketing = env["PROXYCAT_MARKETING_VERSION"]
    build = env["PROXYCAT_BUILD_NUMBER"]
    development_team = env["XCODE_DEVELOPMENT_TEAM"]

    print(f"==> xcodegen (v{marketing} build {build})", flush=True)
    if development_team:
        print(f"==> development team {development_team}", flush=True)
    else:
        print(
            "==> development team unset "
            "(set XCODE_DEVELOPMENT_TEAM to auto-fill signing)",
            flush=True,
        )

    args = [xcodegen, "generate", *extra_args]
    run(args, cwd=ROOT, env=env)
