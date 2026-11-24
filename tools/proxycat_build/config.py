"""Paths, defaults, and the shared build error type."""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

LIBMIHOMO_DIR = ROOT / "libmihomo"
MIHOMO_DIR = ROOT / "mihomo"
FRAMEWORKS_DIR = ROOT / "Frameworks"
XCFRAMEWORK_PATH = FRAMEWORKS_DIR / "Libmihomo.xcframework"
XCODEPROJ_PATH = ROOT / "ProxyCat.xcodeproj"
VERSION_FILE = ROOT / "VERSION"
BUNDLED_ASSETS_DIR = ROOT / "BundledAssets"
GEO_DIR = BUNDLED_ASSETS_DIR / "geo"
UI_DIR = BUNDLED_ASSETS_DIR / "ui"
BUILD_DIR = ROOT / "build"

DEFAULT_GEO_BASE = (
    "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/release"
)
# `<remote>[:<local>]` — the release branch ships GeoLite2-ASN.mmdb while
# mihomo's default geox-url points at ASN.mmdb in the home directory.
GEO_FILES: tuple[tuple[str, str], ...] = (
    ("geoip.dat", "geoip.dat"),
    ("geosite.dat", "geosite.dat"),
    ("country.mmdb", "country.mmdb"),
    ("GeoLite2-ASN.mmdb", "ASN.mmdb"),
)
DEFAULT_UI_TARBALL = (
    "https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz"
)

BUILD_TAGS = "with_gvisor with_low_memory"
DEFAULT_GOGARBLE = (
    "github.com/proxycat,github.com/metacubex/mihomo,github.com/metacubex/sing*"
)

DEFAULT_SCHEME = "Pcat"
DEFAULT_CONFIGURATION = "Debug"
DEFAULT_DEVICE_DESTINATION = "generic/platform=iOS"
DEFAULT_SIM_DESTINATION = "generic/platform=iOS Simulator"

DEFAULT_XCODEGEN = "xcodegen"
DEFAULT_XCODEBUILD = "xcodebuild"
DEFAULT_GOMOBILE = "gomobile"


class BuildError(RuntimeError):
    """A user-actionable build failure."""

    def __init__(self, message: str, *, exit_code: int = 1) -> None:
        super().__init__(message)
        self.exit_code = exit_code
