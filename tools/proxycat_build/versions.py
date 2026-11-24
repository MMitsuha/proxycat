"""Version discovery and ldflags assembly."""

from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Mapping

from .config import (
    BUILD_TAGS,
    MIHOMO_DIR,
    ROOT,
    VERSION_FILE,
    BuildError,
)
from .process import capture, run

DEFAULT_MARKETING_VERSION = "0.1.0"
DEFAULT_BUILD_NUMBER = "1"


def _env(env: Mapping[str, str] | None) -> Mapping[str, str]:
    return os.environ if env is None else env


def marketing_version(
    root: Path = ROOT,
    env: Mapping[str, str] | None = None,
) -> str:
    override = _env(env).get("PROXYCAT_MARKETING_VERSION", "").strip()
    if override:
        return override

    version_file = root / VERSION_FILE.name
    try:
        value = version_file.read_text(encoding="utf-8").strip()
    except OSError:
        value = ""
    return value or DEFAULT_MARKETING_VERSION


def build_number(
    root: Path = ROOT,
    env: Mapping[str, str] | None = None,
) -> str:
    override = _env(env).get("PROXYCAT_BUILD_NUMBER", "").strip()
    if override:
        return override

    try:
        value = capture(["git", "rev-list", "--count", "HEAD"], cwd=root)
    except BuildError:
        value = None
    return value or DEFAULT_BUILD_NUMBER


def project_env(
    *,
    team: str | None = None,
    root: Path = ROOT,
    env: Mapping[str, str] | None = None,
) -> dict[str, str]:
    """Environment for xcodegen; project.yml interpolates these values."""
    result = dict(_env(env))
    result["PROXYCAT_MARKETING_VERSION"] = marketing_version(root, env)
    result["PROXYCAT_BUILD_NUMBER"] = build_number(root, env)
    result["XCODE_DEVELOPMENT_TEAM"] = (
        team if team is not None else result.get("XCODE_DEVELOPMENT_TEAM", "")
    )
    return result


def _git_short(directory: Path, length: int) -> str | None:
    return capture(
        ["git", "-C", str(directory), "rev-parse", f"--short={length}", "HEAD"]
    )


def _git_succeeds(directory: Path, *args: str) -> bool:
    result = run(
        ["git", "-C", str(directory), *args],
        capture=True,
        check=False,
        quiet=True,
    )
    return result.returncode == 0


def resolve_mihomo_version(mihomo_dir: Path = MIHOMO_DIR) -> str:
    short = _git_short(mihomo_dir, 7)
    if short is None:
        return "unknown"

    exact = capture(
        ["git", "-C", str(mihomo_dir), "describe", "--tags", "--exact-match", "HEAD"]
    )
    if exact:
        return exact
    if _git_succeeds(mihomo_dir, "merge-base", "--is-ancestor", "HEAD", "origin/Meta"):
        return f"meta-{short}"
    if _git_succeeds(mihomo_dir, "merge-base", "--is-ancestor", "HEAD", "origin/Alpha"):
        return f"alpha-{short}"
    return (
        capture(
            ["git", "-C", str(mihomo_dir), "describe", "--tags", "--always"]
        )
        or short
    )


def compose_ldflags(
    *,
    version: str,
    build_time: str,
    wrapper_tag: str,
    mihomo_commit: str,
    wrapper_commit: str,
) -> str:
    return " ".join(
        [
            "-s",
            "-w",
            f"-X 'github.com/metacubex/mihomo/constant.Version={version}'",
            f"-X 'github.com/metacubex/mihomo/constant.BuildTime={build_time}'",
            f"-X 'github.com/proxycat/libmihomo.wrapperBuildTime={build_time}'",
            f"-X 'github.com/proxycat/libmihomo.wrapperBuildTag={wrapper_tag}'",
            f"-X 'github.com/proxycat/libmihomo.mihomoCommit={mihomo_commit}'",
            f"-X 'github.com/proxycat/libmihomo.wrapperCommit={wrapper_commit}'",
        ]
    )


@dataclass(frozen=True, slots=True)
class MihomoBuildInfo:
    version: str
    mihomo_commit: str
    wrapper_commit: str
    build_time: str
    build_tags: str
    wrapper_tag: str
    ldflags: str


def mihomo_build_info(
    *,
    obfuscated: bool,
    root: Path = ROOT,
    mihomo_dir: Path = MIHOMO_DIR,
    build_tags: str = BUILD_TAGS,
    build_time: str | None = None,
) -> MihomoBuildInfo:
    stamp = build_time or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    version = resolve_mihomo_version(mihomo_dir)
    mihomo_commit = _git_short(mihomo_dir, 12) or "unknown"
    wrapper_commit = _git_short(root, 12) or "unknown"
    wrapper_tag = build_tags + (" +public" if obfuscated else "")
    return MihomoBuildInfo(
        version=version,
        mihomo_commit=mihomo_commit,
        wrapper_commit=wrapper_commit,
        build_time=stamp,
        build_tags=build_tags,
        wrapper_tag=wrapper_tag,
        ldflags=compose_ldflags(
            version=version,
            build_time=stamp,
            wrapper_tag=wrapper_tag,
            mihomo_commit=mihomo_commit,
            wrapper_commit=wrapper_commit,
        ),
    )
