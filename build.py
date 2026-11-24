#!/usr/bin/env python3
"""ProxyCat build entry point.

Run ``./build.py --help`` for the command list. The implementation lives
in ``tools/proxycat_build`` so individual phases (mihomo, xcodegen,
assets, xcodebuild) can be imported and tested independently.
"""

from __future__ import annotations

from tools.proxycat_build.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
