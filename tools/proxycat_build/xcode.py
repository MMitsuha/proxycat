"""xcodebuild wrappers for device and simulator builds."""

from __future__ import annotations

import os

from .config import (
    DEFAULT_CONFIGURATION,
    DEFAULT_DEVICE_DESTINATION,
    DEFAULT_SCHEME,
    DEFAULT_SIM_DESTINATION,
    DEFAULT_XCODEBUILD,
    ROOT,
    BuildError,
)
from .process import require, run
from . import project


def _configuration(value: str | None) -> str:
    return value or os.environ.get("CONFIGURATION") or DEFAULT_CONFIGURATION


def _scheme(value: str | None) -> str:
    return value or os.environ.get("SCHEME") or DEFAULT_SCHEME


def _xcodebuild() -> str:
    return require(
        os.environ.get("XCODEBUILD", DEFAULT_XCODEBUILD),
        hint="install Xcode and run xcode-select --install",
    )


def build_device(
    *,
    configuration: str | None = None,
    scheme: str | None = None,
    destination: str | None = None,
    team: str | None = None,
) -> None:
    resolved_team = team or os.environ.get("XCODE_DEVELOPMENT_TEAM", "")
    if not resolved_team:
        raise BuildError(
            "XCODE_DEVELOPMENT_TEAM is required for a device build\n"
            "  usage: python3 build.py build --team ABCDE12345",
            exit_code=2,
        )

    project.generate(team=resolved_team)
    xcodebuild = _xcodebuild()
    destination = (
        destination or os.environ.get("DEVICE_DESTINATION") or DEFAULT_DEVICE_DESTINATION
    )
    run(
        [
            xcodebuild,
            "-project",
            "ProxyCat.xcodeproj",
            "-scheme",
            _scheme(scheme),
            "-configuration",
            _configuration(configuration),
            "-destination",
            destination,
            "build",
        ],
        cwd=ROOT,
    )


def build_simulator(
    *,
    configuration: str | None = None,
    scheme: str | None = None,
    destination: str | None = None,
) -> None:
    project.generate()
    xcodebuild = _xcodebuild()
    destination = (
        destination or os.environ.get("SIM_DESTINATION") or DEFAULT_SIM_DESTINATION
    )
    run(
        [
            xcodebuild,
            "-project",
            "ProxyCat.xcodeproj",
            "-scheme",
            _scheme(scheme),
            "-configuration",
            _configuration(configuration),
            "-sdk",
            "iphonesimulator",
            "-destination",
            destination,
            'CODE_SIGN_IDENTITY=',
            "CODE_SIGNING_REQUIRED=NO",
            "CODE_SIGNING_ALLOWED=NO",
            "build",
        ],
        cwd=ROOT,
    )
