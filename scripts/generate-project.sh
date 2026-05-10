#!/usr/bin/env bash
# Generates ProxyCat.xcodeproj via xcodegen.
#
# Resolves marketing version (from VERSION) and build number
# (from `git rev-list --count HEAD`) and exports them as the env vars
# that project.yml interpolates via ${PROXYCAT_MARKETING_VERSION} and
# ${PROXYCAT_BUILD_NUMBER}. It also exports XCODE_DEVELOPMENT_TEAM so
# project.yml can fill DEVELOPMENT_TEAM without hardcoding a personal
# Apple Team ID. Override any of these by exporting them before invoking
# the script.
#
# Usage:
#   ./scripts/generate-project.sh                   # normal
#   XCODE_DEVELOPMENT_TEAM=ABCDE12345 make project  # fill signing team
#   PROXYCAT_BUILD_NUMBER=1000 ./scripts/...        # pin build number
#   make project                                    # canonical entry point

set -euo pipefail

cd "$(dirname "$0")/.."

XCODEGEN_BIN="${XCODEGEN:-xcodegen}"

if ! command -v "$XCODEGEN_BIN" >/dev/null 2>&1; then
  echo "error: xcodegen not found: $XCODEGEN_BIN" >&2
  echo "       install: brew install xcodegen" >&2
  exit 127
fi

: "${PROXYCAT_MARKETING_VERSION:=$(cat VERSION 2>/dev/null || echo 0.1.0)}"
: "${PROXYCAT_BUILD_NUMBER:=$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
: "${XCODE_DEVELOPMENT_TEAM:=}"
export PROXYCAT_MARKETING_VERSION PROXYCAT_BUILD_NUMBER XCODE_DEVELOPMENT_TEAM

echo "==> xcodegen (v${PROXYCAT_MARKETING_VERSION} build ${PROXYCAT_BUILD_NUMBER})"
if [[ -n "${XCODE_DEVELOPMENT_TEAM}" ]]; then
  echo "==> development team ${XCODE_DEVELOPMENT_TEAM}"
else
  echo "==> development team unset (set XCODE_DEVELOPMENT_TEAM to auto-fill signing)"
fi
exec "$XCODEGEN_BIN" generate "$@"
