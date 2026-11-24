"""Environment diagnostics for the build toolchain."""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

from .config import (
    BUNDLED_ASSETS_DIR,
    GEO_DIR,
    LIBMIHOMO_DIR,
    MIHOMO_DIR,
    UI_DIR,
    XCFRAMEWORK_PATH,
)


Check = tuple[str, bool, str, bool]  # label, present, detail, required


def _tool(name: str, *, required: bool) -> Check:
    path = shutil.which(name)
    if path:
        return name, True, path, required
    detail = "not found" if required else "optional, not found"
    return name, False, detail, required


def _path(label: str, path: Path, *, required: bool = False, hint: str = "") -> Check:
    if path.exists():
        return label, True, str(path), required
    detail = "missing"
    if hint:
        detail += f" ({hint})"
    return label, False, detail, required


def _assets(path: Path) -> bool:
    if not path.is_dir():
        return False
    return any(child.name != ".gitkeep" for child in path.iterdir())


def doctor() -> int:
    geo_present = _assets(GEO_DIR)
    ui_present = _assets(UI_DIR)
    checks: list[Check] = [
        _tool("python3", required=True),
        _tool("go", required=True),
        _tool("git", required=True),
        _tool("xcodegen", required=True),
        _tool("xcodebuild", required=True),
        _tool("strip", required=True),
        _tool("gomobile", required=True),
        _tool("garble", required=False),
        _tool("uv", required=False),
        _path(
            "mihomo submodule",
            MIHOMO_DIR / "go.mod",
            hint="run: python3 build.py mihomo-init",
        ),
        _path(
            "Libmihomo.xcframework",
            XCFRAMEWORK_PATH,
            hint="run: python3 build.py libmihomo",
        ),
        _path("BundledAssets", BUNDLED_ASSETS_DIR),
        (
            "geo assets",
            geo_present,
            str(GEO_DIR) if geo_present else "empty (run: python3 build.py assets geo)",
            False,
        ),
        (
            "external UI",
            ui_present,
            str(UI_DIR) if ui_present else "empty (run: python3 build.py assets ui)",
            False,
        ),
    ]

    print(f"ProxyCat build doctor ({sys.platform}, Python {sys.version.split()[0]})")
    print(f"repo: {LIBMIHOMO_DIR.parent}")
    failures = 0
    for label, present, detail, required in checks:
        if present:
            marker = "✓"
        elif required:
            marker = "✗"
            failures += 1
        else:
            marker = "·"
        print(f"  {marker} {label:<22} {detail}")

    if failures:
        print(f"\n{failures} required prerequisite(s) missing.")
        return 1
    print("\nAll required build tools look good.")
    return 0
