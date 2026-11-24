"""Generated-artifact cleanup."""

from __future__ import annotations

import shutil

from .config import BUILD_DIR, LIBMIHOMO_DIR, XCFRAMEWORK_PATH, XCODEPROJ_PATH
from .process import run


def clean() -> None:
    for path in (XCFRAMEWORK_PATH, XCODEPROJ_PATH, BUILD_DIR):
        if path.is_dir():
            shutil.rmtree(path)
        elif path.exists():
            path.unlink()

    if (LIBMIHOMO_DIR / "go.mod").is_file() and shutil.which("go"):
        run(["go", "clean", "-cache"], cwd=LIBMIHOMO_DIR, check=False)

    print("✓ removed Frameworks/Libmihomo.xcframework, ProxyCat.xcodeproj, build/")
