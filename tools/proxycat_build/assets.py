"""Geo database and external-UI asset downloads."""

from __future__ import annotations

import os
import shutil
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

from .config import (
    DEFAULT_GEO_BASE,
    DEFAULT_UI_TARBALL,
    GEO_DIR,
    GEO_FILES,
    UI_DIR,
    BuildError,
)

_USER_AGENT = "proxycat-build/1.0"


def geo_plan(base: str | None = None) -> list[tuple[str, str, str]]:
    """Return ``(remote, local, url)`` tuples for the geo downloads."""
    resolved_base = (base or os.environ.get("GEO_BASE") or DEFAULT_GEO_BASE).rstrip("/")
    return [
        (remote, local, f"{resolved_base}/{remote}") for remote, local in GEO_FILES
    ]


def download(url: str, destination: Path, *, attempts: int = 3) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".tmp")
    request = urllib.request.Request(url, headers={"User-Agent": _USER_AGENT})

    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                expected_header = response.headers.get("Content-Length")
                try:
                    expected = int(expected_header) if expected_header else None
                except ValueError:
                    expected = None
                received = 0
                with temporary.open("wb") as handle:
                    while True:
                        chunk = response.read(1024 * 1024)
                        if not chunk:
                            break
                        handle.write(chunk)
                        received += len(chunk)
                if expected is not None and received != expected:
                    raise BuildError(
                        f"incomplete download for {url}: "
                        f"got {received} of {expected} bytes"
                    )
            os.replace(temporary, destination)
            return
        except (urllib.error.URLError, OSError, BuildError) as error:
            last_error = error
            temporary.unlink(missing_ok=True)
            if attempt < attempts:
                print(
                    f"  ! {destination.name}: {error}; retrying ({attempt}/{attempts})",
                    file=sys.stderr,
                    flush=True,
                )
                time.sleep(1)

    raise BuildError(f"download failed: {url}\n  {last_error}")


def fetch_geo() -> None:
    GEO_DIR.mkdir(parents=True, exist_ok=True)
    for remote, local, url in geo_plan():
        if remote == local:
            print(f"  ↓ {local}", flush=True)
        else:
            print(f"  ↓ {local} (from {remote})", flush=True)
        download(url, GEO_DIR / local)
    print(f"  ✓ geo databases → {GEO_DIR}", flush=True)


def _validate_tar_members(archive: tarfile.TarFile, destination: Path) -> None:
    root = destination.resolve()
    for member in archive.getmembers():
        if not (member.isfile() or member.isdir()):
            raise BuildError(
                f"unsupported archive entry (links/devices are rejected): {member.name}"
            )
        target = (root / member.name).resolve()
        if target != root and root not in target.parents:
            raise BuildError(f"unsafe archive path: {member.name}")


def _extract_tarball(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    try:
        with tarfile.open(archive, "r:gz") as tar:
            _validate_tar_members(tar, destination)
            if sys.version_info >= (3, 12):
                tar.extractall(destination, filter="data")
            else:  # pragma: no cover - macOS ships a modern Python
                tar.extractall(destination)
    except (tarfile.TarError, OSError) as error:
        raise BuildError(f"could not extract {archive.name}: {error}") from error


def _clear_directory(destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for child in destination.iterdir():
        if child.name == ".gitkeep":
            continue
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink()


def _sync_directory(destination: Path, source: Path) -> None:
    _clear_directory(destination)
    for child in source.iterdir():
        target = destination / child.name
        if child.is_dir() and not child.is_symlink():
            shutil.copytree(child, target, symlinks=True)
        else:
            shutil.copy2(child, target, follow_symlinks=False)


def fetch_ui() -> None:
    UI_DIR.mkdir(parents=True, exist_ok=True)
    url = os.environ.get("UI_TARBALL") or DEFAULT_UI_TARBALL

    print("  ↓ metacubexd", flush=True)
    with tempfile.TemporaryDirectory(prefix="proxycat-ui-") as tmp:
        temp_root = Path(tmp)
        archive = temp_root / "ui.tgz"
        download(url, archive)
        extracted = temp_root / "extracted"
        _extract_tarball(archive, extracted)

        entries = list(extracted.iterdir())
        if len(entries) == 1 and entries[0].is_dir():
            source = entries[0]
        else:
            source = extracted
        _sync_directory(UI_DIR, source)
    print(f"  ✓ external UI → {UI_DIR}", flush=True)


def fetch(kind: str = "all") -> None:
    if kind == "geo":
        fetch_geo()
    elif kind == "ui":
        fetch_ui()
    elif kind == "all":
        fetch_geo()
        fetch_ui()
    else:
        raise BuildError(f"unknown asset kind: {kind!r}", exit_code=2)


def clean() -> None:
    for directory in (GEO_DIR, UI_DIR):
        _clear_directory(directory)
    print(f"✓ {GEO_DIR} and {UI_DIR} cleared", flush=True)
